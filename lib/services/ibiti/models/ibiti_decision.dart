// ─── IBITI Decision ─────────────────────────────────────────────────────────────
//
// The final decision IBITI makes about a market event.
// Contains the full reasoning chain: event → hypothesis → debate → verdict.
// ─────────────────────────────────────────────────────────────────────────────────

import 'package:ibiti_guardian/services/ibiti/models/market_event.dart';
import 'package:ibiti_guardian/services/ibiti/models/ibiti_hypothesis.dart';
import 'package:ibiti_guardian/services/ibiti/models/debate_record.dart';
import 'package:ibiti_guardian/services/ibiti/models/execution_mode.dart';

/// A complete decision made by IBITI.
class IbitiDecision {
  /// The event that triggered this decision.
  final MarketEvent event;

  /// The hypothesis that was built (if Brain was invoked).
  final IbitiHypothesis? hypothesis;

  /// The debate record (if Debate was invoked).
  final DebateRecord? debate;

  /// Final verdict.
  final IbitiVerdict verdict;

  /// Human-readable reason for the verdict.
  final String reason;

  /// Which constitution rules fired (if any).
  final List<String> rulesFired;

  /// Execution mode at time of decision.
  final ExecutionMode mode;

  /// When the decision was made.
  final DateTime decidedAt;

  /// Whether this decision led to actual execution (paper or real).
  final bool executed;

  /// Price at decision time (for postmortem comparison).
  final double priceAtDecision;

  const IbitiDecision({
    required this.event,
    this.hypothesis,
    this.debate,
    required this.verdict,
    required this.reason,
    this.rulesFired = const [],
    required this.mode,
    required this.decidedAt,
    this.executed = false,
    this.priceAtDecision = 0,
  });

  /// Technical log line (for debug). Human output — use IbitiHumanFormatter.
  String toLogLine() => '[IBITI] ${verdict.label} | '
      '${event.type.label} | ${event.symbol}@${event.exchange} | '
      '\$${priceAtDecision.toStringAsFixed(6)}';

  Map<String, dynamic> toJson() => {
        'event': event.toJson(),
        'hypothesis': hypothesis?.toJson(),
        'debate': debate?.toJson(),
        'verdict': verdict.name,
        'reason': reason,
        'rulesFired': rulesFired,
        'mode': mode.name,
        'decidedAt': decidedAt.toIso8601String(),
        'executed': executed,
        'priceAtDecision': priceAtDecision,
      };

  factory IbitiDecision.fromJson(Map<String, dynamic> json) => IbitiDecision(
        event:
            MarketEvent.fromJson(json['event'] as Map<String, dynamic>? ?? {}),
        hypothesis: json['hypothesis'] != null
            ? IbitiHypothesis.fromJson(
                json['hypothesis'] as Map<String, dynamic>)
            : null,
        debate: json['debate'] != null
            ? DebateRecord.fromJson(json['debate'] as Map<String, dynamic>)
            : null,
        verdict: IbitiVerdict.values.firstWhere(
          (e) => e.name == json['verdict'],
          orElse: () => IbitiVerdict.reject,
        ),
        reason: json['reason'] as String? ?? '',
        rulesFired: (json['rulesFired'] as List?)?.cast<String>() ?? [],
        mode: ExecutionMode.values.firstWhere(
          (e) => e.name == json['mode'],
          orElse: () => ExecutionMode.observeOnly,
        ),
        decidedAt: DateTime.tryParse(json['decidedAt'] as String? ?? '') ??
            DateTime.now(),
        executed: json['executed'] as bool? ?? false,
        priceAtDecision: (json['priceAtDecision'] as num?)?.toDouble() ?? 0,
      );
}
