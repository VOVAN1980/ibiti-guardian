import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_interface.dart';
import 'package:ibiti_guardian/services/exchanges/binance_exchange_service.dart'
    show PairSubscription;
import 'package:ibiti_guardian/services/market/exchange_trade_flow_tape.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_account_store.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

const _log = GuardianLogger('OkxWS');

// ─── OKX Exchange Service (EEA Endpoints) ──────────────────────────────────────
//
// Architecture: FULL WEBSOCKET — like Binance/Bybit.
//
//   1. REST seed (one-shot): GET /api/v5/market/tickers?instType=SPOT → populates
//      map + collects every USDT instrument ID (e.g., BTC-USDT).
//   2. WS subscribe ALL pairs: tickers/trades in batches of 100
//      → server pushes real-time snapshots/deltas.
//   3. REST fallback: every 60s ONLY as safety net if WS drops data.
//
// OKX v5 specifics:
//   - EEA REST Base: https://eea.okx.com
//   - EEA WS Base: wss://wseea.okx.com:8443/ws/v5/public
//   - volCcy24h = quote volume (USDT)
//   - vol24h = base volume (tokens)
//   - instId = BTC-USDT (normalized to BTCUSDT internally)
//   - WS sends string "ping" keepalive every 15s.
// ───────────────────────────────────────────────────────────────────────────────

class OkxExchangeService implements ExchangeService {
  OkxExchangeService._();
  static final OkxExchangeService instance = OkxExchangeService._();

  String _restBase = 'https://eea.okx.com';
  String _wsUrl = 'wss://wseea.okx.com:8443/ws/v5/public';
  String _quoteAsset = 'USDT';

  @override
  ExchangeId get id => ExchangeId.okx;

  // ── State ──────────────────────────────────────────────────────────────────
  WebSocketChannel? _channel;
  StreamSubscription? _wsSub;
  Timer? _reconnectTimer;
  Timer? _restFallbackTimer;
  Timer? _pingTimer;

  bool _connected = false;
  bool _connecting = false;
  bool _wsLive = false;
  int _reconnectAttempts = 0;
  bool _loggedFirstTickers = false;

  final _tickerController = StreamController<List<LiveTicker>>.broadcast();
  final Map<String, LiveTicker> _tickers = {};
  final Set<String> _updatedSymbols = {};
  Set<String> _knownSymbols = {};
  final List<LiveTicker> _newListings = [];

  /// Throttled emit: don't push full list on every single WS tick.
  Timer? _emitThrottle;
  bool _dirty = false;

  /// All USDT instrument IDs from REST — used for WS subscribe.
  List<String> _allSymbols = [];

  @override
  bool get isConnected => _connected || _wsLive;

  @override
  int get totalPairs => _tickers.length;

  @override
  Stream<List<LiveTicker>> get tickerStream => _tickerController.stream;

  @override
  List<LiveTicker> get currentTickers => _tickers.values.toList();

  // ── Category views ────────────────────────────────────────────────────────

  @override
  List<LiveTicker> get viewNewListings {
    final list = _tickers.values
        .where((t) =>
            t.quoteVolume24h > 500 &&
            t.quoteVolume24h < 500000 &&
            t.priceChangePercent24h.abs() > 5)
        .toList()
      ..sort(
          (a, b) => b.priceChangePercent24h.compareTo(a.priceChangePercent24h));
    return list.take(30).toList();
  }

  @override
  List<LiveTicker> get viewFastGrowth {
    final avgVol = _avgQuoteVolume();
    final list = _tickers.values
        .where((t) => t.priceChangePercent24h > 0.5 && t.quoteVolume24h > 500)
        .map((t) {
      final score = calcMomentumScore(
        priceChangePercent24h: t.priceChangePercent24h,
        quoteVolume24h: t.quoteVolume24h,
        avgVolume24h: avgVol,
        daysListed: t.daysListed,
        growthSinceListing: t.growthSinceListing,
      );
      return t.copyWith(momentumScore: score);
    }).toList()
      ..sort(
          (a, b) => b.priceChangePercent24h.compareTo(a.priceChangePercent24h));
    if (list.length < 10) return topGainers24h.take(30).toList();
    return list.take(30).toList();
  }

  @override
  List<LiveTicker> get viewMemeTrend {
    final list = _tickers.values.where((t) {
      final base = t.baseAsset.toUpperCase();
      final isMeme = _memeKeywords.any((kw) => base.contains(kw));
      final isLowCap = t.lastPrice < 0.001 && t.priceChangePercent24h.abs() > 1;
      return (isMeme || isLowCap) && t.quoteVolume24h > 1000;
    }).toList()
      ..sort(
          (a, b) => b.priceChangePercent24h.compareTo(a.priceChangePercent24h));
    return list;
  }

  @override
  List<LiveTicker> get viewMajors {
    final list = _tickers.values
        .where((t) => _majorBases.contains(t.baseAsset))
        .toList()
      ..sort((a, b) => b.quoteVolume24h.compareTo(a.quoteVolume24h));
    return list;
  }

  @override
  List<LiveTicker> get topGainers24h {
    final list = _tickers.values
        .where((t) => t.priceChangePercent24h > 0 && t.quoteVolume24h > 500)
        .toList()
      ..sort(
          (a, b) => b.priceChangePercent24h.compareTo(a.priceChangePercent24h));
    return list;
  }

  @override
  List<LiveTicker> get topGainersSinceListing => viewFastGrowth;

  @override
  List<LiveTicker> get newListings {
    final result = List<LiveTicker>.from(_newListings);
    _newListings.clear();
    return result;
  }

  double _avgQuoteVolume() {
    if (_tickers.isEmpty) return 100000;
    return _tickers.values.fold(0.0, (s, t) => s + t.quoteVolume24h) /
        _tickers.length;
  }

  // ── Connect / Disconnect ───────────────────────────────────────────────────

  Future<void> _resolveEndpoints() async {
    final creds = await ExchangeAccountStore.instance.getCredentials('okx');
    if (creds != null && creds.containsKey('region')) {
      final reg = creds['region'];
      if (reg == 'eea') {
        _restBase = 'https://eea.okx.com';
        _wsUrl = 'wss://wseea.okx.com:8443/ws/v5/public';
        _quoteAsset = 'USDC';
        _log.i('Using EEA endpoints based on account region (USDC)');
      } else {
        _restBase = 'https://www.okx.com';
        _wsUrl = 'wss://ws.okx.com:8443/ws/v5/public';
        _quoteAsset = 'USDT';
        _log.i('Using Global endpoints based on account region (USDT)');
      }
      return;
    }

    // No credentials saved -> Probe Global REST endpoint
    try {
      final probeUri = Uri.parse('https://www.okx.com/api/v5/market/tickers?instType=SPOT');
      final resp = await http.get(probeUri).timeout(const Duration(seconds: 3));
      if (resp.statusCode == 200) {
        _restBase = 'https://www.okx.com';
        _wsUrl = 'wss://ws.okx.com:8443/ws/v5/public';
        _quoteAsset = 'USDT';
        _log.i('Probe Global succeeded -> Using Global endpoints (USDT)');
      } else {
        _restBase = 'https://eea.okx.com';
        _wsUrl = 'wss://wseea.okx.com:8443/ws/v5/public';
        _quoteAsset = 'USDC';
        _log.i('Probe Global status code ${resp.statusCode} -> Falling back to EEA endpoints (USDC)');
      }
    } catch (e) {
      _restBase = 'https://eea.okx.com';
      _wsUrl = 'wss://wseea.okx.com:8443/ws/v5/public';
      _quoteAsset = 'USDC';
      _log.i('Probe Global failed ($e) -> Falling back to EEA endpoints (USDC)');
    }
  }

  @override
  Future<void> connect() async {
    if (_connected || _connecting) return;
    _connecting = true;
    _log.i('Connecting...');

    await _resolveEndpoints();

    _connected = true;
    _connecting = false;

    // 1. WS opens IMMEDIATELY with majors — no waiting.
    _connectWebSocket();

    // 2. REST fires in background to collect ALL symbol names.
    //    When it returns, re-subscribe WS to ALL pairs.
    unawaited(_fetchTicker24h().then((_) {
      if (_allSymbols.isNotEmpty && _wsLive) {
        _log.i(
            'REST done → re-subscribing WS to all ${_allSymbols.length} pairs');
        _subscribeAllPairs();
      }
    }));

    // 3. REST fallback every 60s — only if WS is dead.
    _restFallbackTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!_wsLive) _fetchTicker24h();
    });
  }

  @override
  Future<void> disconnect() async {
    _log.i('Disconnecting');
    _reconnectTimer?.cancel();
    _restFallbackTimer?.cancel();
    _pingTimer?.cancel();
    _emitThrottle?.cancel();
    _wsSub?.cancel();
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _connected = false;
    _connecting = false;
    _wsLive = false;
  }

  @override
  Future<void> refreshMetadata() async {}

  // ── WebSocket — ALL pairs real-time ───────────────────────────────────────

  void _connectWebSocket() {
    try {
      _wsSub?.cancel();
      try {
        _channel?.sink.close();
      } catch (_) {}
      _channel = null;

      _log.i('Opening WS...');
      _channel = WebSocketChannel.connect(Uri.parse(_wsUrl));

      _wsSub = _channel!.stream.listen(
        _onWsMessage,
        onError: (e) {
          _log.e('WS error: $e');
          _wsLive = false;
          _scheduleReconnect();
        },
        onDone: () {
          _log.i('WS closed');
          _wsLive = false;
          _scheduleReconnect();
        },
      );

      // Subscribe to majors IMMEDIATELY — no waiting for REST.
      final majors = _majorBases.map((b) => '${b}-$_quoteAsset').toList();
      _subscribePairs(majors);
      _log.i('WS live — ${majors.length} majors subscribed instantly using $_quoteAsset');

      // Ping keepalive every 15s.
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        try {
          _channel?.sink.add('ping');
        } catch (_) {}
      });

      _wsLive = true;
      _reconnectAttempts = 0;
    } catch (e) {
      _log.e('WS connect failed: $e');
      _wsLive = false;
      _scheduleReconnect();
    }
  }

  /// Subscribe to a list of OKX instruments via WS.
  void _subscribePairs(List<String> instIds) {
    if (_channel == null || instIds.isEmpty) return;
    final args = <Map<String, String>>[];
    for (final instId in instIds) {
      args.add({'channel': 'tickers', 'instId': instId});
      args.add({'channel': 'trades', 'instId': instId});
    }

    // Send in batches of 100 arguments to avoid OKX message size limit
    for (int i = 0; i < args.length; i += 100) {
      final chunk = args.sublist(i, i + 100 > args.length ? args.length : i + 100);
      _channel!.sink.add(jsonEncode({
        'op': 'subscribe',
        'args': chunk,
      }));
    }
  }

  /// Called after REST returns all symbol names — subscribes WS to everything.
  void _subscribeAllPairs() {
    if (_allSymbols.isEmpty || _channel == null) return;
    _subscribePairs(_allSymbols);
    _log.i('WS upgraded to ${_allSymbols.length} pairs');
  }

  void _scheduleReconnect() {
    _wsLive = false;
    _reconnectTimer?.cancel();
    final delay = Duration(
      seconds: (3 * (1 << _reconnectAttempts.clamp(0, 4))).clamp(3, 30),
    );
    _reconnectAttempts++;
    _log.i('WS reconnecting in ${delay.inSeconds}s (#$_reconnectAttempts)');
    _reconnectTimer = Timer(delay, _connectWebSocket);
  }

  // ── WS Message Handler ────────────────────────────────────────────────────

  void _onWsMessage(dynamic raw) {
    try {
      if (raw is! String) return;
      if (raw == 'pong') return; // ignore keepalive pong

      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic>) return;

      // Ignore subscription confirmations/events
      if (data.containsKey('event')) return;

      final arg = data['arg'];
      if (arg is! Map<String, dynamic>) return;

      final channel = arg['channel']?.toString() ?? '';
      final instId = arg['instId']?.toString() ?? '';
      final parts = instId.split('-');
      if (parts.length != 2) return;
      final base = parts[0];
      final quote = parts[1];
      if (quote != 'USDT' && quote != 'USDC') return;

      final symbol = '$base$quote';
      if (_stables.contains(base)) return;

      final list = data['data'];
      if (list is! List || list.isEmpty) return;

      // -- Trade Flow Tape --
      if (channel == 'trades') {
        for (final t in list) {
          if (t is! Map<String, dynamic>) continue;
          final price = _toDouble(t['px']);
          final size = _toDouble(t['sz']);
          final side = t['side']?.toString().toLowerCase() ?? 'unknown';
          final ts = int.tryParse(t['ts'].toString()) ??
              DateTime.now().millisecondsSinceEpoch;

          ExchangeTradeFlowTape.instance.processPrint(TradePrint(
            exchange: 'okx',
            symbol: symbol,
            timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
            price: price,
            baseQty: size,
            quoteUsd: size * price,
            side: side,
            source: TradeSource.ws,
            confidence: 'high',
          ));
        }
        return;
      }

      if (channel == 'tickers') {
        final tickerData = list[0];
        if (tickerData is! Map<String, dynamic>) return;

        final lastPrice = _toDouble(tickerData['last']);
        if (lastPrice <= 0) return;

        final open = _toDouble(tickerData['open24h']);
        final changePct = open > 0 ? ((lastPrice - open) / open) * 100.0 : 0.0;
        final quoteVol = _toDouble(tickerData['volCcy24h']);

        _tickers[symbol] = LiveTicker(
          symbol: symbol,
          baseAsset: base,
          lastPrice: lastPrice,
          priceChangePercent24h: changePct,
          volume24h: _toDouble(tickerData['vol24h']),
          quoteVolume24h: quoteVol,
          highPrice24h: _toDouble(tickerData['high24h']),
          lowPrice24h: _toDouble(tickerData['low24h']),
          risk: calcRisk(
            quoteVolume24h: quoteVol,
            daysListed: null,
            priceChangePercent24h: changePct,
          ),
        );

        _updatedSymbols.add(symbol);
        _scheduleEmit();
      }
    } catch (e) {
      _log.e('WS parse: $e');
    }
  }

  /// Throttled emit — max 4x/sec. WS ticks mark dirty, timer flushes.
  void _scheduleEmit() {
    _dirty = true;
    if (_emitThrottle != null) return; // timer already pending
    _emitThrottle = Timer(const Duration(milliseconds: 250), () {
      _emitThrottle = null;
      if (_dirty) {
        _dirty = false;
        final updatedTickers = _updatedSymbols
            .map((s) => _tickers[s])
            .whereType<LiveTicker>()
            .toList();
        _updatedSymbols.clear();
        if (updatedTickers.isNotEmpty) {
          _tickerController.add(updatedTickers);
        }
      }
    });
  }

  // ── REST (seed only + fallback) ───────────────────────────────────────────

  Future<void> _fetchTicker24h() async {
    try {
      final resp = await http.get(
        Uri.parse('$_restBase/api/v5/market/tickers?instType=SPOT'),
        headers: const {'accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode != 200) {
        _log.e('REST HTTP ${resp.statusCode}');
        return;
      }

      final body = jsonDecode(resp.body);
      if (body['code'] != '0') {
        _log.e('REST API error: ${body['msg']}');
        return;
      }
      final list = body['data'];
      if (list is! List) return;

      if (!_loggedFirstTickers) {
        _loggedFirstTickers = true;
        _log.i('REST seed: ${list.length} total tickers');
      }

      final instIds = <String>[];
      bool changed = false;

      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final instId = item['instId']?.toString() ?? '';
        final parts = instId.split('-');
        if (parts.length != 2) continue;
        final base = parts[0];
        final quote = parts[1];
        if (quote != 'USDT' && quote != 'USDC') continue;
 
        instIds.add(instId); // collect for WS subscription
 
        final symbol = '$base$quote';
        if (_stables.contains(base)) continue;

        final lastPrice = _toDouble(item['last']);
        if (lastPrice <= 0) continue;

        final open = _toDouble(item['open24h']);
        final changePct = open > 0 ? ((lastPrice - open) / open) * 100.0 : 0.0;
        final quoteVol = _toDouble(item['volCcy24h']);

        final existing = _tickers[symbol];

        // If WS is live and already updated this symbol, skip REST (stale).
        if (existing != null && _wsLive) continue;

        _tickers[symbol] = LiveTicker(
          symbol: symbol,
          baseAsset: base,
          lastPrice: lastPrice,
          priceChangePercent24h: changePct,
          volume24h: _toDouble(item['vol24h']),
          quoteVolume24h: quoteVol,
          highPrice24h: _toDouble(item['high24h']),
          lowPrice24h: _toDouble(item['low24h']),
          isNewlyListed: existing == null && _knownSymbols.isNotEmpty,
          risk: calcRisk(
            quoteVolume24h: quoteVol,
            daysListed: null,
            priceChangePercent24h: changePct,
          ),
        );

        if (existing == null &&
            _knownSymbols.isNotEmpty &&
            !_knownSymbols.contains(symbol)) {
          _newListings.add(_tickers[symbol]!);
          _knownSymbols.add(symbol);
          _log.i('NEW LISTING: $symbol');
        }

        changed = true;
      }

      // Store instrument IDs for WS subscription.
      if (instIds.isNotEmpty) {
        _allSymbols = instIds;
        _log.i('Collected ${instIds.length} USDT symbols for WS');
      }

      _knownSymbols = _tickers.keys.toSet();

      if (changed) {
        _tickerController.add(currentTickers);
      }
    } catch (e) {
      _log.e('REST error: $e');
    }
  }

  // ── Dedicated pair subscription (for TokenDetail) ─────────────────────────

  @override
  PairSubscription subscribePair(String pair) {
    _log.i('Dedicated stream: $pair');

    String instId = pair;
    if (pair.endsWith('USDT')) {
      instId = '${pair.substring(0, pair.length - 4)}-USDT';
    } else if (pair.endsWith('USDC')) {
      instId = '${pair.substring(0, pair.length - 4)}-USDC';
    }

    final channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
    final controller = StreamController<LiveTicker>.broadcast();

    final sub = channel.stream.listen(
      (raw) {
        try {
          if (raw is! String) return;
          if (raw == 'pong') return;

          final data = jsonDecode(raw);
          if (data is! Map<String, dynamic>) return;
          if (data.containsKey('event')) return;

          final arg = data['arg'];
          if (arg is! Map<String, dynamic>) return;

          final ch = arg['channel']?.toString() ?? '';
          if (ch != 'tickers') return;

          final list = data['data'];
          if (list is! List || list.isEmpty) return;

          final tickerData = list[0];
          if (tickerData is! Map<String, dynamic>) return;

          final symbol = pair;
          String base = symbol;
          if (symbol.endsWith('USDT')) {
            base = symbol.substring(0, symbol.length - 4);
          } else if (symbol.endsWith('USDC')) {
            base = symbol.substring(0, symbol.length - 4);
          }
          final lastPrice = _toDouble(tickerData['last']);
          if (lastPrice <= 0) return;

          final open = _toDouble(tickerData['open24h']);
          final changePct = open > 0 ? ((lastPrice - open) / open) * 100.0 : 0.0;
          final quoteVol = _toDouble(tickerData['volCcy24h']);

          final ticker = LiveTicker(
            symbol: symbol,
            baseAsset: base,
            lastPrice: lastPrice,
            priceChangePercent24h: changePct,
            volume24h: _toDouble(tickerData['vol24h']),
            quoteVolume24h: quoteVol,
            highPrice24h: _toDouble(tickerData['high24h']),
            lowPrice24h: _toDouble(tickerData['low24h']),
            risk: calcRisk(
              quoteVolume24h: quoteVol,
              daysListed: null,
              priceChangePercent24h: changePct,
            ),
          );
          _tickers[symbol] = ticker;
          controller.add(ticker);
        } catch (e) {
          _log.e('Dedicated parse: $e');
        }
      },
      onError: (e) => _log.e('Dedicated error: $e'),
    );

    channel.sink.add(jsonEncode({
      'op': 'subscribe',
      'args': [
        {'channel': 'tickers', 'instId': instId}
      ],
    }));

    final pingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      try {
        channel.sink.add('ping');
      } catch (_) {}
    });

    return PairSubscription(
      stream: controller.stream,
      dispose: () {
        pingTimer.cancel();
        sub.cancel();
        try {
          channel.sink.close();
        } catch (_) {}
        controller.close();
        _log.i('Dedicated closed: $pair');
      },
    );
  }

  static double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? 0.0;
  }

  static const _stables = <String>{
    'USDT',
    'USDC',
    'DAI',
    'BUSD',
    'FDUSD',
    'USDE',
    'PYUSD',
    'TUSD',
    'FRAX',
    'LUSD',
    'GUSD',
    'USDP',
    'EUR',
    'EURC',
  };

  static const _memeKeywords = <String>[
    'DOGE',
    'SHIB',
    'PEPE',
    'FLOKI',
    'MEME',
    'WIF',
    'BONK',
    'WOJAK',
    'TROLL',
    'CATS',
    'FROG',
    'MOON',
    'INU',
    'ELON',
    'TRUMP',
    'MAGA',
    'APE',
    'GORILLA',
    'PANDA',
    'TURBO',
    'RETI',
  ];

  static const _majorBases = <String>{
    'BTC',
    'ETH',
    'BNB',
    'SOL',
    'XRP',
    'ADA',
    'AVAX',
    'DOT',
    'LINK',
    'UNI',
    'MATIC',
    'LTC',
    'ATOM',
    'NEAR',
    'APT',
    'OP',
    'ARB',
    'SUI',
    'SEI',
    'TIA',
  };

  /// Finds the best trading pair symbol (instId) for a base asset,
  /// considering active region preferences (EEA prefers USDC, Global prefers USDT).
  /// If the tickers cache is empty, triggers a sync fetch.
  /// Returns null if no matching spot pair is found.
  Future<String?> findBestPair(String baseSymbol, String region) async {
    final base = baseSymbol.toUpperCase();
    
    // If cache is empty, trigger a sync refresh to populate tickers
    if (_tickers.isEmpty) {
      _log.i('Tickers cache empty in findBestPair for $baseSymbol, refreshing...');
      await _fetchTicker24h();
    }

    final prefs = region == 'eea' 
        ? ['USDC', 'USDT'] 
        : ['USDT', 'USDC'];

    for (final quote in prefs) {
      final symbol = '$base$quote';
      if (_tickers.containsKey(symbol)) {
        return '$base-$quote';
      }
    }
    return null;
  }

  void setTickerForTest(String symbol, LiveTicker ticker) {
    _tickers[symbol] = ticker;
  }

  void clearTickersForTest() {
    _tickers.clear();
  }
}
