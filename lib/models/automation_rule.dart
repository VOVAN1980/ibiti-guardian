import 'package:ibiti_guardian/models/delegation_scope.dart';

/// Define an automated triggered event mapped to a consequence action within a delegated scope.
class AutomationRule {
  final String id;

  /// The logical trigger string representing on-chain or external events
  /// e.g. "price_drop", "approval_detected", "high_risk_event"
  final String trigger;

  /// The resulting text intent or action identifier dispatched to the AI parser
  /// e.g. "alert user about high risk", "revoke malicious spender immediately"
  final String action;

  /// The strict permission boundaries dictating if the agent can execute the resulting action
  final DelegationScope? scope;

  /// Indicates if this rule must automatically attempt background execution,
  /// or if it simply generates an alert bubble.
  final bool autoExecute;

  /// If sandbox demotes the automation decision, should it present manual UI verification?
  final bool requireConfirmationFallback;

  const AutomationRule({
    required this.id,
    required this.trigger,
    required this.action,
    this.scope,
    this.autoExecute = false,
    this.requireConfirmationFallback = true,
  });
}
