import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/policy/validators/epk_validator.dart';
import 'package:ibiti_guardian/services/policy/validators/epk_validator_result.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';

class TargetSelectorGuard extends EPKValidator {
  const TargetSelectorGuard() : super('TargetSelectorGuard');

  @override
  Future<EpkValidatorResult> validate(
      TransactionRequest tx, EpkState state) async {
    if (!state.hasTargetSelectorGuard) {
      return EpkValidatorResult.pass();
    }

    final toAddress = tx.toAddress.toLowerCase();

    // Self transfers are always allowed
    if (toAddress == tx.fromAddress.toLowerCase()) {
      return EpkValidatorResult.pass();
    }

    final pStore = PolicyProfileStore.instance;
    final profile = pStore.current;

    final isAddressTrusted = profile.trustedAddresses.contains(toAddress);
    final isContractTrusted = profile.trustedContracts.contains(toAddress);

    // Depending on profile mode, evaluate target
    if (profile.mode == PolicyMode.safe) {
      // TRUSTED ONLY
      if (!isAddressTrusted && !isContractTrusted) {
        return EpkValidatorResult.reject(
          reason: 'STRICT_MODE_UNTRUSTED_TARGET',
          userMessage:
              'Vault is in STRICT mode. You can only transact with explicitly whitelisted addresses or contracts.',
          debugDetails: 'Target $toAddress not found in trusted lists.',
        );
      }
    } else if (profile.mode == PolicyMode.defi) {
      // TRUSTED + ALLOW_UNKNOWN_CONTRACTS check
      if (!isAddressTrusted && !isContractTrusted) {
        if (tx.type == TransactionType.approve &&
            !profile.allowUnknownContracts) {
          return EpkValidatorResult.reject(
            reason: 'GUARDED_UNKNOWN_CONTRACT',
            userMessage:
                'Vault is in GUARDED mode. Approvals to unknown/unverified contracts are not permitted.',
          );
        }

        // If it's a send to an unknown address in guarded mode, we allow it to pass to Threat feed
        // Guarded allows transfers to non-whitelisted, relying on threat Intel Blocklist.
      }
    } else if (profile.mode == PolicyMode.advanced) {
      // Unrestricted scope allows sending anywhere
      return EpkValidatorResult.pass();
    }

    return EpkValidatorResult.pass();
  }
}
