import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/ibiti/ibiti_technical_analysis.dart';
import 'package:ibiti_guardian/services/ibiti/models/candle.dart';
import 'package:ibiti_guardian/services/ibiti/models/candle_snapshot.dart';
import 'package:ibiti_guardian/services/ibiti/models/trend_direction.dart';
import 'package:ibiti_guardian/services/ibiti/models/entry_timing.dart';

void main() {
  group('IbitiTechnicalAnalysis', () {
    final ta = IbitiTechnicalAnalysis.instance;

    List<Candle> generateCandles(int count, double startPrice, double step) {
      return List.generate(count, (i) {
        final price = startPrice + (i * step);
        return Candle(
          openTime: i * 60000,
          open: price - step,
          high: price + 1,
          low: price - 1,
          close: price,
          volume: 1000,
        );
      });
    }

    test('analyze handles empty snapshot', () {
      final snap = CandleSnapshot.empty;
      final result = ta.analyze(snap);
      expect(result.hasData, false);
      expect(result.warnings, isEmpty);
    });

    test('analyze handles insufficient data', () {
      final snap = CandleSnapshot(
        candles5m: generateCandles(10, 100, 1),
        isFresh: true,
      );
      final result = ta.analyze(snap);
      expect(result.hasData, false); // needs 50 for EMA50
    });

    test('RSI calculation', () {
      // 14 periods of gains
      final bullCandles = generateCandles(30, 100, 1); // constantly going up
      final rsiBull = ta.rsi(bullCandles, 14);
      expect(rsiBull, 100.0); // all gains -> RSI 100

      final bearCandles = generateCandles(30, 100, -1); // constantly going down
      final rsiBear = ta.rsi(bearCandles, 14);
      expect(rsiBear, 0.0); // all losses -> RSI 0

      final flatCandles = generateCandles(30, 100, 0); // zero movement
      final rsiFlat = ta.rsi(flatCandles, 14);
      expect(rsiFlat, 50.0); // no gain, no loss -> RSI 50
    });

    test('EMA calculation', () {
      final candles = generateCandles(30, 100, 0); // flat price at 100
      final ema = ta.ema(candles, 14);
      expect(ema, 100.0);
    });

    test('ATR calculation', () {
      final candles =
          generateCandles(20, 100, 0); // Flat price, High=101, Low=99
      // True range for flat price with high/low +/- 1 is 2.0
      final atr = ta.atr(candles, 14);
      expect(atr, closeTo(2.0, 0.1));
    });

    test('volumeRatio calculation', () {
      final candles = generateCandles(30, 100, 1);
      final vol = ta.volumeRatio(candles, 20);
      expect(vol, 1.0); // Volume is constant 1000
    });

    test(
        'detectTrend identifies bullish, bearish, sideways, volatile, exhaustion',
        () {
      expect(ta.detectTrend(30, 20, 10, null, null, null, null),
          TrendDirection.bullish);
      expect(ta.detectTrend(10, 20, 30, null, null, null, null),
          TrendDirection.bearish);
      expect(ta.detectTrend(20, 30, 10, null, null, null, null),
          TrendDirection.sideways);
      expect(ta.detectTrend(null, 20, 10, null, null, null, null),
          TrendDirection.unknown);

      // Exhaustion
      final hugeCandle = Candle(
          openTime: 0, open: 100, high: 105, low: 99, close: 104, volume: 1000);
      expect(ta.detectTrend(30, 20, 10, 85, 4.0, null, hugeCandle),
          TrendDirection.exhaustion);

      // Volatile
      expect(ta.detectTrend(20, 30, 10, null, null, 3.0, null),
          TrendDirection.volatile);
    });

    test('detectEntryTiming identifies conditions properly', () {
      final normalCandle = Candle(
          openTime: 0,
          open: 100,
          high: 101,
          low: 99,
          close: 100.5,
          volume: 100);

      // Dangerous: RSI > 80
      expect(
        ta.detectEntryTiming(
            TrendDirection.bullish, 85, 1.0, 1.0, normalCandle),
        EntryTiming.dangerous,
      );

      // Dangerous: Huge candle after pump (RSI > 70 + > 3% move + large body)
      final hugeCandle = Candle(
          openTime: 0,
          open: 100,
          high: 105,
          low: 99,
          close: 104.5,
          volume: 100);
      expect(
        ta.detectEntryTiming(TrendDirection.bullish, 75, 1.0, 1.0, hugeCandle),
        EntryTiming.dangerous,
      );

      // Late: RSI > 70
      expect(
        ta.detectEntryTiming(
            TrendDirection.bullish, 75, 1.0, 1.0, normalCandle),
        EntryTiming.late,
      );

      // Early: Trend Bullish, RSI < 50, Vol > 1.5
      expect(
        ta.detectEntryTiming(
            TrendDirection.bullish, 40, 2.0, 1.0, normalCandle),
        EntryTiming.early,
      );

      // Normal: Trend Bullish, RSI 45-65
      expect(
        ta.detectEntryTiming(
            TrendDirection.bullish, 50, 1.0, 1.0, normalCandle),
        EntryTiming.normal,
      );
    });

    test('analyze generates full TechnicalSnapshot correctly with S/R and MTF',
        () {
      final candles = generateCandles(60, 100, 0.5); // Slow uptrend
      final snap = CandleSnapshot(
        candles1m: generateCandles(60, 100, 0.5),
        candles5m: candles,
        candles15m: generateCandles(60, 100, 0.5),
        candles1h: generateCandles(60, 100, -0.5), // 1h is counter-trend
        isFresh: true,
      );

      final result = ta.analyze(snap);

      expect(result.hasData, true);
      expect(result.trend, TrendDirection.bullish);
      expect(result.trend1m, TrendDirection.bullish);
      expect(result.trend15m, TrendDirection.bullish);
      expect(result.trend1h, TrendDirection.bearish);

      expect(result.isMultiTimeframeAligned, true); // 1m, 5m, 15m align
      expect(result.isCounterTrend, true); // 5m is bull, 1h is bear

      expect(result.rsi14, 100.0); // Constant gains -> 100 RSI
      expect(
          result.entryTiming, EntryTiming.dangerous); // RSI > 80 -> dangerous

      // Technical scores logic:
      // Trend=Bullish (+0.1 bull)
      // RSI=100 (+0.25 risk)
      // Timing=Dangerous (+0.3 risk)
      // CounterTrend (+0.10 risk)
      // R:R is enforced to 1.5, so R:R < 1.5 penalty is not applied.
      // Total risk: 0.65
      expect(result.technicalBullScore, 0.10);
      expect(result.technicalRiskScore, closeTo(0.65, 0.01));

      // MTF aligned (1m, 15m match 5m) -> exec += 0.05
      // R:R is enforced to 1.5, so R:R < 1.5 penalty is not applied.
      // Total exec: 0.15
      expect(result.technicalExecutionScore, closeTo(0.15, 0.01));

      expect(result.estimatedRiskReward, isNotNull);
      expect(result.warnings, isNotEmpty);
      expect(result.warnings.any((w) => w.contains('RSI 100.0: exhaustion')),
          true);
      expect(
          result.warnings.any((w) => w.contains('Counter-trend risk')), true);
    });
  });
}
