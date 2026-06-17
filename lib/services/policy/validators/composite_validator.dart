import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/policy/validators/epk_validator.dart';
import 'package:ibiti_guardian/services/policy/validators/epk_validator_result.dart';
import 'package:ibiti_guardian/services/policy/validators/spend_limit_validator.dart';
import 'package:ibiti_guardian/services/policy/validators/target_selector_guard.dart';
import 'package:ibiti_guardian/services/policy/validators/threat_feed_blocklist_validator.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';

class CompositeValidator extends EPKValidator {
  final List<EPKValidator> _validators;

  CompositeValidator()
      : _validators = [
          const ThreatFeedBlocklistValidator(), // Highest priority check first
          const TargetSelectorGuard(),
          const SpendLimitValidator(),
        ],
        super('CompositeValidator');

  @override
  Future<EpkValidatorResult> validate(
      TransactionRequest tx, EpkState state) async {
    // If the entire composite system is disabled in UI/State, allow pass
    if (!state.hasCompositeValidator) {
      // Wait, composite validator switch in UI implies evaluating the combination.
      // If disabled, we still run the single ones if they are enabled individually?
      // The UI logic implies they are separate flags.
      // We'll run the child validators regardless of `hasCompositeValidator`,
      // because their individual execution logic checks `state.hasXXX`.
    }

    // Run chronologically
    for (var validator in _validators) {
      final result = await validator.validate(tx, state);
      if (!result.isValid) {
        return result; // Fast fail
      }
    }

    return EpkValidatorResult.pass();
  }
}
