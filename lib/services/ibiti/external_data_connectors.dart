// ─── JARVIS External Data Connectors ────────────────────────────────────────────
//
// Phase 18F: External eyes for JARVIS AI Core.
//
// FREE APIs (no key needed):
//   ✅ CoinGecko      — prices, mcap, categories, trending
//   ✅ DexScreener    — DEX pairs, trending, new listings
//   ✅ DefiLlama      — TVL, protocol data, yields
//   ✅ Fear & Greed   — market sentiment index
//   ✅ CryptoPanic    — aggregated news (free tier)
//
// APIs requiring free key:
//   🔑 CoinMarketCap  — rankings, latest listings
//   🔑 LunarCrush     — social volume, engagement
//   🔑 Etherscan      — whale transfers, token info
// ─────────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import 'package:ibiti_guardian/utils/guardian_logger.dart';

const _log = GuardianLogger('ExtData');

// ═══════════════════════════════════════════════════════════════════════════
// DATA MODELS
// ═══════════════════════════════════════════════════════════════════════════

class FearGreedData {
  final int value; // 0-100
  final String
      classification; // "Extreme Fear", "Fear", "Neutral", "Greed", "Extreme Greed"
  final DateTime timestamp;
  const FearGreedData(
      {required this.value,
      required this.classification,
      required this.timestamp});
  @override
  String toString() => 'FearGreed($value=$classification)';
}

class TrendingToken {
  final String id, symbol, name;
  final int? mcapRank;
  final double? priceChangePercent24h;
  const TrendingToken(
      {required this.id,
      required this.symbol,
      required this.name,
      this.mcapRank,
      this.priceChangePercent24h});
}

class TokenMarketData {
  final String id, symbol, name;
  final double? currentPrice, mcap, volume24h;
  final double? priceChange24h, priceChange7d;
  final int? mcapRank;
  final double? ath, athChangePercent;
  final String? category;
  const TokenMarketData({
    required this.id,
    required this.symbol,
    required this.name,
    this.currentPrice,
    this.mcap,
    this.volume24h,
    this.priceChange24h,
    this.priceChange7d,
    this.mcapRank,
    this.ath,
    this.athChangePercent,
    this.category,
  });
}

class DexPair {
  final String pairAddress, baseToken, quoteToken, chain;
  final double? priceUsd, volume24h, liquidity;
  final double? priceChange5m, priceChange1h, priceChange24h;
  final int? txns24h;
  const DexPair({
    required this.pairAddress,
    required this.baseToken,
    required this.quoteToken,
    required this.chain,
    this.priceUsd,
    this.volume24h,
    this.liquidity,
    this.priceChange5m,
    this.priceChange1h,
    this.priceChange24h,
    this.txns24h,
  });
}

class ProtocolTvl {
  final String name, category, chain;
  final double tvl;
  final double? change1d, change7d;
  const ProtocolTvl(
      {required this.name,
      required this.category,
      required this.chain,
      required this.tvl,
      this.change1d,
      this.change7d});
}

class NewsItem {
  final String title, url, source;
  final DateTime publishedAt;
  final String? sentiment; // positive, negative, neutral
  final List<String> currencies;
  const NewsItem(
      {required this.title,
      required this.url,
      required this.source,
      required this.publishedAt,
      this.sentiment,
      this.currencies = const []});
}

// ═══════════════════════════════════════════════════════════════════════════
// FEAR & GREED INDEX — alternative.me (FREE, no key)
// ═══════════════════════════════════════════════════════════════════════════

class FearGreedConnector {
  FearGreedConnector._();
  static final instance = FearGreedConnector._();

  FearGreedData? _cached;
  DateTime? _lastFetch;
  static const _cacheDuration = Duration(minutes: 30);

  Future<FearGreedData?> get() async {
    if (_cached != null &&
        _lastFetch != null &&
        DateTime.now().difference(_lastFetch!) < _cacheDuration) {
      return _cached;
    }
    try {
      final r = await http
          .get(Uri.parse('https://api.alternative.me/fng/?limit=1'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return _cached;
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      final item = (data['data'] as List).first as Map<String, dynamic>;
      _cached = FearGreedData(
        value: int.parse(item['value'] as String),
        classification: item['value_classification'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(
            int.parse(item['timestamp'] as String) * 1000),
      );
      _lastFetch = DateTime.now();
      _log.d('[FEAR_GREED] $_cached');
      return _cached;
    } catch (e) {
      _log.w('[FEAR_GREED] Failed: $e');
      return _cached;
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// COINGECKO — market data, trending (FREE, no key for basic)
// ═══════════════════════════════════════════════════════════════════════════

class CoinGeckoConnector {
  CoinGeckoConnector._();
  static final instance = CoinGeckoConnector._();

  static const _base = 'https://api.coingecko.com/api/v3';
  static const _rateLimit = Duration(seconds: 12); // Free = 5-6 req/min
  DateTime _lastCall = DateTime(2000);

  Future<Map<String, dynamic>?> _get(String path) async {
    final now = DateTime.now();
    final wait = _rateLimit - now.difference(_lastCall);
    if (wait > Duration.zero) await Future.delayed(wait);
    _lastCall = DateTime.now();
    try {
      final r = await http.get(
        Uri.parse('$_base$path'),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 15));
      if (r.statusCode == 429) {
        _log.w('[COINGECKO] Rate limited');
        return null;
      }
      if (r.statusCode != 200) return null;
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (e) {
      _log.w('[COINGECKO] $path failed: $e');
      return null;
    }
  }

  /// Trending tokens (top 7 by search popularity).
  Future<List<TrendingToken>> getTrending() async {
    final data = await _get('/search/trending');
    if (data == null) return [];
    final coins = data['coins'] as List? ?? [];
    return coins.map((c) {
      final item = c['item'] as Map<String, dynamic>;
      return TrendingToken(
        id: item['id'] as String? ?? '',
        symbol: item['symbol'] as String? ?? '',
        name: item['name'] as String? ?? '',
        mcapRank: item['market_cap_rank'] as int?,
        priceChangePercent24h:
            (item['data']?['price_change_percentage_24h']?['usd'] as num?)
                ?.toDouble(),
      );
    }).toList();
  }

  /// Token market data by CoinGecko ID.
  Future<TokenMarketData?> getTokenInfo(String geckoId) async {
    final data = await _get('/coins/$geckoId?localization=false'
        '&tickers=false&community_data=false&developer_data=false');
    if (data == null) return null;
    final md = data['market_data'] as Map<String, dynamic>?;
    return TokenMarketData(
      id: data['id'] as String? ?? geckoId,
      symbol: (data['symbol'] as String? ?? '').toUpperCase(),
      name: data['name'] as String? ?? '',
      currentPrice: (md?['current_price']?['usd'] as num?)?.toDouble(),
      mcap: (md?['market_cap']?['usd'] as num?)?.toDouble(),
      volume24h: (md?['total_volume']?['usd'] as num?)?.toDouble(),
      priceChange24h: (md?['price_change_percentage_24h'] as num?)?.toDouble(),
      priceChange7d: (md?['price_change_percentage_7d'] as num?)?.toDouble(),
      mcapRank: data['market_cap_rank'] as int?,
      ath: (md?['ath']?['usd'] as num?)?.toDouble(),
      athChangePercent:
          (md?['ath_change_percentage']?['usd'] as num?)?.toDouble(),
      category: (data['categories'] as List?)?.firstOrNull as String?,
    );
  }

  /// Global market data (total mcap, BTC dominance, etc.).
  Future<Map<String, dynamic>?> getGlobalData() async {
    final data = await _get('/global');
    return data?['data'] as Map<String, dynamic>?;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// DEXSCREENER — DEX pairs, trending (FREE, no key)
// ═══════════════════════════════════════════════════════════════════════════

class DexScreenerConnector {
  DexScreenerConnector._();
  static final instance = DexScreenerConnector._();

  static const _base = 'https://api.dexscreener.com';

  Future<List?> _getList(String path) async {
    try {
      final r = await http
          .get(Uri.parse('$_base$path'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final data = jsonDecode(r.body);
      if (data is List) return data;
      if (data is Map) return data['pairs'] as List?;
      return null;
    } catch (e) {
      _log.w('[DEXSCREENER] $path failed: $e');
      return null;
    }
  }

  DexPair _parsePair(Map<String, dynamic> p) {
    return DexPair(
      pairAddress: p['pairAddress'] as String? ?? '',
      baseToken: (p['baseToken']?['symbol'] as String?) ?? '',
      quoteToken: (p['quoteToken']?['symbol'] as String?) ?? '',
      chain: p['chainId'] as String? ?? '',
      priceUsd: double.tryParse(p['priceUsd']?.toString() ?? ''),
      volume24h: (p['volume']?['h24'] as num?)?.toDouble(),
      liquidity: (p['liquidity']?['usd'] as num?)?.toDouble(),
      priceChange5m: (p['priceChange']?['m5'] as num?)?.toDouble(),
      priceChange1h: (p['priceChange']?['h1'] as num?)?.toDouble(),
      priceChange24h: (p['priceChange']?['h24'] as num?)?.toDouble(),
      txns24h: (p['txns']?['h24']?['buys'] as int? ?? 0) +
          (p['txns']?['h24']?['sells'] as int? ?? 0),
    );
  }

  /// Search token pairs by query.
  Future<List<DexPair>> search(String query) async {
    final list = await _getList('/latest/dex/search/?q=$query');
    if (list == null) return [];
    return list.whereType<Map<String, dynamic>>().map(_parsePair).toList();
  }

  /// Get token pairs by contract address.
  Future<List<DexPair>> getByToken(String address) async {
    final list = await _getList('/latest/dex/tokens/$address');
    if (list == null) return [];
    return list.whereType<Map<String, dynamic>>().map(_parsePair).toList();
  }

  /// Trending tokens (boosted/promoted).
  Future<List<DexPair>> getTrending() async {
    try {
      final r = await http
          .get(Uri.parse('$_base/token-boosts/latest/v1'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return [];
      final data = jsonDecode(r.body) as List;
      return data.whereType<Map<String, dynamic>>().map((t) {
        return DexPair(
          pairAddress: t['tokenAddress'] as String? ?? '',
          baseToken: t['description'] as String? ?? '',
          quoteToken: 'USD',
          chain: t['chainId'] as String? ?? '',
          priceUsd: double.tryParse(t['priceUsd']?.toString() ?? ''),
        );
      }).toList();
    } catch (e) {
      _log.w('[DEXSCREENER] trending failed: $e');
      return [];
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// DEFILLAMA — TVL, protocols (FREE, no key)
// ═══════════════════════════════════════════════════════════════════════════

class DefiLlamaConnector {
  DefiLlamaConnector._();
  static final instance = DefiLlamaConnector._();

  static const _base = 'https://api.llama.fi';

  /// Top protocols by TVL.
  Future<List<ProtocolTvl>> getTopProtocols({int limit = 20}) async {
    try {
      final r = await http
          .get(Uri.parse('$_base/protocols'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return [];
      final data = jsonDecode(r.body) as List;
      return data.take(limit).map((p) {
        final m = p as Map<String, dynamic>;
        return ProtocolTvl(
          name: m['name'] as String? ?? '',
          category: m['category'] as String? ?? '',
          chain: (m['chains'] as List?)?.firstOrNull?.toString() ?? '',
          tvl: (m['tvl'] as num?)?.toDouble() ?? 0,
          change1d: (m['change_1d'] as num?)?.toDouble(),
          change7d: (m['change_7d'] as num?)?.toDouble(),
        );
      }).toList();
    } catch (e) {
      _log.w('[DEFILLAMA] protocols failed: $e');
      return [];
    }
  }

  /// Total DeFi TVL.
  Future<double?> getTotalTvl() async {
    try {
      final r = await http
          .get(Uri.parse('https://api.llama.fi/v2/historicalChainTvl'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final data = jsonDecode(r.body) as List;
      if (data.isEmpty) return null;
      return (data.last['tvl'] as num?)?.toDouble();
    } catch (e) {
      _log.w('[DEFILLAMA] TVL failed: $e');
      return null;
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// CRYPTOPANIC — news aggregator (FREE tier, no key needed for basic)
// ═══════════════════════════════════════════════════════════════════════════

class CryptoPanicConnector {
  CryptoPanicConnector._();
  static final instance = CryptoPanicConnector._();

  static const _base = 'https://cryptopanic.com/api/free/v1';

  /// Latest crypto news.
  Future<List<NewsItem>> getNews({String? currency, int limit = 10}) async {
    try {
      var url = '$_base/posts/?public=true';
      if (currency != null) url += '&currencies=$currency';
      final r =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return [];
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      final results = data['results'] as List? ?? [];
      return results.take(limit).map((item) {
        final m = item as Map<String, dynamic>;
        final currencies = (m['currencies'] as List?)
                ?.map((c) => (c as Map)['code']?.toString() ?? '')
                .where((c) => c.isNotEmpty)
                .toList() ??
            [];
        return NewsItem(
          title: m['title'] as String? ?? '',
          url: m['url'] as String? ?? '',
          source: (m['source'] as Map?)?['title'] as String? ?? '',
          publishedAt: DateTime.tryParse(m['published_at'] as String? ?? '') ??
              DateTime.now(),
          sentiment:
              m['votes'] != null ? _extractSentiment(m['votes'] as Map) : null,
          currencies: currencies,
        );
      }).toList();
    } catch (e) {
      _log.w('[CRYPTOPANIC] news failed: $e');
      return [];
    }
  }

  String? _extractSentiment(Map votes) {
    final pos = (votes['positive'] as int?) ?? 0;
    final neg = (votes['negative'] as int?) ?? 0;
    if (pos + neg == 0) return null;
    if (pos > neg * 2) return 'positive';
    if (neg > pos * 2) return 'negative';
    return 'neutral';
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// EXTERNAL DATA AGGREGATOR — unified interface
// ═══════════════════════════════════════════════════════════════════════════

class ExternalDataAggregator {
  ExternalDataAggregator._();
  static final instance = ExternalDataAggregator._();

  // Cached global context (refreshed periodically)
  FearGreedData? _fearGreed;
  List<TrendingToken> _trendingTokens = [];
  Map<String, dynamic>? _globalMarket;
  DateTime? _lastGlobalRefresh;
  static const _globalRefreshInterval = Duration(minutes: 15);

  /// Refresh global context data (call periodically from loop).
  Future<void> refreshGlobalContext() async {
    final now = DateTime.now();
    if (_lastGlobalRefresh != null &&
        now.difference(_lastGlobalRefresh!) < _globalRefreshInterval) {
      return;
    }
    _lastGlobalRefresh = now;

    // Parallel fetch — don't block
    final results = await Future.wait([
      FearGreedConnector.instance.get(),
      CoinGeckoConnector.instance.getTrending(),
      CoinGeckoConnector.instance.getGlobalData(),
    ]);

    _fearGreed = results[0] as FearGreedData?;
    _trendingTokens = results[1] as List<TrendingToken>? ?? [];
    _globalMarket = results[2] as Map<String, dynamic>?;

    _log.i('[EXT_DATA] Global refresh: '
        'fear_greed=${_fearGreed?.value ?? "?"} '
        'trending=${_trendingTokens.length} '
        'global=${_globalMarket != null ? "OK" : "MISS"}');


  }

  /// Build external data map for ContextPack.
  Map<String, dynamic> buildExternalContext({String? symbol}) {
    final map = <String, dynamic>{};

    if (_fearGreed != null) {
      map['fear_greed'] = {
        'value': _fearGreed!.value,
        'label': _fearGreed!.classification,
      };
    }

    if (_trendingTokens.isNotEmpty) {
      map['trending'] = _trendingTokens
          .take(7)
          .map((t) => '${t.symbol}(#${t.mcapRank ?? "?"})')
          .toList();
    }

    if (_globalMarket != null) {
      map['btc_dominance'] = _globalMarket!['market_cap_percentage']?['btc'];
      map['total_mcap'] = _globalMarket!['total_market_cap']?['usd'];
      map['total_volume'] = _globalMarket!['total_volume']?['usd'];
    }

    return map;
  }

  // Getters for direct access
  FearGreedData? get fearGreed => _fearGreed;
  List<TrendingToken> get trendingTokens => _trendingTokens;
  Map<String, dynamic>? get globalMarket => _globalMarket;

  /// Log external data status (for brain report).
  void logStatus() {
    _log.i('╔════════════════════════════════════════════════════');
    _log.i('║ [EXT_DATA] External Connectors Status');
    _log.i('╠════════════════════════════════════════════════════');
    _log.i('║ Fear & Greed: ${_fearGreed ?? "NOT LOADED"}');
    _log.i('║ Trending: ${_trendingTokens.length} tokens');
    _log.i('║ Global Market: ${_globalMarket != null ? "OK" : "MISS"}');
    _log.i(
        '║ Last refresh: ${_lastGlobalRefresh?.toIso8601String() ?? "NEVER"}');
    _log.i('╚════════════════════════════════════════════════════');
  }
}
