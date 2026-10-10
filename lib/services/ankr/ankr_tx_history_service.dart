import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/models/on_chain_tx.dart';
import 'package:ibiti_guardian/services/ankr/ankr_config_service.dart';
import 'package:ibiti_guardian/services/history/tx_history_source.dart';

/// Wallet history from the Ankr Advanced API (`ankr_getTransactionsByAddress`
/// plus `ankr_getTokenTransfers`), merged into one entry per transaction hash.
///
/// Each API stream advances with its own opaque Ankr page token. Continuations
/// and previously loaded transaction details stay in RAM, never in a URL/log.
/// Later pages may enrich an earlier row, so callers must upsert by hash.
class AnkrTxHistoryService implements TxHistorySource {
  AnkrTxHistoryService({http.Client? client, AnkrConfigService? config})
      : _client = client ?? http.Client(),
        _config = config ?? AnkrConfigService.instance;

  static const _endpoint = 'https://rpc.ankr.com/multichain';
  static const pageSize = 25;

  /// Guardian chain key -> Ankr blockchain name.
  static const chains = {
    'bsc': 'bsc',
    'eth': 'eth',
    'polygon': 'polygon',
    'arbitrum': 'arbitrum',
    'base': 'base',
  };
  static const _nativeSymbols = {
    'bsc': 'BNB',
    'eth': 'ETH',
    'polygon': 'POL',
    'arbitrum': 'ETH',
    'base': 'ETH',
  };

  final http.Client _client;
  final AnkrConfigService _config;
  final _continuations = <String, _AnkrContinuation>{};
  int _cursorSequence = 0;
  static const _cursorTtl = Duration(minutes: 30);
  static const _maxContinuations = 8;

  @override
  String get name => 'ankr';

  @override
  bool supports(String chainKey) => chains.containsKey(chainKey);

  @override
  Future<bool> isConfigured() async {
    await _config.ensureLoaded();
    return _config.isConfigured;
  }

  @override
  Future<HistoryPage> fetch({
    required String address,
    required String chainKey,
    String? cursor,
  }) async {
    await _config.ensureLoaded();
    if (!_config.isConfigured) {
      throw const TxHistoryUnavailable('key is not configured');
    }
    final blockchain = chains[chainKey];
    if (blockchain == null) {
      throw TxHistoryUnavailable('does not serve $chainKey');
    }
    final now = DateTime.now().toUtc();
    _continuations.removeWhere(
        (_, state) => now.difference(state.createdAt) > _cursorTtl);
    final previous = cursor == null ? null : _continuations[cursor];
    if (cursor != null &&
        (previous == null ||
            previous.address != address.toLowerCase() ||
            previous.chainKey != chainKey)) {
      throw const TxHistoryUnavailable('history cursor expired or invalid');
    }

    Map<String, dynamic> common() => {
          'blockchain': [blockchain],
          'pageSize': pageSize,
          'descOrder': true,
        };

    final results = await Future.wait([
      if (previous == null || previous.transactionToken != null)
        _rpc('ankr_getTransactionsByAddress', {
          ...common(),
          'address': address,
          if (previous?.transactionToken != null)
            'pageToken': previous!.transactionToken,
        })
      else
        Future.value(<String, dynamic>{'transactions': <dynamic>[]}),
      if (previous == null || previous.transferToken != null)
        _rpc('ankr_getTokenTransfers', {
          ...common(),
          'address': [address],
          if (previous?.transferToken != null)
            'pageToken': previous!.transferToken,
        })
      else
        Future.value(<String, dynamic>{'transfers': <dynamic>[]}),
    ]);
    final txs = _list(results[0]['transactions']);
    final transfers = _list(results[1]['transfers']);
    final transactionToken = _nextPageToken(results[0]);
    final transferToken = _nextPageToken(results[1]);
    if ((transactionToken != null &&
            transactionToken == previous?.transactionToken) ||
        (transferToken != null && transferToken == previous?.transferToken)) {
      throw const TxHistoryUnavailable('history cursor did not advance');
    }

    // Keep the raw rows only for this active history walk. A token movement may
    // arrive after its transaction page; retain gas/status and all transfer legs.
    final transactionsByHash = <String, Map<String, dynamic>>{
      ...?previous?.transactions,
    };
    final transfersByHash = <String, List<Map<String, dynamic>>>{
      ...?previous?.transfers,
    };
    final changedHashes = <String>{};
    for (final tx in txs) {
      final hash = (tx['hash'] ?? '').toString().toLowerCase();
      if (hash.isEmpty) continue;
      transactionsByHash[hash] = tx;
      changedHashes.add(hash);
    }
    for (final transfer in transfers) {
      final hash = (transfer['transactionHash'] ?? '').toString().toLowerCase();
      if (hash.isEmpty) continue;
      transfersByHash[hash] = [
        ...?transfersByHash[hash],
        transfer,
      ];
      changedHashes.add(hash);
    }

    final mapped = AnkrTxMapper.map(
      transactions: [
        for (final hash in changedHashes)
          if (transactionsByHash[hash] != null) transactionsByHash[hash]!,
      ],
      transfers: [
        for (final hash in changedHashes) ...?transfersByHash[hash],
      ],
      wallet: address,
      chainKey: chainKey,
      nativeSymbol: _nativeSymbols[chainKey] ?? 'ETH',
    );

    // Do not consume the old continuation until both calls and mapping succeed:
    // a transient failure must be retryable with exactly the same page tokens.
    if (cursor != null) _continuations.remove(cursor);
    String? next;
    if (transactionToken != null || transferToken != null) {
      while (_continuations.length >= _maxContinuations) {
        _continuations.remove(_continuations.keys.first);
      }
      next = 'pages:${now.microsecondsSinceEpoch}:${++_cursorSequence}';
      _continuations[next] = _AnkrContinuation(
        address: address.toLowerCase(),
        chainKey: chainKey,
        transactionToken: transactionToken,
        transferToken: transferToken,
        transactions: transactionsByHash,
        transfers: transfersByHash,
        createdAt: now,
      );
    }
    // The union can contain up to two provider pages. Never truncate it: doing
    // so discards rows that neither stream will return on its following page.
    return HistoryPage(mapped, next);
  }

  static String? _nextPageToken(Map<String, dynamic> result) {
    final token = result['nextPageToken'];
    if (token == null || token == '') return null;
    if (token is! String || token.trim().isEmpty) {
      throw const TxHistoryUnavailable('invalid provider page token');
    }
    return token;
  }

  static List<Map<String, dynamic>> _list(dynamic value) {
    if (value is! List || value.any((item) => item is! Map)) {
      throw const TxHistoryUnavailable('unexpected history rows');
    }
    return [for (final item in value) Map<String, dynamic>.from(item as Map)];
  }

  Future<Map<String, dynamic>> _rpc(
    String method,
    Map<String, dynamic> params,
  ) async {
    // The key is part of the URL; it must never appear in an error message.
    final uri = Uri.parse('$_endpoint/${_config.apiKey}');
    final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'method': method,
              'params': params,
            }),
          )
          .timeout(const Duration(seconds: 25));
    } catch (e) {
      throw TxHistoryUnavailable('request failed (${e.runtimeType})');
    }
    if (response.statusCode != 200) {
      throw TxHistoryUnavailable('HTTP ${response.statusCode}');
    }
    final Object? body;
    try {
      body = jsonDecode(response.body);
    } catch (_) {
      throw const TxHistoryUnavailable('unreadable answer');
    }
    if (body is! Map<String, dynamic>) {
      throw const TxHistoryUnavailable('unexpected answer');
    }
    final error = body['error'];
    if (error != null) {
      // Provider messages can echo the key-bearing URL or request data.
      final code = error is Map && error['code'] is int ? error['code'] : null;
      throw TxHistoryUnavailable(
          code == null ? 'JSON-RPC error' : 'JSON-RPC error ($code)');
    }
    final result = body['result'];
    if (result is! Map<String, dynamic>) {
      throw const TxHistoryUnavailable('no result');
    }
    return result;
  }
}

class _AnkrContinuation {
  const _AnkrContinuation({
    required this.address,
    required this.chainKey,
    required this.transactionToken,
    required this.transferToken,
    required this.transactions,
    required this.transfers,
    required this.createdAt,
  });

  final String address;
  final String chainKey;
  final String? transactionToken;
  final String? transferToken;
  final Map<String, Map<String, dynamic>> transactions;
  final Map<String, List<Map<String, dynamic>>> transfers;
  final DateTime createdAt;
}

/// Pure mapping from Ankr JSON to [OnChainTx], one entry per transaction hash.
class AnkrTxMapper {
  AnkrTxMapper._();

  static const _approveSelector = '0x095ea7b3';

  static List<OnChainTx> map({
    required List<Map<String, dynamic>> transactions,
    required List<Map<String, dynamic>> transfers,
    required String wallet,
    required String chainKey,
    required String nativeSymbol,
  }) {
    final me = wallet.toLowerCase();
    final txByHash = <String, Map<String, dynamic>>{};
    for (final tx in transactions) {
      final hash = (tx['hash'] ?? '').toString().toLowerCase();
      if (hash.isNotEmpty) txByHash[hash] = tx;
    }
    final legsByHash = <String, List<Map<String, dynamic>>>{};
    for (final leg in transfers) {
      final hash = (leg['transactionHash'] ?? '').toString().toLowerCase();
      if (hash.isNotEmpty) (legsByHash[hash] ??= []).add(leg);
    }

    final hashes = {...txByHash.keys, ...legsByHash.keys};
    final out = <OnChainTx>[];
    for (final hash in hashes) {
      final built = _build(
        hash: hash,
        tx: txByHash[hash],
        legs: legsByHash[hash] ?? const [],
        me: me,
        chainKey: chainKey,
        nativeSymbol: nativeSymbol,
      );
      if (built != null) out.add(built);
    }
    out.sort((a, b) => b.blockTimestamp.compareTo(a.blockTimestamp));
    return out;
  }

  static OnChainTx? _build({
    required String hash,
    required Map<String, dynamic>? tx,
    required List<Map<String, dynamic>> legs,
    required String me,
    required String chainKey,
    required String nativeSymbol,
  }) {
    final timestamp = _timestamp(tx?['timestamp']) ??
        (legs.isEmpty ? null : _timestamp(legs.first['timestamp']));
    if (timestamp == null) return null;

    final txFrom = (tx?['from'] ?? '').toString();
    final txTo = (tx?['to'] ?? '').toString();
    final paidByMe = tx != null && txFrom.toLowerCase() == me;
    final status = tx == null ? null : _bigInt(tx['status']);
    final isSuccess = status == null || status != BigInt.zero;

    double? fee;
    if (tx != null && paidByMe) {
      final gasUsed = _bigInt(tx['gasUsed']);
      final gasPrice = _bigInt(tx['gasPrice']);
      if (gasUsed != null && gasPrice != null) {
        fee = _scale(gasUsed * gasPrice, 18);
      }
    }

    final incoming = [
      for (final l in legs)
        if ((l['toAddress'] ?? '').toString().toLowerCase() == me) l,
    ];
    final outgoing = [
      for (final l in legs)
        if ((l['fromAddress'] ?? '').toString().toLowerCase() == me) l,
    ];

    OnChainTx make({
      required OnChainTxType type,
      required String from,
      required String to,
      required double value,
      String? tokenSymbol,
      String? tokenName,
      String? tokenLogoUrl,
      String? contractAddress,
      String? sellSymbol,
      double? sellValue,
      String? buySymbol,
      double? buyValue,
    }) =>
        OnChainTx(
          hash: hash,
          type: type,
          from: from,
          to: to,
          value: value,
          tokenSymbol: tokenSymbol,
          tokenName: tokenName,
          tokenLogoUrl: tokenLogoUrl,
          contractAddress: contractAddress,
          blockTimestamp: timestamp,
          isSuccess: isSuccess,
          gasUsed: tx == null ? null : _bigInt(tx['gasUsed'])?.toString(),
          chainKey: chainKey,
          feeNative: fee,
          feeSymbol: fee == null ? null : nativeSymbol,
          sellSymbol: sellSymbol,
          sellValue: sellValue,
          buySymbol: buySymbol,
          buyValue: buyValue,
        );

    if (incoming.isNotEmpty && outgoing.isNotEmpty) {
      final out = outgoing.first;
      final inn = incoming.first;
      final sameToken = _contract(out) == _contract(inn);
      if (!sameToken) {
        return make(
          type: OnChainTxType.swap,
          from: me,
          to: txTo,
          value: _legValue(inn),
          tokenSymbol: _s(inn['tokenSymbol']),
          tokenName: _s(inn['tokenName']),
          tokenLogoUrl: _s(inn['thumbnail']),
          contractAddress: _contract(inn),
          sellSymbol: _s(out['tokenSymbol']),
          sellValue: _legValue(out),
          buySymbol: _s(inn['tokenSymbol']),
          buyValue: _legValue(inn),
        );
      }
      // The same token both ways: show the net movement.
      final net = _legValue(inn) - _legValue(out);
      final leg = net >= 0 ? inn : out;
      return make(
        type: net >= 0 ? OnChainTxType.receive : OnChainTxType.send,
        from: (leg['fromAddress'] ?? '').toString(),
        to: (leg['toAddress'] ?? '').toString(),
        value: net.abs(),
        tokenSymbol: _s(leg['tokenSymbol']),
        tokenName: _s(leg['tokenName']),
        tokenLogoUrl: _s(leg['thumbnail']),
        contractAddress: _contract(leg),
      );
    }

    if (incoming.isNotEmpty) {
      final leg = incoming.first;
      return make(
        type: OnChainTxType.receive,
        from: (leg['fromAddress'] ?? '').toString(),
        to: (leg['toAddress'] ?? '').toString(),
        value: _legValue(leg),
        tokenSymbol: _s(leg['tokenSymbol']),
        tokenName: _s(leg['tokenName']),
        tokenLogoUrl: _s(leg['thumbnail']),
        contractAddress: _contract(leg),
      );
    }
    if (outgoing.isNotEmpty) {
      final leg = outgoing.first;
      return make(
        type: OnChainTxType.send,
        from: (leg['fromAddress'] ?? '').toString(),
        to: (leg['toAddress'] ?? '').toString(),
        value: _legValue(leg),
        tokenSymbol: _s(leg['tokenSymbol']),
        tokenName: _s(leg['tokenName']),
        tokenLogoUrl: _s(leg['thumbnail']),
        contractAddress: _contract(leg),
      );
    }

    // No token movement: a native transfer, an approval or another contract call.
    if (tx == null) return null;
    final wei = _bigInt(tx['value']) ?? BigInt.zero;
    final input = (tx['input'] ?? '').toString().toLowerCase();
    if (paidByMe && input.startsWith(_approveSelector) && input.length >= 74) {
      return make(
        type: OnChainTxType.approval,
        from: txFrom,
        to: '0x${input.substring(34, 74)}',
        value: 0,
        contractAddress: txTo.isEmpty ? null : txTo,
      );
    }
    if (paidByMe) {
      return make(
        type: wei > BigInt.zero ? OnChainTxType.send : OnChainTxType.other,
        from: txFrom,
        to: txTo,
        value: _scale(wei, 18),
        tokenSymbol: wei > BigInt.zero ? nativeSymbol : null,
      );
    }
    if (txTo.toLowerCase() == me && wei > BigInt.zero) {
      return make(
        type: OnChainTxType.receive,
        from: txFrom,
        to: txTo,
        value: _scale(wei, 18),
        tokenSymbol: nativeSymbol,
      );
    }
    return null;
  }

  static String? _s(dynamic v) {
    final s = v?.toString();
    return (s == null || s.isEmpty) ? null : s;
  }

  static String? _contract(Map<String, dynamic> leg) =>
      _s(leg['contractAddress'])?.toLowerCase();

  /// Human-readable token amount of a transfer leg.
  static double _legValue(Map<String, dynamic> leg) {
    final human = double.tryParse((leg['value'] ?? '').toString());
    if (human != null) return human;
    final raw = _bigInt(leg['valueRawInteger']);
    final decimals =
        int.tryParse((leg['tokenDecimals'] ?? '18').toString()) ?? 18;
    return raw == null ? 0 : _scale(raw, decimals);
  }

  static double _scale(BigInt raw, int decimals) {
    if (decimals <= 0) return raw.toDouble();
    return raw.toDouble() / _pow10(decimals);
  }

  static double _pow10(int n) {
    var result = 1.0;
    for (var i = 0; i < n; i++) {
      result *= 10;
    }
    return result;
  }

  /// Accepts hex ("0x1a"), decimal text or a number.
  static BigInt? _bigInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return BigInt.from(v);
    if (v is double) return BigInt.from(v);
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    if (s.startsWith('0x') || s.startsWith('0X')) {
      return s.length == 2
          ? BigInt.zero
          : BigInt.tryParse(s.substring(2), radix: 16);
    }
    return BigInt.tryParse(s);
  }

  static DateTime? _timestamp(dynamic v) {
    final seconds = _bigInt(v);
    if (seconds == null || seconds <= BigInt.zero) return null;
    var s = seconds.toInt();
    // Some endpoints return milliseconds.
    if (s > 100000000000) s = s ~/ 1000;
    return DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true);
  }
}
