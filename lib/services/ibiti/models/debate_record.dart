// ─── IBITI Debate Record ────────────────────────────────────────────────────────
//
// Inner debate: 4 agents argue, 1 judge decides.
// BullAgent: "why we should enter"
// BearAgent: "why we should NOT enter"
// RiskAgent: "what could go wrong with execution/market"
// ExecutionAgent: "can we even do this safely?"
// FinalJudge: synthesizes all → verdict
//
// Initially deterministic. LLM-powered debate plugs into same interface.
// ─────────────────────────────────────────────────────────────────────────────────

import 'package:ibiti_guardian/services/ibiti/models/ibiti_hypothesis.dart';

/// One agent's argument in the debate.
class DebateArgument {
  /// Which agent made this argument.
  final DebateRole role;

  /// The argument text.
  final String argument;

  /// Strength of the argument (0.0–1.0).
  final double strength;

  /// Supporting data points.
  final List<String> evidence;

  const DebateArgument({
    required this.role,
    required this.argument,
    this.strength = 0.5,
    this.evidence = const [],
  });

  Map<String, dynamic> toJson() => {
        'role': role.name,
        'argument': argument,
        'strength': strength,
        'evidence': evidence,
      };

  factory DebateArgument.fromJson(Map<String, dynamic> json) => DebateArgument(
        role: DebateRole.values.firstWhere(
          (e) => e.name == json['role'],
          orElse: () => DebateRole.bull,
        ),
        argument: json['argument'] as String? ?? '',
        strength: (json['strength'] as num?)?.toDouble() ?? 0.5,
        evidence: (json['evidence'] as List?)?.cast<String>() ?? [],
      );
}

/// Roles in the inner debate.
enum DebateRole {
  bull,
  bear,
  risk,
  execution,
  judge,
}

extension DebateRoleExt on DebateRole {
  String get label => switch (this) {
        DebateRole.bull => '🟢 Bull',
        DebateRole.bear => '🔴 Bear',
        DebateRole.risk => '🟠 Risk',
        DebateRole.execution => '⚙️ Execution',
        DebateRole.judge => '⚖️ Judge',
      };
}

/// Complete record of one inner debate.
class DebateRecord {
  /// All arguments from all agents.
  final List<DebateArgument> arguments;

  /// The judge's final synthesis.
  final String judgeSummary;

  /// The verdict the judge reached.
  final IbitiVerdict verdict;

  /// How contentious the debate was (0.0 = unanimous, 1.0 = deeply split).
  final double contention;

  /// Composite entry quality score (0.0–1.0). Continuous, not discrete.
  /// Used for slot competition: higher = better entry.
  final double entryQuality;

  /// Whether the debate was deterministic or LLM-powered.
  final String source;

  final DateTime debatedAt;

  const DebateRecord({
    required this.arguments,
    required this.judgeSummary,
    required this.verdict,
    this.contention = 0,
    this.entryQuality = 0,
    this.source = 'deterministic',
    required this.debatedAt,
  });

  /// Get argument by role.
  DebateArgument? byRole(DebateRole role) {
    for (final a in arguments) {
      if (a.role == role) return a;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'arguments': arguments.map((a) => a.toJson()).toList(),
        'judgeSummary': judgeSummary,
        'verdict': verdict.name,
        'contention': contention,
        'entryQuality': entryQuality,
        'source': source,
        'debatedAt': debatedAt.toIso8601String(),
      };

  factory DebateRecord.fromJson(Map<String, dynamic> json) => DebateRecord(
        arguments: (json['arguments'] as List?)
                ?.map((a) => DebateArgument.fromJson(a as Map<String, dynamic>))
                .toList() ??
            [],
        judgeSummary: json['judgeSummary'] as String? ?? '',
        verdict: IbitiVerdict.values.firstWhere(
          (e) => e.name == json['verdict'],
          orElse: () => IbitiVerdict.reject,
        ),
        contention: (json['contention'] as num?)?.toDouble() ?? 0,
        entryQuality: (json['entryQuality'] as num?)?.toDouble() ?? 0,
        source: json['source'] as String? ?? 'deterministic',
        debatedAt: DateTime.tryParse(json['debatedAt'] as String? ?? '') ??
            DateTime.now(),
      );
}
