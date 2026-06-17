// ─── Candle History Service ──────────────────────────────────────────────────────
//
// Phase 7: Production-grade Candle Intelligence Layer.
//
// Design principles:
//   1. NEVER block IbitiLoop on REST. Brain gets cached/empty, never waits.
//   2. Per-tick fetch budget: max N fresh fetches per tick cycle.
//   3. Smart cache: TTL, stale detection, fallback tracking, error memory.
//   4. Validation: sort ascending, drop invalid candles, deduplicate.
//   5. Multi-timeframe ready: 5m now, 1m/15m/1h structure in place.
//
// Flow per tick:
//   1. Loop calls startTickBudget() at beginning of tick.
//   2. For each event, Loop calls getSnapshot() — non-blocking.
//   3. If cache is fresh → return immediately.
//   4. If cache is stale/empty AND budget remains → fire REST fetch.
//   5. If budget exceeded → return stale cache or empty snapshot.
//   6. All fetches are counted and logged.
//
// Supported exchanges (public endpoints, no API key):
//   • Binance:  GET /api/v3/klines
//   • Bybit:    GET /v5/market/kline
//   • Gate.io:  GET /api/v4/spot/candlesticks
//   • MEXC:     GET /api/v3/klines
// ─────────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/services/ibiti/models/candle.dart';
import 'package:ibiti_guardian/services/ibiti/models/candle_snapshot.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_account_store.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

const _log = GuardianLogger('CandleHistory');

class CandleHistoryService {
  CandleHistoryService._();
  static final CandleHistoryService instance = CandleHistoryService._();

  // ── Configuration ──────────────────────────────────────────────────────────

  /// Cache time-to-live. After this, candles are considered stale.
  static const cacheTtl = Duration(minutes: 3);

  /// REST request timeout.
  static const _timeout = Duration(seconds: 5);

  /// Default candle count to fetch (100 × 5m = ~8.3 hours of history).
  static const _defaultLimit = 100;

  /// Maximum fresh REST requests allowed per tick cycle.
  /// Base budget for normal getSnapshot() calls during event processing.
  static const int maxFreshFetchesPerTick = 20;

  /// Additional budget reserved for prefetch candidates.
  /// These slots fire BEFORE event processing to warm TA for top candidates.
  static const int maxPrefetchFetchesPerTick = 12;

  /// Maximum concurrent HTTP requests in flight.
  static const int maxConcurrentFetches = 20;

  // ── Exchange endpoints ─────────────────────────────────────────────────────

  static const _binanceBase = 'https://api.binance.com';
  static const _okxBase = 'https://eea.okx.com';
  static const _gateBase = 'https://api.gateio.ws/api/v4';
  static const _mexcBase = 'https://api.mexc.com';

  // ── State ──────────────────────────────────────────────────────────────────

  final Map<String, _CacheEntry> _cache = {};
  final Set<String> _inFlight = {};

  int _tickFetchesUsed = 0;
  int _prefetchFetchesUsed = 0;
  int _activeFetches = 0;

  final Map<String, DateTime> _lastFlowLog = {};

  // ── Stats ──────────────────────────────────────────────────────────────────

  int _totalFetches = 0;
  int _totalCacheHits = 0;
  int _totalFallbackHits = 0;
  int _totalErrors = 0;
  int _totalBudgetSkips = 0;
  int _totalDuplicateSkips = 0;
  int _totalPrefetches = 0;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Call at the beginning of each tick cycle to reset fetch budget.
  void startTickBudget() {
    _tickFetchesUsed = 0;
    _prefetchFetchesUsed = 0;
  }

  // ── Prefetch API ────────────────────────────────────────────────────────────

  /// Pre-warm candle cache for high-priority candidates.
  /// Called BEFORE event processing loop so that when getSnapshot() runs
  /// later for these symbols, the cache is already hot.
  ///
  /// Uses a separate budget from normal fetches so it doesn't starve
  /// the event processing loop.
  ///
  /// [candidates] — list of {symbol, exchange} maps, already prioritized.
  /// Returns the number of symbols for which fetches were actually scheduled.
  int prefetchCandidates(List<({String symbol, String exchange})> candidates) {
    if (candidates.isEmpty) return 0;

    int scheduled = 0;
    int alreadyReady = 0;

    for (final c in candidates) {
      if (_prefetchFetchesUsed >= maxPrefetchFetchesPerTick) break;

      final pair = _toPair(c.symbol);
      final key5m = '${c.exchange}:$pair:5m';

      // Already fresh in cache — no need to prefetch.
      final cached = _cache[key5m];
      if (cached != null && !cached.isStale && cached.candles.isNotEmpty) {
        alreadyReady++;
        continue;
      }

      // Already in flight — skip.
      if (_inFlight.contains(key5m)) {
        alreadyReady++;
        continue;
      }

      // Schedule the 5m fetch (anchor timeframe).
      if (_activeFetches < maxConcurrentFetches) {
        _inFlight.add(key5m);
        _prefetchFetchesUsed++;
        _activeFetches++;
        _totalPrefetches++;
        unawaited(_fetchAndCache(pair, c.exchange, '5m').whenComplete(() {
          _activeFetches--;
          _inFlight.remove(key5m);
        }));
        scheduled++;
      }
    }

    if (scheduled > 0 || alreadyReady > 0) {
      _log.i('[Prefetch] candidates=${candidates.length} '
          'scheduled=$scheduled ready=$alreadyReady');
    }
    return scheduled;
  }

  // ── Awaitable Prefetch (warm list only) ───────────────────────────────────

  /// Awaitable version of prefetchCandidates for HIGH-PRIORITY warm list.
  /// Unlike fire-and-forget prefetchCandidates(), this WAITS for HTTP
  /// responses to arrive (with timeout) so TA data is ready when JARVIS
  /// processes events.
  ///
  /// Use sparingly — max 5 symbols per tick.
  /// Returns stats for logging.
  Future<({int scheduled, int ready, int pending, bool hitTimeout})>
      awaitPrefetchCandidates(
    List<({String symbol, String exchange})> candidates, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    if (candidates.isEmpty) {
      return (scheduled: 0, ready: 0, pending: 0, hitTimeout: false);
    }

    int alreadyReady = 0;
    int alreadyPending = 0;
    final futures = <Future<void>>[];

    for (final c in candidates) {
      if (_prefetchFetchesUsed >= maxPrefetchFetchesPerTick) break;

      final pair = _toPair(c.symbol);
      final key5m = '${c.exchange}:$pair:5m';

      // Already fresh in cache — no fetch needed.
      final cached = _cache[key5m];
      if (cached != null && !cached.isStale && cached.candles.isNotEmpty) {
        alreadyReady++;
        continue;
      }

      // Already in flight from a previous call.
      if (_inFlight.contains(key5m)) {
        // inFlight + stale cache with data = usable (partial/stale ready).
        if (cached != null && cached.candles.isNotEmpty) {
          alreadyReady++;
        } else {
          // inFlight + no cache = NOT ready, data is still downloading.
          alreadyPending++;
        }
        continue;
      }

      // Schedule and COLLECT the future (don't unawaited).
      if (_activeFetches < maxConcurrentFetches) {
        _inFlight.add(key5m);
        _prefetchFetchesUsed++;
        _activeFetches++;
        _totalPrefetches++;
        final f = _fetchAndCache(pair, c.exchange, '5m').whenComplete(() {
          _activeFetches--;
          _inFlight.remove(key5m);
        });
        futures.add(f);
      }
    }

    if (futures.isEmpty) {
      return (
        scheduled: 0,
        ready: alreadyReady,
        pending: alreadyPending,
        hitTimeout: false,
      );
    }

    // AWAIT all fetches with timeout.
    // On timeout the futures keep running in background — they'll populate
    // the cache for subsequent ticks, so nothing is wasted.
    bool hitTimeout = false;
    try {
      await Future.wait(futures).timeout(timeout);
    } on TimeoutException {
      hitTimeout = true;
    } catch (_) {
      // Individual fetch errors are handled inside _fetchAndCache.
    }

    return (
      scheduled: futures.length,
      ready: alreadyReady,
      pending: alreadyPending,
      hitTimeout: hitTimeout,
    );
  }

  /// Check if a symbol already has fresh TA data ready.
  bool hasFreshCache({required String symbol, required String exchange}) {
    final pair = _toPair(symbol);
    final key5m = '$exchange:$pair:5m';
    final cached = _cache[key5m];
    return cached != null && !cached.isStale && cached.candles.isNotEmpty;
  }

  /// Get a candle snapshot for [symbol] on [exchange].
  /// Synchronous, NEVER blocks. Returns cached data or empty snapshot.
  /// Schedules background fetch if cache is stale/missing and budget allows.
  CandleSnapshot getSnapshot({
    required String symbol,
    required String exchange,
  }) {
    final pair = _toPair(symbol);
    final key1m = '$exchange:$pair:1m';
    final key5m = '$exchange:$pair:5m';
    final key15m = '$exchange:$pair:15m';
    final key1h = '$exchange:$pair:1h';

    // 1. Check cache.
    final cached1m = _cache[key1m];
    final cached5m = _cache[key5m];
    final cached15m = _cache[key15m];
    final cached1h = _cache[key1h];

    if (cached5m != null && !cached5m.isStale) {
      _totalCacheHits++;
      _scheduleMissingOrStaleTimeframes(pair, exchange, {
        '1m': cached1m,
        '15m': cached15m,
        '1h': cached1h,
      });
      return CandleSnapshot(
        candles1m: cached1m?.candles ?? const [],
        candles5m: cached5m.candles,
        candles15m: cached15m?.candles ?? const [],
        candles1h: cached1h?.candles ?? const [],
        isFresh: cached5m.candles.isNotEmpty,
        isFallback: cached5m.isFallback,
        sourceExchange: cached5m.sourceExchange,
        warning: cached5m.candles.isEmpty ? 'cached empty/no data' : null,
      );
    }

    // 1.5 Check in-flight duplicate (using 5m as anchor).
    if (_inFlight.contains(key5m)) {
      _totalDuplicateSkips++;
      if (cached5m != null && cached5m.candles.isNotEmpty) {
        return CandleSnapshot(
          candles1m: cached1m?.candles ?? const [],
          candles5m: cached5m.candles,
          candles15m: cached15m?.candles ?? const [],
          candles1h: cached1h?.candles ?? const [],
          isFresh: false,
          isFallback: cached5m.isFallback,
          sourceExchange: cached5m.sourceExchange,
          warning: 'stale (fetching in background)',
        );
      }
      return CandleSnapshot.empty;
    }

    // 2. Try to schedule fetches.
    final scheduled5m = _scheduleFetch(pair, exchange, '5m');
    _scheduleMissingOrStaleTimeframes(pair, exchange, {
      '1m': cached1m,
      '15m': cached15m,
      '1h': cached1h,
    });

    if (!scheduled5m) {
      // 3. Return stale cache if available.
      if (cached5m != null && cached5m.candles.isNotEmpty) {
        return CandleSnapshot(
          candles1m: cached1m?.candles ?? const [],
          candles5m: cached5m.candles,
          candles15m: cached15m?.candles ?? const [],
          candles1h: cached1h?.candles ?? const [],
          isFresh: false,
          isFallback: cached5m.isFallback,
          sourceExchange: cached5m.sourceExchange,
          warning: 'stale (budget exceeded)',
        );
      }
      return CandleSnapshot.empty;
    }

    // 4. Return stale or empty snapshot immediately while fetch runs.
    if (cached5m != null && cached5m.candles.isNotEmpty) {
      return CandleSnapshot(
        candles1m: cached1m?.candles ?? const [],
        candles5m: cached5m.candles,
        candles15m: cached15m?.candles ?? const [],
        candles1h: cached1h?.candles ?? const [],
        isFresh: false,
        isFallback: cached5m.isFallback,
        sourceExchange: cached5m.sourceExchange,
        warning: 'stale (fetching in background)',
      );
    }
    return CandleSnapshot.empty;
  }

  /// Summary string for periodic logging.
  String get summary {

    return 'Candles: fetched=$_totalFetches prefetched=$_totalPrefetches '
        'hits=$_totalCacheHits '
        'fallback=$_totalFallbackHits errors=$_totalErrors '
        'budgetSkips=$_totalBudgetSkips dupSkips=$_totalDuplicateSkips '
        'cached=${_cache.length}';
  }

  /// Evict stale cache entries older than 10 minutes.
  /// Call from hourly hygiene.
  void evictStale() {
    final now = DateTime.now();
    final staleKeys = _cache.entries
        .where((e) =>
            now.difference(e.value.fetchedAt) > const Duration(minutes: 10))
        .map((e) => e.key)
        .toList();
    for (final k in staleKeys) {
      _cache.remove(k);
    }
    if (staleKeys.isNotEmpty) {
      _log.d('Evicted ${staleKeys.length} stale candle caches');
    }
  }

  // ── Internal fetch logic ───────────────────────────────────────────────────

  void _scheduleMissingOrStaleTimeframes(
      String pair, String exchange, Map<String, _CacheEntry?> entries) {
    for (final entry in entries.entries) {
      final interval = entry.key;
      final cached = entry.value;
      if (cached == null || cached.isStale) {
        _scheduleFetch(pair, exchange, interval);
      }
    }
  }

  bool _scheduleFetch(String pair, String exchange, String interval) {
    final key = '$exchange:$pair:$interval';
    if (_inFlight.contains(key)) {
      _totalDuplicateSkips++;
      return false;
    }

    if (_tickFetchesUsed >= maxFreshFetchesPerTick ||
        _activeFetches >= maxConcurrentFetches) {
      _totalBudgetSkips++;
      return false;
    }

    _inFlight.add(key);
    _tickFetchesUsed++;
    _activeFetches++;

    unawaited(_fetchAndCache(pair, exchange, interval).whenComplete(() {
      _activeFetches--;
      _inFlight.remove(key);
    }));

    return true;
  }

  Future<void> _fetchAndCache(
      String pair, String exchange, String interval) async {
    _totalFetches++;
    var isFallback = false;
    var sourceExchange = exchange;

    // Try the event's exchange first.
    var candles = await _fetchFromExchange(pair, exchange, interval);

    // Fallback to Binance if empty/failed.
    if (candles.isEmpty && exchange != 'binance') {
      candles = await _fetchFromExchange(pair, 'binance', interval);
      if (candles.isNotEmpty) {
        isFallback = true;
        sourceExchange = 'binance';
        _totalFallbackHits++;
      }
    }

    // Sanitize: validate, sort, deduplicate.
    candles = sanitizeCandles(candles);

    // Cache result (even if empty — prevents repeated failed fetches).
    final entry = _CacheEntry(
      candles: candles,
      fetchedAt: DateTime.now(),
      isFallback: isFallback,
      sourceExchange: sourceExchange,
    );
    _cache['$exchange:$pair:$interval'] = entry;

    // Phase 11A: Log exchange flow data (throttled to 1 min per pair/interval)
    if (candles.isNotEmpty) {
      final last = candles.last;
      if (last.takerBuyQuoteVolume != null) {
        final now = DateTime.now();
        final keyLog = '$exchange:$pair:$interval';
        final lastLog = _lastFlowLog[keyLog];
        if (lastLog == null || now.difference(lastLog).inMinutes >= 1) {
          _lastFlowLog[keyLog] = now;
          _log.d(
              '[EXCHANGE_FLOW] exchange=$sourceExchange symbol=$pair interval=$interval '
              'baseVol=${last.baseVolume?.toStringAsFixed(2)} '
              'quoteVol=${last.quoteVolume?.toStringAsFixed(2)} '
              'takerBuyBase=${last.takerBuyBaseVolume?.toStringAsFixed(2)} '
              'takerBuyUsd=${last.takerBuyQuoteVolume?.toStringAsFixed(2)} '
              'takerSellBase=${last.takerSellBaseVolume?.toStringAsFixed(2)} '
              'takerSellUsd=${last.takerSellQuoteVolume?.toStringAsFixed(2)} '
              'buyPressure=${last.buyPressure?.toStringAsFixed(2)}');
        }
      }
    }
  }

  // ── Exchange router ────────────────────────────────────────────────────────

  Future<List<Candle>> _fetchFromExchange(
      String pair, String exchange, String interval) async {
    try {
      switch (exchange.toLowerCase()) {
        case 'binance':
          return await _fetchBinance(pair, interval);
        case 'okx':
          return await _fetchOkx(pair, interval);
        case 'gateio':
          return await _fetchGate(pair, interval);
        case 'mexc':
          return await _fetchMexc(pair, interval);
        default:
          return await _fetchBinance(pair, interval);
      }
    } catch (e) {
      _totalErrors++;
      _log.w('Fetch $exchange:$pair:$interval failed', e);
      return const [];
    }
  }

  // ── Binance ────────────────────────────────────────────────────────────────
  // GET /api/v3/klines?symbol=BTCUSDT&interval=5m&limit=100
  // Returns: [[openTime, open, high, low, close, volume, closeTime, ...], ...]

  Future<List<Candle>> _fetchBinance(String pair, String interval) async {
    final uri = Uri.parse('$_binanceBase/api/v3/klines').replace(
      queryParameters: {
        'symbol': pair,
        'interval': interval,
        'limit': '$_defaultLimit',
      },
    );
    final resp = await http.get(uri).timeout(_timeout);
    if (resp.statusCode != 200) return const [];

    final data = jsonDecode(resp.body);
    if (data is! List || data.isEmpty) return const [];

    return parseBinanceKlines(data);
  }

  /// Visible for testing: Binance parser
  static List<Candle> parseBinanceKlines(List<dynamic> data) {
    return data.map<Candle>((k) {
      final baseVol = double.tryParse(k[5].toString()) ?? 0;
      final quoteVol = double.tryParse(k[7].toString()) ?? 0;
      final takerBuyBase = double.tryParse(k[9].toString()) ?? 0;
      final takerBuyQuote = double.tryParse(k[10].toString()) ?? 0;

      final takerSellBase = baseVol - takerBuyBase;
      final takerSellQuote = quoteVol - takerBuyQuote;
      final buyPressure = quoteVol > 0 ? takerBuyQuote / quoteVol : 0.0;

      return Candle(
        openTime: k[0] as int,
        open: double.tryParse(k[1].toString()) ?? 0,
        high: double.tryParse(k[2].toString()) ?? 0,
        low: double.tryParse(k[3].toString()) ?? 0,
        close: double.tryParse(k[4].toString()) ?? 0,
        volume: baseVol,
        baseVolume: baseVol,
        quoteVolume: quoteVol,
        takerBuyBaseVolume: takerBuyBase,
        takerBuyQuoteVolume: takerBuyQuote,
        takerSellBaseVolume: takerSellBase,
        takerSellQuoteVolume: takerSellQuote,
        buyPressure: buyPressure,
      );
    }).toList();
  }

  // ── OKX ────────────────────────────────────────────────────────────────────
  // GET /api/v5/market/candles?instId=BTC-USDT&bar=5m&limit=100
  // OKX intervals: 1m, 3m, 5m, 15m, 30m, 1H, 2H, 4H, 1D, 1W, 1M
  // NOTE: OKX returns candles in REVERSE order (newest first)!

  Future<List<Candle>> _fetchOkx(String pair, String interval) async {
    final okxInterval = _toOkxInterval(interval);
    final instId = pair.contains('-') ? pair : pair.replaceAll('USDT', '-USDT');
    
    final region = await ExchangeAccountStore.instance.getOkxRegion();
    final baseUrl = region == 'eea' ? 'https://eea.okx.com' : 'https://www.okx.com';

    final uri = Uri.parse('$baseUrl/api/v5/market/candles').replace(
      queryParameters: {
        'instId': instId,
        'bar': okxInterval,
        'limit': '$_defaultLimit',
      },
    );
    final resp = await http.get(uri).timeout(_timeout);
    if (resp.statusCode != 200) return const [];

    final json = jsonDecode(resp.body);
    final list = json['data'];
    if (list is! List || list.isEmpty) return const [];

    return parseOkxKlines(list);
  }

  /// Visible for testing: OKX parser (reverses list to oldest-first)
  static List<Candle> parseOkxKlines(List<dynamic> list) {
    return list.reversed.map<Candle>((k) {
      final baseVol = double.tryParse(k[5].toString()) ?? 0;
      final quoteVol = double.tryParse(k[6].toString()) ?? 0;

      return Candle(
        openTime: int.tryParse(k[0].toString()) ?? 0,
        open: double.tryParse(k[1].toString()) ?? 0,
        high: double.tryParse(k[2].toString()) ?? 0,
        low: double.tryParse(k[3].toString()) ?? 0,
        close: double.tryParse(k[4].toString()) ?? 0,
        volume: baseVol,
        baseVolume: baseVol,
        quoteVolume: quoteVol,
      );
    }).toList();
  }

  String _toOkxInterval(String interval) {
    switch (interval.toLowerCase()) {
      case '1m':
        return '1m';
      case '3m':
        return '3m';
      case '5m':
        return '5m';
      case '15m':
        return '15m';
      case '30m':
        return '30m';
      case '1h':
        return '1H';
      case '4h':
        return '4H';
      case '1d':
        return '1D';
      default:
        return '5m';
    }
  }

  // ── Gate.io ────────────────────────────────────────────────────────────────
  // GET /api/v4/spot/candlesticks?currency_pair=BTC_USDT&interval=5m&limit=100
  // Gate uses underscore pairs: BTC_USDT
  // Returns: [[timestamp, volume, close, high, low, open, isWindow], ...]
  // NOTE: Gate field order is different! Index 5=open, 2=close, 3=high, 4=low.

  Future<List<Candle>> _fetchGate(String pair, String interval) async {
    final gatePair = _toGatePair(pair);
    final uri = Uri.parse('$_gateBase/spot/candlesticks').replace(
      queryParameters: {
        'currency_pair': gatePair,
        'interval': interval,
        'limit': '$_defaultLimit',
      },
    );
    final resp = await http.get(uri).timeout(_timeout);
    if (resp.statusCode != 200) return const [];

    final data = jsonDecode(resp.body);
    if (data is! List || data.isEmpty) return const [];

    return parseGateKlines(data);
  }

  /// Visible for testing: Gate parser
  static List<Candle> parseGateKlines(List<dynamic> data) {
    // Gate.io: [unix_ts, quote_vol, close, high, low, open, base_vol]
    return data.map<Candle>((k) {
      final quoteVol = double.tryParse(k[1].toString()) ?? 0;
      final baseVol = double.tryParse(k[6].toString()) ?? 0;

      return Candle(
        openTime: (int.tryParse(k[0].toString()) ?? 0) * 1000, // s → ms
        open: double.tryParse(k[5].toString()) ?? 0,
        high: double.tryParse(k[3].toString()) ?? 0,
        low: double.tryParse(k[4].toString()) ?? 0,
        close: double.tryParse(k[2].toString()) ?? 0,
        volume: baseVol,
        baseVolume: baseVol,
        quoteVolume: quoteVol,
      );
    }).toList();
  }

  String _toGatePair(String pair) {
    final upper = pair.toUpperCase();
    if (upper.endsWith('USDT')) {
      return '${upper.substring(0, upper.length - 4)}_USDT';
    }
    return upper;
  }

  // ── MEXC ───────────────────────────────────────────────────────────────────
  // GET /api/v3/klines?symbol=BTCUSDT&interval=5m&limit=100
  // Same format as Binance. BUT: MEXC uses '60m' not '1h'.

  Future<List<Candle>> _fetchMexc(String pair, String interval) async {
    final mexcInterval = interval == '1h' ? '60m' : interval;
    final uri = Uri.parse('$_mexcBase/api/v3/klines').replace(
      queryParameters: {
        'symbol': pair,
        'interval': mexcInterval,
        'limit': '$_defaultLimit',
      },
    );
    final resp = await http.get(uri).timeout(_timeout);
    if (resp.statusCode != 200) return const [];

    final data = jsonDecode(resp.body);
    if (data is! List || data.isEmpty) return const [];

    return parseMexcKlines(data);
  }

  /// Visible for testing: MEXC parser (isolated since MEXC arrays may be shorter)
  static List<Candle> parseMexcKlines(List<dynamic> data) {
    return data.map<Candle>((k) {
      if (k is! List || k.length < 6) {
        return const Candle(
            openTime: 0, open: 0, high: 0, low: 0, close: 0, volume: 0);
      }

      final baseVol = double.tryParse(k[5].toString()) ?? 0;
      double? quoteVol;
      double? takerBuyBase;
      double? takerBuyQuote;
      double? takerSellBase;
      double? takerSellQuote;
      double? buyPressure;

      if (k.length > 7) {
        quoteVol = double.tryParse(k[7].toString()) ?? 0;
      }

      if (k.length > 10) {
        takerBuyBase = double.tryParse(k[9].toString()) ?? 0;
        takerBuyQuote = double.tryParse(k[10].toString()) ?? 0;
        takerSellBase = baseVol - takerBuyBase;
        takerSellQuote = (quoteVol ?? 0) - takerBuyQuote;
        buyPressure =
            (quoteVol != null && quoteVol > 0) ? takerBuyQuote / quoteVol : 0.0;
      }

      return Candle(
        openTime: k[0] is int ? k[0] : (int.tryParse(k[0].toString()) ?? 0),
        open: double.tryParse(k[1].toString()) ?? 0,
        high: double.tryParse(k[2].toString()) ?? 0,
        low: double.tryParse(k[3].toString()) ?? 0,
        close: double.tryParse(k[4].toString()) ?? 0,
        volume: baseVol,
        baseVolume: baseVol,
        quoteVolume: quoteVol,
        takerBuyBaseVolume: takerBuyBase,
        takerBuyQuoteVolume: takerBuyQuote,
        takerSellBaseVolume: takerSellBase,
        takerSellQuoteVolume: takerSellQuote,
        buyPressure: buyPressure,
      );
    }).toList();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Ensure pair has USDT suffix.
  String _toPair(String symbol) {
    final upper = symbol.toUpperCase();
    return upper.endsWith('USDT') ? upper : '${upper}USDT';
  }
}

// ── Cache entry ──────────────────────────────────────────────────────────────

class _CacheEntry {
  final List<Candle> candles;
  final DateTime fetchedAt;
  final bool isFallback;
  final String sourceExchange;

  _CacheEntry({
    required this.candles,
    required this.fetchedAt,
    required this.isFallback,
    required this.sourceExchange,
  });

  bool get isStale =>
      DateTime.now().difference(fetchedAt) > CandleHistoryService.cacheTtl;
}
