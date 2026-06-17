import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/services/swap/swap_provider.dart';

// ─── Jupiter API Key Configuration ────────────────────────────────────────────

/// Loads the Jupiter API key from `secrets/jupiter.json`.
///
/// If the key is missing or empty, [JupiterSwapProvider.getQuote] will throw
/// [UnsupportedChainException] with a readable error. There is NO fallback to
/// deprecated v6 endpoints.
class _JupiterConfig {
  static _JupiterConfig? _cache;

  final String apiKey;

  _JupiterConfig._(this.apiKey);

  static Future<_JupiterConfig> load() async {
    if (_cache != null) return _cache!;
    try {
      final raw = await rootBundle.loadString('secrets/jupiter.json');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _cache = _JupiterConfig._(json['JUPITER_API_KEY']?.toString() ?? '');
    } catch (_) {
      _cache = _JupiterConfig._('');
    }
    return _cache!;
  }

  bool get isConfigured => apiKey.isNotEmpty;
}

// ─── Jupiter Swap Provider ───────────────────────────────────────────────────

/// Jupiter Swap API V2 provider for Solana token swaps.
///
/// Uses the Meta-Aggregator flow:
///   1. GET  /swap/v2/order → base64 transaction + requestId
///   2. Client signs the transaction via Privy
///   3. POST /swap/v2/execute → Jupiter landing + txId
///
/// Requires `x-api-key` from `secrets/jupiter.json`.
/// Does NOT fall back to deprecated v6 (`quote-api.jup.ag/v6`).
class JupiterSwapProvider implements SwapProvider {
  JupiterSwapProvider._();
  static final JupiterSwapProvider instance = JupiterSwapProvider._();

  static const String _baseUrl = 'https://api.jup.ag';
  static const Duration _timeout = Duration(seconds: 15);

  /// Well-known SOL wrapped mint (used by Jupiter for native SOL).
  static const String wrappedSolMint =
      'So11111111111111111111111111111111111111112';

  /// Fetches a swap order from Jupiter V2.
  ///
  /// The returned [QuoteResponse] stores:
  /// - `calldata` — raw bytes of the base64 serialized VersionedTransaction
  /// - `routerAddress` — `'jupiter_v2'` marker (not an on-chain contract)
  /// - `extraSummary['requestId']` — needed for `/swap/v2/execute`
  /// - `extraSummary['lastValidBlockHeight']` — for tx validity checking
  /// - `approvalNeeded` — always false (Solana has no ERC-20 approve flow)
  @override
  Future<QuoteResponse> getQuote(QuoteRequest request) async {
    // ── 1. API key validation ─────────────────────────────────────────────
    final config = await _JupiterConfig.load();
    if (!config.isConfigured) {
      throw const JupiterApiKeyMissingException();
    }

    // ── 2. Slippage cap ───────────────────────────────────────────────────
    final clampedSlippageBps =
        request.slippageBps.clamp(0, SwapSlippagePolicy.maxBps);

    // ── 3. Build query parameters ─────────────────────────────────────────
    // Normalize native SOL: Jupiter requires wrapped SOL mint, not 'native'
    const wsolMint = 'So11111111111111111111111111111111111111112';
    String normalizeMint(String addr) {
      final lower = addr.trim().toLowerCase();
      if (lower.isEmpty || lower == 'native' || lower == 'sol') return wsolMint;
      return addr;
    }

    final params = <String, String>{
      'inputMint': normalizeMint(request.sourceTokenAddress),
      'outputMint': normalizeMint(request.targetTokenAddress),
      'amount': request.amount.toString(),
      'taker': request.userAddress,
      'slippageBps': clampedSlippageBps.toString(),
    };

    // ── 4. Call GET /swap/v2/order ─────────────────────────────────────────
    final uri =
        Uri.parse('$_baseUrl/swap/v2/order').replace(queryParameters: params);

    if (kDebugMode) print('[Jupiter] GET /swap/v2/order');
    if (kDebugMode) print('[Jupiter]   inputMint  = ${params['inputMint']}');
    if (kDebugMode) print('[Jupiter]   outputMint = ${params['outputMint']}');
    if (kDebugMode) print('[Jupiter]   amount     = ${params['amount']}');
    if (kDebugMode) print('[Jupiter]   taker      = ${params['taker']}');
    if (kDebugMode) print('[Jupiter]   slippage   = $clampedSlippageBps bps');
    if (kDebugMode) print('[Jupiter] sending request...');

    final response = await http.get(
      uri,
      headers: {
        'x-api-key': config.apiKey,
        'Accept': 'application/json',
      },
    ).timeout(_timeout);

    if (kDebugMode) print('[Jupiter] response status = ${response.statusCode}');

    // ── 5. Handle errors ──────────────────────────────────────────────────
    if (response.statusCode != 200) {
      if (kDebugMode)
        print(
            '[Jupiter] ❌ error body = ${response.body.length > 500 ? response.body.substring(0, 500) : response.body}');
      _handleApiError(response, request);
    }

    // ── 6. Parse response → QuoteResponse ─────────────────────────────────
    if (kDebugMode)
      print('[Jupiter] response body length = ${response.body.length}');
    try {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (kDebugMode) print('[Jupiter] response keys = ${json.keys.toList()}');
      // Log first 300 chars for debugging field structure
      final preview = response.body.length > 300
          ? response.body.substring(0, 300)
          : response.body;
      if (kDebugMode) print('[Jupiter] body preview = $preview');
      final result = _mapOrderResponse(json, request, clampedSlippageBps);
      if (kDebugMode)
        print('[Jupiter] Quote OK: expectedOut=${result.expectedOutputAmount} '
            'minOut=${result.minOutputAmount} '
            'requestId=${result.extraSummary['requestId'] ?? 'N/A'}');
      return result;
    } catch (e, st) {
      if (kDebugMode) print('[Jupiter] ❌ Parse/map failed: $e');
      if (kDebugMode)
        print(
            '[Jupiter] stackTrace: ${st.toString().split('\n').take(5).join('\n')}');
      rethrow;
    }
  }

  /// Submits a signed transaction to Jupiter for managed landing.
  ///
  /// Called from [SolanaExecutionAdapter.executeJupiterSwap].
  /// Returns the on-chain transaction signature (txId).
  Future<String> executeSignedSwap({
    required String requestId,
    required String signedTransactionBase64,
  }) async {
    final config = await _JupiterConfig.load();
    if (!config.isConfigured) {
      throw const JupiterApiKeyMissingException();
    }

    if (kDebugMode) print('[Jupiter] POST /swap/v2/execute');
    if (kDebugMode) print('[Jupiter]   requestId = $requestId');
    if (kDebugMode)
      print('[Jupiter]   signedTx length = ${signedTransactionBase64.length}');

    final response = await http
        .post(
          Uri.parse('$_baseUrl/swap/v2/execute'),
          headers: {
            'x-api-key': config.apiKey,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'requestId': requestId,
            'signedTransaction': signedTransactionBase64,
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (kDebugMode) print('[Jupiter] execute status = ${response.statusCode}');

    if (response.statusCode != 200) {
      final body = _tryDecodeBody(response.body);
      final error = body?['error']?.toString() ??
          body?['errorMessage']?.toString() ??
          'HTTP ${response.statusCode}';
      if (kDebugMode) print('[Jupiter] ❌ execute failed: $error');
      throw Exception('[Jupiter] Execute failed: $error');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final txId = json['txid']?.toString() ??
        json['transactionId']?.toString() ??
        json['signature']?.toString();

    if (txId == null || txId.isEmpty) {
      throw Exception(
          '[Jupiter] Execute succeeded but no txId in response: ${response.body}');
    }

    if (kDebugMode) print('[Jupiter] ✅ swap tx = $txId');
    return txId;
  }

  // ─── Private Helpers ──────────────────────────────────────────────────────

  QuoteResponse _mapOrderResponse(
    Map<String, dynamic> json,
    QuoteRequest request,
    int actualSlippageBps,
  ) {
    // Transaction bytes (base64 serialized VersionedTransaction)
    // Jupiter V2 uses 'swapTransaction'; fallback to 'transaction' for compat.
    final transactionBase64 = json['swapTransaction']?.toString() ??
        json['transaction']?.toString() ??
        '';

    // If transaction is empty, Jupiter couldn't build it (e.g. 0 SOL balance).
    // We still allow the quote for preview; execution will be gated separately.
    final Uint8List txBytes;
    if (transactionBase64.isNotEmpty) {
      txBytes = Uint8List.fromList(base64Decode(transactionBase64));
    } else {
      final errorMsg = json['errorMessage']?.toString() ?? '';
      if (kDebugMode)
        print('[Jupiter] ⚠️ transaction is empty (preview-only quote). '
            'error=$errorMsg');
      txBytes = Uint8List(0);
    }

    // Amounts
    final inAmountStr = json['inAmount']?.toString() ?? '0';
    final outAmountStr = json['outAmount']?.toString() ?? '0';
    final expectedOut = BigInt.tryParse(outAmountStr) ?? BigInt.zero;

    if (expectedOut == BigInt.zero) {
      throw RouteNotFoundException(
          'Jupiter returned zero output for this pair.');
    }

    // Minimum output: compute from slippage (Jupiter doesn't always return it)
    final minOutput = expectedOut *
        BigInt.from(10000 - actualSlippageBps) ~/
        BigInt.from(10000);

    // Request ID (for /execute call)
    final requestId = json['requestId']?.toString() ?? '';

    // Route summary
    final routePlan = (json['routePlan'] as List<dynamic>?) ?? [];
    final routeSummary = routePlan.isEmpty
        ? '${_shortMint(request.sourceTokenAddress)} → ${_shortMint(request.targetTokenAddress)}'
        : routePlan
            .map((r) {
              final info = (r as Map<String, dynamic>)['swapInfo']
                      as Map<String, dynamic>? ??
                  {};
              return info['label']?.toString() ?? '';
            })
            .where((s) => s.isNotEmpty)
            .toSet()
            .join(' + ');

    // Last valid block height
    final lastValidBlockHeight = json['lastValidBlockHeight']?.toString() ?? '';

    return QuoteResponse(
      expectedOutputAmount: expectedOut,
      minOutputAmount: minOutput,
      routerAddress: 'jupiter_v2',
      allowanceTarget: '', // Solana: no ERC-20 approve
      calldata: txBytes,
      nativeValue: BigInt.zero, // Not applicable on Solana
      priceImpactPct: _parsePriceImpact(json),
      gasEstimate: BigInt.from(5000), // Solana base fee in lamports
      approvalNeeded: false, // Solana: no approve step
      providerName: 'Jupiter V2',
      quoteTimestamp: DateTime.now().toUtc(),
      routeSummary: routeSummary,
      extraSummary: {
        'requestId': requestId,
        'lastValidBlockHeight': lastValidBlockHeight,
        'inAmount': inAmountStr,
        'outAmount': outAmountStr,
        'slippageBps': actualSlippageBps,
        'transactionBase64': transactionBase64,
      },
    );
  }

  double _parsePriceImpact(Map<String, dynamic> json) {
    final raw = json['priceImpact']?.toString() ??
        json['priceImpactPct']?.toString() ??
        '0';
    return (double.tryParse(raw) ?? 0.0).abs();
  }

  void _handleApiError(http.Response response, QuoteRequest request) {
    final body = _tryDecodeBody(response.body);
    final error = body?['error']?.toString() ??
        body?['errorCode']?.toString() ??
        body?['errorMessage']?.toString() ??
        'HTTP ${response.statusCode}';

    if (response.statusCode == 400 &&
        (error.contains('NO_ROUTE') ||
            error.contains('ROUTE_NOT_FOUND') ||
            error.contains('no route'))) {
      throw RouteNotFoundException(
        'No Jupiter route found for '
        '${_shortMint(request.sourceTokenAddress)} → '
        '${_shortMint(request.targetTokenAddress)}',
      );
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw Exception(
          '[Jupiter] Authentication failed. Check your API key. ($error)');
    }

    if (response.statusCode == 429) {
      throw Exception('[Jupiter] Rate limit exceeded. Try again shortly.');
    }

    throw Exception(
        '[Jupiter] API error: $error (HTTP ${response.statusCode})');
  }

  Map<String, dynamic>? _tryDecodeBody(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  String _shortMint(String mint) {
    if (mint.length < 12) return mint;
    return '${mint.substring(0, 4)}...${mint.substring(mint.length - 4)}';
  }
}

// ─── Jupiter-specific Exceptions ─────────────────────────────────────────────

/// Thrown when `secrets/jupiter.json` is missing or has an empty API key.
class JupiterApiKeyMissingException implements Exception {
  const JupiterApiKeyMissingException();

  @override
  String toString() =>
      'JupiterApiKeyMissingException: Jupiter API key is not configured. '
      'Add your key to secrets/jupiter.json';
}
