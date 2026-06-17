/// Represents the route a transaction will take during execution.
/// Crucial for UX transparency and Phase 5 routing.
enum ExecutionPath {
  /// Processed natively via standard logic (no EPK), but guarded by Local Policy,
  /// Preview screens, and manual user confirmation.
  localProtected,

  /// Processed via a specialized smart contract layer applying on-chain
  /// policy enforcement (EPK). Includes preview and confirmation.
  epkProtected,

  /// Fallback mode — EPK is unavailable AND local protected routing failed.
  /// User should be explicitly warned of the standard fallback route.
  fallback;

  /// Returns a user-friendly label for the UI preview card
  String get label {
    switch (this) {
      case ExecutionPath.localProtected:
        return 'Local Protected';
      case ExecutionPath.epkProtected:
        return 'EPK Protected';
      case ExecutionPath.fallback:
        return 'Standard Fallback';
    }
  }
}
