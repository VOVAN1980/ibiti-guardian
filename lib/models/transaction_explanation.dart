import 'package:ibiti_guardian/services/policy/guardian_policy_engine.dart';

/// The human-readable explanation of a transaction, built by [TransactionExplainer].
/// Shown in [TransactionPreviewCard] before the user confirms.
class TransactionExplanation {
  /// Short title for the preview card header.
  final String headline;

  /// One or two clear sentences describing the action in plain language.
  final String detail;

  /// Human-readable explanation of what the user is signing.
  final String signingExplanation;

  /// Human-readable summary of the expected on-chain effect.
  final String expectedOutcome;

  /// Human-readable simulation or preflight result.
  final String simulationSummary;

  /// One-line risk summary shown near the bottom of the card.
  final String riskSummary;

  /// Severity drives the colored header strip in the UI.
  final PolicySeverity severity;

  /// Bullet-point warnings derived from simulation flags.
  final List<String> warnings;

  const TransactionExplanation({
    required this.headline,
    required this.detail,
    required this.signingExplanation,
    required this.expectedOutcome,
    required this.simulationSummary,
    required this.riskSummary,
    required this.severity,
    required this.warnings,
  });

  bool get hasWarnings => warnings.isNotEmpty;
}
