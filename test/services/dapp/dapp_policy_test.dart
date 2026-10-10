import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/services/dapp/dapp_policy.dart';
import 'package:ibiti_guardian/services/dapp/dapp_protocol.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';

const account = '0x1111111111111111111111111111111111111111';
const target = '0x2222222222222222222222222222222222222222';
final instant = DateTime(2026, 10, 8, 12);

void main() {
  late DappTransaction tx;
  late PolicyProfile profile;
  late EpkState epk;
  late double? spend;
  late bool unknown;
  void check() => DappPolicy.check(
      tx: tx,
      profile: profile,
      epk: epk,
      spendUsd: spend,
      unknownSpend: unknown,
      now: instant);
  final rejected =
      throwsA(isA<DappError>().having((e) => e.code, 'code', 4100));
  setUp(() {
    tx = DappTransaction.parse({'from': account, 'to': target}, account, 56);
    profile = PolicyProfile.defi();
    epk = const EpkState();
    spend = 10;
    unknown = false;
  });
  test('ordinary priced transfer respects both policy layers',
      () => expect(check, returnsNormally));
  test('Panic/protection pause blocks even a trusted zero-value call', () {
    epk = epk.copyWith(isActive: false);
    spend = 0;
    profile = profile.copyWith(trustedContracts: [target]);
    expect(check, rejected);
  });
  test('Safe profile requires a trusted address', () {
    profile = PolicyProfile.safe();
    expect(check, rejected);
    profile = profile.copyWith(trustedAddresses: [target]);
    expect(check, returnsNormally);
  });
  test('contract calls do not bypass disallowed unknown contracts', () {
    tx = DappTransaction.parse(
        {'from': account, 'to': target, 'data': '0xabcdef01'}, account, 56);
    epk = epk.copyWith(hasSpendLimitValidator: false);
    profile = profile.copyWith(allowUnknownContracts: false);
    unknown = true;
    spend = 0;
    expect(check, rejected);
    profile = profile.copyWith(trustedContracts: [target]);
    expect(check, returnsNormally);
  });
  test(
      'unknown calldata is not a fake zero-dollar transaction under EPK limits',
      () {
    tx = DappTransaction.parse(
        {'from': account, 'to': target, 'data': '0xabcdef01'}, account, 56);
    unknown = true;
    spend = 0;
    profile = profile.copyWith(trustedContracts: [target]);
    expect(check, rejected);
  });
  for (final amount in <double?>[null, double.nan, double.infinity, -1]) {
    test('missing/nonfinite/negative valuation $amount fails closed', () {
      spend = amount;
      expect(check, rejected);
    });
  }
  test('per-transaction EPK limit is enforced', () {
    spend = 101;
    expect(check, rejected);
  });
  test('daily accumulated spend is enforced', () {
    epk = epk.copyWith(spentTodayUsd: 495, lastSpendResetDate: '2026-10-8');
    expect(check, rejected);
  });
  test('previous day spend does not pollute today', () {
    epk = epk.copyWith(spentTodayUsd: 495, lastSpendResetDate: '2026-10-7');
    expect(check, returnsNormally);
  });
  test('profile send limit and expiry remain effective', () {
    profile = profile.copyWith(sendLimitUsd: 5);
    expect(check, rejected);
    profile =
        profile.copyWith(sendLimitUsd: 50, actionExpiries: {'SEND': instant});
    expect(check, rejected);
  });
  test('unlimited approve is never released to a website', () {
    tx = DappTransaction.parse({
      'from': account,
      'to': target,
      'data': '0x095ea7b3${'0' * 24}${target.substring(2)}${'f' * 64}'
    }, account, 56);
    spend = 0;
    expect(check, rejected);
  });
  test('bounded approve uses approve limit, not send limit', () {
    tx = DappTransaction.parse({
      'from': account,
      'to': target,
      'data': '0x095ea7b3${'0' * 24}${target.substring(2)}${'0' * 63}1'
    }, account, 56);
    profile = profile.copyWith(sendLimitUsd: 0, approveLimitUsd: 15);
    expect(check, returnsNormally);
    profile = profile.copyWith(approveLimitUsd: 5);
    expect(check, rejected);
  });
  test('trusted token contract cannot bypass Safe recipient restrictions', () {
    tx = DappTransaction.parse({
      'from': account,
      'to': target,
      'data': '0xa9059cbb${'0' * 24}${account.substring(2)}${'0' * 63}1'
    }, account, 56);
    profile = PolicyProfile.safe().copyWith(trustedContracts: [target]);
    expect(check, rejected);
    profile = profile.copyWith(trustedAddresses: [account]);
    expect(check, returnsNormally);
  });
  test(
      'verified token cannot authorize an untrusted spender when unknown contracts are forbidden',
      () {
    tx = DappTransaction.parse({
      'from': account,
      'to': target,
      'data': '0x095ea7b3${'0' * 24}${account.substring(2)}${'0' * 63}1'
    }, account, 56);
    profile = profile
        .copyWith(allowUnknownContracts: false, trustedContracts: [target]);
    expect(check, rejected);
    profile = profile.copyWith(trustedContracts: [target, account]);
    expect(check, returnsNormally);
  });
  test('corrupt limits cannot silently disable protection', () {
    profile = profile.copyWith(sendLimitUsd: double.nan);
    expect(check, rejected);
    profile = PolicyProfile.defi();
    epk = epk.copyWith(dailyLimit: double.infinity);
    expect(check, rejected);
  });
}
