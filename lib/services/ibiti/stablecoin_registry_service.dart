// ─── Stablecoin Registry Service ────────────────────────────────────────────────
//
// Phase 15A.2: Smart stablecoin detection.
//
// Three layers of detection:
//   1. Local hardcoded known pairs (instant, no network).
//   2. Base-symbol detector: extract base from pair, check if it's a stable base.
//   3. Async internet updater (CoinGecko categories, every 12h).
//
// If internet fails → JARVIS still works on local registry.
// NEVER blocks the trading tick waiting for internet.
// ─────────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/utils/guardian_logger.dart';

const _log = GuardianLogger('StablecoinRegistry');

class StablecoinRegistryService {
  StablecoinRegistryService._();
  static final StablecoinRegistryService instance =
      StablecoinRegistryService._();

  // ── Known quote currencies ────────────────────────────────────────────────

  static const _quoteAssets = {'USDT', 'USDC', 'BUSD', 'FDUSD'};

  // ── Hardcoded stable bases (always present) ───────────────────────────────

  static const _hardcodedStableBases = <String>{
    'USDT', 'USDC', 'DAI', 'FDUSD', 'TUSD', 'BUSD', 'RLUSD',
    'USD1', 'PYUSD', 'USDE', 'USDD', 'USDP', 'GUSD', 'LUSD',
    'FRAX', 'SUSDE', 'USDS', 'EURI', 'BFUSD', 'USDTB',
    // EUR-pegged
    'EURS', 'EURC', 'AGEUR',
    // Algo-stable
    'UST', 'MIM', 'FEI', 'CUSD',
  };

  // ── Hardcoded stable pairs (full trading pair name) ───────────────────────

  static const _hardcodedStablePairs = <String>{
    'USDCUSDT', 'DAIUSDT', 'FDUSDUSDT', 'TUSDUSDT',
    'BUSDUSDT', 'RLUSDUSDT', 'USD1USDT', 'PYUSDUSDT',
    'USDEUSDT', 'USDDUSDT', 'USDPUSDT', 'GUSDUSDT',
    'LUSDUSDT', 'FRAXUSDT', 'SUSDEUSDT', 'USDSUSDT',
    'EURIUSDT', 'BFUSDUSDT', 'USDTBUSDT',
    // Cross-stable pairs
    'USDTBUSDC', 'USDTBUSD',
  };

  // ── Dynamic sets (updated by internet refresh) ────────────────────────────

  final Set<String> _dynamicStableBases = {};
  final Set<String> _dynamicStablePairs = {};

  DateTime? _lastRefresh;
  bool _refreshing = false;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Check if a trading pair symbol is a stablecoin.
  /// Fast, synchronous, never blocks.
  bool isStablecoin(String symbol) {
    final sym = symbol.toUpperCase();

    // Layer 1: Known full pair match.
    if (_hardcodedStablePairs.contains(sym)) return true;
    if (_dynamicStablePairs.contains(sym)) return true;

    // Layer 2: Base-symbol detection.
    final base = _extractBase(sym);
    if (base != null) {
      if (_hardcodedStableBases.contains(base)) return true;
      if (_dynamicStableBases.contains(base)) return true;
    }

    return false;
  }

  /// What source detected this as stablecoin? For logging.
  String detectionSource(String symbol) {
    final sym = symbol.toUpperCase();
    if (_hardcodedStablePairs.contains(sym)) return 'hardcodedPair';
    if (_dynamicStablePairs.contains(sym)) return 'dynamicPair';

    final base = _extractBase(sym);
    if (base != null) {
      if (_hardcodedStableBases.contains(base)) return 'baseDetector';
      if (_dynamicStableBases.contains(base)) return 'dynamicBase';
    }
    return 'unknown';
  }

  /// Total known stablecoin bases (for logging).
  int get totalBases =>
      _hardcodedStableBases.length + _dynamicStableBases.length;

  /// Total known stablecoin pairs (for logging).
  int get totalPairs =>
      _hardcodedStablePairs.length + _dynamicStablePairs.length;

  // ── Base extraction ───────────────────────────────────────────────────────

  /// Extract base asset from a trading pair.
  /// BTCUSDT → BTC, USDCUSDT → USDC, USDTBUSDT → USDTB
  String? _extractBase(String symbol) {
    for (final quote in _quoteAssets) {
      if (symbol.endsWith(quote) && symbol.length > quote.length) {
        final base = symbol.substring(0, symbol.length - quote.length);
        // Ignore single-character bases — too likely to be false positives
        // (e.g. UUSDT → 'U' could match dynamic stable list erroneously).
        if (base.length < 2) return null;
        return base;
      }
    }
    return null;
  }

  // ── Internet refresh ──────────────────────────────────────────────────────

  /// Initialize: log local state, schedule background refresh.
  void initialize() {
    _log.i('Loaded local: bases=${_hardcodedStableBases.length} '
        'pairs=${_hardcodedStablePairs.length}');

    // Fire-and-forget initial refresh.
    unawaited(_refreshFromInternet());
  }

  /// Refresh from CoinGecko stablecoins category. Non-blocking.
  /// Call on startup + every 12h.
  Future<void> _refreshFromInternet() async {
    if (_refreshing) return;

    // Rate limit: no more than once per 12 hours.
    if (_lastRefresh != null &&
        DateTime.now().difference(_lastRefresh!).inHours < 12) {
      return;
    }

    _refreshing = true;
    try {
      // CoinGecko free API: get coins in the "stablecoins" category.
      final url = Uri.parse(
        'https://api.coingecko.com/api/v3/coins/markets'
        '?vs_currency=usd'
        '&category=stablecoins'
        '&order=market_cap_desc'
        '&per_page=100'
        '&page=1'
        '&sparkline=false',
      );

      final response = await http.get(url).timeout(
            const Duration(seconds: 15),
          );

      if (response.statusCode != 200) {
        _log.w('Refresh failed: HTTP ${response.statusCode}, using local');
        return;
      }

      final List<dynamic> coins = jsonDecode(response.body);
      int added = 0;

      for (final coin in coins) {
        final symbol = (coin['symbol'] as String?)?.toUpperCase();
        if (symbol != null &&
            symbol.isNotEmpty &&
            !_hardcodedStableBases.contains(symbol)) {
          if (_dynamicStableBases.add(symbol)) added++;
        }
      }

      _lastRefresh = DateTime.now();
      _log.i('Refresh ok: added=$added total=$totalBases bases');
    } on http.ClientException catch (e) {
      _log.w('Refresh failed (network): $e, using local');
    } on FormatException catch (e) {
      _log.w('Refresh failed (parse): $e, using local');
    } on TimeoutException {
      _log.w('Refresh failed (timeout), using local');
    } catch (e) {
      _log.w('Refresh failed: $e, using local');
    } finally {
      _refreshing = false;
    }
  }

  /// Schedule periodic refresh (call once from IbitiLoop.start).
  Timer? _refreshTimer;

  void startPeriodicRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      const Duration(hours: 12),
      (_) => unawaited(_refreshFromInternet()),
    );
  }

  void dispose() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }
}
