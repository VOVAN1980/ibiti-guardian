import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/models/candle.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

// ─── Exchange Chart Service ─────────────────────────────────────────────────────
//
// Fetches klines (OHLC candle data) directly from exchange REST APIs.
// NO rate limit problems — exchanges allow thousands of calls/min.
//
// Supported:
//   • Binance: GET /api/v3/klines         — intervals: 1m, 5m, 15m, 30m, 1h, 4h, 1d
//   • MEXC:    GET /api/v3/klines         — intervals: 1m, 5m, 15m, 30m, 60m, 4h, 1d
//   • Gate.io: GET /spot/candlesticks     — intervals: 1m, 5m, 15m, 30m, 1h, 4h, 1d
//   • OKX:     GET /api/v5/market/candles — intervals: 1m, 5m, 15m, 30m, 1H, 4H, 1D
//
// ─────────────────────────────────────────────────────────────────────────────────

class ExchangeChartService {
  ExchangeChartService._();
  static final ExchangeChartService instance = ExchangeChartService._();
  static const _log = GuardianLogger('ExchangeChart');

  static const _binanceBase = 'https://api.binance.com';
  static const _mexcBase = 'https://api.mexc.com';
  static const _gateioBase = 'https://api.gateio.ws';
  static const _okxBase = 'https://www.okx.com';

  http.Client client = http.Client();

  // Simple in-memory cache to avoid refetching the same chart in a session
  final Map<String, _CachedChart> _cache = {};

  Duration _getCacheTtl(String rangeKey) {
    switch (rangeKey.toLowerCase()) {
      case '1m':
        return const Duration(seconds: 10);
      case '5m':
        return const Duration(seconds: 25);
      case '15m':
        return const Duration(seconds: 45);
      case '30m':
      case '1h':
        return const Duration(minutes: 2);
      case '24h':
        return const Duration(minutes: 3);
      default:
        return const Duration(minutes: 5);
    }
  }

  /// Legacy wrapper around [fetchCandles] that returns close prices only.
  Future<List<double>> fetchPrices(
    String symbol, {
    required String rangeKey,
    String sourceId = '',
    String sourcePair = '',
  }) async {
    final candles = await fetchCandles(
      symbol,
      rangeKey: rangeKey,
      sourceId: sourceId,
      sourcePair: sourcePair,
    );
    return candles.map((c) => c.close).toList();
  }

  /// Fetch full OHLCV Candles for a symbol.
  ///
  /// [sourceId] controls which exchange to query:
  ///   'binance' → only Binance klines
  ///   'mexc'    → only MEXC klines
  ///   'gateio'  → only Gate.io candlesticks
  ///   'okx'     → only OKX candles
  ///   ''        → parallel all (default, uses whichever returns data first)
  Future<List<Candle>> fetchCandles(
    String symbol, {
    required String rangeKey,
    String sourceId = '',
    String sourcePair = '',
  }) async {
    final s = symbol.toUpperCase();
    final cacheKey = '$s:$rangeKey:$sourceId:$sourcePair';

    // Check cache
    final cached = _cache[cacheKey];
    final ttl = _getCacheTtl(rangeKey);
    if (cached != null && DateTime.now().difference(cached.at) < ttl) {
      return cached.candles;
    }

    final config = _rangeConfig(rangeKey);

    List<Candle> candles = const [];

    if (sourceId == 'binance') {
      candles = await _fetchFromBinance(s, sourcePair, config);
    } else if (sourceId == 'mexc') {
      candles = await _fetchFromMexc(s, sourcePair, config);
    } else if (sourceId == 'gateio') {
      candles = await _fetchFromGateio(s, sourcePair, config);
    } else if (sourceId == 'okx') {
      candles = await _fetchFromOkx(s, sourcePair, config);
    } else {
      // Fire all exchanges in parallel
      final results = await Future.wait([
        _fetchFromBinance(s, sourcePair, config),
        _fetchFromMexc(s, sourcePair, config),
        _fetchFromGateio(s, sourcePair, config),
        _fetchFromOkx(s, sourcePair, config),
      ]);

      // Use whichever returned data
      for (final r in results) {
        if (r.length >= 2) {
          candles = r;
          break;
        }
      }
    }

    if (candles.length >= 2) {
      // Ensure candles are sorted ascending by time
      candles.sort((a, b) => a.time.compareTo(b.time));
      _cache[cacheKey] = _CachedChart(candles, DateTime.now());
    }

    _log.i('[Chart] fetched ${candles.length} candles for $s '
        'range=$rangeKey source=${sourceId.isEmpty ? "all" : sourceId}');

    return candles;
  }

  // ── Binance ─────────────────────────────────────────────────────────────────

  Future<List<Candle>> _fetchFromBinance(
      String symbol, String sourcePair, _KlineConfig config) async {
    final pair = sourcePair.isNotEmpty ? sourcePair : '${symbol}USDT';
    final uri = Uri.parse('$_binanceBase/api/v3/klines').replace(
      queryParameters: {
        'symbol': pair,
        'interval': config.binanceInterval,
        'limit': '${config.limit}',
      },
    );

    try {
      final response = await client.get(uri).timeout(const Duration(seconds: 6));

      if (response.statusCode != 200) return const [];

      final data = jsonDecode(response.body);
      if (data is! List || data.isEmpty) return const [];

      return data
          .map<Candle?>((k) {
            if (k is! List || k.length < 6) return null;
            final time = DateTime.fromMillisecondsSinceEpoch(
                (k[0] as num).toInt(),
                isUtc: true);
            final open = double.tryParse(k[1].toString()) ?? 0.0;
            final high = double.tryParse(k[2].toString()) ?? 0.0;
            final low = double.tryParse(k[3].toString()) ?? 0.0;
            final close = double.tryParse(k[4].toString()) ?? 0.0;
            final volume = double.tryParse(k[5].toString()) ?? 0.0;
            return Candle(
                time: time,
                open: open,
                high: high,
                low: low,
                close: close,
                volume: volume);
          })
          .where((c) => c != null && c.close > 0)
          .cast<Candle>()
          .toList();
    } catch (e) {
      _log.w('Binance failed for $symbol', e);
      return const [];
    }
  }

  // ── MEXC ────────────────────────────────────────────────────────────────────

  Future<List<Candle>> _fetchFromMexc(
      String symbol, String sourcePair, _KlineConfig config) async {
    final pair = sourcePair.isNotEmpty ? sourcePair : '${symbol}USDT';
    final uri = Uri.parse('$_mexcBase/api/v3/klines').replace(
      queryParameters: {
        'symbol': pair,
        'interval': config.mexcInterval,
        'limit': '${config.limit}',
      },
    );

    try {
      final response = await client.get(uri).timeout(const Duration(seconds: 6));

      if (response.statusCode != 200) return const [];

      final data = jsonDecode(response.body);
      if (data is! List || data.isEmpty) return const [];

      return data
          .map<Candle?>((k) {
            if (k is! List || k.length < 6) return null;
            final time = DateTime.fromMillisecondsSinceEpoch(
                (k[0] as num).toInt(),
                isUtc: true);
            final open = double.tryParse(k[1].toString()) ?? 0.0;
            final high = double.tryParse(k[2].toString()) ?? 0.0;
            final low = double.tryParse(k[3].toString()) ?? 0.0;
            final close = double.tryParse(k[4].toString()) ?? 0.0;
            final volume = double.tryParse(k[5].toString()) ?? 0.0;
            return Candle(
                time: time,
                open: open,
                high: high,
                low: low,
                close: close,
                volume: volume);
          })
          .where((c) => c != null && c.close > 0)
          .cast<Candle>()
          .toList();
    } catch (e) {
      _log.w('MEXC failed for $symbol', e);
      return const [];
    }
  }

  // ── Gate.io ─────────────────────────────────────────────────────────────────

  Future<List<Candle>> _fetchFromGateio(
      String symbol, String sourcePair, _KlineConfig config) async {
    // Gate.io REST requires "BTC_USDT" format, but WS normalizes to "BTCUSDT".
    // Normalize: insert underscore before quote asset if missing.
    var pair = sourcePair.isNotEmpty ? sourcePair : '${symbol}_USDT';
    if (!pair.contains('_')) {
      if (pair.endsWith('USDT')) {
        pair = '${pair.substring(0, pair.length - 4)}_USDT';
      } else if (pair.endsWith('USDC')) {
        pair = '${pair.substring(0, pair.length - 4)}_USDC';
      }
    }
    final uri = Uri.parse('$_gateioBase/api/v4/spot/candlesticks').replace(
      queryParameters: {
        'currency_pair': pair,
        'interval': config.gateioInterval,
        'limit': '${config.limit}',
      },
    );

    try {
      final response = await client.get(uri).timeout(const Duration(seconds: 6));

      if (response.statusCode != 200) return const [];

      final data = jsonDecode(response.body);
      if (data is! List || data.isEmpty) return const [];

      return data
          .map<Candle?>((k) {
            if (k is! List || k.length < 6) return null;
            final timeSec = double.tryParse(k[0].toString()) ?? 0.0;
            final time = DateTime.fromMillisecondsSinceEpoch(
                (timeSec * 1000).toInt(),
                isUtc: true);
            final volume = double.tryParse(k[1].toString()) ?? 0.0;
            final close = double.tryParse(k[2].toString()) ?? 0.0;
            final high = double.tryParse(k[3].toString()) ?? 0.0;
            final low = double.tryParse(k[4].toString()) ?? 0.0;
            final open = double.tryParse(k[5].toString()) ?? 0.0;
            return Candle(
                time: time,
                open: open,
                high: high,
                low: low,
                close: close,
                volume: volume);
          })
          .where((c) => c != null && c.close > 0)
          .cast<Candle>()
          .toList();
    } catch (e) {
      _log.w('Gate.io failed for $symbol', e);
      return const [];
    }
  }

  // ── OKX ─────────────────────────────────────────────────────────────────────

  Future<List<Candle>> _fetchFromOkx(
      String symbol, String sourcePair, _KlineConfig config) async {
    // OKX REST requires "BTC-USDT" format, but WS normalizes to "BTCUSDT".
    // Normalize: insert hyphen before quote asset if missing.
    var pair = sourcePair.isNotEmpty ? sourcePair : '$symbol-USDT';
    if (!pair.contains('-')) {
      if (pair.endsWith('USDT')) {
        pair = '${pair.substring(0, pair.length - 4)}-USDT';
      } else if (pair.endsWith('USDC')) {
        pair = '${pair.substring(0, pair.length - 4)}-USDC';
      }
    }
    final uri = Uri.parse('$_okxBase/api/v5/market/candles').replace(
      queryParameters: {
        'instId': pair,
        'bar': config.okxInterval,
        'limit': '${config.limit}',
      },
    );

    try {
      final response = await client.get(uri).timeout(const Duration(seconds: 6));

      if (response.statusCode != 200) return const [];

      final data = jsonDecode(response.body);
      if (data is! Map || data['code'] != '0') return const [];

      final list = data['data'];
      if (list is! List || list.isEmpty) return const [];

      return list
          .map<Candle?>((k) {
            if (k is! List || k.length < 6) return null;
            final timeMs = int.tryParse(k[0].toString()) ?? 0;
            final time = DateTime.fromMillisecondsSinceEpoch(timeMs, isUtc: true);
            final open = double.tryParse(k[1].toString()) ?? 0.0;
            final high = double.tryParse(k[2].toString()) ?? 0.0;
            final low = double.tryParse(k[3].toString()) ?? 0.0;
            final close = double.tryParse(k[4].toString()) ?? 0.0;
            final volume = double.tryParse(k[5].toString()) ?? 0.0;
            return Candle(
                time: time,
                open: open,
                high: high,
                low: low,
                close: close,
                volume: volume);
          })
          .where((c) => c != null && c.close > 0)
          .cast<Candle>()
          .toList();
    } catch (e) {
      _log.w('OKX failed for $symbol', e);
      return const [];
    }
  }

  // ── Range config ────────────────────────────────────────────────────────────

  static _KlineConfig _rangeConfig(String rangeKey) {
    switch (rangeKey) {
      case '1m':
        return const _KlineConfig(
          binanceInterval: '1m',
          mexcInterval: '1m',
          gateioInterval: '1m',
          okxInterval: '1m',
          limit: 60,
        );
      case '5m':
        return const _KlineConfig(
          binanceInterval: '5m',
          mexcInterval: '5m',
          gateioInterval: '5m',
          okxInterval: '5m',
          limit: 60,
        );
      case '15m':
        return const _KlineConfig(
          binanceInterval: '15m',
          mexcInterval: '15m',
          gateioInterval: '15m',
          okxInterval: '15m',
          limit: 96,
        );
      case '30m':
        return const _KlineConfig(
          binanceInterval: '30m',
          mexcInterval: '30m',
          gateioInterval: '30m',
          okxInterval: '30m',
          limit: 96,
        );
      case '1h':
        return const _KlineConfig(
          binanceInterval: '1h',
          mexcInterval: '60m',
          gateioInterval: '1h',
          okxInterval: '1H',
          limit: 72,
        );
      case '24h':
      case '24H':
        return const _KlineConfig(
          binanceInterval: '15m',
          mexcInterval: '15m',
          gateioInterval: '15m',
          okxInterval: '15m',
          limit: 96,
        );
      case '7d':
      case '7D':
        return const _KlineConfig(
          binanceInterval: '1h',
          mexcInterval: '60m',
          gateioInterval: '1h',
          okxInterval: '1H',
          limit: 168,
        );
      case '1mth':
      case '1M':
        return const _KlineConfig(
          binanceInterval: '4h',
          mexcInterval: '4h',
          gateioInterval: '4h',
          okxInterval: '4H',
          limit: 180,
        );
      case '3mth':
      case '3M':
        return const _KlineConfig(
          binanceInterval: '1d',
          mexcInterval: '1d',
          gateioInterval: '1d',
          okxInterval: '1D',
          limit: 90,
        );
      default:
        return const _KlineConfig(
          binanceInterval: '1h',
          mexcInterval: '60m',
          gateioInterval: '1h',
          okxInterval: '1H',
          limit: 168,
        );
    }
  }
}

class _KlineConfig {
  final String binanceInterval;
  final String mexcInterval;
  final String gateioInterval;
  final String okxInterval;
  final int limit;

  const _KlineConfig({
    required this.binanceInterval,
    required this.mexcInterval,
    required this.gateioInterval,
    required this.okxInterval,
    required this.limit,
  });
}

class _CachedChart {
  final List<Candle> candles;
  final DateTime at;
  _CachedChart(this.candles, this.at);
}
