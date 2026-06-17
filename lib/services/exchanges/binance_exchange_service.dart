import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_interface.dart';
import 'package:ibiti_guardian/services/market/exchange_trade_flow_tape.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

const _log = GuardianLogger('BinanceWS');

// ─── Binance Exchange Service ──────────────────────────────────────────────────

/// Binance adapter: REST + WebSocket mini-tickers.
/// Public endpoints — no API key required for viewing.
class BinanceExchangeService implements ExchangeService {
  BinanceExchangeService._();
  static final BinanceExchangeService instance = BinanceExchangeService._();

  static const _restBase = 'https://api.binance.com/api/v3';
  // Mini-ticker stream: all symbols, 1s updates.
  static const _wsUrl = 'wss://stream.binance.com:9443/ws/!miniTicker@arr';

  @override
  ExchangeId get id => ExchangeId.binance;

  // ── State ──────────────────────────────────────────────────────────────────
  WebSocketChannel? _channel;
  StreamSubscription? _wsSub;

  WebSocketChannel? _tradeChannel;
  StreamSubscription? _tradeSub;
  Timer? _tradeSyncTimer;
  int _lastTradeSubCount = 0;

  Timer? _reconnectTimer;
  Timer? _restPollTimer;

  bool _connected = false;
  int _totalPairs = 0;

  final _tickerController = StreamController<List<LiveTicker>>.broadcast();
  final Map<String, LiveTicker> _tickers = {};
  Set<String> _knownSymbols = {};
  final List<LiveTicker> _newListings = [];

  @override
  bool get isConnected => _connected;

  @override
  int get totalPairs => _totalPairs;

  @override
  Stream<List<LiveTicker>> get tickerStream => _tickerController.stream;

  @override
  List<LiveTicker> get currentTickers => _tickers.values.toList();

  // ── 4 category views ────────────────────────────────────────────────────────

  @override
  List<LiveTicker> get viewNewListings {
    // 1. Show newly-detected symbols first (runtime detection).
    final runtime = _tickers.values
        .where((t) => t.isNewlyListed && t.quoteVolume24h > 1000)
        .toList()
      ..sort(
          (a, b) => b.priceChangePercent24h.compareTo(a.priceChangePercent24h));
    if (runtime.length >= 5) return runtime;

    // 2. Fallback: Binance has no listing-date API, so approximate
    //    "new listings" as low-volume, high-growth coins — these are
    //    typically recently listed and not yet widely traded.
    final approx = _tickers.values
        .where((t) =>
            t.quoteVolume24h > 5000 &&
            t.quoteVolume24h < 2000000 &&
            t.priceChangePercent24h.abs() > 3)
        .toList()
      ..sort(
          (a, b) => b.priceChangePercent24h.compareTo(a.priceChangePercent24h));
    // Merge runtime + approximated, deduplicate.
    final merged = <String, LiveTicker>{};
    for (final t in runtime) {
      merged[t.symbol] = t;
    }
    for (final t in approx) {
      merged.putIfAbsent(t.symbol, () => t);
    }
    return merged.values.toList()
      ..sort(
          (a, b) => b.priceChangePercent24h.compareTo(a.priceChangePercent24h));
  }

  @override
  List<LiveTicker> get viewFastGrowth {
    // Momentum-scored — honest: no listing-date data on Binance.
    // Uses priceMomentum + volumeSpike + liquidity.
    final avgVol = _avgQuoteVolume();
    final list = _tickers.values
        .where((t) => t.priceChangePercent24h > 1 && t.quoteVolume24h > 500000)
        .map((t) {
      final score = calcMomentumScore(
        priceChangePercent24h: t.priceChangePercent24h,
        quoteVolume24h: t.quoteVolume24h,
        avgVolume24h: avgVol,
        daysListed: null,
        growthSinceListing: null,
      );
      return t.copyWith(momentumScore: score);
    }).toList()
      ..sort(
          (a, b) => b.priceChangePercent24h.compareTo(a.priceChangePercent24h));
    // Take top 30 by momentum, fallback to 24h gainers if empty.
    if (list.isEmpty) return topGainers24h.take(30).toList();
    return list.take(30).toList();
  }

  @override
  List<LiveTicker> get viewMemeTrend {
    return _tickers.values.where((t) {
      final base = t.baseAsset.toUpperCase();
      final isMeme = _memeKeywords.any((kw) => base.contains(kw));
      final isLowCap =
          t.lastPrice < 0.0001 && t.priceChangePercent24h.abs() > 1;
      return (isMeme || isLowCap) && t.quoteVolume24h > 5000;
    }).toList()
      ..sort(
          (a, b) => b.priceChangePercent24h.compareTo(a.priceChangePercent24h));
  }

  @override
  List<LiveTicker> get viewMajors {
    // Blue-chip coins sorted by 24h volume (market size proxy).
    // BTC/ETH/BNB/SOL always at top — users expect largest coins first.
    return _tickers.values.where((t) {
      return _majorBases.contains(t.baseAsset);
    }).toList()
      ..sort((a, b) => b.quoteVolume24h.compareTo(a.quoteVolume24h));
  }

  @override
  List<LiveTicker> get topGainersSinceListing => viewFastGrowth;

  @override
  List<LiveTicker> get topGainers24h {
    final list = _tickers.values
        .where((t) => t.priceChangePercent24h > 0 && t.quoteVolume24h > 500000)
        .toList()
      ..sort(
          (a, b) => b.priceChangePercent24h.compareTo(a.priceChangePercent24h));
    return list;
  }

  @override
  List<LiveTicker> get newListings {
    final result = List<LiveTicker>.from(_newListings);
    _newListings.clear();
    return result;
  }

  // ── Connect / Disconnect ───────────────────────────────────────────────────

  @override
  Future<void> connect() async {
    if (_connected || _connecting) return;
    _log.i('Connecting to Binance...');
    await _fetchRestSnapshot();
    _connectWebSocket();
    _restPollTimer?.cancel();
    _restPollTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _fetchRestSnapshot(),
    );
  }

  @override
  Future<void> disconnect() async {
    _log.i('Disconnecting Binance');
    _reconnectTimer?.cancel();
    _restPollTimer?.cancel();
    _tradeSyncTimer?.cancel();

    _wsSub?.cancel();
    await _channel?.sink.close();
    _channel = null;

    _tradeSub?.cancel();
    await _tradeChannel?.sink.close();
    _tradeChannel = null;

    _connected = false;
    _connecting = false;
  }

  @override
  Future<void> refreshMetadata() => _fetchRestSnapshot();

  // ── WebSocket ──────────────────────────────────────────────────────────────

  bool _connecting = false;
  int _reconnectAttempts = 0;

  void _connectWebSocket() {
    if (_connecting) return;
    _connecting = true;

    try {
      _wsSub?.cancel();
      _channel?.sink.close().catchError((_) {});
      _channel = null;

      _channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
      _wsSub = _channel!.stream.listen(
        _onWsMessage,
        onError: (e) {
          _log.e('WS error', e);
          _connected = false;
          _connecting = false;
          _scheduleReconnect();
        },
        onDone: () {
          _log.i('WS stream closed');
          _connected = false;
          _connecting = false;
          _scheduleReconnect();
        },
      );
      _connected = true;
      _connecting = false;
      _reconnectAttempts = 0;
      _log.i('Binance WebSocket connected');

      _tradeSyncTimer?.cancel();
      _tradeSyncTimer =
          Timer.periodic(const Duration(minutes: 5), (_) => _syncTradeStream());
      Timer(const Duration(seconds: 3), _syncTradeStream);
    } catch (e) {
      _log.e('WS connect failed', e);
      _connected = false;
      _connecting = false;
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _connected = false;
    _reconnectTimer?.cancel();
    final delay = Duration(
      seconds: (5 * (1 << _reconnectAttempts.clamp(0, 3))).clamp(5, 30),
    );
    _reconnectAttempts++;
    _reconnectTimer = Timer(delay, () {
      _log.i('Binance WS reconnecting (attempt $_reconnectAttempts)...');
      _connectWebSocket();
    });
  }

  void _onWsMessage(dynamic raw) {
    try {
      final dataArr = jsonDecode(raw as String);
      if (dataArr is! List) return;

      final List<LiveTicker> updatedList = [];
      for (final item in dataArr) {
        if (item is! Map<String, dynamic>) continue;
        final symbol = item['s']?.toString() ?? '';
        if (!symbol.endsWith('USDT')) continue;

        final base = symbol.replaceAll('USDT', '');
        if (_stables.contains(base)) continue;

        final lastPrice = _toDouble(item['c']);
        if (lastPrice <= 0) continue;

        final openPrice = _toDouble(item['o']);
        final vol = _toDouble(item['v']);
        final quoteVol = _toDouble(item['q']);

        // Mini-ticker doesn't have 'P' — calculate from open/close.
        final existing = _tickers[symbol];
        double priceChange;
        if (openPrice > 0) {
          priceChange = ((lastPrice - openPrice) / openPrice) * 100;
        } else {
          // Preserve existing value from REST if available.
          priceChange = existing?.priceChangePercent24h ?? 0;
        }

        final ticker = LiveTicker(
          symbol: symbol,
          baseAsset: base,
          lastPrice: lastPrice,
          priceChangePercent24h: priceChange,
          volume24h: vol,
          quoteVolume24h: quoteVol,
          highPrice24h: _toDouble(item['h']),
          lowPrice24h: _toDouble(item['l']),
          isNewlyListed: existing == null && _knownSymbols.isNotEmpty,
          risk: calcRisk(
            quoteVolume24h: quoteVol,
            daysListed: null,
            priceChangePercent24h: priceChange,
          ),
        );

        _tickers[symbol] = ticker;
        updatedList.add(ticker);

        if (existing == null &&
            _knownSymbols.isNotEmpty &&
            !_knownSymbols.contains(symbol)) {
          _newListings.add(_tickers[symbol]!);
          _knownSymbols.add(symbol);
          _log.i('NEW LISTING on Binance: $symbol');
        }
      }

      if (updatedList.isNotEmpty) {
        _tickerController.add(updatedList);
      }
      if (_tradeChannel == null && _tickers.isNotEmpty) {
        _syncTradeStream();
      }
    } catch (e) {
      _log.e('WS parse error', e);
    }
  }

  // ── REST Snapshot ──────────────────────────────────────────────────────────

  Future<void> _fetchRestSnapshot() async {
    try {
      final resp = await http.get(
        Uri.parse('$_restBase/ticker/24hr'),
        headers: const {'accept': 'application/json'},
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) return;
      final data = jsonDecode(resp.body) as List? ?? [];

      final newSymbols = <String>{};
      for (final item in data) {
        if (item is! Map<String, dynamic>) continue;
        final symbol = item['symbol']?.toString() ?? '';
        if (!symbol.endsWith('USDT')) continue;

        final base = symbol.replaceAll('USDT', '');
        if (_stables.contains(base)) continue;

        newSymbols.add(symbol);

        if (!_tickers.containsKey(symbol)) {
          final lastPrice = _toDouble(item['lastPrice']);
          if (lastPrice <= 0) continue;

          final priceChange = _toDouble(item['priceChangePercent']);
          final quoteVol = _toDouble(item['quoteVolume']);

          _tickers[symbol] = LiveTicker(
            symbol: symbol,
            baseAsset: base,
            lastPrice: lastPrice,
            priceChangePercent24h: priceChange,
            volume24h: _toDouble(item['volume']),
            quoteVolume24h: quoteVol,
            highPrice24h: _toDouble(item['highPrice']),
            lowPrice24h: _toDouble(item['lowPrice']),
            risk: calcRisk(
              quoteVolume24h: quoteVol,
              daysListed: null,
              priceChangePercent24h: priceChange,
            ),
          );
        }
      }

      if (_knownSymbols.isNotEmpty) {
        final brandNew = newSymbols.difference(_knownSymbols);
        for (final s in brandNew) {
          final t = _tickers[s];
          if (t != null) {
            _newListings.add(t.copyWith(isNewlyListed: true));
            _log.i('NEW LISTING on Binance (REST): $s');
          }
        }
      }
      _knownSymbols = newSymbols;
      _totalPairs = newSymbols.length;

      _tickerController.add(currentTickers);
    } catch (e) {
      _log.e('REST snapshot error', e);
    }
  }

  // ── Phase 11A2: Global Trade Stream ───────────────────────────────────────

  void _syncTradeStream() {
    if (!_connected || _tickers.isEmpty) return;

    final allPairs = _tickers.keys.toList();
    if ((allPairs.length - _lastTradeSubCount).abs() < 5 &&
        _tradeChannel != null) {
      return; // Already mostly synced
    }

    _log.i('Binance Tape Coverage Mode: FULL');

    _tradeSub?.cancel();
    _tradeChannel?.sink.close().catchError((_) {});
    _tradeChannel = null;

    final url = 'wss://stream.binance.com:9443/ws';
    try {
      _tradeChannel = WebSocketChannel.connect(Uri.parse(url));
      _tradeSub = _tradeChannel!.stream.listen(
        _onTradeMessage,
        onError: (e) => _log.e('Binance trade stream error', e),
        onDone: () => _log.i('Binance trade stream closed'),
      );

      // Binance allows max 1024 streams per connection,
      // but only 50 params per SUBSCRIBE request.
      // Limit to Top 1000 by volume.
      final sortedTickers = _tickers.values.toList()
        ..sort((a, b) => b.quoteVolume24h.compareTo(a.quoteVolume24h));
      final topPairs = sortedTickers.take(1000).map((t) => t.symbol).toList();

      final params = topPairs.map((s) => '${s.toLowerCase()}@trade').toList();

      int chunkIndex = 0;
      for (var i = 0; i < params.length; i += 50) {
        final chunk = params.skip(i).take(50).toList();
        final delayMs = 3000 +
            (chunkIndex * 300); // 3 sec initial delay, then stagger by 300ms
        final reqId = chunkIndex + 1;
        chunkIndex++;

        Future.delayed(Duration(milliseconds: delayMs), () {
          if (_tradeChannel != null) {
            _tradeChannel!.sink.add(jsonEncode({
              'method': 'SUBSCRIBE',
              'params': chunk,
              'id': reqId,
            }));
          }
        });
      }

      _lastTradeSubCount = _tickers.length; // track total tickers
      _log.i('[BinanceWS] Binance coverage=TOP_1000 symbols=${params.length}');
    } catch (e) {
      _log.e('Failed to start Binance trade stream', e);
    }
  }

  void _onTradeMessage(dynamic raw) {
    try {
      final payload = jsonDecode(raw as String);
      if (payload is! Map<String, dynamic>) return;

      final e = payload['e'];
      if (e == 'trade') {
        final symbol = payload['s']?.toString() ?? '';
        final price = _toDouble(payload['p']);
        final qty = _toDouble(payload['q']);
        final isBuyerMaker = payload['m'] == true;
        final side = isBuyerMaker ? 'sell' : 'buy';
        final ts = payload['T'] is int
            ? payload['T'] as int
            : int.tryParse(payload['T'].toString()) ??
                DateTime.now().millisecondsSinceEpoch;

        ExchangeTradeFlowTape.instance.processPrint(TradePrint(
          exchange: 'binance',
          symbol: symbol,
          timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
          price: price,
          baseQty: qty,
          quoteUsd: qty * price,
          side: side,
          source: TradeSource.ws,
          confidence: 'high',
        ));
      }
    } catch (_) {}
  }

  double _avgQuoteVolume() {
    if (_tickers.isEmpty) return 500000;
    final total = _tickers.values.fold(0.0, (s, t) => s + t.quoteVolume24h);
    return total / _tickers.length;
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
    'TRX',
    'TON',
  };

  // ── Per-symbol dedicated stream ───────────────────────────────────────────

  /// Subscribe to a single pair's individual ticker stream.
  /// Uses `<pair>@ticker` which fires on every update (~1s per trade).
  /// Returns a broadcast StreamController + WS subscription that the caller
  /// must cancel via the returned [PairSubscription].
  PairSubscription subscribePair(String pair) {
    final lowerPair = pair.toLowerCase();
    final url =
        'wss://stream.binance.com:9443/stream?streams=$lowerPair@ticker/$lowerPair@trade';
    final controller = StreamController<LiveTicker>.broadcast();

    _log.i('Opening dedicated stream for $pair');

    WebSocketChannel? ws;
    StreamSubscription? sub;

    void connect() {
      try {
        ws = WebSocketChannel.connect(Uri.parse(url));
        sub = ws!.stream.listen(
          (raw) {
            try {
              final payload = jsonDecode(raw as String);
              if (payload is! Map<String, dynamic>) return;

              final streamName = payload['stream']?.toString() ?? '';
              final item = payload['data'];
              if (item is! Map<String, dynamic>) return;

              // -- Phase 11A2: Trade Flow Tape --
              if (streamName.endsWith('@trade')) {
                final symbol = item['s']?.toString() ?? pair;
                final price = _toDouble(item['p']);
                final qty = _toDouble(item['q']);
                final isBuyerMaker = item['m'] ==
                    true; // if buyer is maker, side is sell. if buyer is taker, side is buy.
                final side = isBuyerMaker ? 'sell' : 'buy';
                final ts = item['T'] is int
                    ? item['T'] as int
                    : int.tryParse(item['T'].toString()) ??
                        DateTime.now().millisecondsSinceEpoch;

                ExchangeTradeFlowTape.instance.processPrint(TradePrint(
                  exchange: 'binance',
                  symbol: symbol,
                  timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
                  price: price,
                  baseQty: qty,
                  quoteUsd: qty * price,
                  side: side,
                  source: TradeSource.ws,
                  confidence: 'high',
                ));
                return;
              }

              if (!streamName.endsWith('@ticker')) return;

              final symbol = item['s']?.toString() ?? pair;
              final base = symbol.replaceAll('USDT', '');
              final lastPrice = _toDouble(item['c']);
              if (lastPrice <= 0) return;

              final openPrice = _toDouble(item['o']);
              final priceChange = openPrice > 0
                  ? ((lastPrice - openPrice) / openPrice) * 100
                  : 0.0;

              final ticker = LiveTicker(
                symbol: symbol,
                baseAsset: base,
                lastPrice: lastPrice,
                priceChangePercent24h: priceChange,
                volume24h: _toDouble(item['v']),
                quoteVolume24h: _toDouble(item['q']),
                highPrice24h: _toDouble(item['h']),
                lowPrice24h: _toDouble(item['l']),
              );

              // Also update the main ticker map so terminal stays in sync
              _tickers[symbol] = ticker;

              controller.add(ticker);
            } catch (e) {
              _log.e('Pair stream parse error', e);
            }
          },
          onError: (e) {
            _log.e('Pair stream error for $pair', e);
          },
          onDone: () {
            _log.i('Pair stream closed for $pair');
          },
        );
      } catch (e) {
        _log.e('Pair stream connect failed for $pair', e);
      }
    }

    connect();

    return PairSubscription(
      stream: controller.stream,
      dispose: () {
        sub?.cancel();
        ws?.sink.close().catchError((_) {});
        controller.close();
        _log.i('Pair stream disposed for $pair');
      },
    );
  }
}

/// A dedicated per-pair WebSocket subscription.
/// Caller MUST call [dispose] when done (e.g. in widget.dispose()).
class PairSubscription {
  final Stream<LiveTicker> stream;
  final void Function() dispose;

  const PairSubscription({required this.stream, required this.dispose});
}
