import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/dapp/dapp_verified_receive.dart';
import 'package:ibiti_guardian/services/policy/validators/epk_validator.dart';
import 'package:ibiti_guardian/services/policy/validators/epk_validator_result.dart';
import 'package:ibiti_guardian/services/security/ai_action_gate.dart'
    show AiActionGate;
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
    // Owner decision D12: the official swap routers count as trusted
    // contracts for the AI's own swaps (the swap step and its exact-amount
    // approve step), so «Автономный» swaps work in the STRICT profile too.
    final isContractTrusted = profile.trustedContracts.contains(toAddress) ||
        isOfficialRouterStep(tx);

    // Depending on profile mode, evaluate target
    if (profile.mode == PolicyMode.safe) {
      // TRUSTED ONLY
      if (!isAddressTrusted && !isContractTrusted) {
        if (_approvesOfficialRouterWithoutLimit(tx)) {
          return EpkValidatorResult.reject(
            reason: 'STRICT_MODE_UNLIMITED_APPROVAL',
            userMessage:
                'The AI may let a swap router spend only the exact swap '
                'amount, never an unlimited amount.',
            debugDetails: 'Unlimited / unknown approve amount to router '
                '${tx.spenderAddress ?? toAddress}.',
          );
        }
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

  // ── Official swap routers (D12) ────────────────────────────────────────────

  /// approve(address,uint256) = 0x095ea7b3.
  static const List<int> _approveSelector = [0x09, 0x5e, 0xa7, 0xb3];

  /// An allowance at or above 2^128 counts as unlimited: no real swap amount
  /// comes close, while the "infinite" markers (2^256 − 1, 2^255, uint160
  /// max) are all above it.
  static final BigInt _unlimitedFloor = BigInt.one << 128;

  /// True for one step of the AI's own swap through an official swap router
  /// ([AiActionGate.isOfficialSwapRouter]): AI, market chat, voice or
  /// automation, never the wallet's own windows (they pass earlier) and
  /// never a dApp request (the dApp backend projects its calls as
  /// [TransactionType.unknown] with an empty intent).
  ///
  /// - The swap transaction: sent to an official router (its `to` and the
  ///   router the signer sends it to).
  /// - The ERC-20 `approve(spender, amount)`: to any token contract, when the
  ///   spender is an official router and the amount is FINITE. An unlimited
  ///   approval never qualifies; the finite one is still held to the Approve
  ///   limit by the policy engine (GuardianPolicyEngine._checkApproveV3).
  static bool isOfficialRouterStep(TransactionRequest tx) {
    if (tx.sourceIntent.origin == IntentOrigin.wallet) return false;
    if (tx.sourceIntent.type == IntentType.unknown) return false;
    switch (tx.type) {
      case TransactionType.swap:
        // The signer sends the swap to routerAddress (buildSwapParams).
        return AiActionGate.isOfficialSwapRouter(tx.toAddress) &&
            AiActionGate.isOfficialSwapRouter(
                tx.routerAddress ?? tx.toAddress);
      case TransactionType.approve:
        final token = tx.tokenContract?.trim() ?? '';
        // The signer sends the approve to tokenContract (buildApproveParams).
        if (token.isNotEmpty && !AddressKey.same(token, tx.toAddress)) {
          return false;
        }
        final approval = _approvalOf(tx);
        return approval != null &&
            AiActionGate.isOfficialSwapRouter(approval.spender) &&
            _isFiniteAllowance(approval.amount);
      case TransactionType.send:
      case TransactionType.revoke:
      case TransactionType.unknown:
        return false;
    }
  }

  /// An approve that names an official router as the spender but grants it
  /// an unlimited (or unknown) amount: refused with its own reason.
  static bool _approvesOfficialRouterWithoutLimit(TransactionRequest tx) {
    if (tx.type != TransactionType.approve) return false;
    final approval = _approvalOf(tx);
    return approval != null &&
        AiActionGate.isOfficialSwapRouter(approval.spender) &&
        !_isFiniteAllowance(approval.amount);
  }

  static bool _isFiniteAllowance(BigInt? amount) =>
      amount != null && !amount.isNegative && amount < _unlimitedFloor;

  /// The spender and the amount an approve step grants. From its calldata
  /// when it carries one (exactly `approve(address,uint256)`), else from the
  /// fields the signer encodes (spenderAddress, rawAmount). Null when the
  /// spender is missing or the calldata and the fields disagree. A null
  /// amount means unlimited or unknown.
  static ({String spender, BigInt? amount})? _approvalOf(
      TransactionRequest tx) {
    final fieldSpender = tx.spenderAddress?.trim() ?? '';
    final fieldAmount = tx.isUnlimitedApproval ? null : tx.atomicAmount;
    final data = tx.calldata;
    if (data == null || data.isEmpty) {
      if (fieldSpender.isEmpty) return null;
      return (spender: fieldSpender, amount: fieldAmount);
    }
    final call = _decodeApprove(data);
    if (call == null) return null;
    if (fieldSpender.isNotEmpty &&
        !AddressKey.same(fieldSpender, call.spender)) {
      return null;
    }
    if (tx.isUnlimitedApproval) return (spender: call.spender, amount: null);
    if (fieldAmount != null && fieldAmount != call.amount) return null;
    return call;
  }

  /// Decodes `approve(address,uint256)` calldata; null for anything else.
  static ({String spender, BigInt? amount})? _decodeApprove(List<int> data) {
    if (data.length != 68) return null;
    for (var i = 0; i < 4; i++) {
      if (data[i] != _approveSelector[i]) return null;
    }
    // An address word is 12 zero bytes, then the 20 address bytes.
    for (var i = 4; i < 16; i++) {
      if (data[i] != 0) return null;
    }
    return (
      spender: '0x${_hex(data.sublist(16, 36))}',
      amount: BigInt.parse(_hex(data.sublist(36, 68)), radix: 16),
    );
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
