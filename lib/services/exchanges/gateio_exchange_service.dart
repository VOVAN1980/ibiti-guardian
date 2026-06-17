import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_interface.dart';
import 'package:ibiti_guardian/services/exchanges/binance_exchange_service.dart'
    show PairSubscription;
import 'package:ibiti_guardian/services/market/exchange_trade_flow_tape.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

const _log = GuardianLogger('GateWS');

// ─── Gate.io Exchange Service ──────────────────────────────────────────────────
//
// Architecture: FULL WEBSOCKET — like Binance.
//
//   1. REST seed (one-shot): GET /spot/tickers → populates map + collects
//      every USDT pair name.
//   2. WS subscribe ALL pairs: spot.tickers channel accepts array of all
//      pairs in a single payload → server pushes updates every 1s per pair.
//   3. REST fallback: every 30s ONLY as safety net if WS drops data.
//
// Gate.io WS specifics:
//   - Pair format: BTC_USDT (underscore)
//   - change_percentage = already percent (e.g. "-1.82" = -1.82%)
//   - Server update speed: 1000ms per subscribed pair
//   - Payload: Array[String] — can send ALL pairs at once
// ───────────────────────────────────────────────────────────────────────────────

class GateioExchangeService implements ExchangeService {
  GateioExchangeService._();
  static final GateioExchangeService instance = GateioExchangeService._();

  static const _restBase = 'https://api.gateio.ws/api/v4';
  static const _wsUrl = 'wss://api.gateio.ws/ws/v4/';

  @override
  ExchangeId get id => ExchangeId.gateio;

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

  /// All USDT pair names from REST (e.g. "BTC_USDT") — used for WS subscribe.
  List<String> _allGatePairs = [];

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

  @override
  Future<void> connect() async {
    if (_connected || _connecting) return;
    _connecting = true;
    _log.i('Connecting...');

    _connected = true;
    _connecting = false;

    // 1. WS opens IMMEDIATELY with majors — no waiting.
    _connectWebSocket();

    // 2. REST fires in background to collect ALL pair names.
    //    When it returns, re-subscribe WS to ALL pairs.
    unawaited(_fetchTicker24h().then((_) {
      if (_allGatePairs.isNotEmpty && _wsLive) {
        _log.i(
            'REST done → re-subscribing WS to all ${_allGatePairs.length} pairs');
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
      final majors = _majorBases.map((b) => '${b}_USDT').toList();
      _subscribePairs(majors);
      _log.i('WS live — ${majors.length} majors subscribed instantly');

      // Ping keepalive every 15s.
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        try {
          final n = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          _channel?.sink.add(jsonEncode({'time': n, 'channel': 'spot.ping'}));
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

  /// Subscribe to a list of Gate.io pairs via WS (batched by 100).
  void _subscribePairs(List<String> pairs) {
    if (_channel == null || pairs.isEmpty) return;
    for (int i = 0; i < pairs.length; i += 100) {
      final chunk = pairs.skip(i).take(100).toList();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      // Subscribe to tickers
      _channel!.sink.add(jsonEncode({
        'time': now,
        'channel': 'spot.tickers',
        'event': 'subscribe',
        'payload': chunk,
      }));

      // Subscribe to trades (Phase 11A2)
      _channel!.sink.add(jsonEncode({
        'time': now + 1,
        'channel': 'spot.trades',
        'event': 'subscribe',
        'payload': chunk,
      }));
    }
  }

  /// Called after REST returns all pair names — subscribes WS to everything.
  void _subscribeAllPairs() {
    if (_allGatePairs.isEmpty || _channel == null) return;
    _subscribePairs(_allGatePairs);
    _log.i('WS upgraded to ${_allGatePairs.length} pairs');
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
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic>) return;

      final event = data['event']?.toString() ?? '';
      if (event != 'update') return;

      // -- Phase 11A2: Global Trade Flow Tape from Gate --
      if (data['channel'] == 'spot.trades') {
        final tradeResult = data['result'];
        if (tradeResult is Map<String, dynamic>) {
          final pairStr = tradeResult['currency_pair']?.toString() ?? '';
          if (pairStr.endsWith('_USDT')) {
            final parsedSymbol = pairStr.replaceAll('_', '');
            final price = _toDouble(tradeResult['price']);
            final amount = _toDouble(tradeResult['amount']);
            final side = tradeResult['side']?.toString() ?? 'unknown';
            final ts = tradeResult['create_time_ms'] is int
                ? tradeResult['create_time_ms'] as int
                : int.tryParse(tradeResult['create_time_ms']
                        .toString()
                        .split('.')
                        .first) ??
                    DateTime.now().millisecondsSinceEpoch;

            ExchangeTradeFlowTape.instance.processPrint(TradePrint(
              exchange: 'gateio',
              symbol: parsedSymbol,
              timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
              price: price,
              baseQty: amount,
              quoteUsd: amount * price,
              side: side,
              source: TradeSource.ws,
              confidence: 'high',
            ));
          }
        }
        return;
      }

      if (data['channel'] != 'spot.tickers') return;

      final result = data['result'];
      if (result is! Map<String, dynamic>) return;

      final pair = result['currency_pair']?.toString() ?? '';
      if (!pair.endsWith('_USDT')) return;

      final symbol = pair.replaceAll('_', '');
      final base = symbol.replaceAll('USDT', '');
      if (_stables.contains(base)) return;

      final lastPrice = _toDouble(result['last']);
      if (lastPrice <= 0) return;

      // Gate.io: change_percentage is already in percent
      final changePct = _toDouble(result['change_percentage']);
      final quoteVol = _toDouble(result['quote_volume']);

      _tickers[symbol] = LiveTicker(
        symbol: symbol,
        baseAsset: base,
        lastPrice: lastPrice,
        priceChangePercent24h: changePct,
        volume24h: _toDouble(result['base_volume']),
        quoteVolume24h: quoteVol,
        highPrice24h: _toDouble(result['high_24h']),
        lowPrice24h: _toDouble(result['low_24h']),
        risk: calcRisk(
          quoteVolume24h: quoteVol,
          daysListed: null,
          priceChangePercent24h: changePct,
        ),
      );

      _updatedSymbols.add(symbol);
      _scheduleEmit();
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
        Uri.parse('$_restBase/spot/tickers'),
        headers: const {'accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode != 200) {
        _log.e('REST HTTP ${resp.statusCode}');
        return;
      }

      final data = jsonDecode(resp.body);
      if (data is! List) return;

      if (!_loggedFirstTickers) {
        _loggedFirstTickers = true;
        _log.i('REST seed: ${data.length} total tickers');
      }

      final pairNames = <String>[];
      bool changed = false;

      for (final item in data) {
        if (item is! Map<String, dynamic>) continue;
        final pair = item['currency_pair']?.toString() ?? '';
        if (!pair.endsWith('_USDT')) continue;

        pairNames.add(pair); // collect for WS subscription

        final symbol = pair.replaceAll('_', '');
        final base = symbol.replaceAll('USDT', '');
        if (_stables.contains(base)) continue;

        final lastPrice = _toDouble(item['last']);
        if (lastPrice <= 0) continue;

        final changePct = _toDouble(item['change_percentage']);
        final quoteVol = _toDouble(item['quote_volume']);

        final existing = _tickers[symbol];

        // If WS is live and already updated this symbol, skip REST (stale).
        if (existing != null && _wsLive) continue;

        _tickers[symbol] = LiveTicker(
          symbol: symbol,
          baseAsset: base,
          lastPrice: lastPrice,
          priceChangePercent24h: changePct,
          volume24h: _toDouble(item['base_volume']),
          quoteVolume24h: quoteVol,
          highPrice24h: _toDouble(item['high_24h']),
          lowPrice24h: _toDouble(item['low_24h']),
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

      // Store pair names for WS subscription.
      if (pairNames.isNotEmpty) {
        _allGatePairs = pairNames;
        _log.i('Collected ${pairNames.length} USDT pairs for WS');
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

  PairSubscription subscribePair(String pair) {
    final gatePair = _toGatePair(pair);
    _log.i('Dedicated stream: $gatePair');

    final channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
    final controller = StreamController<LiveTicker>.broadcast();

    final sub = channel.stream.listen(
      (raw) {
        try {
          if (raw is! String) return;
          final data = jsonDecode(raw);
          if (data is! Map<String, dynamic>) return;
          if (data['event'] != 'update') return;

          // -- Phase 11A2: Trade Flow Tape from Gate JSON deals --
          if (data['channel'] == 'spot.trades') {
            final tradeResult = data['result'];
            if (tradeResult is Map<String, dynamic>) {
              final s = tradeResult['currency_pair']?.toString() ?? '';
              final parsedSymbol = s.replaceAll('_', '');
              if (parsedSymbol == pair) {
                final price = _toDouble(tradeResult['price']);
                final amount = _toDouble(tradeResult['amount']);
                final side = tradeResult['side']?.toString() ?? 'unknown';
                final ts = tradeResult['create_time_ms'] is int
                    ? tradeResult['create_time_ms'] as int
                    : int.tryParse(tradeResult['create_time_ms']
                            .toString()
                            .split('.')
                            .first) ??
                        DateTime.now().millisecondsSinceEpoch;

                ExchangeTradeFlowTape.instance.processPrint(TradePrint(
                  exchange: 'gateio',
                  symbol: pair,
                  timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
                  price: price,
                  baseQty: amount,
                  quoteUsd: amount * price,
                  side: side,
                  source: TradeSource.ws,
                  confidence: 'high',
                ));
              }
            }
            return;
          }

          if (data['channel'] != 'spot.tickers') return;

          final result = data['result'];
          if (result is! Map<String, dynamic>) return;

          final symbol = pair;
          final base = symbol.replaceAll('USDT', '');
          final lastPrice = _toDouble(result['last']);
          if (lastPrice <= 0) return;

          final changePct = _toDouble(result['change_percentage']);
          final quoteVol = _toDouble(result['quote_volume']);

          final ticker = LiveTicker(
            symbol: symbol,
            baseAsset: base,
            lastPrice: lastPrice,
            priceChangePercent24h: changePct,
            volume24h: _toDouble(result['base_volume']),
            quoteVolume24h: quoteVol,
            highPrice24h: _toDouble(result['high_24h']),
            lowPrice24h: _toDouble(result['low_24h']),
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

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Subscribe to tickers AND trades.
    channel.sink.add(jsonEncode({
      'time': now,
      'channel': 'spot.tickers',
      'event': 'subscribe',
      'payload': [gatePair],
    }));

    channel.sink.add(jsonEncode({
      'time': now + 1,
      'channel': 'spot.trades',
      'event': 'subscribe',
      'payload': [gatePair],
    }));

    final pingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      try {
        final n = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        channel.sink.add(jsonEncode({'time': n, 'channel': 'spot.ping'}));
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
        _log.i('Dedicated closed: $gatePair');
      },
    );
  }

  String _toGatePair(String pair) {
    if (pair.endsWith('USDT')) {
      return '${pair.substring(0, pair.length - 4)}_USDT';
    }
    return pair;
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
}
