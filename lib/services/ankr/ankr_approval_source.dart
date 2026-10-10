import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/models/approval.dart';
import 'package:ibiti_guardian/services/ankr/ankr_config_service.dart';
import 'package:ibiti_guardian/services/security/approval_source.dart';
import 'package:ibiti_guardian/services/spender_intelligence_service.dart';
import 'package:ibiti_guardian/services/token_metadata_cache.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

/// Discover owner/token/spender pairs from all indexed Approval events, then
/// read allowance(owner, spender) at a fixed, fresh chain block. Events alone
/// are not current allowances (transferFrom may consume an allowance silently).
/// Recent RPC logs overlap the indexed tip to cover ordinary indexer lag.
/// No signer, transaction, approval/revoke, UI or Policy mutation is used here.
class AnkrApprovalSource implements ApprovalSource {
  AnkrApprovalSource(
      {http.Client Function()? clientFactory,
      AnkrConfigService? config,
      DateTime Function()? now,
      Duration requestTimeout = const Duration(seconds: 20),
      Duration scanBudget = const Duration(seconds: 60),
      Duration retryDelay = const Duration(milliseconds: 500)})
      : _clientFactory = clientFactory ?? http.Client.new,
        _config = config ?? AnkrConfigService.instance,
        _now = now ?? DateTime.now,
        _requestTimeout = requestTimeout,
        _scanBudget = scanBudget,
        _retryDelay = retryDelay;

  static const _log = GuardianLogger('ApprovalRead');
  static const approvalTopic =
      '0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925';
  static const _addressPattern = r'^0x[0-9a-fA-F]{40}$';
  static const _wordPattern = r'^0x[0-9a-fA-F]{64}$';
  static const _chains = {
    1: 'eth',
    56: 'bsc',
    137: 'polygon',
    42161: 'arbitrum',
    10: 'optimism',
    8453: 'base',
    100: 'gnosis'
  };
  static const _maxPages = 40;
  static const _maxPairs = 256;
  static const _maxIndexerLag = 512;
  static const _overlap = 128;
  static const _maxBlockAge = Duration(minutes: 2);
  static const _maxAttempts = 3;
  // Only documented transient gateway conditions; invalid params/auth/plan and
  // node contract errors are never retried or accepted as empty approvals.
  static const _transientRpcCodes = {
    -32603,
    -32055,
    -32056,
    -32057,
    -32059,
    -32061,
    -32063,
    -32064,
    -32065,
    -32067,
    -32068,
    -32069,
    -32070,
    -32071,
    -32072,
    -32073,
    -32076,
    -32077,
    -32090,
  };

  final http.Client Function() _clientFactory;
  final AnkrConfigService _config;
  final DateTime Function() _now;
  // Injectable durations for deterministic retry/deadline tests. All attempts
  // and backoff share one total deadline, not a fresh budget per request.
  final Duration _requestTimeout;
  final Duration _scanBudget;
  final Duration _retryDelay;

  @override
  Future<List<ApprovalData>> fetch(
    String wallet, {
    required int chainId,
    String? targetTokenAddress,
  }) async {
    if (!RegExp(_addressPattern).hasMatch(wallet) ||
        (targetTokenAddress != null &&
            !RegExp(_addressPattern).hasMatch(targetTokenAddress))) {
      throw const ApprovalSourceException('invalid_address');
    }
    final chain = _chains[chainId];
    if (chain == null) throw const ApprovalSourceException('unsupported_chain');
    await _config.ensureLoaded();
    if (!_config.isConfigured) {
      throw const ApprovalSourceException('missing_key');
    }
    var client = _clientFactory();
    final watch = Stopwatch()..start();
    var requestId = 0;
    final rpcUri = Uri.parse('https://rpc.ankr.com/$chain/${_config.apiKey}');
    final indexUri =
        Uri.parse('https://rpc.ankr.com/multichain/${_config.apiKey}');

    Future<dynamic> rpc(Uri uri, String method, dynamic params) async {
      for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
        final remaining = _scanBudget - watch.elapsed;
        if (remaining <= Duration.zero) {
          _log.w('Read failed method=$method code=scan_timeout');
          throw const ApprovalSourceException('scan_timeout');
        }
        var delay = _retryDelay * attempt;
        var resetClient = false;
        late ApprovalSourceException failure;
        try {
          final id = ++requestId;
          final response = await client
              .post(uri,
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({
                    'jsonrpc': '2.0',
                    'id': id,
                    'method': method,
                    'params': params
                  }))
              .timeout(
                  remaining < _requestTimeout ? remaining : _requestTimeout);
          if (watch.elapsed >= _scanBudget) {
            throw const ApprovalSourceException('scan_timeout');
          }
          if (response.statusCode != 200) {
            // Respect a provider's requested pause without extending the total
            // deadline. Never print response headers/body or the endpoint URI.
            final seconds = int.tryParse(response.headers['retry-after'] ?? '');
            if (seconds != null && seconds > 0) {
              final requestedDelay = Duration(seconds: seconds);
              if (requestedDelay > delay) delay = requestedDelay;
            }
            throw ApprovalSourceException('http_${response.statusCode}');
          }
          final decoded = jsonDecode(response.body);
          if (decoded is! Map ||
              decoded['id'] != id ||
              decoded['jsonrpc'] != '2.0') {
            throw const ApprovalSourceException('invalid_rpc_response');
          }
          if (decoded['error'] != null) {
            final error = decoded['error'];
            if (method == 'eth_call' && error is Map && error['code'] == 3) {
              throw const ApprovalSourceException('contract_reverted');
            }
            if (error is Map && _transientRpcCodes.contains(error['code'])) {
              throw const ApprovalSourceException('rpc_transient');
            }
            throw const ApprovalSourceException('rpc_error');
          }
          if (!decoded.containsKey('result') || decoded['result'] == null) {
            throw const ApprovalSourceException('missing_result');
          }
          return decoded['result'];
        } on ApprovalSourceException catch (e) {
          failure = e;
        } on TimeoutException {
          failure = const ApprovalSourceException('scan_timeout');
          resetClient = true;
        } on http.ClientException {
          failure = const ApprovalSourceException('network_error');
          resetClient = true;
        } on FormatException {
          failure = const ApprovalSourceException('invalid_json');
        } catch (_) {
          failure = const ApprovalSourceException('network_error');
          // Unknown exceptions are not treated as transient transport failures.
          _log.w('Read failed method=$method code=${failure.code}');
          throw failure;
        }
        // Future.timeout alone does not stop HTTP. Close this scan's client
        // before replacing it so a timed-out socket/body cannot be reused.
        if (resetClient) client.close();
        final status = failure.code.startsWith('http_')
            ? int.tryParse(failure.code.substring(5))
            : null;
        final transient = resetClient ||
            failure.code == 'rpc_transient' ||
            status == 408 ||
            status == 429 ||
            (status != null && status >= 500 && status < 600);
        if (!transient || attempt == _maxAttempts) {
          _log.w(
              'Read failed method=$method code=${failure.code} attempt=$attempt');
          throw failure;
        }
        if (delay >= _scanBudget - watch.elapsed) {
          _log.w('Read failed method=$method code=scan_timeout');
          throw const ApprovalSourceException('scan_timeout');
        }
        _log.w(
            'Read retry method=$method code=${failure.code} attempt=$attempt');
        await Future<void>.delayed(delay);
        if (watch.elapsed >= _scanBudget) {
          _log.w('Read failed method=$method code=scan_timeout');
          throw const ApprovalSourceException('scan_timeout');
        }
        if (resetClient) client = _clientFactory();
      }
      throw const ApprovalSourceException('scan_timeout');
    }

    try {
      if (_quantity(await rpc(rpcUri, 'eth_chainId', [])) != chainId) {
        throw const ApprovalSourceException('chain_mismatch');
      }
      final head =
          _block(await rpc(rpcUri, 'eth_getBlockByNumber', ['latest', false]));
      _requireFresh(head.timestamp);
      final height = head.number;
      final blockTag = '0x${height.toRadixString(16)}';
      var indexEnd = height;
      final owner = wallet.toLowerCase();
      final ownerTopic = '0x${owner.substring(2).padLeft(64, '0')}';
      final pairs = <String, (String, String)>{};

      void absorb(dynamic logs,
          {required int from, required int to, required bool indexed}) {
        if (logs is! List) throw const ApprovalSourceException('invalid_logs');
        for (final row in logs) {
          if (row is! Map ||
              row['removed'] != false ||
              (indexed && row['blockchain'] != chain)) {
            throw const ApprovalSourceException('invalid_log');
          }
          final topics = row['topics'];
          if (topics is! List ||
              topics.length < 3 ||
              topics[0].toString().toLowerCase() != approvalTopic ||
              topics[1].toString().toLowerCase() != ownerTopic ||
              !RegExp(_wordPattern).hasMatch(topics[2].toString()) ||
              !topics[2].toString().startsWith('0x${'0' * 24}')) {
            throw const ApprovalSourceException('log_filter_mismatch');
          }
          final number = _quantity(row['blockNumber']);
          if (number < from || number > to) {
            throw const ApprovalSourceException('log_range_mismatch');
          }
          // ERC-721 shares the signature but has an indexed tokenId (4 topics).
          if (topics.length == 4) continue;
          final token = row['address'];
          if (topics.length != 3 ||
              token is! String ||
              !RegExp(_addressPattern).hasMatch(token) ||
              row['data'] is! String ||
              !RegExp(_wordPattern).hasMatch(row['data'])) {
            throw const ApprovalSourceException('invalid_erc20_log');
          }
          if (targetTokenAddress != null &&
              token.toLowerCase() != targetTokenAddress.toLowerCase()) {
            throw const ApprovalSourceException('log_token_mismatch');
          }
          final spender =
              '0x${topics[2].toString().substring(26)}'.toLowerCase();
          pairs['${token.toLowerCase()}_$spender'] =
              (token.toLowerCase(), spender);
          if (pairs.length > _maxPairs) {
            throw const ApprovalSourceException('pair_limit');
          }
        }
      }

      String? pageToken;
      final seenTokens = <String>{};
      for (var page = 0; page < _maxPages; page++) {
        final result = await rpc(indexUri, 'ankr_getLogs', {
          'blockchain': [chain],
          'fromBlock': 0,
          'toBlock': height,
          'topics': [
            [approvalTopic],
            [ownerTopic]
          ],
          'pageSize': 1000,
          'descOrder': false,
          'decodeLogs': false,
          'syncCheck': true,
          if (targetTokenAddress != null) 'address': [targetTokenAddress],
          if (pageToken != null) 'pageToken': pageToken,
        });
        if (result is! Map) {
          throw const ApprovalSourceException('invalid_log_page');
        }
        // Verify the synchronization metadata belonging to THIS logs page,
        // not a separate general statistics endpoint. Keep the oldest tip
        // across pages and cover its remaining tail via the actual RPC node.
        final sync = result['syncStatus'];
        if (sync is! Map || sync['status'] != 'synced') {
          throw const ApprovalSourceException('invalid_index_status');
        }
        final syncSeconds = _quantity(sync['timestamp']);
        if (syncSeconds > 253402300799) {
          throw const ApprovalSourceException('invalid_index_status');
        }
        _requireFresh(DateTime.fromMillisecondsSinceEpoch(syncSeconds * 1000,
            isUtc: true));
        final indexedHeight = _quantity(sync['blockNumber']);
        if (height - indexedHeight > _maxIndexerLag) {
          throw const ApprovalSourceException('indexer_stale');
        }
        indexEnd = math.min(indexEnd, indexedHeight);
        absorb(result['logs'], from: 0, to: height, indexed: true);
        final next = result['nextPageToken'];
        if (next != null && next is! String) {
          throw const ApprovalSourceException('invalid_cursor');
        }
        pageToken = next == null || next == '' ? null : next as String;
        if (pageToken == null) break;
        if (!seenTokens.add(pageToken)) {
          throw const ApprovalSourceException('cursor_cycle');
        }
      }
      if (pageToken != null) throw const ApprovalSourceException('page_limit');
      final tailFrom = math.max(0, indexEnd - _overlap);
      absorb(
          await rpc(rpcUri, 'eth_getLogs', [
            {
              'fromBlock': '0x${tailFrom.toRadixString(16)}',
              'toBlock': blockTag,
              'topics': [approvalTopic, ownerTopic],
              if (targetTokenAddress != null) 'address': targetTokenAddress,
            }
          ]),
          from: tailFrom,
          to: height,
          indexed: false);

      final out = <ApprovalData>[];
      final metadata = <String, TokenMetadata>{};
      for (final pair in pairs.values) {
        final (token, spender) = pair;
        final callData =
            '0xdd62ed3e${owner.substring(2).padLeft(64, '0')}${spender.substring(2).padLeft(64, '0')}';
        final raw = await rpc(rpcUri, 'eth_call', [
          {'to': token, 'data': callData},
          blockTag
        ]);
        final allowance = _word(raw);
        if (allowance == BigInt.zero) continue;
        var meta = metadata[token] ?? TokenMetadataCache().get(chain, token);
        if (meta == null) {
          // Decimals must be known for the existing ApprovalData contract. An
          // absent/malformed decimals() is not guessed as 18 or a safe result.
          final decimals = _word(await rpc(rpcUri, 'eth_call', [
            {'to': token, 'data': '0x313ce567'},
            blockTag
          ]));
          if (decimals > BigInt.from(255)) {
            throw const ApprovalSourceException('invalid_decimals');
          }
          String? symbol;
          try {
            symbol = _symbol(await rpc(rpcUri, 'eth_call', [
              {'to': token, 'data': '0x95d89b41'},
              blockTag
            ]));
          } on ApprovalSourceException catch (e) {
            // Symbol is optional in ERC-20; only a contract revert may be ignored.
            if (e.code != 'contract_reverted') rethrow;
          }
          meta = TokenMetadata(
              tokenAddress: token,
              name: symbol ?? token,
              symbol:
                  symbol ?? '${token.substring(0, 6)}…${token.substring(38)}',
              decimals: decimals.toInt());
          metadata[token] = meta;
        }
        final intel = SpenderIntelligenceService.instance;
        final reputation = intel.getReputation(chainId, spender);
        out.add(ApprovalData(
            chainId: chainId,
            token: token,
            spenderAddress: spender,
            spender: intel.getTrustedLabel(chainId, spender) ?? spender,
            walletAddress: owner,
            allowance: allowance,
            decimals: meta.decimals,
            tokenName: meta.name,
            tokenSymbol: meta.symbol,
            isKnownDex: reputation == SpenderReputation.dex,
            reputation: reputation,
            // No explorer verification/age inference. Match legacy parser's
            // unknown-age fallback, without inventing a verified contract.
            isVerified: false,
            contractAgeDays: 365));
      }
      final after =
          _block(await rpc(rpcUri, 'eth_getBlockByNumber', [blockTag, false]));
      if (after.number != height || after.hash != head.hash) {
        throw const ApprovalSourceException('block_changed');
      }
      _requireFresh(after.timestamp);
      return out;
    } finally {
      watch.stop();
      client.close();
    }
  }

  void _requireFresh(DateTime timestamp) {
    final age = _now().toUtc().difference(timestamp);
    if (age > _maxBlockAge || age < const Duration(seconds: -30)) {
      throw const ApprovalSourceException('rpc_stale');
    }
  }

  static int _quantity(dynamic raw) {
    final value = raw is int
        ? raw
        : raw is String
            ? (raw.startsWith('0x')
                ? int.tryParse(raw.substring(2), radix: 16)
                : int.tryParse(raw))
            : null;
    if (value == null || value < 0) {
      throw const ApprovalSourceException('invalid_quantity');
    }
    return value;
  }

  static BigInt _word(dynamic raw) {
    if (raw is! String || !RegExp(_wordPattern).hasMatch(raw)) {
      throw const ApprovalSourceException('invalid_call_result');
    }
    return BigInt.parse(raw.substring(2), radix: 16);
  }

  static ({int number, String hash, DateTime timestamp}) _block(dynamic raw) {
    if (raw is! Map ||
        raw['hash'] is! String ||
        !RegExp(_wordPattern).hasMatch(raw['hash'])) {
      throw const ApprovalSourceException('invalid_block');
    }
    final seconds = _quantity(raw['timestamp']);
    if (seconds > 253402300799) {
      throw const ApprovalSourceException('invalid_block');
    }
    return (
      number: _quantity(raw['number']),
      hash: (raw['hash'] as String).toLowerCase(),
      timestamp:
          DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true)
    );
  }

  static String? _symbol(dynamic raw) {
    if (raw is! String || !RegExp(r'^0x[0-9a-fA-F]+$').hasMatch(raw)) {
      return null;
    }
    final hex = raw.substring(2);
    String? text;
    try {
      if (hex.length == 64) {
        text = utf8.decode([
          for (var i = 0; i < 64; i += 2)
            int.parse(hex.substring(i, i + 2), radix: 16)
        ]).replaceAll('\u0000', '');
      } else if (hex.length >= 128 &&
          hex.substring(0, 64) == '20'.padLeft(64, '0')) {
        final length = int.parse(hex.substring(64, 128), radix: 16);
        if (length > 0 && length <= 32 && hex.length >= 128 + length * 2) {
          text = utf8.decode([
            for (var i = 128; i < 128 + length * 2; i += 2)
              int.parse(hex.substring(i, i + 2), radix: 16)
          ]);
        }
      }
    } catch (_) {
      return null;
    }
    // Contract-supplied text is untrusted, not a trusted token identity.
    return text != null && RegExp(r'^[A-Za-z0-9._-]{1,32}$').hasMatch(text)
        ? text
        : null;
  }
}
