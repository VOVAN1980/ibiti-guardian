// ─── Exit Profile ───────────────────────────────────────────────────────────────
//
// Phase 10A: Adaptive Exit Intelligence.
// Phase 19C: Strategy Memory Lifecycle.
//
// Instead of hardcoded TP/SL, JARVIS learns optimal exits from paper trade
// history. Each combination of (strategyType × tokenMaturity × rocketStage)
// accumulates real statistics about price behavior after entry.
//
// Lifecycle:
//   ACTIVE      — used for trade decisions
//   PROBATION   — being retested with shadow/paper
//   QUARANTINED — NOT used for entries, kept as warning
//   ARCHIVED    — compressed history, no participation
//
// Auto-quarantine rules:
//   PF < 0.8 + samples > 30 → quarantine
//   expectancy < 0 + samples > 20 → quarantine
//
// Rehabilitation:
//   shadow/paper epoch PF > 1.3 + epoch samples > 20 → probation
//   probation epoch PF > 1.5 + epoch samples > 30 → active
// ─────────────────────────────────────────────────────────────────────────────────

import 'package:ibiti_guardian/services/ibiti/models/strategy_context.dart';

/// Phase 19C: Strategy Memory Lifecycle status.
enum ProfileStatus {
  /// Used for active trade decisions.
  active,

  /// Being retested — limited trust, shadow/paper only.
  probation,

  /// NOT used for entries. Kept as "don't repeat" warning.
  quarantined,

  /// Compressed history, no participation.
  archived,
}

/// Learned exit behavior for one (strategy × maturity × stage) bucket.
class ExitProfile {
  /// Strategy this profile applies to.
  final StrategyType strategyType;

  /// Token maturity this profile applies to.
  final TokenMaturity tokenMaturity;

  /// Rocket stage (if applicable).
  final RocketStage rocketStage;

  /// How many closed trades contributed to this profile.
  int samples;

  // ── Learned statistics ──

  /// Average maximum favorable move (peak above entry) in percent.
  /// "How far up does price typically go in this context?"
  double avgMaxFavorableMovePct;

  /// Average maximum adverse move (lowest dip below entry) in percent.
  /// "How far down does price typically dip before recovering (or not)?"
  double avgMaxAdverseMovePct;

  /// Average time from entry to peak price (in minutes).
  double avgTimeToPeakMin;

  /// Average hold time of losing trades (in minutes).
  double avgTimeToFailureMin;

  /// Best observed TP percent (learned from what-if simulation).
  double bestObservedTpPct;

  /// Best observed SL percent (learned from what-if simulation).
  double bestObservedSlPct;

  /// Expectancy with learned TP/SL (avg net gain per trade).
  double expectancy;

  /// Profit factor with learned TP/SL.
  double profitFactor;

  /// Phase 19C: Current lifecycle status.
  ProfileStatus status;

  /// Phase 19C: Why this profile was quarantined (empty if active).
  String quarantineReason;

  /// Phase 19C: When status last changed.
  DateTime statusChangedAt;

  // ── Phase 19C: Epoch tracking (current session / regime) ──

  /// Samples recorded in the current epoch (since last status reset).
  int epochSamples;

  /// Wins in the current epoch.
  int epochWins;

  /// Losses in the current epoch.
  int epochLosses;

  /// Gross win USD in current epoch (for PF calculation).
  double epochGrossWinUsd;

  /// Gross loss USD in current epoch (for PF calculation).
  double epochGrossLossUsd;

  /// Epoch profit factor.
  double get epochPF =>
      epochGrossLossUsd > 0 ? epochGrossWinUsd / epochGrossLossUsd : 0;

  /// Epoch win rate.
  double get epochWR => epochSamples > 0 ? epochWins / epochSamples : 0;

  /// When this profile was last updated.
  DateTime updatedAt;

  ExitProfile({
    required this.strategyType,
    this.tokenMaturity = TokenMaturity.unknown,
    this.rocketStage = RocketStage.unknown,
    this.samples = 0,
    this.avgMaxFavorableMovePct = 0,
    this.avgMaxAdverseMovePct = 0,
    this.avgTimeToPeakMin = 0,
    this.avgTimeToFailureMin = 0,
    this.bestObservedTpPct = 0,
    this.bestObservedSlPct = 0,
    this.expectancy = 0,
    this.profitFactor = 0,
    this.status = ProfileStatus.active,
    this.quarantineReason = '',
    this.epochSamples = 0,
    this.epochWins = 0,
    this.epochLosses = 0,
    this.epochGrossWinUsd = 0,
    this.epochGrossLossUsd = 0,
    DateTime? updatedAt,
    DateTime? statusChangedAt,
  })  : updatedAt = updatedAt ?? DateTime.now(),
        statusChangedAt = statusChangedAt ?? DateTime.now();

  /// Composite key for lookup.
  String get key =>
      '${strategyType.name}:${tokenMaturity.name}:${rocketStage.name}';

  /// Whether this profile has enough data to be used for exit planning.
  /// Phase 19C: Only ACTIVE profiles are reliable for live trading.
  bool get isReliable => samples >= 8 && status == ProfileStatus.active;

  /// Whether this profile can contribute data (active or probation).
  bool get canLearn =>
      status == ProfileStatus.active || status == ProfileStatus.probation;

  /// Whether this profile has any data at all.
  bool get hasData => samples > 0;

  /// Update running averages with a new closed trade observation.
  void record({
    required double maxFavorableMovePct,
    required double maxAdverseMovePct,
    required double timeToPeakMin,
    required double timeToFailureMin,
  }) {
    samples++;
    // Exponential moving average — recent trades matter more.
    final alpha = samples < 5 ? 1.0 / samples : 0.2;
    avgMaxFavorableMovePct =
        _ema(avgMaxFavorableMovePct, maxFavorableMovePct, alpha);
    avgMaxAdverseMovePct = _ema(avgMaxAdverseMovePct, maxAdverseMovePct, alpha);
    avgTimeToPeakMin = _ema(avgTimeToPeakMin, timeToPeakMin, alpha);
    avgTimeToFailureMin = _ema(avgTimeToFailureMin, timeToFailureMin, alpha);
    updatedAt = DateTime.now();
  }

  double _ema(double old, double newVal, double alpha) =>
      old * (1 - alpha) + newVal * alpha;

  Map<String, dynamic> toJson() => {
        'strategyType': strategyType.name,
        'tokenMaturity': tokenMaturity.name,
        'rocketStage': rocketStage.name,
        'samples': samples,
        'avgMaxFavorableMovePct': avgMaxFavorableMovePct,
        'avgMaxAdverseMovePct': avgMaxAdverseMovePct,
        'avgTimeToPeakMin': avgTimeToPeakMin,
        'avgTimeToFailureMin': avgTimeToFailureMin,
        'bestObservedTpPct': bestObservedTpPct,
        'bestObservedSlPct': bestObservedSlPct,
        'expectancy': expectancy,
        'profitFactor': profitFactor,
        'status': status.name,
        'quarantineReason': quarantineReason,
        'epochSamples': epochSamples,
        'epochWins': epochWins,
        'epochLosses': epochLosses,
        'epochGrossWinUsd': epochGrossWinUsd,
        'epochGrossLossUsd': epochGrossLossUsd,
        'statusChangedAt': statusChangedAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory ExitProfile.fromJson(Map<String, dynamic> json) => ExitProfile(
        strategyType: StrategyType.values.firstWhere(
          (e) => e.name == json['strategyType'],
          orElse: () => StrategyType.researchOnly,
        ),
        tokenMaturity: TokenMaturity.values.firstWhere(
          (e) => e.name == json['tokenMaturity'],
          orElse: () => TokenMaturity.unknown,
        ),
        rocketStage: RocketStage.values.firstWhere(
          (e) => e.name == json['rocketStage'],
          orElse: () => RocketStage.unknown,
        ),
        samples: json['samples'] as int? ?? 0,
        avgMaxFavorableMovePct:
            (json['avgMaxFavorableMovePct'] as num?)?.toDouble() ?? 0,
        avgMaxAdverseMovePct:
            (json['avgMaxAdverseMovePct'] as num?)?.toDouble() ?? 0,
        avgTimeToPeakMin: (json['avgTimeToPeakMin'] as num?)?.toDouble() ?? 0,
        avgTimeToFailureMin:
            (json['avgTimeToFailureMin'] as num?)?.toDouble() ?? 0,
        bestObservedTpPct: (json['bestObservedTpPct'] as num?)?.toDouble() ?? 0,
        bestObservedSlPct: (json['bestObservedSlPct'] as num?)?.toDouble() ?? 0,
        expectancy: (json['expectancy'] as num?)?.toDouble() ?? 0,
        profitFactor: (json['profitFactor'] as num?)?.toDouble() ?? 0,
        status: ProfileStatus.values.firstWhere(
          (e) => e.name == (json['status'] as String?),
          orElse: () => ProfileStatus.active,
        ),
        quarantineReason: json['quarantineReason'] as String? ?? '',
        epochSamples: json['epochSamples'] as int? ?? 0,
        epochWins: json['epochWins'] as int? ?? 0,
        epochLosses: json['epochLosses'] as int? ?? 0,
        epochGrossWinUsd: (json['epochGrossWinUsd'] as num?)?.toDouble() ?? 0,
        epochGrossLossUsd: (json['epochGrossLossUsd'] as num?)?.toDouble() ?? 0,
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
        statusChangedAt:
            DateTime.tryParse(json['statusChangedAt'] as String? ?? ''),
      );

  @override
  String toString() => 'ExitProfile($key '
      'status=${status.name} '
      'samples=$samples '
      'avgMFE=${avgMaxFavorableMovePct.toStringAsFixed(1)}% '
      'avgMAE=${avgMaxAdverseMovePct.toStringAsFixed(1)}% '
      'bestTP=${bestObservedTpPct.toStringAsFixed(1)}% '
      'bestSL=${bestObservedSlPct.toStringAsFixed(1)}% '
      'PF=${profitFactor.toStringAsFixed(2)} '
      'epochPF=${epochPF.toStringAsFixed(2)} '
      'epoch=$epochSamples)';

  // ── Phase 19C: Lifecycle transitions ──

  /// Quarantine this profile with a reason.
  void quarantine(String reason) {
    status = ProfileStatus.quarantined;
    quarantineReason = reason;
    statusChangedAt = DateTime.now();
    // Reset epoch counters — new epoch starts when/if rehabilitated.
    _resetEpoch();
  }

  /// Move to probation (being retested).
  void probate(String reason) {
    status = ProfileStatus.probation;
    quarantineReason = 'PROBATION: $reason';
    statusChangedAt = DateTime.now();
    _resetEpoch();
  }

  /// Rehabilitate to active.
  void rehabilitate(String reason) {
    status = ProfileStatus.active;
    quarantineReason = '';
    statusChangedAt = DateTime.now();
    _resetEpoch();
  }

  /// Record epoch outcome for lifecycle evaluation.
  void recordEpochTrade({required double netPnlUsd}) {
    epochSamples++;
    if (netPnlUsd > 0) {
      epochWins++;
      epochGrossWinUsd += netPnlUsd;
    } else {
      epochLosses++;
      epochGrossLossUsd += netPnlUsd.abs();
    }
  }

  void _resetEpoch() {
    epochSamples = 0;
    epochWins = 0;
    epochLosses = 0;
    epochGrossWinUsd = 0;
    epochGrossLossUsd = 0;
  }

  /// Check if this profile should be auto-quarantined.
  /// Called after recording new data.
  bool shouldQuarantine() {
    if (status != ProfileStatus.active) return false;
    // PF < 0.8 over 30+ samples → quarantine.
    if (samples >= 30 && profitFactor > 0 && profitFactor < 0.8) return true;
    // Negative expectancy over 20+ samples → quarantine.
    if (samples >= 20 && expectancy < 0) return true;
    return false;
  }

  /// Check if this quarantined profile deserves probation.
  /// Based on epoch (new data since quarantine).
  bool shouldRehabilitate() {
    if (status != ProfileStatus.quarantined) return false;
    // Epoch must have enough samples with good PF.
    if (epochSamples >= 20 && epochPF > 1.3) return true;
    return false;
  }

  /// Check if probation profile should graduate to active.
  bool shouldGraduate() {
    if (status != ProfileStatus.probation) return false;
    if (epochSamples >= 30 && epochPF > 1.5) return true;
    return false;
  }
}
