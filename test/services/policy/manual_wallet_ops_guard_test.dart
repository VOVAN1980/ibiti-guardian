import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/services/policy/validators/composite_validator.dart';
import 'package:ibiti_guardian/services/policy/validators/spend_limit_validator.dart';
import 'package:ibiti_guardian/services/policy/validators/target_selector_guard.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';

/// The default profile is STRICT and EPK protection is on by default. The
/// user's own Send / Swap from the wallet windows must still reach any
/// address (an exchange deposit, a friend); AI / market / dApp requests keep
/// the strict whitelist.
void main() {
  const from = '0x73761dae1912544cbdf2c08129918b83f88d9015';
  const exchangeDeposit = '0x1111111111111111111111111111111111111111';

  TransactionRequest tx({
    required TransactionType type,
    required IntentOrigin origin,
    String symbol = 'USDT',
    double amount = 3,
  }) =>
      TransactionRequest(
        type: type,
        fromAddress: from,
        toAddress: exchangeDeposit,
        tokenSymbol: symbol,
        amount: amount,
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent: IntentData(
          type: IntentType.sendAsset,
          rawInput: 'test',
          origin: origin,
        ),
      );

  test('default profile is strict with an empty whitelist', () {
    final profile = PolicyProfileStore.instance.current;
    expect(profile.mode, PolicyMode.safe);
    expect(profile.trustedAddresses, isEmpty);
  });

  test('manual wallet send reaches a non-whitelisted address', () async {
    final result = await CompositeValidator().validate(
        tx(type: TransactionType.send, origin: IntentOrigin.wallet),
        const EpkState());
    expect(result.isValid, true);
  });

  test('manual wallet BNB send is not refused by the stablecoin-only check',
      () async {
    final result = await const SpendLimitValidator().validate(
        tx(
            type: TransactionType.send,
            origin: IntentOrigin.wallet,
            symbol: 'BNB',
            amount: 0.005),
        const EpkState());
    expect(result.isValid, true);
  });

  test('manual wallet swap passes the whitelist', () async {
    final result = await const TargetSelectorGuard().validate(
        tx(type: TransactionType.swap, origin: IntentOrigin.wallet),
        const EpkState());
    expect(result.isValid, true);
  });

  test('AI / market send to a non-whitelisted address is still refused',
      () async {
    final result = await CompositeValidator().validate(
        tx(type: TransactionType.send, origin: IntentOrigin.market),
        const EpkState());
    expect(result.isValid, false);
  });

  test('a revoke is never stopped by the whitelist', () async {
    final result = await const TargetSelectorGuard().validate(
        tx(type: TransactionType.revoke, origin: IntentOrigin.market),
        const EpkState());
    expect(result.isValid, true);
  });
}
