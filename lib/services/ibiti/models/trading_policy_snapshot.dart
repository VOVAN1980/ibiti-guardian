// ─── Trading Policy Snapshot ────────────────────────────────────────────────
//
// JARVIS reads policy. JARVIS does not own policy.
//
// This is an IMMUTABLE snapshot of the current trading policy at a point in
// time. It is produced by TradingPolicyProvider and consumed by every layer
// that needs to know "am I allowed to trade / how much / when".
//
// PaperTrader keeps its own DailyBudget for paper accounting.
// When real trading activates, the execution pipeline MUST gate every
// action through PolicySnapshot — not through DailyBudget.
//
// Fields align with the App-level Policy / EPK that the user configures.
// ─────────────────────────────────────────────────────────────────────────────

/// Immutable point-in-time snapshot of the trading policy.
///
/// Created by [TradingPolicyProvider.currentSnapshot] and consumed
/// by JARVIS cognitive loop, debate engine, and (future) execution gate.
class TradingPolicySnapshot {
  // ── Gate ──────────────────────────────────────────────────────────────────

  /// Master switch. If false, no trades of any kind are allowed.
  final bool tradingAllowed;

  /// Human-readable reason why trading is blocked (if [tradingAllowed] false).
  /// Examples: "settlement_window", "daily_loss_breached", "user_disabled".
  final String? reasonIfBlocked;

  // ── Capital limits ────────────────────────────────────────────────────────

  /// Maximum USD that may be deployed in a single calendar day.
  final double maxDailyTradingLimitUsd;

  /// How much of [maxDailyTradingLimitUsd] is still available right now.
  /// Provider calculates: limit − (sum of today's allocations).
  final double remainingDailyTradingLimitUsd;

  /// Maximum realized loss in USD before trading halts for the day.
  final double maxDailyLossUsd;

  /// Maximum drawdown from peak equity, expressed as percentage (0–100).
  final double maxDrawdownPct;

  // ── Position limits ───────────────────────────────────────────────────────

  /// Maximum number of simultaneously open positions.
  final int maxOpenPositions;

  /// Halt trading after N consecutive losses in the same day.
  final int stopAfterLosses;

  // ── Execution quality limits ──────────────────────────────────────────────

  /// Maximum acceptable slippage in basis points (1 bp = 0.01%).
  final double maxSlippageBps;

  /// Maximum gas fee in USD that JARVIS may pay per transaction.
  final double maxGasFeeUsd;

  // ── Trading window ────────────────────────────────────────────────────────

  /// Start of the allowed trading window (local time), e.g. "00:01".
  final String tradingWindowStartLocal;

  /// End of the allowed trading window (local time), e.g. "23:55".
  final String tradingWindowEndLocal;

  /// True when the current time falls within the settlement window
  /// (typically 23:55–23:59 local). During settlement, new entries
  /// are forbidden and open positions should be wound down.
  final bool isSettlementWindow;

  // ── Timezone awareness ────────────────────────────────────────────────────

  /// IANA timezone name if available (e.g. "Europe/Berlin").
  final String? localTimezoneName;

  /// UTC offset in hours (e.g. +2.0 for CEST). Always populated.
  final double utcOffsetHours;

  // ── Exit / Ratchet policy ─────────────────────────────────────────────────

  /// Disaster stop: hard loss limit from entry price. Default -15%.
  /// This is a SEATBELT for catastrophic failure, not a trading stop.
  /// Normal SL (5%) catches regular drops. Disaster catches liquidity collapse.
  final double disasterStopPct;

  /// Ratchet activation: minimum peak gain % before trailing floor activates.
  /// Default: 15% for autonomous, 3% for user experiments.
  final double ratchetActivationPct;

  /// Ratchet distance: floor = peak - this value. Default: 10%.
  final double ratchetDistancePct;

  /// Ratchet minimum floor: floor never goes below this % above entry. Default: 5%.
  final double ratchetMinFloorPct;

  // ── Timestamp ─────────────────────────────────────────────────────────────

  /// When this snapshot was taken.
  final DateTime createdAt;

  const TradingPolicySnapshot({
    required this.tradingAllowed,
    this.reasonIfBlocked,
    required this.maxDailyTradingLimitUsd,
    required this.remainingDailyTradingLimitUsd,
    required this.maxDailyLossUsd,
    required this.maxDrawdownPct,
    required this.maxOpenPositions,
    required this.stopAfterLosses,
    required this.maxSlippageBps,
    required this.maxGasFeeUsd,
    required this.tradingWindowStartLocal,
    required this.tradingWindowEndLocal,
    required this.isSettlementWindow,
    this.localTimezoneName,
    required this.utcOffsetHours,
    required this.createdAt,
    this.disasterStopPct = -15.0, // seatbelt, not trading stop
    this.ratchetActivationPct = 15.0,
    this.ratchetDistancePct = 10.0,
    this.ratchetMinFloorPct = 5.0,
  });

  // ── Convenience ───────────────────────────────────────────────────────────

  /// True if there is remaining budget and trading is allowed.
  bool get hasBudget => tradingAllowed && remainingDailyTradingLimitUsd > 0;

  /// True if we are inside the allowed trading window (not settlement).
  bool get isWithinTradingWindow => tradingAllowed && !isSettlementWindow;

  /// Quick pre-flight: can JARVIS even consider entering right now?
  bool get canConsiderEntry =>
      tradingAllowed &&
      !isSettlementWindow &&
      remainingDailyTradingLimitUsd > 0;

  // ── Logging ───────────────────────────────────────────────────────────────

  String toLogLine() => '[POLICY] '
      'allowed=$tradingAllowed '
      'limit=\$${maxDailyTradingLimitUsd.toStringAsFixed(2)} '
      'remaining=\$${remainingDailyTradingLimitUsd.toStringAsFixed(2)} '
      'maxLoss=\$${maxDailyLossUsd.toStringAsFixed(2)} '
      'dd=${maxDrawdownPct.toStringAsFixed(1)}% '
      'pos=$maxOpenPositions '
      'stopAfter=$stopAfterLosses '
      'slip=${maxSlippageBps.toStringAsFixed(0)}bp '
      'gas=\$${maxGasFeeUsd.toStringAsFixed(2)} '
      'window=$tradingWindowStartLocal–$tradingWindowEndLocal '
      'settlement=$isSettlementWindow'
      '${reasonIfBlocked != null ? ' BLOCKED=$reasonIfBlocked' : ''}';

  // ── Serialization ─────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'tradingAllowed': tradingAllowed,
        'reasonIfBlocked': reasonIfBlocked,
        'maxDailyTradingLimitUsd': maxDailyTradingLimitUsd,
        'remainingDailyTradingLimitUsd': remainingDailyTradingLimitUsd,
        'maxDailyLossUsd': maxDailyLossUsd,
        'maxDrawdownPct': maxDrawdownPct,
        'maxOpenPositions': maxOpenPositions,
        'stopAfterLosses': stopAfterLosses,
        'maxSlippageBps': maxSlippageBps,
        'maxGasFeeUsd': maxGasFeeUsd,
        'tradingWindowStartLocal': tradingWindowStartLocal,
        'tradingWindowEndLocal': tradingWindowEndLocal,
        'isSettlementWindow': isSettlementWindow,
        'localTimezoneName': localTimezoneName,
        'utcOffsetHours': utcOffsetHours,
        'createdAt': createdAt.toIso8601String(),
        'disasterStopPct': disasterStopPct,
        'ratchetActivationPct': ratchetActivationPct,
        'ratchetDistancePct': ratchetDistancePct,
        'ratchetMinFloorPct': ratchetMinFloorPct,
      };

  factory TradingPolicySnapshot.fromJson(Map<String, dynamic> json) =>
      TradingPolicySnapshot(
        tradingAllowed: json['tradingAllowed'] as bool? ?? false,
        reasonIfBlocked: json['reasonIfBlocked'] as String?,
        maxDailyTradingLimitUsd:
            (json['maxDailyTradingLimitUsd'] as num?)?.toDouble() ?? 0,
        remainingDailyTradingLimitUsd:
            (json['remainingDailyTradingLimitUsd'] as num?)?.toDouble() ?? 0,
        maxDailyLossUsd: (json['maxDailyLossUsd'] as num?)?.toDouble() ?? 0,
        maxDrawdownPct: (json['maxDrawdownPct'] as num?)?.toDouble() ?? 0,
        maxOpenPositions: json['maxOpenPositions'] as int? ?? 0,
        stopAfterLosses: json['stopAfterLosses'] as int? ?? 3,
        maxSlippageBps: (json['maxSlippageBps'] as num?)?.toDouble() ?? 100,
        maxGasFeeUsd: (json['maxGasFeeUsd'] as num?)?.toDouble() ?? 0.50,
        tradingWindowStartLocal:
            json['tradingWindowStartLocal'] as String? ?? '00:01',
        tradingWindowEndLocal:
            json['tradingWindowEndLocal'] as String? ?? '23:55',
        isSettlementWindow: json['isSettlementWindow'] as bool? ?? false,
        localTimezoneName: json['localTimezoneName'] as String?,
        utcOffsetHours: (json['utcOffsetHours'] as num?)?.toDouble() ?? 0,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
        disasterStopPct: (json['disasterStopPct'] as num?)?.toDouble() ?? -15.0,
        ratchetActivationPct:
            (json['ratchetActivationPct'] as num?)?.toDouble() ?? 15.0,
        ratchetDistancePct:
            (json['ratchetDistancePct'] as num?)?.toDouble() ?? 10.0,
        ratchetMinFloorPct:
            (json['ratchetMinFloorPct'] as num?)?.toDouble() ?? 5.0,
      );

  @override
  String toString() => toLogLine();
}
