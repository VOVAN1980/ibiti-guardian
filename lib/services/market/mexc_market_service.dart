import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/utils/guardian_logger.dart';

// ─── MEXC New Listings & Top Gainers ───────────────────────────────────────────

const _log = GuardianLogger('MexcMkt');

/// A single ticker from MEXC — includes listing date and growth since listing.
class MexcTicker {
  final String symbol;
  final String baseAsset;
  final String fullName;
  final double lastPrice;
  final double priceChangePercent24h;

  /// Growth since listing date (the real moonshot number).
  /// e.g. SOLU listed at $0.0001, now $0.0004 → +300%.
  final double growthSinceListing;

  final double volume;
  final double quoteVolume;
  final double highPrice;
  final double lowPrice;

  /// When the coin was first listed on MEXC.
  final DateTime? listingDate;

  /// How many days ago was the listing.
  final int daysListed;

  /// On-chain contract address (if known from MEXC).
  final String? contractAddress;

  const MexcTicker({
    required this.symbol,
    required this.baseAsset,
    required this.fullName,
    required this.lastPrice,
    required this.priceChangePercent24h,
    required this.growthSinceListing,
    required this.volume,
    required this.quoteVolume,
    required this.highPrice,
    required this.lowPrice,
    this.listingDate,
    required this.daysListed,
    this.contractAddress,
  });
}

/// Fetches live data from MEXC exchange — new listings, top gainers,
/// the actual moonshot coins with +100%, +500%, +1000%.
///
/// Uses two endpoints:
///   1. `/exchangeInfo` — listing dates + contract addresses
///   2. `/ticker/24hr` — current prices
///   3. `/klines` — first-day open price (for growth-since-listing calculation)
///
/// All endpoints are PUBLIC — no API key needed for viewing.
class MexcMarketService {
  MexcMarketService._();

  static final MexcMarketService instance = MexcMarketService._();

  static const _baseUrl = 'https://api.mexc.com/api/v3';

  /// Cached tickers from last fetch.
  List<MexcTicker> _cachedTickers = const [];
  DateTime? _lastFetch;

  /// All cached tickers.
  List<MexcTicker> get cachedTickers => _cachedTickers;

  /// Top gainers since listing — sorted by biggest growth.
  /// This matches what MEXC shows on "Показывают рост на споте".
  List<MexcTicker> get topGainers {
    final gainers = _cachedTickers
        .where((t) => t.growthSinceListing > 0 && t.quoteVolume > 1000)
        .toList()
      ..sort((a, b) => b.growthSinceListing.compareTo(a.growthSinceListing));
    return gainers;
  }

  /// Fetches new listings (last 30 days) with growth-since-listing data.
  /// No API key required — all public endpoints.
  Future<List<MexcTicker>> fetchTickers({bool forceRefresh = false}) async {
    // Cache for 30 seconds.
    if (!forceRefresh &&
        _lastFetch != null &&
        DateTime.now().difference(_lastFetch!) < const Duration(seconds: 30) &&
        _cachedTickers.isNotEmpty) {
      return _cachedTickers;
    }

    try {
      // Step 1: Get all symbols with listing dates.
      final infoUri = Uri.parse('$_baseUrl/exchangeInfo');
      final infoResp = await http.get(infoUri, headers: const {
        'accept': 'application/json'
      }).timeout(const Duration(seconds: 15));

      if (infoResp.statusCode != 200) {
        throw Exception('MEXC exchangeInfo error: ${infoResp.statusCode}');
      }

      final infoData = jsonDecode(infoResp.body);
      final symbols = infoData['symbols'] as List? ?? [];

      // Filter: only USDT pairs, listed in last 30 days, active.
      final now = DateTime.now().millisecondsSinceEpoch;
      const thirtyDaysMs = 30 * 24 * 60 * 60 * 1000;
      final newSymbols = <Map<String, dynamic>>[];

      for (final sym in symbols) {
        if (sym is! Map<String, dynamic>) continue;
        final symbolName = sym['symbol']?.toString() ?? '';
        if (!symbolName.endsWith('USDT')) continue;

        final status = sym['status']?.toString() ?? '';
        if (status != '1') continue; // Only active trading pairs.

        final firstOpenTime = (sym['firstOpenTime'] as num?)?.toInt() ?? 0;
        if (firstOpenTime <= 0) continue;

        // Only recently listed (last 30 days).
        if (now - firstOpenTime > thirtyDaysMs) continue;

        final base = sym['baseAsset']?.toString() ?? '';
        if (base.isEmpty || _stables.contains(base)) continue;

        newSymbols.add(sym);
      }

      if (newSymbols.isEmpty) {
        _cachedTickers = const [];
        _lastFetch = DateTime.now();
        return _cachedTickers;
      }

      // Step 2: Get 24hr tickers for current prices.
      final tickerUri = Uri.parse('$_baseUrl/ticker/24hr');
      final tickerResp = await http.get(tickerUri, headers: const {
        'accept': 'application/json'
      }).timeout(const Duration(seconds: 15));

      if (tickerResp.statusCode != 200) {
        throw Exception('MEXC ticker error: ${tickerResp.statusCode}');
      }

      final tickerData = jsonDecode(tickerResp.body) as List? ?? [];
      final tickerMap = <String, Map<String, dynamic>>{};
      for (final t in tickerData) {
        if (t is! Map<String, dynamic>) continue;
        final s = t['symbol']?.toString() ?? '';
        tickerMap[s] = t;
      }

      // Step 3: For each new symbol, get the first-day open price
      // to calculate growth since listing.
      final tickers = <MexcTicker>[];

      // Batch — process max 20 to avoid rate limiting.
      final toProcess = newSymbols.take(40).toList();

      for (final sym in toProcess) {
        final symbolName = sym['symbol']?.toString() ?? '';
        final base = sym['baseAsset']?.toString() ?? '';
        final fullName = sym['fullName']?.toString() ?? base;
        final firstOpenTime = (sym['firstOpenTime'] as num?)?.toInt() ?? 0;
        final contract = sym['contractAddress']?.toString();

        final ticker = tickerMap[symbolName];
        if (ticker == null) continue;

        final lastPrice = _toDouble(ticker['lastPrice']);
        if (lastPrice <= 0) continue;

        final change24h = _toDouble(ticker['priceChangePercent']);
        final vol = _toDouble(ticker['volume']);
        final quoteVol = _toDouble(ticker['quoteVolume']);
        final high = _toDouble(ticker['highPrice']);
        final low = _toDouble(ticker['lowPrice']);

        final listingDate = DateTime.fromMillisecondsSinceEpoch(
          firstOpenTime,
          isUtc: true,
        );
        final daysListed =
            DateTime.now().toUtc().difference(listingDate).inDays;

        // Get first-day open price via klines.
        double growthSinceListing = 0;
        try {
          final klineUri = Uri.parse(
            '$_baseUrl/klines?symbol=$symbolName&interval=1d&startTime=$firstOpenTime&limit=1',
          );
          final klineResp = await http.get(klineUri, headers: const {
            'accept': 'application/json'
          }).timeout(const Duration(seconds: 5));

          if (klineResp.statusCode == 200) {
            final klineData = jsonDecode(klineResp.body);
            if (klineData is List && klineData.isNotEmpty) {
              final firstCandle = klineData[0];
              if (firstCandle is List && firstCandle.length >= 2) {
                final openPrice = _toDouble(firstCandle[1]);
                if (openPrice > 0) {
                  growthSinceListing =
                      ((lastPrice - openPrice) / openPrice) * 100;
                }
              }
            }
          }
        } catch (_) {
          // If kline fetch fails, use 24h change as fallback.
          growthSinceListing = change24h;
        }

        tickers.add(MexcTicker(
          symbol: symbolName,
          baseAsset: base,
          fullName: fullName,
          lastPrice: lastPrice,
          priceChangePercent24h: change24h,
          growthSinceListing: growthSinceListing,
          volume: vol,
          quoteVolume: quoteVol,
          highPrice: high,
          lowPrice: low,
          listingDate: listingDate,
          daysListed: daysListed,
          contractAddress: contract,
        ));
      }

      _cachedTickers = tickers;
      _lastFetch = DateTime.now();
      return tickers;
    } catch (e) {
      _log.e('fetchTickers error', e);
      return _cachedTickers;
    }
  }

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0.0;
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
}
