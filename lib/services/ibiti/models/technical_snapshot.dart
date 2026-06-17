// ─── Technical Snapshot ────────────────────────────────────────────────────────
//
// Structured output from the Technical Analysis layer.
// Consumed by IbitiBrain to adjust hypothesis scoring.
// ─────────────────────────────────────────────────────────────────────────────────

import 'trend_direction.dart';
import 'entry_timing.dart';

class TechnicalSnapshot {
  final bool hasData;

  // ── Indicators ──
  final double? rsi14;
  final double? ema9;
  final double? ema21;
  final double? ema50;
  final double? atr14;
  final double? atrPercent;
  final double? volumeRatio;
  final double? candleBodyRatio;

  // ── Interpretations ──
  final TrendDirection trend; // primary (usually 5m)
  final TrendDirection trend1m;
  final TrendDirection trend5m;
  final TrendDirection trend15m;
  final TrendDirection trend1h;
  final EntryTiming entryTiming;

  // ── MTF Alignment ──
  final double timeframeAgreementScore;
  final bool isMultiTimeframeAligned;
  final bool isCounterTrend;

  // ── Modifiers for Brain ──
  final double technicalBullScore;
  final double technicalBearScore;
  final double technicalRiskScore;
  final double technicalExecutionScore;

  // ── Trade Plan Estimates ──
  final double? suggestedStopLossPercent;
  final double? suggestedTakeProfitPercent;
  final double? estimatedRiskReward;

  // ── Logs / Reasoning ──
  final List<String> warnings;

  const TechnicalSnapshot({
    required this.hasData,
    this.rsi14,
    this.ema9,
    this.ema21,
    this.ema50,
    this.atr14,
    this.atrPercent,
    this.volumeRatio,
    this.candleBodyRatio,
    this.trend = TrendDirection.unknown,
    this.trend1m = TrendDirection.unknown,
    this.trend5m = TrendDirection.unknown,
    this.trend15m = TrendDirection.unknown,
    this.trend1h = TrendDirection.unknown,
    this.entryTiming = EntryTiming.unknown,
    this.timeframeAgreementScore = 0.0,
    this.isMultiTimeframeAligned = false,
    this.isCounterTrend = false,
    this.technicalBullScore = 0.0,
    this.technicalBearScore = 0.0,
    this.technicalRiskScore = 0.0,
    this.technicalExecutionScore = 0.0,
    this.suggestedStopLossPercent,
    this.suggestedTakeProfitPercent,
    this.estimatedRiskReward,
    this.warnings = const [],
  });

  static const empty = TechnicalSnapshot(hasData: false);

  @override
  String toString() {
    if (!hasData) return 'TechnicalSnapshot(empty)';
    return 'TechnicalSnapshot(trend=$trend entry=$entryTiming '
        'rsi=${rsi14?.toStringAsFixed(1)} '
        'volRatio=${volumeRatio?.toStringAsFixed(1)} '
        'R:R=${estimatedRiskReward?.toStringAsFixed(1)})';
  }
}
