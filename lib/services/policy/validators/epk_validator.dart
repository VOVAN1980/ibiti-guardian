import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/policy/validators/epk_validator_result.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';

/// Base interface for all Local EPK Fallback Validators.
/// Ensures consistent execution structure that can later be mapped to Solidity logic.
abstract class EPKValidator {
  final String validatorName;

  const EPKValidator(this.validatorName);

  /// Validates the given transaction against the current EpkState.
  Future<EpkValidatorResult> validate(TransactionRequest tx, EpkState state);
}
