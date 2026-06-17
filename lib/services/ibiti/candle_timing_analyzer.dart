// ── Candle Timing Analyzer ───────────────────────────────────────────────────
//
// Phase 17F-B: Flow-First Candle Timing.
//
// Candles no longer decide direction. Flow decides direction.
// Candles now only provide TIMING intelligence:
//
//   Red candle + strong inflow = DIP ENTRY (buy the fear)
//   Green candle + weak flow = OVERHEATED (don't chase)
//   Green candle + accelerating flow = MOMENTUM CONFIRM
//   Red candle + retail noise/outflow = DISTRIBUTION EXIT RISK
//
// Output: CandleTimingSignal with:
//   - role (what the candle pattern means for timing)
//   - timingMod (-0.15 to +0.15, added to EQ)
//   - reason (human-readable explanation)
//
// flowMod ALWAYS dominates candleTimingMod.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:ibiti_guardian/services/ibiti/models/candle_snapshot.dart';
import 'package:ibiti_guardian/services/ibiti/models/market_event.dart';
import 'package:ibiti_guardian/services/ibiti/models/strategy_context.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

const _log = GuardianLogger('CandleTiming');

/// What role does the current candle pattern play in timing?
enum CandleTimingRole {
  /// Red candle + strong inflow = buy the dip. Flow says money coming in.
  dipEntry,

  /// Green candle + accelerating flow = ride the momentum.
  momentumConfirm,

  /// Green candle + weak/no flow = overheated. Don't chase.
  overheatedWait,

  /// Red candle + outflow/retail noise = distribution. Exit risk.
  distributionExitRisk,

  /// Candle doesn't give strong timing signal.
  neutralTiming,

  /// No candle data available.
  noData;

  String get label => switch (this) {
        dipEntry => 'DIP_ENTRY',
        momentumConfirm => 'MOMENTUM_CONFIRM',
        overheatedWait => 'OVERHEATED_WAIT',
        distributionExitRisk => 'DISTRIBUTION_EXIT',
        neutralTiming => 'NEUTRAL',
        noData => 'NO_DATA',
      };
}

/// Output of candle timing analysis.
class CandleTimingSignal {
  final CandleTimingRole role;

  /// EQ modifier from candle timing (-0.15 to +0.15).
  /// This is ALWAYS smaller than flowMod to ensure flow dominates.
  final double timingMod;

  /// Human-readable reason.
  final String reason;

  const CandleTimingSignal({
    required this.role,
    required this.timingMod,
    required this.reason,
  });

  /// No-data signal.
  static const noData = CandleTimingSignal(
    role: CandleTimingRole.noData,
    timingMod: 0.0,
    reason: 'no_candle_data',
  );

  String toLogLine() => '${role.label} mod=${timingMod >= 0 ? '+' : ''}'
      '${timingMod.toStringAsFixed(2)} reason=$reason';
}

/// Phase 17F-B: Analyzes candle patterns for TIMING only.
/// Flow decides direction. Candles decide WHEN to enter.
class CandleTimingAnalyzer {
  CandleTimingAnalyzer._();
  static final CandleTimingAnalyzer instance = CandleTimingAnalyzer._();

  /// Analyze candle timing in context of flow.
  CandleTimingSignal analyze({
    required MarketEvent event,
    required CandleSnapshot candles,
    required String flowClass,
    required double volumeFlowScore,
    StrategyContext? strategyContext,
  }) {
    if (candles.isEmpty) return CandleTimingSignal.noData;

    final recent5m = candles.candles5m;
    if (recent5m.length < 3) return CandleTimingSignal.noData;

    // Get last 3 candles for pattern analysis.
    final last = recent5m.last;
    final prev = recent5m[recent5m.length - 2];
    final prev2 = recent5m[recent5m.length - 3];

    final lastRed = last.isBearish;
    final lastGreen = last.isBullish;
    final strongFlow =
        flowClass == 'seriousInflow' || flowClass == 'whaleInflow';
    final weakFlow = flowClass == 'retailNoise' || flowClass.isEmpty;
    final moderateFlow = flowClass == 'retailInterest';

    // Volume acceleration: is the last candle's volume above average?
    final avgVol = recent5m.length >= 5
        ? recent5m
                .sublist(recent5m.length - 5)
                .fold<double>(0, (s, c) => s + c.volume) /
            5
        : last.volume;
    final volAccelerating = last.volume > avgVol * 1.3;

    // Consecutive pattern: how many of the last 3 are same direction?
    final consecutiveRed = [last, prev, prev2].where((c) => c.isBearish).length;
    final consecutiveGreen =
        [last, prev, prev2].where((c) => c.isBullish).length;

    // Wick analysis: long lower wick = buyers stepping in.
    final lowerWick = last.open > last.close
        ? last.close - last.low // bearish: wick below close
        : last.open - last.low; // bullish: wick below open
    final hasLongLowerWick = last.range > 0 && lowerWick / last.range > 0.5;

    // ── Decision Matrix ──

    // 1. RED CANDLE + STRONG FLOW = DIP ENTRY
    if (lastRed && strongFlow) {
      final mod = hasLongLowerWick ? 0.12 : 0.08;
      final wickNote =
          hasLongLowerWick ? ' + long_lower_wick(buyer_absorption)' : '';
      _log.d('[CANDLE_TIMING] ${event.symbol} DIP_ENTRY: '
          'red candle + $flowClass$wickNote');
      return CandleTimingSignal(
        role: CandleTimingRole.dipEntry,
        timingMod: mod,
        reason: 'red_candle+${flowClass}_inflow$wickNote',
      );
    }

    // 2. GREEN CANDLE + ACCELERATING FLOW = MOMENTUM CONFIRM
    if (lastGreen && (strongFlow || moderateFlow) && volAccelerating) {
      _log.d('[CANDLE_TIMING] ${event.symbol} MOMENTUM_CONFIRM: '
          'green + $flowClass + vol_accelerating');
      return const CandleTimingSignal(
        role: CandleTimingRole.momentumConfirm,
        timingMod: 0.10,
        reason: 'green_candle+flow+vol_accelerating',
      );
    }

    // 3. GREEN CANDLE + WEAK FLOW = OVERHEATED / DON'T CHASE
    if (lastGreen && weakFlow && consecutiveGreen >= 2) {
      _log.d('[CANDLE_TIMING] ${event.symbol} OVERHEATED_WAIT: '
          'consecutive green + weak flow');
      return const CandleTimingSignal(
        role: CandleTimingRole.overheatedWait,
        timingMod: -0.10,
        reason: 'consecutive_green+weak_flow_dont_chase',
      );
    }

    // 4. RED CANDLE + WEAK FLOW / OUTFLOW = DISTRIBUTION EXIT RISK
    if (lastRed && weakFlow && consecutiveRed >= 2) {
      _log.d('[CANDLE_TIMING] ${event.symbol} DISTRIBUTION_EXIT: '
          'consecutive red + weak/no flow');
      return const CandleTimingSignal(
        role: CandleTimingRole.distributionExitRisk,
        timingMod: -0.15,
        reason: 'consecutive_red+weak_flow_distribution',
      );
    }

    // 5. Single red + weak flow = mild caution
    if (lastRed && weakFlow) {
      return const CandleTimingSignal(
        role: CandleTimingRole.distributionExitRisk,
        timingMod: -0.08,
        reason: 'red_candle+weak_flow',
      );
    }

    // 6. Single green + no strong flow = mild overheated
    if (lastGreen && weakFlow) {
      return const CandleTimingSignal(
        role: CandleTimingRole.overheatedWait,
        timingMod: -0.05,
        reason: 'green_candle+weak_flow',
      );
    }

    // 7. Green + moderate flow = neutral-positive
    if (lastGreen && moderateFlow) {
      return const CandleTimingSignal(
        role: CandleTimingRole.momentumConfirm,
        timingMod: 0.05,
        reason: 'green+moderate_flow',
      );
    }

    // 8. Red + moderate flow = mild dip opportunity
    if (lastRed && moderateFlow) {
      return const CandleTimingSignal(
        role: CandleTimingRole.dipEntry,
        timingMod: 0.03,
        reason: 'red_dip+moderate_flow',
      );
    }

    // Default: neutral timing.
    return const CandleTimingSignal(
      role: CandleTimingRole.neutralTiming,
      timingMod: 0.0,
      reason: 'neutral',
    );
  }
}
