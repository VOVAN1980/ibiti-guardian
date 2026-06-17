// ─── IBITI Pattern Lesson ────────────────────────────────────────────────────────
//
// A lesson learned from experience. Tagged with market phase so lessons
// from bull markets don't poison bear market decisions.
// ─────────────────────────────────────────────────────────────────────────────────

import 'package:ibiti_guardian/services/ibiti/models/market_event.dart';
import 'package:ibiti_guardian/services/ibiti/models/market_phase.dart';

/// A single lesson IBITI has learned.
class PatternLesson {
  /// Unique ID for this lesson.
  final String id;

  /// The pattern that was observed, e.g. "vertical_candle_after_120pct".
  final String pattern;

  /// What IBITI learned, e.g. "require consolidation before entry".
  final String lesson;

  /// Which event type this lesson applies to.
  final MarketEventType? relatedEventType;

  /// Which token this lesson is about (null = applies globally).
  final String? symbol;

  /// Market phase when this lesson was learned.
  final MarketPhase learnedInPhase;

  /// Weight adjustment for scoring (-1.0 to +1.0).
  /// Negative = penalty (avoid), Positive = bonus (favour).
  final double ruleWeight;

  /// How many times this lesson has been confirmed by subsequent postmortems.
  int confirmations;

  /// Confidence in this lesson (0.0–1.0).
  /// Starts at 0.5. Grows with confirmations, decays without them.
  /// Lessons with confidence < 0.1 are considered dead.
  double confidence;

  /// When this lesson was first learned.
  final DateTime learnedAt;

  /// When this lesson was last confirmed or updated.
  DateTime lastConfirmedAt;

  PatternLesson({
    required this.id,
    required this.pattern,
    required this.lesson,
    this.relatedEventType,
    this.symbol,
    this.learnedInPhase = MarketPhase.sideways,
    this.ruleWeight = 0,
    this.confirmations = 1,
    this.confidence = 1.0, // Start with full confidence in a new lesson.
    DateTime? learnedAt,
    DateTime? lastConfirmedAt,
  })  : learnedAt = learnedAt ?? DateTime.now(),
        lastConfirmedAt = lastConfirmedAt ?? DateTime.now();

  /// Effective weight — degrades over time if not confirmed.
  /// Now factors in confidence: dead lessons have near-zero influence.
  double get effectiveWeight {
    final daysSinceConfirm = DateTime.now().difference(lastConfirmedAt).inDays;
    // Weight decays by 10% per week without confirmation.
    final decay = (1.0 - (daysSinceConfirm / 70)).clamp(0.1, 1.0);
    return ruleWeight * decay * confidence;
  }

  /// Whether this lesson is effectively dead and should be cleaned up.
  bool get isDead => confidence < 0.1;

  /// Strengthen confidence when a postmortem confirms this lesson.
  void confirm() {
    confirmations++;
    confidence = (confidence + 0.1).clamp(0.0, 1.0);
    lastConfirmedAt = DateTime.now();
  }

  /// Weaken confidence when a postmortem contradicts this lesson.
  void contradict() {
    confidence = (confidence - 0.15).clamp(0.0, 1.0);
    lastConfirmedAt = DateTime.now();
  }

  /// Apply weekly time decay. Call during hourly hygiene.
  /// Decays by 5% per week (~0.7% per day) without confirmation.
  void applyTimeDecay() {
    final daysSinceConfirm = DateTime.now().difference(lastConfirmedAt).inDays;
    if (daysSinceConfirm >= 7) {
      final weeks = daysSinceConfirm / 7;
      // Each unconfirmed week costs 5% confidence.
      final weeklyDecay = 0.05 * weeks;
      confidence = (confidence - weeklyDecay).clamp(0.0, 1.0);
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'pattern': pattern,
        'lesson': lesson,
        'relatedEventType': relatedEventType?.name,
        'symbol': symbol,
        'learnedInPhase': learnedInPhase.name,
        'ruleWeight': ruleWeight,
        'confirmations': confirmations,
        'confidence': confidence,
        'learnedAt': learnedAt.toIso8601String(),
        'lastConfirmedAt': lastConfirmedAt.toIso8601String(),
      };

  factory PatternLesson.fromJson(Map<String, dynamic> json) => PatternLesson(
        id: json['id'] as String? ?? '',
        pattern: json['pattern'] as String? ?? '',
        lesson: json['lesson'] as String? ?? '',
        relatedEventType: json['relatedEventType'] != null
            ? MarketEventType.values.firstWhere(
                (e) => e.name == json['relatedEventType'],
                orElse: () => MarketEventType.volumeSpike,
              )
            : null,
        symbol: json['symbol'] as String?,
        learnedInPhase: MarketPhase.values.firstWhere(
          (e) => e.name == json['learnedInPhase'],
          orElse: () => MarketPhase.sideways,
        ),
        ruleWeight: (json['ruleWeight'] as num?)?.toDouble() ?? 0,
        confirmations: json['confirmations'] as int? ?? 1,
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0.5,
        learnedAt: DateTime.tryParse(json['learnedAt'] as String? ?? ''),
        lastConfirmedAt:
            DateTime.tryParse(json['lastConfirmedAt'] as String? ?? ''),
      );
}
