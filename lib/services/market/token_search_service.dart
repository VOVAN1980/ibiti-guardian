import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_registry.dart';

// ─── Token Search Service ───────────────────────────────────────────────────────
//
// Unified search across all data sources:
//   1. Local cache (CoinGecko markets) — instant
//   2. Exchange tickers (Binance + MEXC) — instant
//   3. CoinGecko /search API — network fallback
//
// Usage:
//   final results = await TokenSearchService.instance.search('doge');
// ─────────────────────────────────────────────────────────────────────────────────

class SearchResult {
  final String id; // CoinGecko ID (e.g. 'dogecoin') or empty
  final String symbol; // 'DOGE'
  final String name; // 'Dogecoin'
  final double? price;
  final double? change24h;
  final double? marketCap; // Actual market cap in USD (null if unknown)
  final int? marketCapRank; // CoinGecko rank (1 = BTC, 2 = ETH...)
  final String? imageUrl;
  final String source; // 'cache', 'exchange', 'coingecko_search'

  const SearchResult({
    required this.id,
    required this.symbol,
    required this.name,
    this.price,
    this.change24h,
    this.marketCap,
    this.marketCapRank,
    this.imageUrl,
    required this.source,
  });

  /// Unique dedup key: source-qualified ID prevents cross-chain symbol collisions.
  /// e.g. CoinGecko 'ethereum' vs exchange 'ETH' are the same, but
  /// 'token-a-on-eth' vs 'token-a-on-sol' with same symbol won't collide.
  String get dedupKey => id.isNotEmpty ? id : '$source:$symbol';
}

class TokenSearchService {
  TokenSearchService._();
  static final TokenSearchService instance = TokenSearchService._();

  static const _baseUrl = 'https://api.coingecko.com/api/v3';

  /// Search for tokens by name, symbol, or partial match.
  ///
  /// Strategy:
  ///   1. Search local CoinGecko cache (instant, ~60 results)
  ///   2. Search live exchange tickers (instant, ~2000+ results)
  ///   3. If local results < 3, hit CoinGecko /search API (network)
  ///
  /// Returns deduplicated results, sorted by relevance.
  Future<List<SearchResult>> search(String query, {int limit = 20}) async {
    if (query.trim().isEmpty) return const [];

    final q = query.trim().toLowerCase();
    final results = <String, SearchResult>{}; // keyed by dedupKey

    // ── Source 1: CoinGecko cached markets ─────────────────────────────
    final cached = MarketDataService.instance.cachedMarkets;
    for (final asset in cached) {
      if (_matches(asset.symbol, asset.name, q)) {
        final r = SearchResult(
          id: asset.id,
          symbol: asset.symbol,
          name: asset.name,
          price: asset.price,
          change24h: asset.change24h,
          marketCap: asset.marketCap,
          marketCapRank: asset.rank > 0 ? asset.rank : null,
          imageUrl: asset.imageUrl,
          source: 'cache',
        );
        results[r.dedupKey] = r;
      }
    }

    // ── Source 2: Live exchange tickers ─────────────────────────────────────
    final registry = ExchangeRegistry.instance;
    for (final exchangeId in registry.availableExchanges) {
      final svc = registry.serviceFor(exchangeId);
      for (final ticker in svc.currentTickers) {
        // Skip if we already have a CoinGecko result for this symbol
        // (CoinGecko has richer data: image, name, market cap)
        final hasRicherMatch = results.values.any(
          (r) => r.symbol == ticker.baseAsset && r.source == 'cache',
        );
        if (hasRicherMatch) continue;

        if (_matches(ticker.baseAsset, '', q)) {
          final r = SearchResult(
            id: '', // no CoinGecko ID for exchange-only tokens
            symbol: ticker.baseAsset,
            name: ticker.baseAsset,
            price: ticker.lastPrice,
            change24h: ticker.priceChangePercent24h,
            imageUrl: null,
            source: 'exchange:${exchangeId.name}',
          );
          results.putIfAbsent(r.dedupKey, () => r);
        }
      }
    }

    // ── Source 3: CoinGecko /search API (network fallback) ─────────────────
    if (results.length < 3 && q.length >= 2) {
      try {
        final remote = await _searchCoinGecko(q);
        for (final r in remote) {
          results.putIfAbsent(r.dedupKey, () => r);
        }
      } catch (_) {
        // Network error — return what we have locally.
      }
    }

    // ── Sort by relevance ──────────────────────────────────────────────────
    final sorted = results.values.toList()
      ..sort((a, b) {
        // Exact symbol match first
        final aExact = a.symbol.toLowerCase() == q ? 0 : 1;
        final bExact = b.symbol.toLowerCase() == q ? 0 : 1;
        if (aExact != bExact) return aExact.compareTo(bExact);

        // CoinGecko cache results (richer data) before exchange-only
        final aCache = a.source == 'cache' ? 0 : 1;
        final bCache = b.source == 'cache' ? 0 : 1;
        if (aCache != bCache) return aCache.compareTo(bCache);

        // Then by actual market cap (higher = more relevant)
        final aCap = a.marketCap ?? 0;
        final bCap = b.marketCap ?? 0;
        return bCap.compareTo(aCap);
      });

    return sorted.take(limit).toList();
  }

  /// Hit CoinGecko /search endpoint for remote results.
  Future<List<SearchResult>> _searchCoinGecko(String query) async {
    final uri = Uri.parse('$_baseUrl/search').replace(
      queryParameters: {'query': query},
    );

    final response = await http.get(uri, headers: const {
      'accept': 'application/json'
    }).timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) return const [];

    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>) return const [];

    final coins = data['coins'];
    if (coins is! List) return const [];

    return coins
        .whereType<Map<String, dynamic>>()
        .take(15)
        .map((coin) => SearchResult(
              id: coin['id']?.toString() ?? '',
              symbol: (coin['symbol']?.toString() ?? '').toUpperCase(),
              name: coin['name']?.toString() ?? '',
              // CoinGecko /search returns rank, NOT market cap.
              // Store correctly in marketCapRank, not marketCap.
              marketCapRank: (coin['market_cap_rank'] as num?)?.toInt(),
              imageUrl: coin['large']?.toString() ?? coin['thumb']?.toString(),
              source: 'coingecko_search',
            ))
        .toList();
  }

  bool _matches(String symbol, String name, String query) {
    final s = symbol.toLowerCase();
    final n = name.toLowerCase();
    return s.contains(query) || n.contains(query);
  }
}
