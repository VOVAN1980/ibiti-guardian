/// Local representation of an active EPK rule governing the execution enforcement layer.
/// Used for UI explanations and audit trails.
class EpkRuleSnapshot {
  /// Unique identifier of the on-chain rule (e.g. 'LIMIT_GLOBAL_500')
  final String ruleId;

  /// Human-readable explanation of what the EPK rule enforces
  final String description;

  /// Whether this rule is currently strictly blocking execution
  final bool isBlocking;

  /// Severity context, mapped from the enforcement layer
  final String severityLevel;

  const EpkRuleSnapshot({
    required this.ruleId,
    required this.description,
    this.isBlocking = false,
    this.severityLevel = 'INFO',
  });
}
