import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class MarketDataService extends ChangeNotifier {
  MarketDataService._();

  static const _baseUrl = 'https://api.coingecko.com/api/v3';
  static final MarketDataService instance = MarketDataService._();

  final Map<String, List<MarketAsset>> _marketsCache = {};
  final Map<String, MarketAssetDetail> _detailCache = {};
  final Map<String, List<double>> _chartCache = {};
  final Map<String, List<OhlcCandle>> _ohlcCache = {};

  // ── Rate limiter for CoinGecko free tier ──────────────────────────────────
  /// Minimum interval between CoinGecko API calls.
  /// Free tier: ~10-30 calls/min. 3s gap = ~20 calls/min max.
  static const Duration _minRequestInterval = Duration(seconds: 3);
  DateTime _lastRequestAt = DateTime(2000);
  int _consecutiveRateLimits = 0;

  /// Live exchange data keyed by source:pair (e.g. "binance:BTCUSDT").
  /// Injected by [ExchangeMarketBridge], never by CoinGecko.
  final Map<String, MarketAsset> _exchangeOverrides = {};

  /// Insertion timestamps for exchange overrides — used for TTL purge.
  final Map<String, DateTime> _exchangeOverrideTimestamps = {};

  // ── Cached liveExchangeMovers (dirty-flag pattern) ────────────────────────
  List<MarketAsset>? _liveMoversCache;
  bool _liveMoversStale = true;

  /// Exchange data older than this is evicted to prevent zombie tokens.
  Timer? _notifyThrottle;

  /// Must be ≤ [maxStaleness] so stale overrides never slip past the
  /// freshness guard.
  static const Duration _exchangeOverrideTtl = Duration(minutes: 5);

  // ── P1 Fix: Data freshness tracking ────────────────────────────────────────
  /// Maximum age of market data before consumers should treat it as stale.
  static const Duration maxStaleness = Duration(minutes: 5);

  /// Timestamp of last successful CoinGecko fetch OR exchange bridge update.
  DateTime? _lastRefreshedAt;

  /// When the market data was last successfully refreshed.
  DateTime? get lastRefreshedAt => _lastRefreshedAt;

  /// Returns true if market data is older than [maxStaleness] or never loaded.
  /// Consumers (Scout, AutomationEngine) should check this before acting.
  bool get isStale =>
      _lastRefreshedAt == null ||
      DateTime.now().difference(_lastRefreshedAt!) > maxStaleness;

  /// All market assets merged from CoinGecko + exchange overrides.
  ///
  /// Merge strategy:
  /// - If both CoinGecko and exchange have the symbol → use exchange
  ///   prices (faster) but keep CoinGecko metadata (images, sparkline, rank).
  /// - If only exchange has it → use raw exchange data (no image).
  /// - If only CoinGecko has it → use as-is.
  ///
  /// Used by GuardianAssistantService, MarketScoutService, AutomationEngine.
  List<MarketAsset> get cachedMarkets {
    final cgAssets = _marketsCache.values.expand((list) => list).toList();

    if (_exchangeOverrides.isEmpty) {
      return cgAssets;
    }

    // Purge stale exchange entries before merging.
    _purgeStaleExchangeOverrides();

    // Index CoinGecko data by symbol for O(1) lookup.
    final bySymbol = <String, MarketAsset>{};
    for (final a in cgAssets) {
      bySymbol[a.symbol] = a;
    }

    // Merge exchange data: update prices, keep metadata.
    // Keys are now source:pair (e.g. 'binance:BTCUSDT').
    // For cachedMarkets: pick highest-volume per symbol for backward compat.
    final bestExBySymbol = <String, MarketAsset>{};
    for (final exchange in _exchangeOverrides.values) {
      final sym = exchange.symbol;
      final existing = bestExBySymbol[sym];
      if (existing == null || exchange.volume > existing.volume) {
        bestExBySymbol[sym] = exchange;
      }
    }

    for (final entry in bestExBySymbol.entries) {
      final symbol = entry.key;
      final exchange = entry.value;
      final cg = bySymbol[symbol];

      if (cg != null) {
        // Merge: exchange price + CoinGecko metadata.
        bySymbol[symbol] = MarketAsset(
          id: cg.id,
          symbol: cg.symbol,
          name: cg.name,
          imageUrl: cg.imageUrl,
          price: exchange.price,
          change24h: exchange.change24h,
          marketCap: cg.marketCap,
          volume: exchange.volume,
          rank: cg.rank,
          sparkline: cg.sparkline,
          high24h: exchange.high24h,
          low24h: exchange.low24h,
          change7d: cg.change7d,
          change30d: cg.change30d,
          networkGroup: cg.networkGroup,
          sourceId: exchange.sourceId,
          sourcePair: exchange.sourcePair,
          sourceUpdatedAt: exchange.sourceUpdatedAt,
        );
      } else {
        // Exchange-only asset — no CoinGecko metadata.
        bySymbol[symbol] = exchange;
      }
    }

    return bySymbol.values.toList(growable: false);
  }

  // ── Exchange-native top movers ───────────────────────────────────────────

  /// Stablecoin / wrapped / leveraged token blacklist for market feed.
  static const _feedBlacklist = <String>{
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
    'CRVUSD',
    'GHO',
    'SUSD',
    'MIM',
    'DOLA',
    'EURC',
    'EURS',
    'STETH',
    'WSTETH',
    'CBETH',
    'RETH',
    'WETH',
    'WBTC',
    'TBTC',
    'WBNB',
    'WMATIC',
    'WAVAX',
    'WSOL',
  };

  /// Live exchange movers — pure exchange tickers sorted by 24h change.
  /// NOT mixed with CoinGecko top-250 ranking.
  /// Enriched with CoinGecko metadata (name, image) where available.
  List<MarketAsset> get liveExchangeMovers {
    if (!_liveMoversStale && _liveMoversCache != null) {
      return _liveMoversCache!;
    }
    _liveMoversCache = _computeLiveExchangeMovers();
    _liveMoversStale = false;
    return _liveMoversCache!;
  }

  List<MarketAsset> _computeLiveExchangeMovers() {
    _purgeStaleExchangeOverrides();
    if (_exchangeOverrides.isEmpty) return [];

    // Index CoinGecko for metadata enrichment (name, image, sparkline).
    final cgBySymbol = <String, MarketAsset>{};
    for (final a in _marketsCache.values.expand((l) => l)) {
      cgBySymbol[a.symbol] = a;
    }

    // Deduplicate: keep highest-volume entry per base symbol.
    // Keys are now source:pair — we want one display row per base symbol.
    final bestBySymbol = <String, MarketAsset>{};
    for (final ex in _exchangeOverrides.values) {
      final sym = ex.symbol;

      // Filter: no stables/wrapped/leveraged, min volume $10k, price > 0
      if (_feedBlacklist.contains(sym)) continue;
      if (ex.volume < 10000 || ex.price <= 0) continue;
      // Skip leveraged tokens (Binance UP/DOWN/BEAR/BULL)
      if (sym.endsWith('UP') ||
          sym.endsWith('DOWN') ||
          sym.endsWith('BEAR') ||
          sym.endsWith('BULL')) continue;
      if (sym.length > 8 && (sym.contains('UP') || sym.contains('DOWN')))
        continue;

      // Dedupe: keep highest 24h change per symbol — surfaces rockets,
      // not just high-volume entries.
      final existing = bestBySymbol[sym];
      if (existing == null || ex.change24h > existing.change24h) {
        bestBySymbol[sym] = ex;
      }
    }

    final movers = <MarketAsset>[];
    for (final entry in bestBySymbol.entries) {
      final sym = entry.key;
      final ex = entry.value;
      final cg = cgBySymbol[sym];
      movers.add(MarketAsset(
        id: cg?.id ?? ex.id,
        symbol: sym,
        name: cg?.name ?? ex.name,
        imageUrl: cg?.imageUrl ?? '',
        price: ex.price,
        change24h: ex.change24h,
        marketCap: cg?.marketCap ?? 0,
        volume: ex.volume,
        rank: cg?.rank ?? 0,
        sparkline: cg?.sparkline ?? const [],
        high24h: ex.high24h,
        low24h: ex.low24h,
        change7d: cg?.change7d ?? 0,
        change30d: cg?.change30d ?? 0,
        networkGroup: cg?.networkGroup ?? 'Multi-chain',
        sourceId: ex.sourceId,
        sourcePair: ex.sourcePair,
        sourceUpdatedAt: ex.sourceUpdatedAt,
      ));
    }

    // Sort by 24h change descending — real top gainers first.
    movers.sort((a, b) => b.change24h.compareTo(a.change24h));
    return movers;
  }

  /// Merge exchange ticker data into the cache.
  ///
  /// Called by [ExchangeMarketBridge] on every ticker update.
  /// Does NOT replace CoinGecko data — only overrides price/volume fields.
  void mergeExchangeData(Map<String, MarketAsset> exchangeAssets) {
    final now = DateTime.now();
    _exchangeOverrides.addAll(exchangeAssets);
    for (final key in exchangeAssets.keys) {
      _exchangeOverrideTimestamps[key] = now;
    }
    _lastRefreshedAt = now;

    // Invalidate liveExchangeMovers cache.
    _liveMoversStale = true;

    // Opportunistic purge of stale entries.
    _purgeStaleExchangeOverrides();

    // Throttle: notify listeners at most once per second.
    // Exchange WS fires hundreds of times/sec — we batch into 1s updates.
    _notifyThrottle ??= Timer(const Duration(seconds: 1), () {
      _notifyThrottle = null;
      notifyListeners();
    });
  }

  /// Removes exchange overrides older than [_exchangeOverrideTtl].
  /// Prevents zombie tokens from lingering when an exchange stops
  /// sending updates (e.g. delisted asset, websocket disconnect).
  void _purgeStaleExchangeOverrides() {
    final cutoff = DateTime.now().subtract(_exchangeOverrideTtl);
    final staleKeys = _exchangeOverrideTimestamps.entries
        .where((e) => e.value.isBefore(cutoff))
        .map((e) => e.key)
        .toList();
    for (final key in staleKeys) {
      _exchangeOverrides.remove(key);
      _exchangeOverrideTimestamps.remove(key);
    }
  }

  /// Waits if the last CoinGecko request was too recent.
  /// Applies exponential backoff on consecutive 429s.
  /// Uses a synchronous reservation mechanism to perfectly stagger concurrent calls.
  Future<void> _waitForRateLimit() async {
    final backoff = _consecutiveRateLimits > 0
        ? Duration(
            seconds: 6 * (_consecutiveRateLimits + 1)) // 12s, 18s, 24s...
        : _minRequestInterval;

    final now = DateTime.now();
    final elapsed = now.difference(_lastRequestAt);

    if (elapsed < backoff) {
      // Calculate how long we need to wait
      final waitTime = backoff - elapsed;
      // Reserve our spot by pushing _lastRequestAt forward BEFORE we yield execution
      _lastRequestAt = _lastRequestAt.add(backoff);

      await Future.delayed(waitTime);
    } else {
      // No wait needed, but we claim this exact moment to block immediate followers
      _lastRequestAt = now;
    }
  }

  /// Resolve a ticker symbol (e.g. 'BTC') to a CoinGecko ID (e.g. 'bitcoin').
  /// Returns empty string if no match found in cache.
  String resolveId(String symbol) {
    final s = symbol.toUpperCase();
    for (final a in cachedMarkets) {
      if (a.symbol == s) return a.id;
    }
    return '';
  }

  /// Build a full MarketAsset from an exchange ticker symbol,
  /// merging CoinGecko metadata (image, name, market cap, sparkline)
  /// with live exchange price data.
  MarketAsset resolveAssetFromTicker({
    required String symbol,
    required double price,
    required double change24h,
    required double volume,
    required double high24h,
    required double low24h,
    String sourceId = '',
    String sourcePair = '',
  }) {
    final s = symbol.toUpperCase();

    // Auto-resolve live exchange source if missing
    if (sourceId.isEmpty) {
      final exMatch =
          _exchangeOverrides.values.where((e) => e.symbol == s).firstOrNull;
      if (exMatch != null) {
        sourceId = exMatch.sourceId;
        sourcePair = exMatch.sourcePair;
      }
    }

    // Try to find a CoinGecko match for rich metadata
    final cgMatch = cachedMarkets.where((a) => a.symbol == s).firstOrNull;

    if (cgMatch != null) {
      // Merge: exchange live price + CoinGecko metadata
      return MarketAsset(
        id: cgMatch.id,
        symbol: cgMatch.symbol,
        name: cgMatch.name,
        imageUrl: cgMatch.imageUrl,
        price: price,
        change24h: change24h,
        marketCap: cgMatch.marketCap,
        volume: volume,
        rank: cgMatch.rank,
        sparkline: cgMatch.sparkline,
        high24h: high24h,
        low24h: low24h,
        change7d: cgMatch.change7d,
        change30d: cgMatch.change30d,
        networkGroup: cgMatch.networkGroup,
        sourceId: sourceId,
        sourcePair: sourcePair,
        sourceUpdatedAt: DateTime.now(),
      );
    }

    // No CoinGecko match — exchange-only asset
    return MarketAsset(
      id: '',
      symbol: s,
      name: s,
      imageUrl: '',
      price: price,
      change24h: change24h,
      marketCap: 0,
      volume: volume,
      rank: 0,
      sparkline: const [],
      high24h: high24h,
      low24h: low24h,
      change7d: 0,
      change30d: 0,
      networkGroup: '',
      sourceId: sourceId,
      sourcePair: sourcePair,
      sourceUpdatedAt: DateTime.now(),
    );
  }

  Future<List<MarketAsset>> fetchMarkets({
    String vsCurrency = 'usd',
    int page = 1,
    int perPage = 60,
    bool forceRefresh = false,
  }) async {
    final cacheKey = '$vsCurrency:$page:$perPage';
    if (!forceRefresh && _marketsCache.containsKey(cacheKey)) {
      return _marketsCache[cacheKey]!;
    }

    final uri = Uri.parse('$_baseUrl/coins/markets').replace(
      queryParameters: {
        'vs_currency': vsCurrency,
        'order': 'market_cap_desc',
        'per_page': '$perPage',
        'page': '$page',
        'sparkline': 'true',
        'price_change_percentage': '24h,7d,30d',
      },
    );

    // Rate limit guard: wait if needed
    await _waitForRateLimit();

    final response = await http.get(uri, headers: const {
      'accept': 'application/json'
    }).timeout(const Duration(seconds: 18));

    _lastRequestAt = DateTime.now();

    if (response.statusCode == 429) {
      _consecutiveRateLimits++;
      // Return cached data if available instead of throwing
      if (_marketsCache.containsKey(cacheKey)) {
        return _marketsCache[cacheKey]!;
      }
      throw Exception('Market feed error: 429 (rate limited)');
    }
    _consecutiveRateLimits = 0;

    if (response.statusCode != 200) {
      throw Exception('Market feed error: ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    if (data is! List) return const [];

    final markets = data
        .whereType<Map<String, dynamic>>()
        .map(MarketAsset.fromJson)
        .toList(growable: false);
    _marketsCache[cacheKey] = markets;
    _lastRefreshedAt = DateTime.now();
    _liveMoversStale = true; // CG metadata may enrich exchange movers
    return markets;
  }

  Future<MarketAssetDetail> fetchDetail(
    String assetId, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _detailCache.containsKey(assetId)) {
      return _detailCache[assetId]!;
    }

    final uri = Uri.parse('$_baseUrl/coins/$assetId').replace(
      queryParameters: const {
        'localization': 'false',
        'tickers': 'true',
        'market_data': 'true',
        'community_data': 'false',
        'developer_data': 'false',
        'sparkline': 'false',
      },
    );

    await _waitForRateLimit();

    final response = await http.get(uri, headers: const {
      'accept': 'application/json'
    }).timeout(const Duration(seconds: 18));

    _lastRequestAt = DateTime.now();

    if (response.statusCode == 429) {
      _consecutiveRateLimits++;
      if (_detailCache.containsKey(assetId)) return _detailCache[assetId]!;
      throw Exception('Asset detail error: 429 (rate limited)');
    }
    _consecutiveRateLimits = 0;

    if (response.statusCode != 200) {
      throw Exception('Asset detail error: ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>) {
      throw Exception('Asset detail payload invalid');
    }

    final detail = MarketAssetDetail.fromJson(data);
    _detailCache[assetId] = detail;
    return detail;
  }

  Future<List<double>> fetchChart(
    String assetId, {
    required String rangeKey,
    bool forceRefresh = false,
  }) async {
    final days = switch (rangeKey) {
      '24H' => '1',
      '7D' => '7',
      '1M' => '30',
      '3M' => '90',
      _ => '7',
    };
    final cacheKey = '$assetId:$days';
    if (!forceRefresh && _chartCache.containsKey(cacheKey)) {
      return _chartCache[cacheKey]!;
    }

    final uri = Uri.parse('$_baseUrl/coins/$assetId/market_chart').replace(
      queryParameters: {
        'vs_currency': 'usd',
        'days': days,
        'interval': days == '1' ? 'hourly' : 'daily',
      },
    );

    await _waitForRateLimit();

    final response = await http.get(uri, headers: const {
      'accept': 'application/json'
    }).timeout(const Duration(seconds: 18));

    _lastRequestAt = DateTime.now();

    if (response.statusCode == 429) {
      _consecutiveRateLimits++;
      if (_chartCache.containsKey(cacheKey)) return _chartCache[cacheKey]!;
      throw Exception('Chart feed error: 429 (rate limited)');
    }
    _consecutiveRateLimits = 0;

    if (response.statusCode != 200) {
      throw Exception('Chart feed error: ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>) return const [];
    final raw = data['prices'];
    if (raw is! List) return const [];

    final prices = raw
        .whereType<List>()
        .map((entry) => entry.length > 1 ? _toDouble(entry[1]) : 0.0)
        .where((value) => value > 0)
        .toList(growable: false);

    _chartCache[cacheKey] = prices;
    return prices;
  }

  Future<List<OhlcCandle>> fetchOhlc(
    String assetId, {
    required String rangeKey,
    bool forceRefresh = false,
  }) async {
    final days = switch (rangeKey) {
      '24H' => '1',
      '7D' => '7',
      '1M' => '30',
      '3M' => '90',
      _ => '7',
    };
    final cacheKey = '$assetId:ohlc:$days';
    if (!forceRefresh && _ohlcCache.containsKey(cacheKey)) {
      return _ohlcCache[cacheKey]!;
    }

    final uri = Uri.parse('$_baseUrl/coins/$assetId/ohlc').replace(
      queryParameters: {
        'vs_currency': 'usd',
        'days': days,
      },
    );

    final response = await http.get(uri, headers: const {
      'accept': 'application/json'
    }).timeout(const Duration(seconds: 18));

    if (response.statusCode != 200) {
      throw Exception('OHLC feed error: ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    if (data is! List) return const [];

    final candles = data
        .whereType<List>()
        .where((entry) => entry.length >= 5)
        .map(
          (entry) => OhlcCandle(
            timestamp: DateTime.fromMillisecondsSinceEpoch(
              (entry[0] as num).toInt(),
              isUtc: true,
            ),
            open: _toDouble(entry[1]),
            high: _toDouble(entry[2]),
            low: _toDouble(entry[3]),
            close: _toDouble(entry[4]),
          ),
        )
        .toList(growable: false);

    _ohlcCache[cacheKey] = candles;
    return candles;
  }

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0.0;
  }

  void clearForTest() {
    _marketsCache.clear();
    _detailCache.clear();
    _chartCache.clear();
    _ohlcCache.clear();
    _exchangeOverrides.clear();
    _exchangeOverrideTimestamps.clear();
    _liveMoversCache = null;
    _liveMoversStale = true;
    _lastRefreshedAt = null;
  }
}

class MarketAsset {
  final String id;
  final String symbol;
  final String name;
  final String imageUrl;
  final double price;
  final double change24h;
  final double marketCap;
  final double volume;
  final int rank;
  final List<double> sparkline;
  final double high24h;
  final double low24h;
  final double change7d;
  final double change30d;
  final String networkGroup;

  /// Data source: 'coingecko', 'binance', 'mexc'
  final String sourceId;

  /// Exchange pair symbol, e.g. 'XMRUSDT'. Empty for CoinGecko.
  final String sourcePair;

  /// When this price was last confirmed from its source.
  final DateTime? sourceUpdatedAt;

  const MarketAsset({
    required this.id,
    required this.symbol,
    required this.name,
    required this.imageUrl,
    required this.price,
    required this.change24h,
    required this.marketCap,
    required this.volume,
    required this.rank,
    required this.sparkline,
    required this.high24h,
    required this.low24h,
    required this.change7d,
    required this.change30d,
    required this.networkGroup,
    this.sourceId = 'coingecko',
    this.sourcePair = '',
    this.sourceUpdatedAt,
  });

  factory MarketAsset.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString() ?? '';
    final symbol = (json['symbol']?.toString() ?? '').toUpperCase();
    return MarketAsset(
      id: id,
      symbol: symbol,
      name: json['name']?.toString() ?? symbol,
      imageUrl: json['image']?.toString() ?? '',
      price: MarketDataService._toDouble(json['current_price']),
      change24h:
          MarketDataService._toDouble(json['price_change_percentage_24h']),
      marketCap: MarketDataService._toDouble(json['market_cap']),
      volume: MarketDataService._toDouble(json['total_volume']),
      rank: (json['market_cap_rank'] as num?)?.toInt() ?? 0,
      sparkline: ((json['sparkline_in_7d']?['price'] as List?) ?? const [])
          .map((v) => MarketDataService._toDouble(v))
          .where((v) => v > 0)
          .toList(growable: false),
      high24h: MarketDataService._toDouble(json['high_24h']),
      low24h: MarketDataService._toDouble(json['low_24h']),
      change7d: MarketDataService._toDouble(
          json['price_change_percentage_7d_in_currency']),
      change30d: MarketDataService._toDouble(
          json['price_change_percentage_30d_in_currency']),
      networkGroup: _inferNetworkGroup(id, symbol),
      sourceId: 'coingecko',
    );
  }

  String get status {
    if (change24h >= 6) return 'Breakout';
    if (change24h >= 2) return 'Bullish';
    if (change24h <= -6) return 'Flush';
    if (change24h <= -2) return 'Pullback';
    return 'Range';
  }

  static String _inferNetworkGroup(String id, String symbol) {
    final stable = {'USDT', 'USDC', 'DAI', 'FDUSD', 'BUSD'};
    if (symbol == 'BTC') return 'Bitcoin';
    if (stable.contains(symbol)) return 'Stablecoins';
    if (symbol == 'SOL' || symbol == 'JUP' || symbol == 'RAY') return 'Solana';
    if (symbol == 'BNB' || symbol == 'CAKE') return 'BNB Chain';
    if (symbol == 'ARB' || id.contains('arbitrum')) return 'Arbitrum';
    if (symbol == 'ETH' ||
        symbol == 'UNI' ||
        symbol == 'LINK' ||
        symbol == 'AAVE' ||
        symbol == 'MKR') {
      return 'Ethereum';
    }
    return 'Multi-chain';
  }
}

class MarketAssetDetail {
  final String id;
  final String description;
  final List<String> venues;
  final String homepage;
  final double ath;
  final double atl;
  final double circulatingSupply;
  final double marketCap;
  final double totalVolume;
  final double high24h;
  final double low24h;

  const MarketAssetDetail({
    required this.id,
    required this.description,
    required this.venues,
    required this.homepage,
    required this.ath,
    required this.atl,
    required this.circulatingSupply,
    required this.marketCap,
    required this.totalVolume,
    required this.high24h,
    required this.low24h,
  });

  factory MarketAssetDetail.fromJson(Map<String, dynamic> json) {
    final tickers = (json['tickers'] as List? ?? const [])
        .whereType<Map<String, dynamic>>();
    final venueNames = <String>{};
    for (final ticker in tickers) {
      final marketName = ticker['market']?['name']?.toString().trim();
      if (marketName != null && marketName.isNotEmpty) {
        venueNames.add(marketName);
      }
      if (venueNames.length >= 6) break;
    }

    final marketData = json['market_data'] as Map<String, dynamic>? ?? const {};
    final current =
        marketData['current_price'] as Map<String, dynamic>? ?? const {};
    final homepages = (json['links']?['homepage'] as List? ?? const [])
        .map((e) => e?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();

    return MarketAssetDetail(
      id: json['id']?.toString() ?? '',
      description: (json['description']?['en']?.toString() ?? '')
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .trim(),
      venues: venueNames.toList(growable: false),
      homepage: homepages.isEmpty ? '' : homepages.first,
      ath: MarketDataService._toDouble(current['usd']) == 0
          ? MarketDataService._toDouble(marketData['ath']?['usd'])
          : MarketDataService._toDouble(marketData['ath']?['usd']),
      atl: MarketDataService._toDouble(marketData['atl']?['usd']),
      circulatingSupply:
          MarketDataService._toDouble(marketData['circulating_supply']),
      marketCap: MarketDataService._toDouble(marketData['market_cap']?['usd']),
      totalVolume:
          MarketDataService._toDouble(marketData['total_volume']?['usd']),
      high24h: MarketDataService._toDouble(marketData['high_24h']?['usd']),
      low24h: MarketDataService._toDouble(marketData['low_24h']?['usd']),
    );
  }
}

class OhlcCandle {
  final DateTime timestamp;
  final double open;
  final double high;
  final double low;
  final double close;

  const OhlcCandle({
    required this.timestamp,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
  });
}
