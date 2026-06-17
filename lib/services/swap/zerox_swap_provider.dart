import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' show min;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/services/swap/swap_provider.dart';
import 'package:ibiti_guardian/models/intent_data.dart';

// ─── 0x API Configuration ────────────────────────────────────────────────────

/// Loads the 0x API key from `secrets/0x.json`.
class _ZeroXConfig {
  static _ZeroXConfig? _cache;

  final String apiKey;

  _ZeroXConfig._(this.apiKey);

  static Future<_ZeroXConfig> load() async {
    if (_cache != null) return _cache!;
    try {
      final raw = await rootBundle.loadString('secrets/0x.json');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _cache = _ZeroXConfig._(json['ZEROX_API_KEY']?.toString() ?? '');
    } catch (_) {
      _cache = _ZeroXConfig._('');
    }
    return _cache!;
  }
}

// ─── Chain Mapping ────────────────────────────────────────────────────────────

const _supportedChains = <int, String>{
  1: 'ethereum',
  56: 'bsc',
  137: 'polygon',
  42161: 'arbitrum',
  10: 'optimism',
  8453: 'base',
  43114: 'avalanche',
};

// ─── ZeroXSwapProvider ───────────────────────────────────────────────────────

/// Phase 8 production swap provider using the 0x Swap API v2 (AllowanceHolder flow).
///
/// Endpoint: GET /swap/allowance-holder/quote
/// Docs: https://0x.org/docs/api#tag/Swap/operation/swap::allowanceHolder::getQuote
///
/// This flow requires standard ERC-20 `approve(allowanceTarget, amount)` before execution.
/// Permit2 double-signature flow is intentionally deferred to Phase 9+.
class ZeroXSwapProvider implements SwapProvider {
  ZeroXSwapProvider._();
  static final ZeroXSwapProvider instance = ZeroXSwapProvider._();

  static const String _baseUrl = 'https://api.0x.org';
  static const Duration _timeout = Duration(seconds: 12);

  @override
  Future<QuoteResponse> getQuote(QuoteRequest request) async {
    // ── 1. Chain validation ──────────────────────────────────────────────────
    if (!_supportedChains.containsKey(request.chainId)) {
      throw UnsupportedChainException(request.chainId);
    }

    // ── 2. Slippage cap enforcement (never trust caller) ─────────────────────
    final clampedSlippageBps =
        request.slippageBps.clamp(0, SwapSlippagePolicy.maxBps);
    // Convert bps to 0x percentage string: 200 bps → "0.02"
    final slippageStr = (clampedSlippageBps / 10000).toStringAsFixed(4);

    // ── 3. Build query parameters ─────────────────────────────────────────────
    final params = {
      'chainId': request.chainId.toString(),
      'sellToken': request.sourceTokenAddress,
      'buyToken': request.targetTokenAddress,
      if (request.amountMode == AmountMode.exactIn)
        'sellAmount': request.amount.toString()
      else
        'buyAmount': request.amount.toString(),
      'slippagePercentage': slippageStr,
      'taker': request.userAddress,
    };

    // ── Debug log (never logs API key) ───────────────────────────────────────
    if (kDebugMode) print('[0x] GET /swap/allowance-holder/quote');
    if (kDebugMode) print('[0x]   chainId      = ${params['chainId']}');
    if (kDebugMode) print('[0x]   sellToken    = ${params['sellToken']}');
    if (kDebugMode) print('[0x]   buyToken     = ${params['buyToken']}');
    if (kDebugMode)
      print('[0x]   sellAmount   = ${params['sellAmount'] ?? 'N/A'}');
    if (kDebugMode)
      print('[0x]   buyAmount    = ${params['buyAmount'] ?? 'N/A'}');
    if (kDebugMode)
      print('[0x]   slippage     = $slippageStr ($clampedSlippageBps bps)');
    if (kDebugMode) print('[0x]   taker        = ${params['taker']}');

    // ── 4. Load API key & fire the request ────────────────────────────────────
    final config = await _ZeroXConfig.load();
    final uri = Uri.parse('$_baseUrl/swap/allowance-holder/quote')
        .replace(queryParameters: params);

    // ── Hard debug: safe URL (strip API key from logs) ──────────────────────
    final safeUrl = uri.replace(queryParameters: params).toString();
    if (kDebugMode) print('[0x] sending request to $safeUrl');
    if (kDebugMode) print('[0x] apiKey present = ${config.apiKey.isNotEmpty}');

    final http.Response response;
    try {
      response = await http.get(
        uri,
        headers: {
          '0x-api-key': config.apiKey,
          '0x-version': 'v2',
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
      ).timeout(_timeout);
    } on TimeoutException {
      if (kDebugMode)
        print('[0x] ⏱ quote timeout after ${_timeout.inSeconds}s');
      throw Exception('0x quote timeout after ${_timeout.inSeconds} seconds');
    } catch (e) {
      if (kDebugMode) print('[0x] ❌ quote request failed: $e');
      rethrow;
    }

    // ── Hard debug: response received ───────────────────────────────────────
    if (kDebugMode) print('[0x] response status = ${response.statusCode}');
    if (kDebugMode)
      print('[0x] response body head = '
          '${response.body.substring(0, min(800, response.body.length))}');

    // ── 5. Parse & classify errors ───────────────────────────────────────────
    if (response.statusCode != 200) {
      final body = _tryDecodeBody(response.body);
      final reason = body?['reason']?.toString() ??
          body?['code']?.toString() ??
          'HTTP ${response.statusCode}';
      final validationErrors = body?['validationErrors'] as List? ?? [];

      // Route not found / no liquidity
      if (response.statusCode == 400 &&
          (reason.contains('NO_ROUTES') ||
              reason.contains('NO_LIQUIDITY') ||
              validationErrors.any((e) => e.toString().contains('NO_ROUTE')))) {
        throw RouteNotFoundException(
            'No route found for this pair on chainId=${request.chainId}');
      }

      // Illiquid token
      if (response.statusCode == 400 &&
          (reason.contains('INSUFFICIENT_ASSET_LIQUIDITY') ||
              reason.contains('SAMPLER_FAILED'))) {
        throw const IlliquidTokenException(
            'Token pair is too illiquid for a quote on this chain.');
      }

      // Generic error
      if (kDebugMode) print('[0x] ❌ API error: $reason');
      throw Exception('0x API error [$reason]: ${response.body}');
    }

    // ── 6. Map response to QuoteResponse ─────────────────────────────────────
    if (kDebugMode) print('[0x] ✅ parsing successful quote response...');
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final mapped = _mapResponse(json, request, clampedSlippageBps);
    if (kDebugMode)
      print('[0x] ✅ quote mapped: provider=${mapped.providerName} '
          'approval=${mapped.approvalNeeded} '
          'expectedOut=${mapped.expectedOutputAmount}');
    return mapped;
  }

  // ─── Private Helpers ────────────────────────────────────────────────────────

  QuoteResponse _mapResponse(
    Map<String, dynamic> json,
    QuoteRequest request,
    int actualSlippageBps,
  ) {
    // 0x v2 AllowanceHolder response shape:
    // {
    //   "buyAmount": "...",
    //   "sellAmount": "...",
    //   "transaction": { "to": "...", "data": "...", "value": "...", "gas": "...", "gasPrice": "..." },
    //   "permit2": { ... },          // ignored — AllowanceHolder flow doesn't need permit2
    //   "issues": {
    //     "allowance": { "actual": "0", "spender": "0x..." },   // v2: singular object
    //     // OR (v1 legacy):
    //     "allowances": [{ "spender": "...", "token": "...", "actual": "...", "minimum": "..." }],
    //   },
    //   "route": { "fills": [ { "from": "...", "to": "...", "source": "...", "proportionBps": "..." } ] },
    //   "minBuyAmount": "...",
    //   "priceImpact": "...",        // decimal string, e.g. "0.0015" = 0.15%
    //   ...
    // }

    final tx = (json['transaction'] as Map<String, dynamic>?) ?? {};
    final issues = (json['issues'] as Map<String, dynamic>?) ?? {};

    // ── Allowance detection (v2 singular + v1 plural) ──────────────────────
    // v2 returns: "allowance": { "actual": "0", "spender": "0x..." }
    // v1 returns: "allowances": [{ "spender": "...", ... }]
    // We normalise both into a single spender + approvalNeeded flag.
    final allowanceV2 = issues['allowance'] as Map<String, dynamic>?;
    final allowancesV1 = (issues['allowances'] as List<dynamic>?) ?? [];

    bool approvalNeeded;
    String? issueSpender;

    if (allowanceV2 != null) {
      // v2: object with "actual" and "spender"
      final actualStr = allowanceV2['actual']?.toString() ?? '0';
      final actual = _parseBigInt(actualStr);
      issueSpender = allowanceV2['spender']?.toString();
      approvalNeeded = actual < request.amount;
      if (kDebugMode)
        print('[0x] v2 allowance: actual=$actual needed=${request.amount} '
            'spender=$issueSpender → approvalNeeded=$approvalNeeded');
    } else if (allowancesV1.isNotEmpty) {
      // v1: array of objects with "spender"
      issueSpender =
          (allowancesV1.first as Map<String, dynamic>)['spender']?.toString();
      approvalNeeded = true;
      if (kDebugMode)
        print('[0x] v1 allowances array present → approvalNeeded=true '
            'spender=$issueSpender');
    } else {
      approvalNeeded = false;
      if (kDebugMode) print('[0x] no allowance issues → approvalNeeded=false');
    }

    // Router / tx.to
    final routerAddress = tx['to']?.toString() ?? '';
    if (routerAddress.isEmpty) throw Exception('0x returned empty tx.to');

    // AllowanceTarget: from issues spender, or fall back to routerAddress
    final String allowanceTarget = issueSpender ?? routerAddress;

    // Calldata
    final calldataHex = tx['data']?.toString() ?? '0x';
    final calldata = _hexToBytes(calldataHex);

    // Native value (eth/bnb attached to tx)
    final valueStr = tx['value']?.toString() ?? '0';
    final nativeValue = _parseBigInt(valueStr);

    // Gas estimate
    final gasStr = tx['gas']?.toString() ?? '0';
    final gasEstimate = _parseBigInt(gasStr);

    // Expected output
    final buyAmountStr = json['buyAmount']?.toString() ?? '0';
    final expectedOut = _parseBigInt(buyAmountStr);

    // Minimum output (either from field or compute from slippage)
    final minBuyStr = json['minBuyAmount']?.toString();
    BigInt minOutput;
    if (minBuyStr != null && minBuyStr.isNotEmpty) {
      minOutput = _parseBigInt(minBuyStr);
    } else {
      // Compute: expectedOut * (10000 - slippageBps) / 10000
      minOutput = expectedOut *
          BigInt.from(10000 - actualSlippageBps) ~/
          BigInt.from(10000);
    }

    // Price impact
    final priceImpactRaw = json['priceImpact']?.toString() ?? '0';
    final priceImpactPct = (double.tryParse(priceImpactRaw) ?? 0.0) * 100;

    // Route summary
    final fills = (json['route']?['fills'] as List<dynamic>?) ?? [];
    final routeSummary = fills.isEmpty
        ? '${request.sourceTokenAddress.substring(0, 6)}... → ${request.targetTokenAddress.substring(0, 6)}...'
        : fills
            .map((f) => (f as Map<String, dynamic>)['source']?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toSet()
            .join(' + ');

    return QuoteResponse(
      expectedOutputAmount: expectedOut,
      minOutputAmount: minOutput,
      routerAddress: routerAddress,
      allowanceTarget: allowanceTarget,
      calldata: calldata,
      nativeValue: nativeValue,
      priceImpactPct: priceImpactPct,
      gasEstimate: gasEstimate,
      approvalNeeded: approvalNeeded,
      providerName: '0x AllowanceHolder',
      quoteTimestamp: DateTime.now().toUtc(),
      routeSummary: routeSummary,
      extraSummary: {
        'slippageBps': actualSlippageBps,
        'chainId': request.chainId,
        'takerAddress': request.userAddress,
      },
    );
  }

  Map<String, dynamic>? _tryDecodeBody(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Uint8List _hexToBytes(String hex) {
    final clean = hex.startsWith('0x') ? hex.substring(2) : hex;
    if (clean.isEmpty) return Uint8List(0);
    final bytes = <int>[];
    for (var i = 0; i < clean.length; i += 2) {
      bytes.add(int.parse(clean.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  BigInt _parseBigInt(String s) {
    try {
      return BigInt.parse(s);
    } catch (_) {
      return BigInt.zero;
    }
  }
}
