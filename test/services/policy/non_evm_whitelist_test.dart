import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/screens/security/ai_trust_actions.dart';
import 'package:ibiti_guardian/services/execution/guardian_execution_service.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/utils/address_key.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Solana and Tron sends skip the EVM signer, so the AI whitelist is checked
/// just before they are sent: the same rule as on EVM networks.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const solFrom = '7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2';
  const solFriend = 'BPFLoaderUpgradeab1e11111111111111111111111';
  const tronFrom = 'TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7';
  const tronExchange = 'TQrY8tryqsYVCYS3MFbtffiPp2ccyn4STm';

  TransactionRequest tx(
    String chainKey,
    String from,
    String to,
    IntentOrigin origin,
  ) =>
      TransactionRequest(
        type: TransactionType.send,
        fromAddress: from,
        toAddress: to,
        tokenSymbol: chainKey == 'solana' ? 'SOL' : 'TRX',
        amount: 1,
        chainId: 0,
        chainKey: chainKey,
        sourceIntent: IntentData(
          type: IntentType.sendAsset,
          rawInput: 'test',
          origin: origin,
        ),
      );

  Future<String?> check(TransactionRequest t, {bool active = true}) =>
      GuardianExecutionService.nonEvmWhitelistBlock(
          t, EpkState(isActive: active));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    for (final a in [...PolicyProfileStore.instance.current.trustedAddresses]) {
      await PolicyProfileStore.instance.removeTrustedAddress(a);
    }
  });

  test('an AI send on Solana to an untrusted address is stopped', () async {
    final reason = await check(
        tx('solana', solFrom, solFriend, IntentOrigin.market));
    expect(reason, contains('trusted addresses'));
  });

  test('once the owner trusts it, the AI send on Solana goes through',
      () async {
    await PolicyProfileStore.instance.addTrustedAddress(solFriend);
    expect(
        await check(tx('solana', solFrom, solFriend, IntentOrigin.market)),
        isNull);
  });

  test('Tron works the same way', () async {
    final aiSend = tx('tron', tronFrom, tronExchange, IntentOrigin.market);
    expect(await check(aiSend), isNotNull);
    await PolicyProfileStore.instance.addTrustedAddress(tronExchange);
    expect(await check(aiSend), isNull);
  });

  test("the owner's own Solana / Tron sends are never limited", () async {
    expect(
        await check(tx('solana', solFrom, solFriend, IntentOrigin.wallet)),
        isNull);
    expect(
        await check(tx('tron', tronFrom, tronExchange, IntentOrigin.wallet)),
        isNull);
  });

  test('with protection paused the whitelist is off, as on EVM', () async {
    expect(
        await check(tx('solana', solFrom, solFriend, IntentOrigin.market),
            active: false),
        isNull);
  });

  test('a Solana address in another letter case is a different account',
      () async {
    // Base58 is case-sensitive: trusting one account must not let the AI
    // send to a look-alike that differs only in letter case.
    await PolicyProfileStore.instance.addTrustedAddress(solFriend);
    expect(PolicyProfileStore.instance.current.trustedAddresses, [solFriend]);
    final lookAlike = solFriend.toLowerCase();
    expect(
        await check(tx('solana', solFrom, lookAlike, IntentOrigin.market)),
        isNotNull);
    expect(AiTrustActions.isTrusted(lookAlike), false);
    expect(AiTrustActions.isTrusted(solFriend), true);
  });

  test('0x addresses still match in any letter case', () async {
    const evm = '0x195898373cC0c85F7fE7b325C3fE0e1FfF701383';
    expect(AddressKey.same(evm, evm.toLowerCase()), true);
    expect(AddressKey.same(evm, '0X${evm.substring(2).toUpperCase()}'), true);
    expect(AddressKey.same(solFriend, solFriend.toLowerCase()), false);
    expect(AddressKey.same(tronExchange, tronExchange.toLowerCase()), false);
  });

  test('Solana and Tron contacts can be trusted from the address book', () {
    expect(AiTrustActions.canTrust(solFriend), true);
    expect(AiTrustActions.canTrust(tronExchange), true);
    expect(AiTrustActions.canTrust('0x195898373cC0c85F7fE7b325C3fE0e1FfF701383'),
        true);
    expect(AiTrustActions.canTrust('not an address'), false);
  });
}
