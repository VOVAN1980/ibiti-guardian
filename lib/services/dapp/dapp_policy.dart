import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'dapp_protocol.dart';
import 'dapp_verified_receive.dart';

/// Local dApp gate. It does not change AI permissions or existing wallet rules.
class DappPolicy {
  static void check(
      {required DappTransaction tx,
      required PolicyProfile profile,
      required EpkState epk,
      required double? spendUsd,
      required bool unknownSpend,
      bool contractCall = false,
      DappReceiveEvidence? verifiedReceive,
      DateTime? now}) {
    if (!epk.isActive) {
      throw const DappError(4100, 'Guardian protection is paused.');
    }
    final trusted = [...profile.trustedAddresses, ...profile.trustedContracts]
        .any((a) => a.toLowerCase() == tx.to.toLowerCase());
    final receiving = verifiedReceive?.matches(tx, now: now) ?? false;
    if (verifiedReceive != null && !receiving) {
      throw const DappError(4100, 'Withdrawal simulation is no longer fresh.');
    }
    // A proved receive may reach native one-time consent. This never changes
    // the profile and does not authorize signing; the backend consumes consent.
    if (!receiving && (profile.mode == PolicyMode.safe && !trusted ||
        tx.data != '0x' && !trusted && !profile.allowUnknownContracts)) {
      throw const DappError(
          4100, 'Your policy does not allow this contract or address.');
    }
    final tokenRecipient = tx.tokenRecipient;
    if (tokenRecipient != null) {
      final recipientTrusted = [
        ...profile.trustedAddresses,
        ...profile.trustedContracts
      ].any((a) => a.toLowerCase() == tokenRecipient.toLowerCase());
      if (!recipientTrusted &&
          (profile.mode == PolicyMode.safe ||
              tx.isApproval && !profile.allowUnknownContracts)) {
        throw const DappError(4100,
            'Your policy does not allow this token recipient or spender.');
      }
    }
    // An estimateGas success is not proof of token balance changes. Never use
    // zero native value as a fake zero-USD spend for arbitrary contract calls.
    if (unknownSpend && epk.hasSpendLimitValidator) {
      throw const DappError(4100,
          'EPK cannot verify this contract call against your spending limits.');
    }
    if (spendUsd == null || !spendUsd.isFinite || spendUsd < 0) {
      throw const DappError(
          4100, 'The outgoing amount cannot be priced safely.');
    }
    final action = tx.isApproval
        ? 'APPROVE'
        : unknownSpend || contractCall
            ? 'SWAP'
            : 'SEND';
    final limit = tx.isApproval
        ? profile.approveLimitUsd
        : unknownSpend || contractCall
            ? profile.swapLimitUsd
            : profile.sendLimitUsd;
    final instant = now ?? DateTime.now();
    if (!limit.isFinite ||
        limit < 0 ||
        epk.hasSpendLimitValidator &&
            (!epk.perTxLimit.isFinite ||
                epk.perTxLimit < 0 ||
                !epk.dailyLimit.isFinite ||
                epk.dailyLimit < 0 ||
                !epk.spentTodayUsd.isFinite ||
                epk.spentTodayUsd < 0)) {
      throw const DappError(4100, 'Invalid policy spending limit.');
    }
    final expiry = profile.actionExpiries[action];
    if (expiry != null && !instant.isBefore(expiry) ||
        tx.isUnlimitedApproval ||
        spendUsd > limit) {
      throw const DappError(
          4100, 'The transaction exceeds your active policy limit.');
    }
    if (epk.hasSpendLimitValidator) {
      final date = '${instant.year}-${instant.month}-${instant.day}';
      final spent = epk.lastSpendResetDate == date ? epk.spentTodayUsd : 0.0;
      if (spendUsd > epk.perTxLimit ||
          (!tx.isApproval && spent + spendUsd > epk.dailyLimit)) {
        throw const DappError(
            4100, 'The transaction exceeds your EPK spending limit.');
      }
    }
  }
}
