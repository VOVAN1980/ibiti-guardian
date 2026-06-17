// ─── Candle Snapshot ────────────────────────────────────────────────────────────
//
// Structured candle data package for Brain/TA consumption.
// Contains multi-timeframe candles with freshness/source metadata.
//
// Phase 7: starts with 5m. Structure ready for 1m/15m/1h extension.
// ─────────────────────────────────────────────────────────────────────────────────

import 'candle.dart';

class CandleSnapshot {
  /// 1-minute candles (momentum/entry confirmation).
  final List<Candle> candles1m;

  /// 5-minute candles (primary timeframe for Phase 8 TA).
  final List<Candle> candles5m;

  /// 15-minute candles (optional, may be empty).
  final List<Candle> candles15m;

  /// 1-hour candles (optional, may be empty).
  final List<Candle> candles1h;

  /// True if candles were fetched fresh this tick (not stale cache).
  final bool isFresh;

  /// True if candles came from a fallback exchange (not the event's exchange).
  final bool isFallback;

  /// Exchange that provided the candles.
  final String sourceExchange;

  /// Optional warning (e.g. "stale data", "low candle count").
  final String? warning;

  const CandleSnapshot({
    this.candles1m = const [],
    this.candles5m = const [],
    this.candles15m = const [],
    this.candles1h = const [],
    this.isFresh = false,
    this.isFallback = false,
    this.sourceExchange = '',
    this.warning,
  });

  /// Empty snapshot — no candles available.
  static const empty = CandleSnapshot();

  /// True if we have at least 20 candles on the primary timeframe (5m).
  bool get hasEnoughData => candles5m.length >= 20;

  /// True if snapshot has any usable candle data.
  bool get isNotEmpty => candles5m.isNotEmpty;

  /// True if snapshot is completely empty.
  bool get isEmpty => candles5m.isEmpty;

  @override
  String toString() =>
      'CandleSnapshot(1m=${candles1m.length} 5m=${candles5m.length} 15m=${candles15m.length} '
      '1h=${candles1h.length} fresh=$isFresh '
      'fallback=$isFallback src=$sourceExchange'
      '${warning != null ? ' ⚠$warning' : ''})';
}
