import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_registry.dart';

// ─── Watchlist Service ──────────────────────────────────────────────────────────
//
// Manages the user's watchlist of favorite tokens.
// Stores entries as CoinGecko IDs when available, raw SYMBOL when not.
// Persists to SharedPreferences.
//
// Entry format in storage:
//   'bitcoin'      → CoinGecko ID (matched against cachedMarkets)
//   'sym:NEWTOKEN' → Raw symbol prefix (exchange-only, no CoinGecko match)
//
// Usage:
//   WatchlistService.instance.toggle('bitcoin');     // CoinGecko token
//   WatchlistService.instance.toggleSymbol('IBITI');  // exchange-only token
// ─────────────────────────────────────────────────────────────────────────────────

class WatchlistService extends ChangeNotifier {
  WatchlistService._();
  static final WatchlistService instance = WatchlistService._();

  static const _prefsKey = 'guardian_watchlist';
  static const _symPrefix = 'sym:';

  final List<String> _entries = []; // mixed: CoinGecko IDs + 'sym:SYMBOL'
  bool _loaded = false;

  /// All raw entries (for debugging/export).
  List<String> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;
  int get count => _entries.length;

  /// Check if a CoinGecko ID is in the watchlist.
  bool isFavorite(String coinGeckoId) {
    if (coinGeckoId.isEmpty) return false;
    return _entries.contains(coinGeckoId.toLowerCase());
  }

  /// Check by symbol — works for both CoinGecko and exchange-only tokens.
  bool isFavoriteBySymbol(String symbol) {
    final s = symbol.toUpperCase();
    // Direct symbol entry?
    if (_entries.contains('$_symPrefix$s')) return true;
    // CoinGecko asset with this symbol?
    final cached = MarketDataService.instance.cachedMarkets;
    for (final asset in cached) {
      if (asset.symbol == s && _entries.contains(asset.id)) return true;
    }
    return false;
  }

  /// Check by either ID or symbol — convenience for Token Detail screen.
  bool isFavoriteAny(String id, String symbol) {
    if (id.isNotEmpty && isFavorite(id)) return true;
    return isFavoriteBySymbol(symbol);
  }

  /// Toggle by CoinGecko ID (preferred for tokens with known IDs).
  void toggle(String coinGeckoId) {
    if (coinGeckoId.isEmpty) return;
    final id = coinGeckoId.toLowerCase();
    if (_entries.contains(id)) {
      _entries.remove(id);
    } else {
      _entries.add(id);
    }
    _save();
    notifyListeners();
  }

  /// Toggle by raw symbol (for exchange-only tokens without CoinGecko ID).
  void toggleSymbol(String symbol) {
    final key = '$_symPrefix${symbol.toUpperCase()}';
    if (_entries.contains(key)) {
      _entries.remove(key);
    } else {
      _entries.add(key);
    }
    _save();
    notifyListeners();
  }

  /// Smart toggle: uses ID if available, falls back to symbol.
  void toggleSmart(String id, String symbol) {
    if (id.isNotEmpty) {
      toggle(id);
    } else {
      toggleSymbol(symbol);
    }
  }

  /// Get live market data for all watchlisted tokens.
  ///
  /// Merges CoinGecko cache + exchange tickers to cover both sources.
  /// For CoinGecko-matched tokens, overlays LIVE exchange prices so
  /// the watchlist shows real-time data, not stale 90s-old snapshots.
  List<MarketAsset> get watchlistAssets {
    if (_entries.isEmpty) return const [];

    final result = <MarketAsset>[];
    final cached = MarketDataService.instance.cachedMarkets;
    final matched = <String>{};

    // 1. Match CoinGecko IDs against cache
    for (final entry in _entries) {
      if (entry.startsWith(_symPrefix)) continue;
      final asset = cached.where((a) => a.id == entry).firstOrNull;
      if (asset != null) {
        result.add(asset);
        matched.add(entry);
      }
    }

    // 2. Match sym: entries against exchange tickers
    for (final entry in _entries) {
      if (!entry.startsWith(_symPrefix)) continue;
      if (matched.contains(entry)) continue;

      final symbol = entry.substring(_symPrefix.length);

      // Try CoinGecko cache first (might have appeared since watchlisting)
      final cgAsset = cached.where((a) => a.symbol == symbol).firstOrNull;
      if (cgAsset != null) {
        result.add(cgAsset);
        continue;
      }

      // Try exchange tickers
      for (final exId in ExchangeRegistry.instance.availableExchanges) {
        final svc = ExchangeRegistry.instance.serviceFor(exId);
        final ticker =
            svc.currentTickers.where((t) => t.baseAsset == symbol).firstOrNull;
        if (ticker != null) {
          result.add(MarketAsset(
            id: '',
            symbol: ticker.baseAsset,
            name: ticker.baseAsset,
            imageUrl: '',
            price: ticker.lastPrice,
            change24h: ticker.priceChangePercent24h,
            marketCap: 0,
            volume: ticker.quoteVolume24h,
            rank: 0,
            sparkline: const [],
            high24h: ticker.highPrice24h,
            low24h: ticker.lowPrice24h,
            change7d: 0,
            change30d: 0,
            networkGroup: '',
          ));
          break;
        }
      }
    }

    return result;
  }

  // ── Persistence ────────────────────────────────────────────────────────────

  /// Load watchlist from SharedPreferences. Call once at app start.
  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_prefsKey);
    if (saved != null) {
      _entries
        ..clear()
        ..addAll(saved);
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, _entries);
  }
}
