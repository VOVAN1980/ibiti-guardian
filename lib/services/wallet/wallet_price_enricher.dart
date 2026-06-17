import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

// --- Wallet Price Enricher ---------------------------------------------------
//
// SINGLE source of truth for token prices in the entire app.
// PortfolioAdapter provides ONLY balances (priceUsd=0).
// This service enriches with real prices from CoinGecko.
//
// Persistent cache: last successful prices survive app restart.
// If CoinGecko is unavailable after relaunch, stale prices are used
// (up to 24h) — BNB never becomes "—" if it was priced before.
// -----------------------------------------------------------------------------

class WalletPriceEnricher {
  WalletPriceEnricher._();
  static final instance = WalletPriceEnricher._();

  static const _log = GuardianLogger('PriceEnricher');
  static const _apiBase = 'https://api.coingecko.com/api/v3';
  static const _storageKey = 'wallet_price_cache';
  static const _storageTsKey = 'wallet_price_cache_ts';

  // In-memory cache: symbol -> {usd, change}
  final Map<String, Map<String, double>> _cache = {};
  DateTime? _cacheTs;
  bool _diskLoaded = false;

  /// Fresh cache: CoinGecko data < 180s old.
  static const _freshTtl = Duration(seconds: 180);

  /// Stale cache: use persisted prices up to 24h after last success.
  static const _staleTtl = Duration(hours: 24);

  /// Well-known symbol -> CoinGecko ID mapping for top tokens.
  static const _knownIds = <String, String>{
    'BTC': 'bitcoin',
    'ETH': 'ethereum',
    'BNB': 'binancecoin',
    'SOL': 'solana',
    'TRX': 'tron',
    'MATIC': 'matic-network',
    'POL': 'matic-network',
    'AVAX': 'avalanche-2',
    'DOGE': 'dogecoin',
    'SHIB': 'shiba-inu',
    'ADA': 'cardano',
    'XRP': 'ripple',
    'DOT': 'polkadot',
    'LINK': 'chainlink',
    'UNI': 'uniswap',
    'AAVE': 'aave',
    'USDT': 'tether',
    'USDC': 'usd-coin',
    'DAI': 'dai',
    'BUSD': 'binance-usd',
    'FDUSD': 'first-digital-usd',
    'WBTC': 'wrapped-bitcoin',
    'WETH': 'weth',
    'WBNB': 'wbnb',
    'PEPE': 'pepe',
    'ARB': 'arbitrum',
    'OP': 'optimism',
    'FTM': 'fantom',
    'NEAR': 'near',
    'APT': 'aptos',
    'SUI': 'sui',
    'SEI': 'sei-network',
    'INJ': 'injective-protocol',
    'ATOM': 'cosmos',
    'FIL': 'filecoin',
    'LTC': 'litecoin',
    'BCH': 'bitcoin-cash',
    'XLM': 'stellar',
    'ALGO': 'algorand',
    'MSVP': 'msvp',
  };

  /// Stablecoins: always price=1, change=0. No API call needed.
  static const _stablecoins = {
    'USDT',
    'USDC',
    'DAI',
    'BUSD',
    'FDUSD',
    'TUSD',
    'PYUSD',
    'GUSD',
    'USDP',
  };

  // ── Persistent cache ────────────────────────────────────────────────────────

  /// Load last successful prices from disk. Called once on first enrich().
  Future<void> _loadFromDisk() async {
    if (_diskLoaded) return;
    _diskLoaded = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      final tsMs = prefs.getInt(_storageTsKey);

      if (raw != null && tsMs != null) {
        final saved = jsonDecode(raw) as Map<String, dynamic>;
        final savedTs = DateTime.fromMillisecondsSinceEpoch(tsMs);
        final age = DateTime.now().difference(savedTs);

        // Only restore if within stale TTL (24h)
        if (age < _staleTtl) {
          for (final entry in saved.entries) {
            final data = entry.value as Map<String, dynamic>;
            _cache[entry.key] = {
              'usd': (data['usd'] as num?)?.toDouble() ?? 0.0,
              'change': (data['change'] as num?)?.toDouble() ?? 0.0,
            };
          }
          _cacheTs = savedTs;
          _log.d('Restored ${_cache.length} prices from disk '
              '(age: ${age.inMinutes}m)');
        } else {
          _log.d('Disk cache expired (${age.inHours}h), starting fresh');
        }
      }
    } catch (e) {
      _log.w('Failed to load price cache from disk', e);
    }
  }

  /// Persist current cache to disk.
  Future<void> _saveToDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Convert to JSON-safe map (exclude stablecoins — no need to persist)
      final toSave = <String, Map<String, double>>{};
      for (final entry in _cache.entries) {
        if (!_stablecoins.contains(entry.key)) {
          toSave[entry.key] = entry.value;
        }
      }

      await prefs.setString(_storageKey, jsonEncode(toSave));
      await prefs.setInt(_storageTsKey, DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      _log.w('Failed to save price cache to disk', e);
    }
  }

  // ── Core enrichment ─────────────────────────────────────────────────────────

  /// Enrich a list of [WalletAsset] with price + 24h change data.
  /// Returns a new list with enriched copies. Never throws.
  Future<List<WalletAsset>> enrich(List<WalletAsset> assets) async {
    if (assets.isEmpty) return assets;

    // Load persisted prices on first call
    await _loadFromDisk();

    // Ensure stablecoins are always in cache
    for (final s in _stablecoins) {
      _cache.putIfAbsent(s, () => {'usd': 1.0, 'change': 0.0});
    }

    // Try to pre-populate / update cache with live prices from MarketDataService
    final liveSymbols = <String>{};
    try {
      final markets = MarketDataService.instance.cachedMarkets;
      for (final a in assets) {
        final sym = a.symbol.toUpperCase();
        if (_stablecoins.contains(sym)) continue;
        final match = markets.where((m) => m.symbol.toUpperCase() == sym).firstOrNull;
        if (match != null && match.price > 0) {
          _cache[sym] = {
            'usd': match.price,
            'change': match.change24h,
          };
          liveSymbols.add(sym);
        }
      }
    } catch (e) {
      _log.w('Failed to read live prices from MarketDataService: $e');
    }

    try {
      // Collect symbols that need CoinGecko lookup
      final symbolToId = <String, String>{};
      for (final a in assets) {
        final sym = a.symbol.toUpperCase();
        if (_stablecoins.contains(sym)) continue;
        if (liveSymbols.contains(sym)) continue; // We already have real-time price from exchange!
        if (_cache.containsKey(sym) &&
            _cacheTs != null &&
            DateTime.now().difference(_cacheTs!) < _freshTtl) {
          continue; // cache is fresh for this symbol
        }
        final id = _resolveId(sym);
        if (id != null) symbolToId[sym] = id;
      }

      if (symbolToId.isNotEmpty) {
        // Batch CoinGecko call — only for symbols we actually need
        final ids = symbolToId.values.toSet().join(',');
        final url = Uri.parse(
          '$_apiBase/simple/price?ids=$ids&vs_currencies=usd&include_24hr_change=true',
        );

        final resp = await http.get(url).timeout(const Duration(seconds: 8));

        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body) as Map<String, dynamic>;

          // MERGE into existing cache — never replace
          for (final entry in symbolToId.entries) {
            final sym = entry.key;
            final cgId = entry.value;
            final cgData = data[cgId];
            if (cgData != null) {
              _cache[sym] = {
                'usd': (cgData['usd'] as num?)?.toDouble() ?? 0.0,
                'change': (cgData['usd_24h_change'] as num?)?.toDouble() ?? 0.0,
              };
            }
          }

          _cacheTs = DateTime.now();
          _log.d('Enriched ${symbolToId.length} symbols from CoinGecko '
              '(cache total: ${_cache.length})');

          // Persist successful fetch to disk
          _saveToDisk(); // fire-and-forget
        } else {
          _log.w('CoinGecko returned ${resp.statusCode}');
          // Extend stale cache TTL so we don't retry immediately
          if (_cache.isNotEmpty) _cacheTs = DateTime.now();
        }
      }
    } catch (e) {
      _log.w('Price enrichment failed (non-fatal)', e);
      // Keep stale cache on error — show old prices, not "—"
      if (_cache.isNotEmpty) _cacheTs = DateTime.now();
    }

    return _applyCache(assets);
  }

  // ── Cache application ───────────────────────────────────────────────────────

  /// Apply cached price data to assets.
  /// Updates priceUsd and valueUsd so portfolio totals are accurate.
  List<WalletAsset> _applyCache(List<WalletAsset> assets) {
    return assets.map((a) {
      final sym = a.symbol.toUpperCase();

      // Stablecoins: always price=1, change=0, even without cache
      if (_stablecoins.contains(sym)) {
        final stableValue = a.balance * 1.0;
        return a.copyWith(
          priceUsd: 1.0,
          valueUsd: stableValue,
          priceChange24hPct: 0.0,
          valueChange24hUsd: 0.0,
          priceAvailable: true,
        );
      }

      final data = _cache[sym];
      if (data != null) {
        final currentPrice = data['usd'] ?? 0.0;
        final changePct = data['change'] ?? 0.0;
        final currentValue = a.balance * currentPrice;

        // valueChange: how much USD value changed in 24h
        // previousValue = currentValue / (1 + changePct/100)
        // valueChange = currentValue - previousValue
        final valueChange = changePct.abs() > 0.001
            ? currentValue - (currentValue / (1 + changePct / 100))
            : 0.0;

        return a.copyWith(
          priceUsd: currentPrice,
          valueUsd: currentValue,
          priceChange24hPct: changePct,
          valueChange24hUsd: valueChange,
          priceAvailable: currentPrice > 0,
        );
      }

      // No data — mark as price unavailable if price is zero
      if (a.priceUsd <= 0) {
        return a.copyWith(priceAvailable: false);
      }

      return a;
    }).toList();
  }

  // ── Symbol resolution ───────────────────────────────────────────────────────

  /// Resolve symbol to CoinGecko ID using static map + MarketDataService cache.
  String? _resolveId(String symbol) {
    // Static map first
    final known = _knownIds[symbol];
    if (known != null) return known;

    // Try MarketDataService cache (CoinGecko markets list)
    try {
      final markets = MarketDataService.instance.cachedMarkets;
      for (final m in markets) {
        if (m.symbol.toUpperCase() == symbol && m.id.isNotEmpty) {
          return m.id;
        }
      }
    } catch (_) {}

    return null;
  }
}
