/// Represents the boundaries within which the AI or Automation Engine is permitted
/// to execute actions automatically without explicit user confirmation.
class DelegationScope {
  /// Unique identifier of this delegation scope
  final String id;

  /// Max USD amount the AI can authorize per day/session
  final double maxAmountUsd;

  /// E.g. ['SEND', 'REVOKE']
  final List<String> allowedActions;

  /// Only trusted contracts are allowed (empty means unrestricted)
  final List<String> allowedContracts;

  /// When this scope expires
  final DateTime expiresAt;

  /// Whether the AI still requires real simulation to pass successfully (almost always true)
  final bool requireSimulation;

  /// Amount of USD already consumed by the agent in this scope session
  double usedUsd;

  /// Time when the daily limit tracker was last reset internally
  DateTime lastReset;

  DelegationScope({
    required this.id,
    required this.maxAmountUsd,
    this.allowedActions = const [],
    this.allowedContracts = const [],
    required this.expiresAt,
    this.requireSimulation = true,
    this.usedUsd = 0.0,
    DateTime? lastReset,
  }) : lastReset = lastReset ?? DateTime.now();

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}
