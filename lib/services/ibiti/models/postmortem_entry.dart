// ─── IBITI Postmortem Entry ──────────────────────────────────────────────────────
//
// After every decision, IBITI checks back: was I right?
// Prices at 15m, 30m, 60m compared to decision price.
// Generates a lesson and updates token/exchange profiles.
// ─────────────────────────────────────────────────────────────────────────────────

import 'package:ibiti_guardian/services/ibiti/models/ibiti_hypothesis.dart';
import 'package:ibiti_guardian/services/ibiti/models/market_event.dart';
import 'package:ibiti_guardian/services/ibiti/models/market_phase.dart';

/// Outcome quality.
enum PostmortemOutcome {
  /// Decision was correct (rejected a dump, watched and it pumped, etc.)
  correct,

  /// Decision was wrong (missed a pump, entered a dump, etc.)
  wrong,

  /// Too early to tell / insufficient data.
  inconclusive,
}

/// A postmortem evaluation of one IBITI decision.
class PostmortemEntry {
  /// SQLite row id (null before first INSERT, set after).
  int? dbId;

  /// Unique ID linking to the original decision (legacy string key).
  final String decisionId;

  /// Foreign key to decisions table in SQLite (null if not linked yet).
  final int? decisionDbId;

  final String symbol;
  final String exchange;

  /// The type of market event that triggered this decision (Phase 3).
  final MarketEventType eventType;

  /// What IBITI decided.
  final IbitiVerdict originalVerdict;

  /// Price when decision was made.
  final double priceAtDecision;

  /// Price 15 minutes after decision (null = not yet checked).
  double? priceAfter15min;

  /// Price 30 minutes after decision.
  double? priceAfter30min;

  /// Price 60 minutes after decision.
  double? priceAfter60min;

  /// Calculated % change at each interval.
  double? get changeAfter15min => priceAfter15min != null && priceAtDecision > 0
      ? ((priceAfter15min! - priceAtDecision) / priceAtDecision) * 100
      : null;

  double? get changeAfter30min => priceAfter30min != null && priceAtDecision > 0
      ? ((priceAfter30min! - priceAtDecision) / priceAtDecision) * 100
      : null;

  double? get changeAfter60min => priceAfter60min != null && priceAtDecision > 0
      ? ((priceAfter60min! - priceAtDecision) / priceAtDecision) * 100
      : null;

  /// Was the decision correct?
  PostmortemOutcome outcome;

  /// Generated lesson from this experience.
  String? lesson;

  /// Market phase during this decision.
  final MarketPhase marketPhase;

  /// When the decision was made.
  final DateTime decidedAt;

  /// When postmortem evaluation was completed.
  DateTime? evaluatedAt;

  /// Whether all price checks are complete.
  bool get isComplete => priceAfter60min != null;

  PostmortemEntry({
    this.dbId,
    required this.decisionId,
    this.decisionDbId,
    required this.symbol,
    required this.exchange,
    this.eventType = MarketEventType.volumeSpike,
    required this.originalVerdict,
    required this.priceAtDecision,
    this.priceAfter15min,
    this.priceAfter30min,
    this.priceAfter60min,
    this.outcome = PostmortemOutcome.inconclusive,
    this.lesson,
    this.marketPhase = MarketPhase.sideways,
    required this.decidedAt,
    this.evaluatedAt,
  });

  Map<String, dynamic> toJson() => {
        'decisionId': decisionId,
        'symbol': symbol,
        'exchange': exchange,
        'eventType': eventType.name,
        'originalVerdict': originalVerdict.name,
        'priceAtDecision': priceAtDecision,
        'priceAfter15min': priceAfter15min,
        'priceAfter30min': priceAfter30min,
        'priceAfter60min': priceAfter60min,
        'outcome': outcome.name,
        'lesson': lesson,
        'marketPhase': marketPhase.name,
        'decidedAt': decidedAt.toIso8601String(),
        'evaluatedAt': evaluatedAt?.toIso8601String(),
      };

  factory PostmortemEntry.fromJson(Map<String, dynamic> json) =>
      PostmortemEntry(
        decisionId: json['decisionId'] as String? ?? '',
        symbol: json['symbol'] as String? ?? '',
        exchange: json['exchange'] as String? ?? '',
        eventType: MarketEventType.values.firstWhere(
          (e) => e.name == json['eventType'],
          orElse: () => MarketEventType.volumeSpike,
        ),
        originalVerdict: IbitiVerdict.values.firstWhere(
          (e) => e.name == json['originalVerdict'],
          orElse: () => IbitiVerdict.reject,
        ),
        priceAtDecision: (json['priceAtDecision'] as num?)?.toDouble() ?? 0,
        priceAfter15min: (json['priceAfter15min'] as num?)?.toDouble(),
        priceAfter30min: (json['priceAfter30min'] as num?)?.toDouble(),
        priceAfter60min: (json['priceAfter60min'] as num?)?.toDouble(),
        outcome: PostmortemOutcome.values.firstWhere(
          (e) => e.name == json['outcome'],
          orElse: () => PostmortemOutcome.inconclusive,
        ),
        lesson: json['lesson'] as String?,
        marketPhase: MarketPhase.values.firstWhere(
          (e) => e.name == json['marketPhase'],
          orElse: () => MarketPhase.sideways,
        ),
        decidedAt: DateTime.tryParse(json['decidedAt'] as String? ?? '') ??
            DateTime.now(),
        evaluatedAt: json['evaluatedAt'] != null
            ? DateTime.tryParse(json['evaluatedAt'] as String)
            : null,
      );
}
