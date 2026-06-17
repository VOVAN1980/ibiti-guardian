// ─── Strategy Knowledge ─────────────────────────────────────────────────────
//
// Phase 10D: JARVIS strategic memory.
//
// Each strategy is a living knowledge object with:
//   - Conditions (where it works / fails)
//   - Evidence (samples, PF, expectancy, win rate)
//   - Failure modes (known ways it breaks)
//   - Status lifecycle (rawIdea → testing → confirmed → quarantined)
//   - Confidence score (evidence-based, not opinion)
//
// JARVIS doesn't just remember trades — it remembers strategies.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:convert';

// ═════════════════════════════════════════════════════════════════════════════
// ENUMS
// ═════════════════════════════════════════════════════════════════════════════

/// Lifecycle status of a strategy.
enum StrategyKnowledgeStatus {
  rawIdea,
  testing,
  promising,
  confirmed,
  conditional,
  quarantined,
  failed,
  dangerous,
  obsolete,
}

/// Where the strategy knowledge originated.
enum StrategyKnowledgeSource {
  paperTrades,
  shadowTrades,
  observations,
  opportunityTrajectory,
  counterfactuals,
  userInstruction,
  aiHypothesis,
  importedKnowledge,
}

/// Market applicability.
enum StrategyApplicability {
  allMarkets,
  bullOnly,
  bearOnly,
  sidewaysOnly,
  listingOnly,
  rocketOnly,
  microcapOnly,
  majorOnly,
  memeOnly,
  unknown,
}

// ═════════════════════════════════════════════════════════════════════════════
// STRATEGY CONDITIONS — where it works
// ═════════════════════════════════════════════════════════════════════════════

class StrategyConditions {
  List<String> allowedAssetCategories;
  List<String> blockedAssetCategories;
  List<String> allowedMarketPhases;
  List<String> blockedMarketPhases;
  List<String> allowedHeartbeats;
  List<String> blockedHeartbeats;
  List<String> allowedFlowClasses;
  List<String> blockedFlowClasses;
  List<String> allowedExchanges;
  List<String> blockedExchanges;
  double minEntryQuality;
  double minFlowScore;
  double minVolume24h;
  double maxSpreadPct;
  double minRiskReward;
  bool requiresRocketTrajectory;
  bool requiresMilestone25;
  bool requiresReturnToPeak;
  double? minPullbackPct;
  double? maxPullbackPct;
  List<String> blockedCandleTimingRoles;
  int minMinutesBeforeEod;
  int maxHoldMinutes;

  StrategyConditions({
    this.allowedAssetCategories = const [],
    this.blockedAssetCategories = const [],
    this.allowedMarketPhases = const [],
    this.blockedMarketPhases = const [],
    this.allowedHeartbeats = const [],
    this.blockedHeartbeats = const [],
    this.allowedFlowClasses = const [],
    this.blockedFlowClasses = const [],
    this.allowedExchanges = const [],
    this.blockedExchanges = const [],
    this.minEntryQuality = 0.0,
    this.minFlowScore = 0.0,
    this.minVolume24h = 0.0,
    this.maxSpreadPct = 100.0,
    this.minRiskReward = 0.0,
    this.requiresRocketTrajectory = false,
    this.requiresMilestone25 = false,
    this.requiresReturnToPeak = false,
    this.minPullbackPct,
    this.maxPullbackPct,
    this.blockedCandleTimingRoles = const [],
    this.minMinutesBeforeEod = 0,
    this.maxHoldMinutes = 240,
  });

  Map<String, dynamic> toJson() => {
        'allowedAssetCategories': allowedAssetCategories,
        'blockedAssetCategories': blockedAssetCategories,
        'allowedMarketPhases': allowedMarketPhases,
        'blockedMarketPhases': blockedMarketPhases,
        'allowedHeartbeats': allowedHeartbeats,
        'blockedHeartbeats': blockedHeartbeats,
        'allowedFlowClasses': allowedFlowClasses,
        'blockedFlowClasses': blockedFlowClasses,
        'allowedExchanges': allowedExchanges,
        'blockedExchanges': blockedExchanges,
        'minEntryQuality': minEntryQuality,
        'minFlowScore': minFlowScore,
        'minVolume24h': minVolume24h,
        'maxSpreadPct': maxSpreadPct,
        'minRiskReward': minRiskReward,
        'requiresRocketTrajectory': requiresRocketTrajectory,
        'requiresMilestone25': requiresMilestone25,
        'requiresReturnToPeak': requiresReturnToPeak,
        'minPullbackPct': minPullbackPct,
        'maxPullbackPct': maxPullbackPct,
        'blockedCandleTimingRoles': blockedCandleTimingRoles,
        'minMinutesBeforeEod': minMinutesBeforeEod,
        'maxHoldMinutes': maxHoldMinutes,
      };

  factory StrategyConditions.fromJson(Map<String, dynamic> j) =>
      StrategyConditions(
        allowedAssetCategories:
            (j['allowedAssetCategories'] as List?)?.cast<String>() ?? [],
        blockedAssetCategories:
            (j['blockedAssetCategories'] as List?)?.cast<String>() ?? [],
        allowedMarketPhases:
            (j['allowedMarketPhases'] as List?)?.cast<String>() ?? [],
        blockedMarketPhases:
            (j['blockedMarketPhases'] as List?)?.cast<String>() ?? [],
        allowedHeartbeats:
            (j['allowedHeartbeats'] as List?)?.cast<String>() ?? [],
        blockedHeartbeats:
            (j['blockedHeartbeats'] as List?)?.cast<String>() ?? [],
        allowedFlowClasses:
            (j['allowedFlowClasses'] as List?)?.cast<String>() ?? [],
        blockedFlowClasses:
            (j['blockedFlowClasses'] as List?)?.cast<String>() ?? [],
        allowedExchanges:
            (j['allowedExchanges'] as List?)?.cast<String>() ?? [],
        blockedExchanges:
            (j['blockedExchanges'] as List?)?.cast<String>() ?? [],
        minEntryQuality: (j['minEntryQuality'] as num?)?.toDouble() ?? 0,
        minFlowScore: (j['minFlowScore'] as num?)?.toDouble() ?? 0,
        minVolume24h: (j['minVolume24h'] as num?)?.toDouble() ?? 0,
        maxSpreadPct: (j['maxSpreadPct'] as num?)?.toDouble() ?? 100,
        minRiskReward: (j['minRiskReward'] as num?)?.toDouble() ?? 0,
        requiresRocketTrajectory:
            j['requiresRocketTrajectory'] as bool? ?? false,
        requiresMilestone25: j['requiresMilestone25'] as bool? ?? false,
        requiresReturnToPeak: j['requiresReturnToPeak'] as bool? ?? false,
        minPullbackPct: (j['minPullbackPct'] as num?)?.toDouble(),
        maxPullbackPct: (j['maxPullbackPct'] as num?)?.toDouble(),
        blockedCandleTimingRoles:
            (j['blockedCandleTimingRoles'] as List?)?.cast<String>() ?? [],
        minMinutesBeforeEod: j['minMinutesBeforeEod'] as int? ?? 0,
        maxHoldMinutes: j['maxHoldMinutes'] as int? ?? 240,
      );
}

// ═════════════════════════════════════════════════════════════════════════════
// STRATEGY EVIDENCE — proof it works (or doesn't)
// ═════════════════════════════════════════════════════════════════════════════

class StrategyEvidence {
  int paperSamples;
  int shadowSamples;
  int observationSamples;
  int counterfactualSamples;
  int opportunitySamples;
  int wins;
  int losses;
  double winRate;
  double expectancy;
  double profitFactor;
  double netPnlUsd;
  double avgWinUsd;
  double avgLossUsd;
  double avgHoldMinutes;
  double maxDrawdownPct;
  double bestTradeUsd;
  double worstTradeUsd;
  double counterfactualDeltaUsd;
  int blockedCount;
  double blockedSavedUsd;
  double blockedMissedUsd;
  double evidenceConfidence;
  DateTime? firstEvidenceAt;
  DateTime? lastEvidenceAt;

  StrategyEvidence({
    this.paperSamples = 0,
    this.shadowSamples = 0,
    this.observationSamples = 0,
    this.counterfactualSamples = 0,
    this.opportunitySamples = 0,
    this.wins = 0,
    this.losses = 0,
    this.winRate = 0,
    this.expectancy = 0,
    this.profitFactor = 0,
    this.netPnlUsd = 0,
    this.avgWinUsd = 0,
    this.avgLossUsd = 0,
    this.avgHoldMinutes = 0,
    this.maxDrawdownPct = 0,
    this.bestTradeUsd = 0,
    this.worstTradeUsd = 0,
    this.counterfactualDeltaUsd = 0,
    this.blockedCount = 0,
    this.blockedSavedUsd = 0,
    this.blockedMissedUsd = 0,
    this.evidenceConfidence = 0,
    this.firstEvidenceAt,
    this.lastEvidenceAt,
  });

  int get totalSamples =>
      paperSamples +
      shadowSamples +
      observationSamples +
      counterfactualSamples +
      opportunitySamples;

  Map<String, dynamic> toJson() => {
        'paperSamples': paperSamples,
        'shadowSamples': shadowSamples,
        'observationSamples': observationSamples,
        'counterfactualSamples': counterfactualSamples,
        'opportunitySamples': opportunitySamples,
        'wins': wins,
        'losses': losses,
        'winRate': winRate,
        'expectancy': expectancy,
        'profitFactor': profitFactor,
        'netPnlUsd': netPnlUsd,
        'avgWinUsd': avgWinUsd,
        'avgLossUsd': avgLossUsd,
        'avgHoldMinutes': avgHoldMinutes,
        'maxDrawdownPct': maxDrawdownPct,
        'bestTradeUsd': bestTradeUsd,
        'worstTradeUsd': worstTradeUsd,
        'counterfactualDeltaUsd': counterfactualDeltaUsd,
        'blockedCount': blockedCount,
        'blockedSavedUsd': blockedSavedUsd,
        'blockedMissedUsd': blockedMissedUsd,
        'evidenceConfidence': evidenceConfidence,
        'firstEvidenceAt': firstEvidenceAt?.toIso8601String(),
        'lastEvidenceAt': lastEvidenceAt?.toIso8601String(),
      };

  factory StrategyEvidence.fromJson(Map<String, dynamic> j) => StrategyEvidence(
        paperSamples: j['paperSamples'] as int? ?? 0,
        shadowSamples: j['shadowSamples'] as int? ?? 0,
        observationSamples: j['observationSamples'] as int? ?? 0,
        counterfactualSamples: j['counterfactualSamples'] as int? ?? 0,
        opportunitySamples: j['opportunitySamples'] as int? ?? 0,
        wins: j['wins'] as int? ?? 0,
        losses: j['losses'] as int? ?? 0,
        winRate: (j['winRate'] as num?)?.toDouble() ?? 0,
        expectancy: (j['expectancy'] as num?)?.toDouble() ?? 0,
        profitFactor: (j['profitFactor'] as num?)?.toDouble() ?? 0,
        netPnlUsd: (j['netPnlUsd'] as num?)?.toDouble() ?? 0,
        avgWinUsd: (j['avgWinUsd'] as num?)?.toDouble() ?? 0,
        avgLossUsd: (j['avgLossUsd'] as num?)?.toDouble() ?? 0,
        avgHoldMinutes: (j['avgHoldMinutes'] as num?)?.toDouble() ?? 0,
        maxDrawdownPct: (j['maxDrawdownPct'] as num?)?.toDouble() ?? 0,
        bestTradeUsd: (j['bestTradeUsd'] as num?)?.toDouble() ?? 0,
        worstTradeUsd: (j['worstTradeUsd'] as num?)?.toDouble() ?? 0,
        counterfactualDeltaUsd:
            (j['counterfactualDeltaUsd'] as num?)?.toDouble() ?? 0,
        blockedCount: j['blockedCount'] as int? ?? 0,
        blockedSavedUsd: (j['blockedSavedUsd'] as num?)?.toDouble() ?? 0,
        blockedMissedUsd: (j['blockedMissedUsd'] as num?)?.toDouble() ?? 0,
        evidenceConfidence: (j['evidenceConfidence'] as num?)?.toDouble() ?? 0,
        firstEvidenceAt: j['firstEvidenceAt'] != null
            ? DateTime.tryParse(j['firstEvidenceAt'] as String)
            : null,
        lastEvidenceAt: j['lastEvidenceAt'] != null
            ? DateTime.tryParse(j['lastEvidenceAt'] as String)
            : null,
      );
}

// ═════════════════════════════════════════════════════════════════════════════
// FAILURE MODE — known way a strategy breaks
// ═════════════════════════════════════════════════════════════════════════════

class StrategyFailureMode {
  final String id;
  String title;
  String description;
  int occurrenceCount;
  double pnlImpactUsd;
  List<String> exampleTradeKeys;
  List<String> affectedSymbols;
  String likelyCause;
  String suggestedFix;
  String verificationPlan;
  DateTime firstSeenAt;
  DateTime lastSeenAt;

  StrategyFailureMode({
    required this.id,
    required this.title,
    this.description = '',
    this.occurrenceCount = 1,
    this.pnlImpactUsd = 0,
    this.exampleTradeKeys = const [],
    this.affectedSymbols = const [],
    this.likelyCause = '',
    this.suggestedFix = '',
    this.verificationPlan = '',
    DateTime? firstSeenAt,
    DateTime? lastSeenAt,
  })  : firstSeenAt = firstSeenAt ?? DateTime.now(),
        lastSeenAt = lastSeenAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'occurrenceCount': occurrenceCount,
        'pnlImpactUsd': pnlImpactUsd,
        'exampleTradeKeys': exampleTradeKeys,
        'affectedSymbols': affectedSymbols,
        'likelyCause': likelyCause,
        'suggestedFix': suggestedFix,
        'verificationPlan': verificationPlan,
        'firstSeenAt': firstSeenAt.toIso8601String(),
        'lastSeenAt': lastSeenAt.toIso8601String(),
      };

  factory StrategyFailureMode.fromJson(Map<String, dynamic> j) =>
      StrategyFailureMode(
        id: j['id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        description: j['description'] as String? ?? '',
        occurrenceCount: j['occurrenceCount'] as int? ?? 1,
        pnlImpactUsd: (j['pnlImpactUsd'] as num?)?.toDouble() ?? 0,
        exampleTradeKeys:
            (j['exampleTradeKeys'] as List?)?.cast<String>() ?? [],
        affectedSymbols: (j['affectedSymbols'] as List?)?.cast<String>() ?? [],
        likelyCause: j['likelyCause'] as String? ?? '',
        suggestedFix: j['suggestedFix'] as String? ?? '',
        verificationPlan: j['verificationPlan'] as String? ?? '',
        firstSeenAt: j['firstSeenAt'] != null
            ? DateTime.tryParse(j['firstSeenAt'] as String) ?? DateTime.now()
            : DateTime.now(),
        lastSeenAt: j['lastSeenAt'] != null
            ? DateTime.tryParse(j['lastSeenAt'] as String) ?? DateTime.now()
            : DateTime.now(),
      );
}

// ═════════════════════════════════════════════════════════════════════════════
// STRATEGY KNOWLEDGE — the living strategy object
// ═════════════════════════════════════════════════════════════════════════════

class StrategyKnowledge {
  final String id;
  String title;
  String strategyType;
  StrategyKnowledgeStatus status;
  StrategyKnowledgeSource source;
  StrategyApplicability applicability;
  String thesis;
  StrategyConditions conditions;
  StrategyEvidence evidence;
  List<StrategyFailureMode> failureModes;
  List<String> lessons;
  List<String> developerRequestIds;
  double confidence;
  double utilityScore;
  int revision;
  DateTime createdAt;
  DateTime updatedAt;
  DateTime? lastConfirmedAt;
  DateTime? lastFailedAt;
  DateTime? quarantinedAt;
  String? quarantineReason;

  StrategyKnowledge({
    required this.id,
    required this.title,
    required this.strategyType,
    this.status = StrategyKnowledgeStatus.rawIdea,
    this.source = StrategyKnowledgeSource.paperTrades,
    this.applicability = StrategyApplicability.unknown,
    this.thesis = '',
    StrategyConditions? conditions,
    StrategyEvidence? evidence,
    this.failureModes = const [],
    this.lessons = const [],
    this.developerRequestIds = const [],
    this.confidence = 0,
    this.utilityScore = 0,
    this.revision = 1,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.lastConfirmedAt,
    this.lastFailedAt,
    this.quarantinedAt,
    this.quarantineReason,
  })  : conditions = conditions ?? StrategyConditions(),
        evidence = evidence ?? StrategyEvidence(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'strategyType': strategyType,
        'status': status.name,
        'source': source.name,
        'applicability': applicability.name,
        'thesis': thesis,
        'conditions': conditions.toJson(),
        'evidence': evidence.toJson(),
        'failureModes': failureModes.map((f) => f.toJson()).toList(),
        'lessons': lessons,
        'developerRequestIds': developerRequestIds,
        'confidence': confidence,
        'utilityScore': utilityScore,
        'revision': revision,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'lastConfirmedAt': lastConfirmedAt?.toIso8601String(),
        'lastFailedAt': lastFailedAt?.toIso8601String(),
        'quarantinedAt': quarantinedAt?.toIso8601String(),
        'quarantineReason': quarantineReason,
      };

  /// Serialize conditions/evidence/failures to JSON strings for DB.
  String get conditionsJson => jsonEncode(conditions.toJson());
  String get evidenceJson => jsonEncode(evidence.toJson());
  String get failureModesJson =>
      jsonEncode(failureModes.map((f) => f.toJson()).toList());
  String get lessonsJson => jsonEncode(lessons);
  String get devRequestIdsJson => jsonEncode(developerRequestIds);

  /// Build from DB row.
  factory StrategyKnowledge.fromRow(Map<String, dynamic> r) {
    final cJson = r['conditions_json'] as String? ?? '{}';
    final eJson = r['evidence_json'] as String? ?? '{}';
    final fJson = r['failure_modes_json'] as String? ?? '[]';
    final lJson = r['lessons_json'] as String? ?? '[]';
    final dJson = r['developer_request_ids_json'] as String? ?? '[]';

    return StrategyKnowledge(
      id: r['id'] as String? ?? '',
      title: r['title'] as String? ?? '',
      strategyType: r['strategy_type'] as String? ?? '',
      status: StrategyKnowledgeStatus.values.firstWhere(
        (s) => s.name == (r['status'] as String? ?? ''),
        orElse: () => StrategyKnowledgeStatus.rawIdea,
      ),
      source: StrategyKnowledgeSource.values.firstWhere(
        (s) => s.name == (r['source'] as String? ?? ''),
        orElse: () => StrategyKnowledgeSource.paperTrades,
      ),
      applicability: StrategyApplicability.values.firstWhere(
        (s) => s.name == (r['applicability'] as String? ?? ''),
        orElse: () => StrategyApplicability.unknown,
      ),
      thesis: r['thesis'] as String? ?? '',
      conditions: StrategyConditions.fromJson(
          jsonDecode(cJson) as Map<String, dynamic>),
      evidence:
          StrategyEvidence.fromJson(jsonDecode(eJson) as Map<String, dynamic>),
      failureModes: (jsonDecode(fJson) as List)
          .map((f) => StrategyFailureMode.fromJson(f as Map<String, dynamic>))
          .toList(),
      lessons: (jsonDecode(lJson) as List).cast<String>(),
      developerRequestIds: (jsonDecode(dJson) as List).cast<String>(),
      confidence: (r['confidence'] as num?)?.toDouble() ?? 0,
      utilityScore: (r['utility_score'] as num?)?.toDouble() ?? 0,
      revision: r['revision'] as int? ?? 1,
      createdAt:
          DateTime.tryParse(r['created_at'] as String? ?? '') ?? DateTime.now(),
      updatedAt:
          DateTime.tryParse(r['updated_at'] as String? ?? '') ?? DateTime.now(),
      lastConfirmedAt: r['last_confirmed_at'] != null
          ? DateTime.tryParse(r['last_confirmed_at'] as String)
          : null,
      lastFailedAt: r['last_failed_at'] != null
          ? DateTime.tryParse(r['last_failed_at'] as String)
          : null,
      quarantinedAt: r['quarantined_at'] != null
          ? DateTime.tryParse(r['quarantined_at'] as String)
          : null,
      quarantineReason: r['quarantine_reason'] as String?,
    );
  }

  /// Compact log line.
  String toLogLine() => '[STRATEGY_KB] $id status=${status.name} '
      'type=$strategyType samples=${evidence.totalSamples} '
      'WR=${(evidence.winRate * 100).toStringAsFixed(0)}% '
      'PF=${evidence.profitFactor.toStringAsFixed(2)} '
      'exp=${evidence.expectancy.toStringAsFixed(4)} '
      'conf=${confidence.toStringAsFixed(2)} '
      'failures=${failureModes.length}';

  @override
  String toString() => toLogLine();
}
