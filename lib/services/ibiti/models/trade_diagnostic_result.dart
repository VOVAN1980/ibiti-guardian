// ─── Trade Diagnostic Result ────────────────────────────────────────────────
//
// Phase 10B: JARVIS Diagnostic Engine.
//
// After every trade closes, the classifier produces a TradeDiagnosticResult
// that explains WHAT happened, WHY, and WHAT to change — with evidence.
//
// This is NOT a simple "reason" string. It's a full medical report:
//   - Primary diagnosis (the main thing that went wrong/right)
//   - Secondary factors (contributing causes)
//   - Evidence (numbers that prove it)
//   - Explanation (human-readable narrative)
//   - Suggested fix (concrete action item)
//   - Verification plan (how to check if the fix worked)
//
// JARVIS must PROVE its diagnosis, not guess.
// ─────────────────────────────────────────────────────────────────────────────

/// Severity of the diagnostic finding.
enum DiagnosticSeverity {
  /// Informational — trade worked as expected.
  info,

  /// Warning — minor issue, worth tracking.
  warning,

  /// High — significant problem affecting PnL.
  high,

  /// Critical — systemic issue, needs immediate attention.
  critical,
}

/// Which subsystem domain the diagnosis belongs to.
enum DiagnosticDomain {
  entry,
  exit,
  sizing,
  market,
  flow,
  cost,
  timing,
  strategy,
  data,
  policy,
  system,
}

/// Specific diagnostic reason — the "what happened" label.
///
/// Each reason maps to a concrete, evidence-backed explanation.
/// JARVIS must not use [unknown] unless genuinely unable to classify.
enum TradeDiagnosticReason {
  // ── Good outcomes ──────────────────────────────────────────────────────
  /// TP hit, net positive.
  goodTakeProfit,

  /// Trailing stop locked profit after peak.
  goodTrailing,

  /// Breakeven lock prevented loss.
  goodBreakevenProtection,

  /// Skip/block saved money (shadow showed loss).
  goodSkipWouldHaveLost,

  /// Held through pullback, recovered to profit.
  goodHoldThroughPullback,

  // ── Entry problems ─────────────────────────────────────────────────────
  /// Entered during exhaustion/panic/distribution phase.
  badMarketPhaseEntry,

  /// Flow score was weak at entry.
  weakFlowEntry,

  /// Flow was retailNoise at entry.
  retailNoiseEntry,

  /// Entered too late after the pump already happened.
  lateEntryAfterPump,

  /// Candle timing showed OVERHEATED_WAIT.
  overheatedEntry,

  /// Candle timing showed distribution signals.
  distributionEntry,

  /// Low liquidity asset — slippage/spread risk.
  lowLiquidityEntry,

  /// Asset category was wrong for this strategy.
  badAssetCategory,

  /// Strategy type doesn't fit current market conditions.
  badStrategyForMarket,

  // ── Exit problems ──────────────────────────────────────────────────────
  /// Too many SL exits — systemic pattern.
  stopLossDominance,

  /// SL was provably too tight (price recovered after hit).
  slTooTight,

  /// TP was too close — fees ate the profit.
  tpTooClose,

  /// TP was too far — price never reached it.
  tpTooFar,

  /// Flow died and exit was correct (no regret).
  flowDiedExitCorrect,

  /// Flow died but exit was too late (damage already done).
  flowDiedTooLate,

  /// Trailing stop was too tight — exited before full move.
  trailingTooTight,

  /// Trailing stop was too loose — gave back too much.
  trailingTooLoose,

  /// Expired without clear thesis — wasted a slot.
  expiredWithoutThesis,

  /// Held too long — should have exited earlier.
  heldTooLong,

  /// Exited too early — missed the bigger move.
  exitedTooEarly,

  // ── Scaling ────────────────────────────────────────────────────────────
  /// Scale-in contributed to profit.
  scaleHelped,

  /// Scale-in made the loss worse.
  scaleHurt,

  /// Scaled too early — price hadn't confirmed.
  scaleTooEarly,

  /// Scaled without enough flow confirmation.
  scaleWithoutEnoughFlow,

  /// Scale was correctly blocked by rules.
  scaleBlockedCorrectly,

  /// Missed a scaling opportunity.
  scaleMissingOpportunity,

  // ── Cost / execution ───────────────────────────────────────────────────
  /// Total cost (fees+slippage) was too high relative to PnL.
  costTooHigh,

  /// Spread was too wide for profitable execution.
  spreadTooWide,

  /// Slippage ate the profit.
  slippageTooHigh,

  /// Trade lost mainly from fee noise, not direction.
  feeNoise,

  /// Risk:Reward ratio was bad at entry.
  badRiskReward,

  // ── Strategy knowledge ─────────────────────────────────────────────────
  /// Strategy worked as designed.
  strategyWorked,

  /// Strategy failed in this context.
  strategyFailed,

  /// Not enough data to evaluate strategy.
  strategyNeedsMoreSamples,

  /// Strategy works only under specific conditions.
  strategyOnlyWorksConditionally,

  /// Missing rocket trajectory data.
  missingRocketTrajectory,

  /// Missing external data source.
  missingExternalData,

  /// Missing social signal data.
  missingSocialSignal,

  /// Missing listing announcement data.
  missingListingData,

  /// Missing whale/on-chain data.
  missingWhaleData,

  // ── Policy / constraints ───────────────────────────────────────────────
  /// Daily budget was exhausted.
  budgetExhausted,

  /// Policy blocked this trade.
  policyBlocked,

  /// Cooldown timer blocked re-entry.
  cooldownBlocked,

  /// No TA data available for better SL/TP.
  taMissing,

  /// Trading window was about to close.
  dailyWindowBlocked,

  // ── Fallback ───────────────────────────────────────────────────────────
  /// Unable to classify — should be very rare.
  unknown,
}

/// Full diagnostic result for a single closed trade.
///
/// This is the "medical report" that JARVIS produces after every trade.
/// It contains not just a label, but evidence, explanation, and action items.
class TradeDiagnosticResult {
  /// Unique trade key (e.g. "binance:ALPHAUSDT").
  final String tradeKey;

  /// The main diagnosis — what was the primary factor.
  final TradeDiagnosticReason primaryReason;

  /// Contributing factors (may be empty).
  final List<TradeDiagnosticReason> secondaryReasons;

  /// Which subsystem domain this diagnosis belongs to.
  final DiagnosticDomain domain;

  /// How severe is this finding.
  final DiagnosticSeverity severity;

  /// One-line summary (for logs).
  final String shortSummary;

  /// Evidence string (numbers, facts).
  final String evidence;

  /// Human-readable narrative explanation.
  final String explanation;

  /// What should be changed to prevent this.
  final String suggestedFix;

  /// How to verify the fix worked.
  final String verificationPlan;

  /// Confidence in this diagnosis (0.0–1.0).
  final double confidence;

  // ── Numeric evidence ─────────────────────────────────────────────────

  final double? netPnl;
  final double? entryQuality;
  final double? rrAtEntry;
  final double? flowScoreAtEntry;
  final double? maxDrawdownPct;
  final double? holdMinutes;
  final double? fees;
  final double? slippage;

  // ── Context evidence ─────────────────────────────────────────────────

  final String? strategyType;
  final String? assetCategory;
  final String? marketPhaseAtEntry;
  final String? heartbeatAtEntry;
  final String? flowAtEntry;
  final String? flowAtExit;
  final String? closeReason;

  const TradeDiagnosticResult({
    required this.tradeKey,
    required this.primaryReason,
    this.secondaryReasons = const [],
    required this.domain,
    required this.severity,
    required this.shortSummary,
    this.evidence = '',
    this.explanation = '',
    this.suggestedFix = '',
    this.verificationPlan = '',
    this.confidence = 0.5,
    this.netPnl,
    this.entryQuality,
    this.rrAtEntry,
    this.flowScoreAtEntry,
    this.maxDrawdownPct,
    this.holdMinutes,
    this.fees,
    this.slippage,
    this.strategyType,
    this.assetCategory,
    this.marketPhaseAtEntry,
    this.heartbeatAtEntry,
    this.flowAtEntry,
    this.flowAtExit,
    this.closeReason,
  });

  /// Compact log line for console output.
  String toLogLine() {
    final sec = secondaryReasons.isNotEmpty
        ? ' secondary=${secondaryReasons.map((r) => r.name).join(',')}'
        : '';
    final pnlStr = netPnl != null ? ' pnl=${netPnl!.toStringAsFixed(4)}' : '';
    final eqStr =
        entryQuality != null ? ' EQ=${entryQuality!.toStringAsFixed(2)}' : '';
    final rrStr =
        rrAtEntry != null ? ' RR=${rrAtEntry!.toStringAsFixed(1)}' : '';
    final fsStr = flowScoreAtEntry != null
        ? ' fs=${flowScoreAtEntry!.toStringAsFixed(2)}'
        : '';
    final ddStr = maxDrawdownPct != null
        ? ' dd=${(maxDrawdownPct! * 100).toStringAsFixed(1)}%'
        : '';

    return '[TRADE_DIAG] $tradeKey '
        'primary=${primaryReason.name} '
        'severity=${severity.name} '
        'domain=${domain.name} '
        'conf=${confidence.toStringAsFixed(2)}'
        '$pnlStr$eqStr$rrStr$fsStr$ddStr$sec'
        '${suggestedFix.isNotEmpty ? ' fix="$suggestedFix"' : ''}';
  }

  Map<String, dynamic> toJson() => {
        'tradeKey': tradeKey,
        'primaryReason': primaryReason.name,
        'secondaryReasons': secondaryReasons.map((r) => r.name).toList(),
        'domain': domain.name,
        'severity': severity.name,
        'shortSummary': shortSummary,
        'evidence': evidence,
        'explanation': explanation,
        'suggestedFix': suggestedFix,
        'verificationPlan': verificationPlan,
        'confidence': confidence,
        'netPnl': netPnl,
        'entryQuality': entryQuality,
        'rrAtEntry': rrAtEntry,
        'flowScoreAtEntry': flowScoreAtEntry,
        'maxDrawdownPct': maxDrawdownPct,
        'holdMinutes': holdMinutes,
        'fees': fees,
        'slippage': slippage,
        'strategyType': strategyType,
        'assetCategory': assetCategory,
        'marketPhaseAtEntry': marketPhaseAtEntry,
        'heartbeatAtEntry': heartbeatAtEntry,
        'flowAtEntry': flowAtEntry,
        'flowAtExit': flowAtExit,
        'closeReason': closeReason,
      };

  @override
  String toString() => toLogLine();
}
