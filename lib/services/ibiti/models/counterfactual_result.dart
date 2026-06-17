// ─── Counterfactual Result ──────────────────────────────────────────────────
//
// Phase 10C: JARVIS Counterfactual Engine.
//
// For every trade, shadow, observation, and missed opportunity,
// JARVIS asks: "what would have happened if I did X instead?"
//
// This is NOT speculation. Each scenario uses real price data
// (entry, exit, peak, 1h/4h checks) to compute hypothetical PnL.
//
// Rules:
//   - One case ≠ a reason to change rules. Need count >= 3.
//   - Low confidence = honest. Don't pretend certainty.
//   - Lesson must be actionable, not philosophical.
// ─────────────────────────────────────────────────────────────────────────────

/// What alternative scenario is being evaluated.
enum CounterfactualScenario {
  /// What if I didn't enter at all?
  noEntry,

  /// What if I entered at the original signal price?
  enterAtSignal,

  /// What if I entered when first seen (opportunity tracker)?
  enterAtFirstSeen,

  /// What if I entered at +25% milestone?
  enterAtMilestone25,

  /// What if I entered at +100% milestone?
  enterAtMilestone100,

  /// What if I held longer instead of exiting?
  holdLonger,

  /// What if I exited earlier (at peak)?
  exitEarlier,

  /// What if I didn't scale in?
  noScale,

  /// What if I scaled earlier?
  scaleEarlier,

  /// What if I scaled later?
  scaleLater,

  /// What if cooldown didn't block me?
  ignoreCooldown,

  /// What if budget didn't block me?
  ignoreBudget,

  /// What if cost gate didn't block me?
  ignoreCostGate,

  /// What if TA block didn't apply?
  ignoreTaBlock,

  /// What if market phase block didn't apply?
  ignorePhaseBlock,

  /// What if flow block didn't apply?
  ignoreFlowBlock,

  /// What if I used RocketTrajectory data?
  useRocketTrajectory,
}

/// What type of subject is being analyzed.
enum CounterfactualSubjectType {
  /// A real closed paper trade.
  paperTrade,

  /// A blocked entry (shadow trade).
  shadow,

  /// A researchOnly observation.
  observation,

  /// A tracked opportunity / rocket trajectory.
  opportunity,
}

/// Full counterfactual analysis result.
class CounterfactualResult {
  /// Key identifying the subject (e.g. "binance:ALPHAUSDT" or trade id).
  final String subjectKey;

  /// What type of data this analysis is based on.
  final CounterfactualSubjectType subjectType;

  /// The alternative scenario evaluated.
  final CounterfactualScenario scenario;

  /// What actually happened (PnL or 0 if not entered).
  final double actualPnl;

  /// What would have happened under the scenario.
  final double hypotheticalPnl;

  /// Difference: hypothetical - actual. Positive = scenario was better.
  final double deltaPnl;

  /// Actual exit price (null if never entered).
  final double? actualExitPrice;

  /// Hypothetical exit price under scenario.
  final double? hypotheticalExitPrice;

  /// Entry price used.
  final double? entryPrice;

  /// Peak price observed.
  final double? peakPrice;

  /// Evidence string with numbers.
  final String evidence;

  /// Human-readable explanation.
  final String explanation;

  /// Actionable lesson learned.
  final String lesson;

  /// What JARVIS requests to change.
  final String requestedChange;

  /// How to verify the change worked.
  final String verificationPlan;

  /// Confidence in this analysis (0.0–1.0).
  final double confidence;

  /// When this was computed.
  final DateTime createdAt;

  CounterfactualResult({
    required this.subjectKey,
    required this.subjectType,
    required this.scenario,
    required this.actualPnl,
    required this.hypotheticalPnl,
    required this.deltaPnl,
    this.actualExitPrice,
    this.hypotheticalExitPrice,
    this.entryPrice,
    this.peakPrice,
    this.evidence = '',
    this.explanation = '',
    this.lesson = '',
    this.requestedChange = '',
    this.verificationPlan = '',
    this.confidence = 0.5,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Compact log line.
  String toLogLine() => '[COUNTERFACTUAL] $subjectKey '
      'type=${subjectType.name} '
      'scenario=${scenario.name} '
      'actual=${actualPnl.toStringAsFixed(4)} '
      'hyp=${hypotheticalPnl.toStringAsFixed(4)} '
      'delta=${deltaPnl >= 0 ? "+" : ""}${deltaPnl.toStringAsFixed(4)} '
      'conf=${confidence.toStringAsFixed(2)} '
      'lesson="$lesson"';

  Map<String, dynamic> toJson() => {
        'subjectKey': subjectKey,
        'subjectType': subjectType.name,
        'scenario': scenario.name,
        'actualPnl': actualPnl,
        'hypotheticalPnl': hypotheticalPnl,
        'deltaPnl': deltaPnl,
        'actualExitPrice': actualExitPrice,
        'hypotheticalExitPrice': hypotheticalExitPrice,
        'entryPrice': entryPrice,
        'peakPrice': peakPrice,
        'evidence': evidence,
        'explanation': explanation,
        'lesson': lesson,
        'requestedChange': requestedChange,
        'verificationPlan': verificationPlan,
        'confidence': confidence,
        'createdAt': createdAt.toIso8601String(),
      };

  factory CounterfactualResult.fromRow(Map<String, dynamic> r) {
    return CounterfactualResult(
      subjectKey: r['subject_key'] as String? ?? '',
      subjectType: CounterfactualSubjectType.values.firstWhere(
        (t) => t.name == (r['subject_type'] as String? ?? ''),
        orElse: () => CounterfactualSubjectType.paperTrade,
      ),
      scenario: CounterfactualScenario.values.firstWhere(
        (s) => s.name == (r['scenario'] as String? ?? ''),
        orElse: () => CounterfactualScenario.noEntry,
      ),
      actualPnl: (r['actual_pnl'] as num?)?.toDouble() ?? 0,
      hypotheticalPnl: (r['hypothetical_pnl'] as num?)?.toDouble() ?? 0,
      deltaPnl: (r['delta_pnl'] as num?)?.toDouble() ?? 0,
      actualExitPrice: (r['actual_exit_price'] as num?)?.toDouble(),
      hypotheticalExitPrice: (r['hypothetical_exit_price'] as num?)?.toDouble(),
      entryPrice: (r['entry_price'] as num?)?.toDouble(),
      peakPrice: (r['peak_price'] as num?)?.toDouble(),
      evidence: r['evidence'] as String? ?? '',
      explanation: r['explanation'] as String? ?? '',
      lesson: r['lesson'] as String? ?? '',
      requestedChange: r['requested_change'] as String? ?? '',
      verificationPlan: r['verification_plan'] as String? ?? '',
      confidence: (r['confidence'] as num?)?.toDouble() ?? 0.5,
      createdAt:
          DateTime.tryParse(r['created_at'] as String? ?? '') ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toRow() => {
        'subject_key': subjectKey,
        'subject_type': subjectType.name,
        'scenario': scenario.name,
        'actual_pnl': actualPnl,
        'hypothetical_pnl': hypotheticalPnl,
        'delta_pnl': deltaPnl,
        'actual_exit_price': actualExitPrice,
        'hypothetical_exit_price': hypotheticalExitPrice,
        'entry_price': entryPrice,
        'peak_price': peakPrice,
        'evidence': evidence,
        'explanation': explanation,
        'lesson': lesson,
        'requested_change': requestedChange,
        'verification_plan': verificationPlan,
        'confidence': confidence,
        'created_at': createdAt.toIso8601String(),
      };

  @override
  String toString() => toLogLine();
}
