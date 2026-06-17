// ─── Candle Model ───────────────────────────────────────────────────────────────
//
// OHLCV candle for technical analysis. Immutable value object.
// Used by CandleHistoryService and IbitiTechnicalAnalysis.
// ─────────────────────────────────────────────────────────────────────────────────

class Candle {
  /// Candle open timestamp (ms since epoch).
  final int openTime;

  final double open;
  final double high;
  final double low;
  final double close;

  /// Exchange-reported volume. May be base or quote volume depending on
  /// the exchange. Do NOT assume USDT denomination.
  final double volume;

  // ── Phase 11A: Exact Exchange Flow Data ──
  final double? baseVolume;
  final double? quoteVolume;
  final double? takerBuyBaseVolume;
  final double? takerBuyQuoteVolume;
  final double? takerSellBaseVolume;
  final double? takerSellQuoteVolume;
  final double? buyPressure;

  const Candle({
    required this.openTime,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
    this.baseVolume,
    this.quoteVolume,
    this.takerBuyBaseVolume,
    this.takerBuyQuoteVolume,
    this.takerSellBaseVolume,
    this.takerSellQuoteVolume,
    this.buyPressure,
  });

  /// Candle body size (absolute).
  double get body => (close - open).abs();

  /// Full range (wick to wick).
  double get range => high - low;

  /// True if candle is bullish (close >= open).
  bool get isBullish => close >= open;

  /// True if candle is bearish (close < open).
  bool get isBearish => close < open;

  /// Percentage change from open to close.
  double get changePercent => open > 0 ? ((close - open) / open) * 100 : 0;

  /// Structural validity check.
  bool get isValid =>
      openTime > 0 && close > 0 && high >= low && high > 0 && low > 0;

  @override
  String toString() =>
      'Candle(${DateTime.fromMillisecondsSinceEpoch(openTime).toIso8601String()} '
      'O=$open H=$high L=$low C=$close V=${volume.toStringAsFixed(0)})';
}

/// Normalize and clean a raw candle list:
/// - Drop invalid candles (close <= 0, high < low, openTime <= 0)
/// - Remove duplicate openTime entries (keep last)
/// - Sort by openTime ascending
List<Candle> sanitizeCandles(List<Candle> raw) {
  if (raw.isEmpty) return const [];

  // Filter invalid.
  final valid = raw.where((c) => c.isValid).toList();
  if (valid.isEmpty) return const [];

  // Sort ascending by openTime.
  valid.sort((a, b) => a.openTime.compareTo(b.openTime));

  // Remove duplicate timestamps (keep last occurrence).
  final seen = <int>{};
  final deduped = <Candle>[];
  for (var i = valid.length - 1; i >= 0; i--) {
    if (seen.add(valid[i].openTime)) {
      deduped.add(valid[i]);
    }
  }
  deduped.sort((a, b) => a.openTime.compareTo(b.openTime));

  return deduped;
}
