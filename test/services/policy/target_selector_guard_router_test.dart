// Owner decision D12: the official swap routers (0x AllowanceHolder /
// Exchange Proxy, Jupiter, SunSwap) count as trusted contracts for the AI's
// own swaps, so «Автономный» swaps are not refused at signing in the default
// STRICT profile. Only the swap step to the router and the ERC-20 approve
// that lets the router spend a FINITE amount qualify; unlimited approvals,
// other spenders, sends, dApp requests and the wallet's own windows keep
// their old rules.
//
// Run: flutter test test/services/policy/target_selector_guard_router_test.dart

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/execution/native_transaction_builder.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/services/policy/validators/composite_validator.dart';
import 'package:ibiti_guardian/services/policy/validators/epk_validator_result.dart';
import 'package:ibiti_guardian/services/policy/validators/target_selector_guard.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const from = '0x73761dae1912544cbdf2c08129918b83f88d9015';
  // 0x AllowanceHolder: the swap's `to` and the approve spender.
  const allowanceHolder = '0x0000000000001fF3684f28c67538d4D072C22734';
  // 0x Exchange Proxy (v1).
  const exchangeProxy = '0xDef1C0ded9bec7F1a1670819833240f027b25EfF';
  // BSC USDT: the token being approved.
  const token = '0x55d398326f99059fF775485246999027B3197955';
  const untrustedEoa = '0x1111111111111111111111111111111111111111';
  const unknownSpender = '0x2222222222222222222222222222222222222222';

  final tenUsdt = BigInt.from(10) * BigInt.from(10).pow(18);
  final maxUint256 = (BigInt.one << 256) - BigInt.one;

  IntentData aiSwapIntent({IntentOrigin origin = IntentOrigin.market}) =>
      IntentData(
        type: IntentType.swapAsset,
        rawInput: 'swap 10 USDT to BNB',
        sourceTokenSymbol: 'USDT',
        targetTokenSymbol: 'BNB',
        origin: origin,
      );

  // Shaped like SwapIntentBuilder's swap step.
  TransactionRequest swapStep({
    String to = allowanceHolder,
    String? router,
    IntentData? intent,
  }) =>
      TransactionRequest(
        type: TransactionType.swap,
        fromAddress: from,
        toAddress: to,
        tokenSymbol: 'USDT',
        tokenContract: token,
        targetTokenSymbol: 'BNB',
        amount: 10,
        rawAmount: tenUsdt,
        chainId: 56,
        chainKey: 'bsc',
        calldata: Uint8List.fromList(const [0x2c, 0x2a, 0x2b, 0x2c, 0, 1]),
        routerAddress: router ?? to,
        sourceIntent: intent ?? aiSwapIntent(),
      );

  // Shaped like SwapIntentBuilder's approve step (no calldata: the executor
  // encodes approve(spenderAddress, rawAmount) and sends it to the token).
  TransactionRequest approveStep({
    String spender = allowanceHolder,
    BigInt? raw,
    bool noRaw = false,
    bool unlimited = false,
    Uint8List? calldata,
    String? tokenContract = token,
    IntentData? intent,
  }) =>
      TransactionRequest(
        type: TransactionType.approve,
        fromAddress: from,
        toAddress: token,
        tokenSymbol: 'USDT',
        tokenContract: tokenContract,
        amount: 10,
        rawAmount: noRaw ? null : (raw ?? tenUsdt),
        chainId: 56,
        chainKey: 'bsc',
        spenderAddress: spender,
        isUnlimitedApproval: unlimited,
        calldata: calldata,
        sourceIntent: intent ?? aiSwapIntent(),
      );

  Future<EpkValidatorResult> guard(TransactionRequest tx) =>
      const TargetSelectorGuard().validate(tx, const EpkState());

  Future<bool> signerPasses(TransactionRequest tx) async =>
      (await CompositeValidator().validate(tx, const EpkState())).isValid;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('the default profile is STRICT with no trusted contracts', () {
    final profile = PolicyProfileStore.instance.current;
    expect(profile.mode, PolicyMode.safe);
    expect(profile.trustedContracts, isEmpty);
    expect(profile.trustedAddresses, isEmpty);
  });

  group('STRICT profile, AI / market origin', () {
    test('a swap sent to an official router is allowed', () async {
      expect((await guard(swapStep())).isValid, true);
      expect(await signerPasses(swapStep()), true);
      // Any letter case; the Exchange Proxy counts too.
      expect(
          (await guard(swapStep(to: allowanceHolder.toLowerCase()))).isValid,
          true);
      expect((await guard(swapStep(to: exchangeProxy))).isValid, true);
    });

    test('a swap to a contract that is not an official router is refused',
        () async {
      final r = await guard(swapStep(to: unknownSpender));
      expect(r.isValid, false);
      expect(r.rejectionReason, 'STRICT_MODE_UNTRUSTED_TARGET');
    });

    test('a swap whose router differs from an official `to` is refused',
        () async {
      // The signer sends the swap to routerAddress: both must be official.
      final r = await guard(swapStep(router: unknownSpender));
      expect(r.isValid, false);
    });

    test('an approve of a finite amount to an official router is allowed',
        () async {
      expect((await guard(approveStep())).isValid, true);
      expect(await signerPasses(approveStep()), true);
      // The same approve as encoded calldata (spender decoded from it).
      final data =
          NativeTransactionBuilder.buildApproveCalldata(allowanceHolder, tenUsdt);
      expect((await guard(approveStep(calldata: data))).isValid, true);
    });

    test('an unlimited approve to an official router is still refused',
        () async {
      // The flag the executor turns into maxUint256.
      final flagged = await guard(approveStep(unlimited: true));
      expect(flagged.isValid, false);
      expect(flagged.rejectionReason, 'STRICT_MODE_UNLIMITED_APPROVAL');
      expect(await signerPasses(approveStep(unlimited: true)), false);

      // maxUint256 as the amount.
      final maxRaw = await guard(approveStep(raw: maxUint256));
      expect(maxRaw.isValid, false);
      expect(maxRaw.rejectionReason, 'STRICT_MODE_UNLIMITED_APPROVAL');

      // maxUint256 in the calldata.
      final maxData = NativeTransactionBuilder.buildApproveCalldata(
          allowanceHolder, maxUint256);
      expect(
          (await guard(approveStep(calldata: maxData, noRaw: true))).isValid,
          false);

      // Other "infinite" markers (2^255) count as unlimited too.
      expect(
          (await guard(approveStep(raw: BigInt.one << 255))).isValid, false);

      // An unknown amount is never treated as finite.
      expect((await guard(approveStep(noRaw: true))).isValid, false);
    });

    test('an approve to a spender that is not an official router is refused',
        () async {
      final r = await guard(approveStep(spender: unknownSpender));
      expect(r.isValid, false);
      expect(r.rejectionReason, 'STRICT_MODE_UNTRUSTED_TARGET');
      expect(await signerPasses(approveStep(spender: unknownSpender)), false);
    });

    test('calldata that disagrees with the fields is refused', () async {
      // Calldata names another spender than spenderAddress.
      final otherSpender =
          NativeTransactionBuilder.buildApproveCalldata(unknownSpender, tenUsdt);
      expect((await guard(approveStep(calldata: otherSpender))).isValid, false);
      // Calldata grants more than rawAmount.
      final more = NativeTransactionBuilder.buildApproveCalldata(
          allowanceHolder, tenUsdt * BigInt.two);
      expect((await guard(approveStep(calldata: more))).isValid, false);
      // Not approve(address,uint256) at all: transfer(router, amount).
      final transfer = NativeTransactionBuilder.buildTransferCalldata(
          allowanceHolder, tenUsdt);
      expect((await guard(approveStep(calldata: transfer))).isValid, false);
    });

    test('an approve sent to another contract than its token is refused',
        () async {
      // toAddress is the token, but the signer would call tokenContract.
      final r = await guard(approveStep(tokenContract: unknownSpender));
      expect(r.isValid, false);
    });

    test('a send to an untrusted address is still refused', () async {
      final send = TransactionRequest(
        type: TransactionType.send,
        fromAddress: from,
        toAddress: untrustedEoa,
        tokenSymbol: 'USDT',
        tokenContract: token,
        amount: 3,
        rawAmount: BigInt.from(3) * BigInt.from(10).pow(18),
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent: const IntentData(
          type: IntentType.sendAsset,
          rawInput: 'send 3 USDT',
        ),
      );
      final r = await guard(send);
      expect(r.isValid, false);
      expect(r.rejectionReason, 'STRICT_MODE_UNTRUSTED_TARGET');
      expect(await signerPasses(send), false);
    });

    test('a plain send to a router address is not a swap: still refused',
        () async {
      final send = TransactionRequest(
        type: TransactionType.send,
        fromAddress: from,
        toAddress: allowanceHolder,
        tokenSymbol: 'USDT',
        tokenContract: token,
        amount: 3,
        rawAmount: BigInt.from(3) * BigInt.from(10).pow(18),
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent: const IntentData(
          type: IntentType.sendAsset,
          rawInput: 'send 3 USDT',
        ),
      );
      expect((await guard(send)).isValid, false);
    });
  });

  group('dApp requests are unchanged', () {
    // DappWalletBackend projects every call as TransactionType.unknown with
    // IntentData.empty() (origin market) and the raw calldata.
    TransactionRequest dapp(String to, Uint8List data) => TransactionRequest(
          type: TransactionType.unknown,
          fromAddress: from,
          toAddress: to,
          chainId: 56,
          chainKey: 'bsc',
          sourceIntent: IntentData.empty(),
          amount: 0,
          rawAmount: BigInt.zero,
          calldata: data,
        );

    test('a dApp call to an official router is still refused', () async {
      final r = await guard(
          dapp(allowanceHolder, Uint8List.fromList(const [1, 2, 3, 4])));
      expect(r.isValid, false);
      expect(r.rejectionReason, 'STRICT_MODE_UNTRUSTED_TARGET');
    });

    test('a dApp approve of a finite amount to a router is still refused',
        () async {
      final data =
          NativeTransactionBuilder.buildApproveCalldata(allowanceHolder, tenUsdt);
      expect((await guard(dapp(token, data))).isValid, false);
      expect(await signerPasses(dapp(token, data)), false);
    });

    test('an approve step without an intent (system / dApp) never qualifies',
        () async {
      final r = await guard(approveStep(intent: IntentData.empty()));
      expect(r.isValid, false);
      expect(TargetSelectorGuard.isOfficialRouterStep(
              swapStep(intent: IntentData.empty())),
          false);
    });
  });

  test("the wallet's own swap and approve pass as before", () async {
    final own = aiSwapIntent(origin: IntentOrigin.wallet);
    expect((await guard(swapStep(to: unknownSpender, intent: own))).isValid,
        true);
    expect(
        (await guard(approveStep(spender: unknownSpender, intent: own)))
            .isValid,
        true);
    // The wallet path never relies on the router rule.
    expect(TargetSelectorGuard.isOfficialRouterStep(swapStep(intent: own)),
        false);
  });

  group('GUARDED (defi) profile with unknown contracts off', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await PolicyProfileStore.instance.setMode(PolicyMode.defi);
      await PolicyProfileStore.instance.setAllowUnknownContracts(false);
    });

    tearDown(() async {
      await PolicyProfileStore.instance.setMode(PolicyMode.safe);
    });

    test('the router counts as a trusted contract for a finite approve',
        () async {
      expect(PolicyProfileStore.instance.current.allowUnknownContracts, false);
      expect((await guard(approveStep())).isValid, true);
    });

    test('an unlimited approve or another spender is still refused',
        () async {
      final unlimited = await guard(approveStep(unlimited: true));
      expect(unlimited.isValid, false);
      expect(unlimited.rejectionReason, 'GUARDED_UNKNOWN_CONTRACT');
      expect((await guard(approveStep(spender: unknownSpender))).isValid,
          false);
    });
  });
}
