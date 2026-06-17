// ─── Technical Analysis Service ────────────────────────────────────────────────
//
// Calculates technical indicators (RSI, EMA, ATR) and interprets market structure
// (Trend, Entry Timing) from a CandleSnapshot.
// ─────────────────────────────────────────────────────────────────────────────────

import 'dart:math';

import 'package:ibiti_guardian/services/ibiti/models/candle.dart';
import 'package:ibiti_guardian/services/ibiti/models/candle_snapshot.dart';
import 'package:ibiti_guardian/services/ibiti/models/trend_direction.dart';
import 'package:ibiti_guardian/services/ibiti/models/entry_timing.dart';
import 'package:ibiti_guardian/services/ibiti/models/technical_snapshot.dart';

class IbitiTechnicalAnalysis {
  IbitiTechnicalAnalysis._();
  static final IbitiTechnicalAnalysis instance = IbitiTechnicalAnalysis._();

  /// Analyzes the candle snapshot and produces a TechnicalSnapshot.
  /// Does not crash on missing/empty candles.
  TechnicalSnapshot analyze(CandleSnapshot snapshot) {
    if (!snapshot.hasEnoughData) {
      return TechnicalSnapshot.empty;
    }

    final candles = snapshot.candles5m;
    if (candles.length < 50) {
      // Need at least 50 candles for EMA50
      return TechnicalSnapshot.empty;
    }

    final currentCandle = candles.last;
    final closePrice = currentCandle.close;

    // ── Indicators ──
    final rsi14 = rsi(candles, 14);
    final ema9 = ema(candles, 9);
    final ema21 = ema(candles, 21);
    final ema50 = ema(candles, 50);
    final atr14 = atr(candles, 14);

    final atrPct =
        atr14 != null && closePrice > 0 ? (atr14 / closePrice) * 100 : null;

    final volRatio = volumeRatio(candles, 20);
    final bodyRatio = candleBodyRatio(currentCandle);

    // ── Interpretations ──
    final trend =
        detectTrend(ema9, ema21, ema50, rsi14, volRatio, atrPct, currentCandle);
    final timing =
        detectEntryTiming(trend, rsi14, volRatio, atrPct, currentCandle);

    // ── MTF Trends ──
    final trend1m = _detectTrendForCandles(snapshot.candles1m);
    final trend15m = _detectTrendForCandles(snapshot.candles15m);
    final trend1h = _detectTrendForCandles(snapshot.candles1h);

    int alignedCount = 0;
    if (trend1m == trend && trend1m != TrendDirection.unknown) alignedCount++;
    if (trend15m == trend && trend15m != TrendDirection.unknown) alignedCount++;
    if (trend1h == trend && trend1h != TrendDirection.unknown) alignedCount++;

    final isMultiTimeframeAligned = alignedCount >= 2;
    final isCounterTrend = trend1h != TrendDirection.unknown &&
        trend1h != TrendDirection.sideways &&
        trend != TrendDirection.unknown &&
        trend != trend1h;
    final timeframeAgreementScore = alignedCount / 3.0;

    // ── Trade Plan (ATR-based) ──
    // Primary: ATR-proportional targets.
    // TP = ATR × 2.0, SL = ATR × 1.0
    // S/R levels used as secondary cap (don't set TP above resistance).
    final effectiveAtr = atr14 ?? closePrice * 0.015; // 1.5% fallback

    // ATR-based distances.
    double tpDist = effectiveAtr * 2.0;
    double slDist = effectiveAtr * 1.0;

    // S/R refinement: if resistance is closer than ATR×2, cap TP there
    // (but minimum ATR×1.2 to keep it profitable).
    final resistance = getRecentSwingHigh(candles, 20);
    final support = getRecentSwingLow(candles, 20);

    final distToResistance = resistance - closePrice;
    if (distToResistance > 0 &&
        distToResistance < tpDist &&
        distToResistance > effectiveAtr * 1.2) {
      tpDist = distToResistance;
    }

    final distToSupport = closePrice - support;
    if (distToSupport > 0 &&
        distToSupport < slDist &&
        distToSupport > effectiveAtr * 0.5) {
      slDist = distToSupport;
    }

    // Enforce minimum R:R of 1.5.
    if (slDist > 0 && tpDist / slDist < 1.5) {
      slDist = tpDist / 1.5;
    }

    final slPercent = (slDist / closePrice) * 100;
    final tpPercent = (tpDist / closePrice) * 100;
    final riskReward = slDist > 0 ? tpDist / slDist : 2.0;

    // ── Brain Scores ──
    final scores = buildScores(
      trend,
      timing,
      rsi14,
      volRatio,
      atrPct,
      riskReward,
      isCounterTrend: isCounterTrend,
      isMultiTimeframeAligned: isMultiTimeframeAligned,
    );

    // ── Human Reasoning / Logs ──
    final warnings = <String>[];
    if (rsi14 != null) {
      if (rsi14 == 50.0 && volRatio == 0.0) {
        warnings.add('RSI flat (no volume)');
      } else if (rsi14 > 80) {
        warnings.add('RSI ${rsi14.toStringAsFixed(1)}: exhaustion, dangerous');
      } else if (rsi14 > 70) {
        warnings.add(
            'RSI ${rsi14.toStringAsFixed(1)}: overbought, late entry risk');
      } else if (rsi14 < 30) {
        warnings.add('RSI ${rsi14.toStringAsFixed(1)}: oversold');
      }
    }
    warnings.add('Trend 5m: ${trend.name}');
    if (trend1h != TrendDirection.unknown)
      warnings.add('Trend 1h: ${trend1h.name}');
    if (isMultiTimeframeAligned) warnings.add('MTF Aligned');
    if (isCounterTrend) warnings.add('Counter-trend risk');

    if (atrPct != null && atrPct > 2.0) {
      warnings
          .add('ATR high (${atrPct.toStringAsFixed(1)}%): wider stop needed');
    }
    if (volRatio != null && volRatio > 2.0) {
      warnings.add('Volume ${volRatio.toStringAsFixed(1)}x: real interest');
    }
    warnings.add('Entry timing: ${timing.name}');

    warnings.add('R:R ${riskReward.toStringAsFixed(1)} (from S/R)');
    if (riskReward < 1.5) {
      warnings.add('Execution penalized: bad R:R');
    } else if (riskReward >= 2.0) {
      warnings.add('Execution improved: good R:R');
    }

    return TechnicalSnapshot(
      hasData: true,
      rsi14: rsi14,
      ema9: ema9,
      ema21: ema21,
      ema50: ema50,
      atr14: atr14,
      atrPercent: atrPct,
      volumeRatio: volRatio,
      candleBodyRatio: bodyRatio,
      trend: trend,
      trend1m: trend1m,
      trend5m: trend, // since trend is 5m
      trend15m: trend15m,
      trend1h: trend1h,
      entryTiming: timing,
      timeframeAgreementScore: timeframeAgreementScore,
      isMultiTimeframeAligned: isMultiTimeframeAligned,
      isCounterTrend: isCounterTrend,
      technicalBullScore: scores['bull'] ?? 0.0,
      technicalBearScore: scores['bear'] ?? 0.0,
      technicalRiskScore: scores['risk'] ?? 0.0,
      technicalExecutionScore: scores['exec'] ?? 0.0,
      suggestedStopLossPercent: slPercent,
      suggestedTakeProfitPercent: tpPercent,
      estimatedRiskReward: riskReward,
      warnings: warnings,
    );
  }

  // ── RSI (Relative Strength Index) ──
  // Uses Wilder's Smoothing Method
  double? rsi(List<Candle> candles, int period) {
    if (candles.length <= period) return null;

    double sumGain = 0;
    double sumLoss = 0;

    for (int i = 1; i <= period; i++) {
      final change = candles[i].close - candles[i - 1].close;
      if (change > 0) {
        sumGain += change;
      } else {
        sumLoss -= change; // positive loss
      }
    }

    double avgGain = sumGain / period;
    double avgLoss = sumLoss / period;

    for (int i = period + 1; i < candles.length; i++) {
      final change = candles[i].close - candles[i - 1].close;
      double gain = 0;
      double loss = 0;

      if (change > 0) {
        gain = change;
      } else {
        loss = -change;
      }

      avgGain = (avgGain * (period - 1) + gain) / period;
      avgLoss = (avgLoss * (period - 1) + loss) / period;
    }

    if (avgLoss == 0 && avgGain == 0) return 50.0;
    if (avgLoss == 0) return 100.0;
    if (avgGain == 0) return 0.0;
    final rs = avgGain / avgLoss;
    return 100.0 - (100.0 / (1.0 + rs));
  }

  // ── EMA (Exponential Moving Average) ──
  double? ema(List<Candle> candles, int period) {
    if (candles.length < period) return null;

    final multiplier = 2.0 / (period + 1);

    // SMA for the first 'period' to initialize
    double sum = 0;
    for (int i = 0; i < period; i++) {
      sum += candles[i].close;
    }
    double ema = sum / period;

    for (int i = period; i < candles.length; i++) {
      ema = (candles[i].close - ema) * multiplier + ema;
    }

    return ema;
  }

  // ── ATR (Average True Range) ──
  // Uses Wilder's Smoothing Method
  double? atr(List<Candle> candles, int period) {
    if (candles.length <= period) return null;

    final trueRanges = <double>[];
    // TR calculation starts from index 1 (needs previous close)
    for (int i = 1; i < candles.length; i++) {
      final current = candles[i];
      final prev = candles[i - 1];

      final tr1 = current.high - current.low;
      final tr2 = (current.high - prev.close).abs();
      final tr3 = (current.low - prev.close).abs();

      trueRanges.add(max(tr1, max(tr2, tr3)));
    }

    if (trueRanges.length < period) return null;

    double atr = 0;
    for (int i = 0; i < period; i++) {
      atr += trueRanges[i];
    }
    atr /= period;

    for (int i = period; i < trueRanges.length; i++) {
      atr = (atr * (period - 1) + trueRanges[i]) / period;
    }

    return atr;
  }

  // ── Volume Ratio ──
  double? volumeRatio(List<Candle> candles, int lookback) {
    if (candles.length < lookback + 1) return null;

    final currentVol = candles.last.volume;
    if (currentVol <= 0) return 0;

    double sumVol = 0;
    for (int i = candles.length - 1 - lookback; i < candles.length - 1; i++) {
      sumVol += candles[i].volume;
    }

    final avgVol = sumVol / lookback;
    if (avgVol <= 0) return currentVol > 0 ? 99.0 : 0.0;

    return currentVol / avgVol;
  }

  // ── Candle Body Ratio ──
  double candleBodyRatio(Candle candle) {
    final range = candle.range;
    if (range <= 0) return 0;
    return candle.body / range;
  }

  // ── Interpretations ──

  TrendDirection _detectTrendForCandles(List<Candle> candles) {
    if (candles.length < 50) return TrendDirection.unknown;
    return detectTrend(ema(candles, 9), ema(candles, 21), ema(candles, 50),
        null, null, null, null // MTF trends just use EMA for now
        );
  }

  TrendDirection detectTrend(double? ema9, double? ema21, double? ema50,
      double? rsi, double? volRatio, double? atrPct, Candle? candle) {
    if (ema9 == null || ema21 == null || ema50 == null) {
      return TrendDirection.unknown;
    }

    if (rsi != null &&
        rsi > 80 &&
        volRatio != null &&
        volRatio > 3.0 &&
        candle != null &&
        candleBodyRatio(candle) > 0.5) {
      return TrendDirection.exhaustion;
    }

    bool isUnclear =
        !(ema9 > ema21 && ema21 > ema50) && !(ema9 < ema21 && ema21 < ema50);
    if (isUnclear && atrPct != null && atrPct > 2.5) {
      return TrendDirection.volatile;
    }

    if (ema9 > ema21 && ema21 > ema50) {
      return TrendDirection.bullish;
    } else if (ema9 < ema21 && ema21 < ema50) {
      return TrendDirection.bearish;
    } else {
      return TrendDirection.sideways;
    }
  }

  EntryTiming detectEntryTiming(TrendDirection trend, double? rsi,
      double? volRatio, double? atrPct, Candle candle) {
    if (rsi == null) return EntryTiming.unknown;

    final bodyRatio = candleBodyRatio(candle);
    final isHugeMove = candle.changePercent.abs() > 3.0;
    final isHugeBodyAfterPump = isHugeMove && rsi > 70 && bodyRatio > 0.7;
    final isLongWickRejection =
        bodyRatio < 0.3 && (candle.changePercent.abs() > 1.0);
    final isIndecisionVolume =
        bodyRatio < 0.3 && volRatio != null && volRatio > 2.0;

    // Dangerous
    if (rsi > 80 ||
        isHugeBodyAfterPump ||
        isLongWickRejection ||
        (atrPct != null && atrPct > 3.0)) {
      return EntryTiming.dangerous;
    }

    // Late
    if (rsi > 70 || (volRatio != null && volRatio > 6.0)) {
      return EntryTiming.late;
    }

    // Indecision warning (often leads to late/danger if bought early)
    if (isIndecisionVolume) {
      return EntryTiming
          .dangerous; // or late? Let's say dangerous for distribution risk
    }

    // Early
    if (trend == TrendDirection.bullish &&
        rsi < 50 &&
        (volRatio != null && volRatio > 1.5)) {
      return EntryTiming.early;
    }
    if (trend == TrendDirection.sideways && rsi < 40) {
      return EntryTiming.early;
    }

    // Normal
    if (trend == TrendDirection.bullish && rsi >= 45 && rsi <= 65) {
      return EntryTiming.normal;
    }

    return EntryTiming.unknown;
  }

  // ── Support / Resistance ──
  double getRecentSwingHigh(List<Candle> candles, int lookback) {
    if (candles.isEmpty) return 0.0;
    final start = max(0, candles.length - lookback);
    double highest = candles[start].high;
    for (int i = start + 1; i < candles.length; i++) {
      if (candles[i].high > highest) highest = candles[i].high;
    }
    return highest;
  }

  double getRecentSwingLow(List<Candle> candles, int lookback) {
    if (candles.isEmpty) return 0.0;
    final start = max(0, candles.length - lookback);
    double lowest = candles[start].low;
    for (int i = start + 1; i < candles.length; i++) {
      if (candles[i].low < lowest) lowest = candles[i].low;
    }
    return lowest;
  }

  Map<String, double> buildScores(
    TrendDirection trend,
    EntryTiming timing,
    double? rsi,
    double? volRatio,
    double? atrPct,
    double? rr, {
    bool isCounterTrend = false,
    bool isMultiTimeframeAligned = false,
  }) {
    double bull = 0.0;
    double bear = 0.0;
    double risk = 0.0;
    double exec = 0.0;

    // Trend
    if (trend == TrendDirection.bullish) {
      bull += 0.10;
    }
    if (trend == TrendDirection.bearish) {
      bear += 0.15;
    }

    // RSI
    if (rsi != null) {
      if (rsi > 80) {
        risk += 0.25;
      } else if (rsi > 70) {
        risk += 0.15;
      }

      if (rsi < 30 && trend != TrendDirection.bearish) {
        bull += 0.10;
      }
    }

    // Volume
    if (volRatio != null) {
      if (volRatio > 3.0 && trend == TrendDirection.bullish) {
        bull += 0.10;
      }
      if (volRatio > 6.0 && rsi != null && rsi > 70) {
        risk += 0.15;
      }
    }

    // ATR
    if (atrPct != null && atrPct > 2.0) {
      risk += 0.10;
    }

    // Timing
    if (timing == EntryTiming.late) {
      risk += 0.15;
    }
    if (timing == EntryTiming.dangerous) {
      risk += 0.30;
    }

    // Multi-timeframe alignment
    if (isCounterTrend) {
      risk += 0.10;
    }
    if (isMultiTimeframeAligned) {
      exec += 0.05;
    }

    // R:R
    if (rr != null) {
      if (rr < 1.5) {
        exec -= 0.15;
        risk += 0.15;
      } else if (rr >= 2.0) {
        exec += 0.10;
      }
    }

    return {
      'bull': bull,
      'bear': bear,
      'risk': risk,
      'exec': exec,
    };
  }
}
