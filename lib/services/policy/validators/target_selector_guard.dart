import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/dapp/dapp_verified_receive.dart';
import 'package:ibiti_guardian/services/policy/validators/epk_validator.dart';
import 'package:ibiti_guardian/services/policy/validators/epk_validator_result.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/utils/address_key.dart';

class TargetSelectorGuard extends EPKValidator {
  final DappReceiveEvidence? verifiedReceive;
  const TargetSelectorGuard({this.verifiedReceive}) : super('TargetSelectorGuard');

  @override
  Future<EpkValidatorResult> validate(
      TransactionRequest tx, EpkState state) async {
    if (!state.hasTargetSelectorGuard) {
      return EpkValidatorResult.pass();
    }

    // Only host-produced, fresh exact-receive evidence can qualify. Ordinary
    // sends, approvals and other targets still use the user's existing rules.
    if (verifiedReceive?.matchesContext(tx) ?? false) {
      return EpkValidatorResult.pass();
    }
    // 0x addresses ignore case; Solana / Tron addresses are exact.
    final toAddress = AddressKey.of(tx.toAddress);

    // The user decides where their own money goes. A send or swap started in
    // the wallet's own Send / Swap window, reviewed and confirmed with the PIN,
    // goes to any address or swap route (an exchange deposit, a friend, the
    // swap provider's contracts). The default profile is STRICT and the app
    // has no screen to whitelist an address, so this guard used to refuse
    // every manual send and swap. Manual operations stay bounded by the
    // wallet Send / Swap / Approve limits (policy engine); the threat
    // blocklist they also pass is empty for now. AI, market and dApp requests
    // still face this guard.
    if (tx.sourceIntent.origin == IntentOrigin.wallet) {
      return EpkValidatorResult.pass();
    }

    // Revoking sets an allowance to zero: it can only take permissions away,
    // so a strict whitelist must never stand between the user and a revoke.
    if (tx.type == TransactionType.revoke) {
      return EpkValidatorResult.pass();
    }

    // Self transfers are always allowed
    if (toAddress == AddressKey.of(tx.fromAddress)) {
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
              'This address is not in your trusted addresses. The AI may send '
              'only to trusted addresses: add it in Address book → ⋯ → Trust '
              'for AI (PIN), or Command Center → Trusted addresses.',
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

        // Guarded mode lets sends to unknown addresses through; only the
        // spend limits apply after this. The threat blocklist that runs
        // before this guard is empty for now, so it does not vet the address.
      }
    } else if (profile.mode == PolicyMode.advanced) {
      // Unrestricted scope allows sending anywhere
      return EpkValidatorResult.pass();
    }

    return EpkValidatorResult.pass();
  }
}
