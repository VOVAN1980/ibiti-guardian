import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_interface.dart';
import 'package:ibiti_guardian/services/exchanges/binance_exchange_service.dart'
    show PairSubscription;
import 'package:ibiti_guardian/services/exchanges/mexc_proto.dart';
import 'package:ibiti_guardian/services/market/exchange_trade_flow_tape.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

const _log = GuardianLogger('MexcWS');

// ─── MEXC Exchange Service ─────────────────────────────────────────────────────

/// MEXC adapter: WebSocket for live tickers + REST for metadata/fallback.
/// Public endpoints only — no API key needed for viewing.
class MexcExchangeService implements ExchangeService {
  MexcExchangeService._();
  static final MexcExchangeService instance = MexcExchangeService._();

  static const _restBase = 'https://api.mexc.com/api/v3';
  static const _wsUrl = 'wss://wbs-api.mexc.com/ws';

  @override
  ExchangeId get id => ExchangeId.mexc;

  // ── State ──────────────────────────────────────────────────────────────────
  WebSocketChannel? _channel;
  StreamSubscription? _wsSub;
  Timer? _reconnectTimer;
  Timer? _restPollTimer;
  Timer? _pingTimer;
  Timer? _restFallbackTimer;

  bool _connected = false;
  bool _connecting = false;
  bool _wsLive = false;
  bool _wsBlocked = false;
  bool _loggedFirstBinary = false;
  bool _loggedFirstTickers = false;
  int _totalPairs = 0;
  int _reconnectAttempts = 0;

  final _tickerController = StreamController<List<LiveTicker>>.broadcast();

  /// symbol → ticker (in-memory, updated by WS or REST fallback).
  final Map<String, LiveTicker> _tickers = {};

  /// Symbols seen (for new listing detection).
  Set<String> _knownSymbols = {};

  /// New listings detected since last read.
  final List<LiveTicker> _newListings = [];

  /// symbol → listing metadata (fetched once from exchangeInfo).
  final Map<String, _ListingMeta> _meta = {};

  // -- Phase 11A2: Tape Coverage --
  // Mode: ALL_RADAR_ROTATING_TRADE_FLOW
  // 1. ALL MEXC pairs watched by miniTicker radar.
  // 2. prioritySlots (up to 180 pairs) always subscribed to deals.
  // 3. rotatingSlots (up to 390 pairs) rotate through remaining pairs every 30s.
  // 19 shards max (to respect 20 IP connection limit).
  final List<_MexcTradeShard> _dealShards = [];
  Timer? _shardingTimer;
  int _rotationCursor = 0;

  @override
  bool get isConnected => _connected || _wsLive;

  @override
  int get totalPairs => _tickers.length;

  @override
  Stream<List<LiveTicker>> get tickerStream => _tickerController.stream;

  @override
  List<LiveTicker> get currentTickers => _tickers.values.toList();

  // ── 4 category views ──────────────────────────────────────────────────────

  @override
  List<LiveTicker> get viewNewListings {
    final list = _tickers.values
        .where((t) => (t.daysListed ?? 999) <= 7 && t.quoteVolume24h > 500)
        .toList()
      ..sort((a, b) => (b.growthSinceListing ?? b.priceChangePercent24h)
          .compareTo(a.growthSinceListing ?? a.priceChangePercent24h));
    return list;
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
    final list = _tickers.values.where((t) {
      return _majorBases.contains(t.baseAsset);
    }).toList()
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

  // Legacy compat
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
    final total = _tickers.values.fold(0.0, (s, t) => s + t.quoteVolume24h);
    return total / _tickers.length;
  }

  // ── Connect / Disconnect ───────────────────────────────────────────────────

  @override
  Future<void> connect() async {
    if (_connected || _connecting) return;
    _connecting = true;
    _log.i('Connecting to MEXC...');

    // Mark connected immediately — WS is the primary path now.
    _connected = true;
    _connecting = false;

    // 1. Open WebSocket FIRST — this is the live data path.
    _connectWebSocket();

    // 2. Fetch listing metadata (daysListed, growthSinceListing) via REST.
    //    Without this, viewNewListings is always empty.
    unawaited(_fetchRestSnapshot());

    // 3. Initial REST ticker fetch as seed (WS may take a moment to populate).
    unawaited(_fetchTicker24h());
  }

  @override
  Future<void> disconnect() async {
    _log.i('Disconnecting MEXC');
    _reconnectTimer?.cancel();
    _restPollTimer?.cancel();
    _pingTimer?.cancel();
    _restFallbackTimer?.cancel();
    _shardingTimer?.cancel();
    _wsSub?.cancel();
    await _channel?.sink.close();

    for (final shard in _dealShards) {
      shard.dispose();
    }
    _dealShards.clear();

    _channel = null;
    _connected = false;
    _connecting = false;
    _wsLive = false;
  }

  @override
  Future<void> refreshMetadata() async {}

  // ── WebSocket ──────────────────────────────────────────────────────────────

  void _connectWebSocket() {
    if (_connecting && !_connected) return; // Still doing initial REST.
    if (_wsBlocked) return; // MEXC blocked us — don't retry.

    try {
      _wsSub?.cancel();
      _channel?.sink.close().catchError((_) {});
      _channel = null;

      _log.i('Opening MEXC WebSocket...');
      _channel =
          WebSocketChannel.connect(Uri.parse('wss://wbs-api.mexc.com/ws'));

      _wsSub = _channel!.stream.listen(
        _onWsMessage,
        onError: (e) {
          _log.e('WS error', e);
          _wsLive = false;
          _scheduleReconnect();
        },
        onDone: () {
          _log.i('WS stream closed');
          _wsLive = false;
          _scheduleReconnect();
        },
      );

      // Subscribe to all mini tickers — official MEXC V3 channel.
      const _channel_name = 'spot@public.miniTickers.v3.api.pb@UTC+8';
      final subPayload = jsonEncode({
        'method': 'SUBSCRIPTION',
        'params': [_channel_name],
      });
      _log.i('Subscribing: $_channel_name');
      _channel!.sink.add(subPayload);

      // Start ping keepalive (every 20s).
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(
        const Duration(seconds: 20),
        (_) {
          try {
            _channel?.sink.add(jsonEncode({'method': 'PING'}));
          } catch (_) {}
        },
      );

      // -- Phase 11A2: Dynamic Deals Subscription --
      _shardingTimer?.cancel();
      _shardingTimer = Timer.periodic(
          const Duration(seconds: 30), (_) => _syncShardedDeals());
      // Call it immediately after a small delay to ensure _tickers is populated from REST/WS
      Timer(const Duration(seconds: 3), _syncShardedDeals);

      // Stop REST fallback if it was running.
      _restFallbackTimer?.cancel();
      _restFallbackTimer = null;

      _wsLive = true;
      _reconnectAttempts = 0;
      _log.i('MEXC WebSocket connected');
    } catch (e) {
      _log.e('WS connect failed', e);
      _wsLive = false;
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_wsBlocked) return; // MEXC blocked us — don't reconnect.
    _wsLive = false;
    _reconnectTimer?.cancel();
    final delay = Duration(
      seconds: (5 * (1 << _reconnectAttempts.clamp(0, 3))).clamp(5, 30),
    );
    _reconnectAttempts++;
    _reconnectTimer = Timer(delay, () {
      _log.i('MEXC WS reconnecting (attempt $_reconnectAttempts)...');
      _connectWebSocket();
    });
  }

  /// Activate REST polling as fallback when WS is down/blocked.
  void _startRestFallback() {
    if (_restFallbackTimer != null) return; // Already running.
    _log.i('[MexcWS] WS blocked — starting REST fallback every 5s');
    _restFallbackTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _fetchTicker24h();
    });
  }

  // ── Phase 11A2: Sharded Deals Farm ───────────────────────────────────────

  void _syncShardedDeals() {
    if (!_wsLive || _tickers.isEmpty) return;

    final allPairs = _tickers.keys.toList();
    if (allPairs.isEmpty) return;

    // 1. Identify Priority Pairs (Hot candidates, rockets, etc)
    final prioritySet = <String>{};
    prioritySet.addAll(viewNewListings.take(20).map((e) => e.symbol));
    prioritySet.addAll(viewFastGrowth.take(100).map((e) => e.symbol));
    prioritySet.addAll(viewMemeTrend.take(40).map((e) => e.symbol));
    prioritySet.addAll(viewMajors.take(20).map((e) => e.symbol));

    final priorityPairs = prioritySet.toList();
    if (priorityPairs.length > 180) {
      priorityPairs.length = 180; // Hard cap priority to 180 (6 shards)
    }

    // 2. Identify Rotating Pairs
    final priorityPairsSet = priorityPairs.toSet();
    final remainingPairs =
        allPairs.where((p) => !priorityPairsSet.contains(p)).toList();

    // Take up to 390 pairs for rotation (13 shards)
    final rotatingBatch = <String>[];
    if (remainingPairs.isNotEmpty) {
      if (_rotationCursor >= remainingPairs.length) {
        _rotationCursor = 0;
      }
      final end = (_rotationCursor + 390).clamp(0, remainingPairs.length);
      rotatingBatch.addAll(remainingPairs.sublist(_rotationCursor, end));

      // If we need to wrap around
      if (rotatingBatch.length < 390 && remainingPairs.length > 390) {
        final remainder = 390 - rotatingBatch.length;
        rotatingBatch.addAll(remainingPairs.sublist(0, remainder));
      }

      _log.i(
          '[MEXC_ROTATION_STEP] active=390 range=$_rotationCursor->${end} nextCursor=${(end) % remainingPairs.length}');
      _rotationCursor = (end) % remainingPairs.length;
    }

    // 3. Rebuild / Update shards (19 shards max)
    if (_dealShards.isEmpty) {
      for (int i = 1; i <= 19; i++) {
        final shard = _MexcTradeShard(i);
        shard.connect();
        _dealShards.add(shard);
      }
    }

    // Assign pairs to shards
    final targetPairs = [...priorityPairs, ...rotatingBatch];
    int pairIdx = 0;

    for (int i = 0; i < 19; i++) {
      final shard = _dealShards[i];
      final chunk = <String>[];
      for (int c = 0; c < 30 && pairIdx < targetPairs.length; c++) {
        chunk.add(targetPairs[pairIdx++]);
      }
      shard.updatePairs(chunk);
    }

    final trackedCount = targetPairs.length;
    _log.i('[MEXC_TAPE_COVERAGE]\n'
        '  mode=ALL_RADAR_ROTATING_TRADE_FLOW\n'
        '  trackedSymbols=$trackedCount\n'
        '  totalSymbols=${allPairs.length}\n'
        '  prioritySymbols=${priorityPairs.length}\n'
        '  rotatingSymbols=${rotatingBatch.length}\n'
        '  shards=19\n'
        '  rotationCursor=$_rotationCursor\n'
        '  cycleCoveragePct=${((trackedCount / allPairs.length) * 100).toStringAsFixed(1)}%');
  }

  void _promoteCandidate(String symbol, String reason) {
    if (_dealShards.isEmpty) return;

    // Check if already subscribed
    for (final shard in _dealShards) {
      if (shard.pairs.contains(symbol)) return;
    }

    // Pick a shard to evict from. We prefer the last rotating shard.
    final targetShard = _dealShards.last;
    if (targetShard.pairs.isEmpty) return;

    final evicted = targetShard.pairs.last;
    final newPairs = List<String>.from(targetShard.pairs);
    newPairs.removeLast();
    newPairs.insert(0, symbol);

    targetShard.updatePairs(newPairs);
    _log.w(
        '[MEXC_CANDIDATE_TRADE_FLOW_ARMED] symbol=$symbol reason=$reason evicted=$evicted');

    // Optional REST backfill could go here
  }

  // ── WS Message Handler ────────────────────────────────────────────────────

  void _onWsMessage(dynamic raw) {
    try {
      // MEXC sends protobuf as binary frames.
      // But subscription confirmations and pong come as JSON text.
      if (raw is String) {
        // JSON response (subscription confirmation, pong, error).
        if (raw.contains('PONG') || raw.contains('pong')) return;

        // ── Handle "Blocked" — MEXC refuses the subscription ──────────────
        if (raw.contains('Blocked')) {
          _log.w('miniTicker stream blocked by MEXC — keeping last tickers');
          _log.w(
              'Server response: ${raw.length > 300 ? raw.substring(0, 300) : raw}');
          _wsBlocked = true;
          _wsLive = false;
          _reconnectTimer?.cancel();
          _pingTimer?.cancel();
          _shardingTimer?.cancel();
          _wsSub?.cancel();
          _channel?.sink.close().catchError((_) {});
          _channel = null;
          // Fall back to REST polling so data keeps updating.
          _startRestFallback();
          return;
        }

        // -- Phase 11A2: Trade Flow Tape from MEXC JSON deals --
        // (Deals are parsed in _MexcTradeShard now, but we keep this here
        //  in case any deal stream was opened on the main connection)
        try {
          final data = jsonDecode(raw);
          if (data is Map<String, dynamic>) {
            final channel = data['c']?.toString() ?? '';
            if (channel.startsWith('spot@public.deals.v3.api@')) {
              final symbol = channel.split('@').last;
              final d = data['d'];
              if (d is Map<String, dynamic> && d['deals'] is List) {
                for (final t in d['deals']) {
                  if (t is! Map<String, dynamic>) continue;
                  final price = _toDouble(t['p']);
                  final qty = _toDouble(t['q']);
                  final sideInt = t['S']; // 1 = buy, 2 = sell
                  final side = sideInt == 1
                      ? 'buy'
                      : (sideInt == 2 ? 'sell' : 'unknown');
                  final ts = t['t'] is int
                      ? t['t'] as int
                      : int.tryParse(t['t'].toString()) ??
                          DateTime.now().millisecondsSinceEpoch;

                  ExchangeTradeFlowTape.instance.processPrint(TradePrint(
                    exchange: 'mexc',
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
              }
              return;
            }
          }
        } catch (_) {}

        // Log subscription confirmations for diagnostics.
        if (raw.contains('Subscribed') || raw.contains('code')) {
          _log.i(
              'WS response: ${raw.length > 300 ? raw.substring(0, 300) : raw}');
        } else {
          _log.d('WS text: ${raw.length > 200 ? raw.substring(0, 200) : raw}');
        }
        return;
      }

      // Binary protobuf data.
      final Uint8List bytes;
      if (raw is Uint8List) {
        bytes = raw;
      } else if (raw is List<int>) {
        bytes = Uint8List.fromList(raw);
      } else {
        _log.e('WS: unexpected data type: ${raw.runtimeType}');
        return;
      }

      if (bytes.isEmpty) return;

      // Decode the wrapper.
      final wrapper = MexcPushWrapper.fromBuffer(bytes);

      // Diagnostic: log channel and presence on first binary frame.
      if (!_loggedFirstBinary) {
        _loggedFirstBinary = true;
        _log.i('First binary frame: channel="${wrapper.channel}", '
            'hasMiniTickers=${wrapper.hasPublicMiniTickers}, '
            'bytes=${bytes.length}');
      }

      if (!wrapper.hasPublicMiniTickers) return;

      final tickers = wrapper.publicMiniTickers!;
      if (tickers.items.isEmpty) return;

      // Diagnostic: log first batch size + sample ticker.
      if (!_loggedFirstTickers) {
        _loggedFirstTickers = true;
        final sample = tickers.items.first;
        _log.i('First ticker batch: ${tickers.items.length} items, '
            'sample: ${sample.symbol} price=${sample.price} '
            'rate=${sample.rate} vol=${sample.volume}');
      }

      final List<LiveTicker> updatedList = [];
      for (final item in tickers.items) {
        final symbol = item.symbol;
        if (symbol.isEmpty || !symbol.endsWith('USDT')) continue;

        final base = symbol.replaceAll('USDT', '');
        if (_stables.contains(base)) continue;

        final lastPrice = _toDouble(item.price);
        if (lastPrice <= 0) continue;

        // rate is a decimal ratio, e.g. "0.0354" = +3.54%
        final rateRatio = _toDouble(item.rate);
        final priceChange = rateRatio * 100;

        final quoteVol = _toDouble(item.volume);
        final existing = _tickers[symbol];
        final meta = _meta[symbol];

        final ticker = LiveTicker(
          symbol: symbol,
          baseAsset: base,
          lastPrice: lastPrice,
          priceChangePercent24h: priceChange,
          volume24h: _toDouble(item.quantity),
          quoteVolume24h: quoteVol,
          highPrice24h: _toDouble(item.high),
          lowPrice24h: _toDouble(item.low),
          growthSinceListing: meta?.growthSinceListing,
          daysListed: meta?.daysListed,
          isNewlyListed: existing == null && _knownSymbols.isNotEmpty,
          risk: calcRisk(
            quoteVolume24h: quoteVol,
            daysListed: meta?.daysListed,
            priceChangePercent24h: priceChange,
          ),
        );

        _tickers[symbol] = ticker;
        updatedList.add(ticker);

        // New listing detected.
        if (existing == null &&
            _knownSymbols.isNotEmpty &&
            !_knownSymbols.contains(symbol)) {
          _newListings.add(_tickers[symbol]!);
          _knownSymbols.add(symbol);
          _log.i('NEW LISTING on MEXC (WS): $symbol');
          _promoteCandidate(symbol, 'newListing');
        } else if (existing != null) {
          // Detect abnormal acceleration (e.g. 2% jump in a single tick)
          if (existing.lastPrice > 0) {
            final jump =
                (lastPrice - existing.lastPrice).abs() / existing.lastPrice;
            if (jump > 0.02) {
              _promoteCandidate(symbol, 'priceSpike');
            }
          }
        }
      }

      _totalPairs = _tickers.length;

      if (updatedList.isNotEmpty) {
        _tickerController.add(updatedList);
      }
    } catch (e) {
      _log.e('WS parse error', e);
    }
  }

  // ── REST Ticker Poll (fallback only) ───────────────────────────────────────

  Future<void> _fetchTicker24h() async {
    try {
      final resp = await http.get(
        Uri.parse('$_restBase/ticker/24hr'),
        headers: const {'accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode != 200) {
        _log.e('Ticker poll HTTP ${resp.statusCode}');
        return;
      }

      final data = jsonDecode(resp.body);
      if (data is! List) {
        _log.e('[DIAG] Response is not a List: ${data.runtimeType}');
        return;
      }

      bool changed = false;
      for (final item in data) {
        if (item is! Map<String, dynamic>) continue;
        final symbol = item['symbol']?.toString() ?? '';
        if (!symbol.endsWith('USDT')) continue;

        final base = symbol.replaceAll('USDT', '');
        if (_stables.contains(base)) continue;

        final lastPrice = _toDouble(item['lastPrice']);
        if (lastPrice <= 0) continue;

        final existing = _tickers[symbol];
        final meta = _meta[symbol];

        final priceChange = _toDouble(item['priceChangePercent']);
        final quoteVol = _toDouble(item['quoteVolume']);
        final days = meta?.daysListed;

        _tickers[symbol] = LiveTicker(
          symbol: symbol,
          baseAsset: base,
          lastPrice: lastPrice,
          priceChangePercent24h: priceChange,
          volume24h: _toDouble(item['volume']),
          quoteVolume24h: quoteVol,
          highPrice24h: _toDouble(item['highPrice']),
          lowPrice24h: _toDouble(item['lowPrice']),
          growthSinceListing: meta?.growthSinceListing,
          daysListed: days,
          isNewlyListed: existing == null && _knownSymbols.isNotEmpty,
          risk: calcRisk(
            quoteVolume24h: quoteVol,
            daysListed: days,
            priceChangePercent24h: priceChange,
          ),
        );

        // New listing detected.
        if (existing == null &&
            _knownSymbols.isNotEmpty &&
            !_knownSymbols.contains(symbol)) {
          _newListings.add(_tickers[symbol]!);
          _knownSymbols.add(symbol);
          _log.i('NEW LISTING detected: $symbol');
        }

        changed = true;
      }

      _totalPairs = _tickers.length;

      if (changed) {
        _tickerController.add(currentTickers);
      }
    } catch (e) {
      _log.e('Ticker poll error', e);
    }
  }

  // ── REST Snapshot ──────────────────────────────────────────────────────────

  Future<void> _fetchRestSnapshot() async {
    try {
      // 1. Get exchange info (listing dates).
      final infoResp = await http.get(
        Uri.parse('$_restBase/exchangeInfo'),
        headers: const {'accept': 'application/json'},
      ).timeout(const Duration(seconds: 15));

      if (infoResp.statusCode != 200) return;
      final infoData = jsonDecode(infoResp.body);
      final symbols = infoData['symbols'] as List? ?? [];

      final now = DateTime.now().millisecondsSinceEpoch;
      const thirtyDaysMs = 30 * 24 * 60 * 60 * 1000;
      final newSymbolsThisPoll = <String>{};
      final recentSymbols = <String>[];

      for (final sym in symbols) {
        if (sym is! Map<String, dynamic>) continue;
        final s = sym['symbol']?.toString() ?? '';
        if (!s.endsWith('USDT')) continue;
        if (sym['status']?.toString() != '1') continue;

        newSymbolsThisPoll.add(s);

        final firstOpen = (sym['firstOpenTime'] as num?)?.toInt() ?? 0;
        if (firstOpen > 0 && now - firstOpen < thirtyDaysMs) {
          recentSymbols.add(s);
          final listingDate = DateTime.fromMillisecondsSinceEpoch(
            firstOpen,
            isUtc: true,
          );
          _meta[s] = _ListingMeta(
            listingDate: listingDate,
            daysListed: DateTime.now().toUtc().difference(listingDate).inDays,
          );
        }
      }

      // Detect newly listed symbols vs previous poll.
      if (_knownSymbols.isNotEmpty) {
        final brandNew = newSymbolsThisPoll.difference(_knownSymbols);
        for (final s in brandNew) {
          final existing = _tickers[s];
          if (existing != null) {
            _newListings.add(existing.copyWith(isNewlyListed: true));
            _log.i('NEW LISTING detected via REST poll: $s');
          }
        }
      }
      _knownSymbols = newSymbolsThisPoll;
      _totalPairs = newSymbolsThisPoll.length;

      // 2. Get opening prices for recent symbols to calculate growth.
      // Do max 20 to not hit rate limits.
      final toEnrich = recentSymbols.take(20).toList();
      for (final s in toEnrich) {
        if (_meta[s]?.growthSinceListing != null) continue;
        final listingTs = _meta[s]!.listingDate.millisecondsSinceEpoch;
        try {
          final klineResp = await http.get(
            Uri.parse(
                '$_restBase/klines?symbol=$s&interval=1d&startTime=$listingTs&limit=1'),
            headers: const {'accept': 'application/json'},
          ).timeout(const Duration(seconds: 5));

          if (klineResp.statusCode == 200) {
            final kd = jsonDecode(klineResp.body);
            if (kd is List && kd.isNotEmpty) {
              final candle = kd[0];
              if (candle is List && candle.length >= 2) {
                final openPrice = _toDouble(candle[1]);
                final currentPrice = _tickers[s]?.lastPrice ?? 0;
                if (openPrice > 0 && currentPrice > 0) {
                  _meta[s] = _meta[s]!.copyWith(
                    growthSinceListing:
                        ((currentPrice - openPrice) / openPrice) * 100,
                  );
                }
              }
            }
          }
        } catch (e) {
          _log.d('kline enrich for $s: $e');
        }
      }

      _tickerController.add(currentTickers);
    } catch (e) {
      _log.e('REST snapshot error', e);
    }
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

  /// Subscribe to a single pair's individual ticker stream on MEXC.
  /// Opens a separate WebSocket to `wss://wbs-api.mexc.com/ws` and subscribes
  /// to `spot@public.miniTicker.v3.api.pb@<PAIR>@UTC+8` (singular per-pair).
  ///
  /// Returns a [PairSubscription] — caller MUST call `.dispose()` in widget.dispose().
  PairSubscription subscribePair(String pair) {
    final controller = StreamController<LiveTicker>.broadcast();
    _log.i('[MexcWS] pair subscribe $pair');

    WebSocketChannel? ws;
    StreamSubscription? sub;
    Timer? ping;
    bool loggedFirst = false;

    void connect() {
      try {
        ws = WebSocketChannel.connect(Uri.parse(_wsUrl));

        sub = ws!.stream.listen(
          (raw) {
            try {
              // MEXC sends text for confirmations, binary for data.
              if (raw is String) {
                if (raw.contains('PONG') || raw.contains('pong')) return;
                if (raw.contains('Blocked')) {
                  _log.w('[MexcWS] pair stream blocked for $pair: '
                      '${raw.length > 200 ? raw.substring(0, 200) : raw}');
                  return;
                }
                _log.d('[MexcWS] pair text ($pair): '
                    '${raw.length > 200 ? raw.substring(0, 200) : raw}');
                return;
              }

              // Binary protobuf data.
              final Uint8List bytes;
              if (raw is Uint8List) {
                bytes = raw;
              } else if (raw is List<int>) {
                bytes = Uint8List.fromList(raw);
              } else {
                return;
              }
              if (bytes.isEmpty) return;

              final wrapper = MexcPushWrapper.fromBuffer(bytes);

              // Diagnostic: log first frame from this pair stream.
              if (!loggedFirst) {
                loggedFirst = true;
                _log.i('[MexcWS] pair frame $pair channel="${wrapper.channel}" '
                    'hasMiniTickers=${wrapper.hasPublicMiniTickers} '
                    'bytes=${bytes.length}');
              }

              if (!wrapper.hasPublicMiniTickers) return;

              final tickers = wrapper.publicMiniTickers!;
              // Filter for our specific pair.
              for (final item in tickers.items) {
                if (item.symbol != pair) continue;

                final lastPrice = _toDouble(item.price);
                if (lastPrice <= 0) continue;

                final rateRatio = _toDouble(item.rate);
                final priceChange = rateRatio * 100;
                final base = pair.replaceAll('USDT', '');

                final ticker = LiveTicker(
                  symbol: pair,
                  baseAsset: base,
                  lastPrice: lastPrice,
                  priceChangePercent24h: priceChange,
                  volume24h: _toDouble(item.quantity),
                  quoteVolume24h: _toDouble(item.volume),
                  highPrice24h: _toDouble(item.high),
                  lowPrice24h: _toDouble(item.low),
                );

                // Also update the main ticker map so terminal stays in sync.
                _tickers[pair] = ticker;

                _log.d('[MexcWS] pair tick $pair '
                    'price=$lastPrice change=$priceChange');

                controller.add(ticker);
              }
            } catch (e) {
              _log.e('[MexcWS] pair stream parse error ($pair)', e);
            }
          },
          onError: (e) => _log.e('[MexcWS] pair stream error ($pair)', e),
          onDone: () => _log.i('[MexcWS] pair stream closed ($pair)'),
        );

        // Subscribe to singular per-pair miniTicker channel.
        final channelName = 'spot@public.miniTicker.v3.api.pb@$pair@UTC+8';
        ws!.sink.add(jsonEncode({
          'method': 'SUBSCRIPTION',
          'params': [channelName],
        }));
        _log.i('[MexcWS] subscribed: $channelName');

        // Ping keepalive.
        ping?.cancel();
        ping = Timer.periodic(
          const Duration(seconds: 20),
          (_) {
            try {
              ws?.sink.add(jsonEncode({'method': 'PING'}));
            } catch (_) {}
          },
        );
      } catch (e) {
        _log.e('[MexcWS] pair stream connect failed ($pair)', e);
      }
    }

    connect();

    return PairSubscription(
      stream: controller.stream,
      dispose: () {
        ping?.cancel();
        sub?.cancel();
        ws!.sink.close().catchError((_) {});
        controller.close();
        _log.i('[MexcWS] pair stream disposed ($pair)');
      },
    );
  }
}

// ── Internal helpers ──────────────────────────────────────────────────────────

class _ListingMeta {
  final DateTime listingDate;
  final int daysListed;
  final double? growthSinceListing;

  const _ListingMeta({
    required this.listingDate,
    required this.daysListed,
    this.growthSinceListing,
  });

  _ListingMeta copyWith({double? growthSinceListing}) => _ListingMeta(
        listingDate: listingDate,
        daysListed: daysListed,
        growthSinceListing: growthSinceListing ?? this.growthSinceListing,
      );
}

class _MexcTradeShard {
  final int id;
  List<String> pairs = [];

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _ping;
  bool _disposed = false;

  _MexcTradeShard(this.id);

  void connect() {
    if (_disposed) return;
    try {
      _channel =
          WebSocketChannel.connect(Uri.parse('wss://wbs-api.mexc.com/ws'));
      _sub = _channel!.stream.listen(
        _onMessage,
        onError: (e) {
          if (!_disposed) _scheduleReconnect();
        },
        onDone: () {
          if (!_disposed) _scheduleReconnect();
        },
      );

      _ping?.cancel();
      _ping = Timer.periodic(const Duration(seconds: 20), (_) {
        try {
          _channel?.sink.add(jsonEncode({'method': 'PING'}));
        } catch (_) {}
      });

      if (pairs.isNotEmpty) {
        _sendSubscribe(pairs);
      }
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void updatePairs(List<String> newPairs) {
    if (_disposed || _channel == null) {
      pairs = List.from(newPairs);
      return;
    }

    final currentSet = pairs.toSet();
    final newSet = newPairs.toSet();

    final toUnsubscribe = currentSet.difference(newSet).toList();
    final toSubscribe = newSet.difference(currentSet).toList();

    if (toUnsubscribe.isNotEmpty) {
      _sendUnsubscribe(toUnsubscribe);
    }
    if (toSubscribe.isNotEmpty) {
      _sendSubscribe(toSubscribe);
    }

    pairs = List.from(newPairs);
  }

  void _sendSubscribe(List<String> targets) {
    if (_channel == null || targets.isEmpty) return;
    final params = targets
        .map((s) => 'spot@public.aggre.deals.v3.api.pb@100ms@$s')
        .toList();
    _channel!.sink.add(jsonEncode({
      'method': 'SUBSCRIPTION',
      'params': params,
    }));
  }

  void _sendUnsubscribe(List<String> targets) {
    if (_channel == null || targets.isEmpty) return;
    final params = targets
        .map((s) => 'spot@public.aggre.deals.v3.api.pb@100ms@$s')
        .toList();
    _channel!.sink.add(jsonEncode({
      'method': 'UNSUBSCRIPTION',
      'params': params,
    }));
  }

  void _scheduleReconnect() {
    dispose(reconnect: true);
    if (!_disposed) {
      Timer(const Duration(seconds: 5), connect);
    }
  }

  void _onMessage(dynamic raw) {
    if (raw is String) {
      if (raw.contains('Blocked') || raw.contains('Not Subscribed')) {
        print('[MexcTradeShard] $id BLOCKED/FAILED: $raw');
      }
      return;
    }

    if (raw is List<int>) {
      final str = utf8.decode(raw, allowMalformed: true);

      final channelRegex =
          RegExp(r'spot@public\.aggre\.deals\.v3\.api\.pb@100ms@([A-Z0-9]+)');
      final channelMatch = channelRegex.firstMatch(str);
      if (channelMatch == null) return;

      final symbol = channelMatch.group(1)!;

      final tradeRegex = RegExp(
          r'\x0A[\x01-\x1F]([0-9]+(?:\.[0-9]+)?)\x12[\x01-\x1F]([0-9]+(?:\.[0-9]+)?)\x18([\x01\x02])');
      final matches = tradeRegex.allMatches(str);

      for (final m in matches) {
        try {
          final price = double.parse(m.group(1)!);
          final qty = double.parse(m.group(2)!);
          final sideByte = m.group(3)!.codeUnitAt(0);
          final side = sideByte == 1 ? 'buy' : 'sell';

          ExchangeTradeFlowTape.instance.processPrint(TradePrint(
            exchange: 'mexc',
            symbol: symbol,
            timestamp: DateTime.now(),
            price: price,
            baseQty: qty,
            quoteUsd: qty * price,
            side: side,
            source: TradeSource.ws,
            confidence: 'high',
          ));
        } catch (_) {}
      }
    }
  }

  static double _toDoubleLocal(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? 0.0;
  }

  void dispose({bool reconnect = false}) {
    if (!reconnect) _disposed = true;
    _ping?.cancel();
    _sub?.cancel();
    _channel?.sink.close().catchError((_) {});
    _channel = null;
  }
}
