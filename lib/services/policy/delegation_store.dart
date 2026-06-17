import 'package:ibiti_guardian/models/delegation_scope.dart';

/// Define the storage strategy for AI delegation bounds.
/// Abstract ready to migrate to persistent JSON store in later phases.
abstract class DelegationStore {
  /// Loads the active session delegation scope.
  DelegationScope? getActive();

  /// Applies a newly constrained behavior box to the AI.
  void setScope(DelegationScope scope);

  /// Strips the AI of its autonomous execution capabilities.
  void clear();
}

/// Phase 6 implementation storing limits persistently strictly only for the active app session layer.
class InMemoryDelegationStore implements DelegationStore {
  DelegationScope? _currentScope;

  @override
  DelegationScope? getActive() {
    if (_currentScope != null && _currentScope!.isExpired) {
      clear(); // automatic cleanup
      return null;
    }
    return _currentScope;
  }

  @override
  void setScope(DelegationScope scope) {
    _currentScope = scope;
  }

  @override
  void clear() {
    _currentScope = null;
  }
}
