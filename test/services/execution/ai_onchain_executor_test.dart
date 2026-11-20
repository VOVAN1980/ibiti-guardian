// AiOnchainExecutor: on-chain operations the AI runs in «Автономный» mode,
// always through AiActionGate, plus the controller's no-PIN hard check (C4).
//
// Run: flutter test test/services/execution/ai_onchain_executor_test.dart

import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/models/swap_execution_plan.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/execution/ai_onchain_executor.dart';
import 'package:ibiti_guardian/services/execution/guardian_execution_controller.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/services/policy/tx_usd_valuer.dart';
import 'package:ibiti_guardian/services/security/ai_action_gate.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/swap/swap_provider.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _owner = '0x73761dae1912544cbdf2c08129918b83f88d9015';
const _card2 = '0x2222222222222222222222222222222222222222';
const _trusted = '0x1111111111111111111111111111111111111111';
const _stranger = '0x3333333333333333333333333333333333333333';
const _usdt = '0x55d398326f99059fF775485246999027B3197955';
const _allowanceHolder = '0x0000000000001fF3684f28c67538d4D072C22734';
const _unknownRouter = '0x4444444444444444444444444444444444444444';

TransactionRequest _send({
  String to = _trusted,
  double amount = 10,
  String symbol = 'USDT',
  String chainKey = 'bsc',
}) =>
    TransactionRequest(
      type: TransactionType.send,
      fromAddress: _owner,
      toAddress: to,
      tokenSymbol: symbol,
      tokenContract: _usdt,
      amount: amount,
      rawAmount: BigInt.from(amount * 1000) * BigInt.from(10).pow(15),
      chainId: chainKey == 'eth' ? 1 : 56,
      chainKey: chainKey,
      sourceIntent: const IntentData(
        type: IntentType.sendAsset,
        rawInput: 'send',
      ),
    );

TransactionRequest _revoke() => const TransactionRequest(
      type: TransactionType.revoke,
      fromAddress: _owner,
      toAddress: _usdt,
      tokenSymbol: 'USDT',
      tokenContract: _usdt,
      spenderAddress: _stranger,
      chainId: 56,
      chainKey: 'bsc',
      sourceIntent: IntentData(
        type: IntentType.revokeApproval,
        rawInput: 'revoke',
      ),
    );

TransactionRequest _approve({String spender = _allowanceHolder}) =>
    TransactionRequest(
      type: TransactionType.approve,
      fromAddress: _owner,
      toAddress: _usdt,
      tokenSymbol: 'USDT',
      tokenContract: _usdt,
      amount: 20,
      rawAmount: BigInt.from(20) * BigInt.from(10).pow(18),
      spenderAddress: spender,
      chainId: 56,
      chainKey: 'bsc',
      sourceIntent: const IntentData(
        type: IntentType.swapAsset,
        rawInput: 'swap',
      ),
    );

TransactionRequest _swap({
  String from = 'USDT',
  String to = 'BNB',
  String router = _allowanceHolder,
  double amount = 20,
}) =>
    TransactionRequest(
      type: TransactionType.swap,
      fromAddress: _owner,
      toAddress: router,
      routerAddress: router,
      tokenSymbol: from,
      tokenContract: _usdt,
      targetTokenSymbol: to,
      amount: amount,
      rawAmount: BigInt.from(amount) * BigInt.from(10).pow(18),
      chainId: 56,
      chainKey: 'bsc',
      quoteSummary: {
        'quoteTimestamp': DateTime.now().toUtc().toIso8601String(),
      },
      sourceIntent: const IntentData(
        type: IntentType.swapAsset,
        rawInput: 'swap',
      ),
    );

SwapExecutionPlan _plan({bool withApprove = true, String router = _allowanceHolder}) =>
    SwapExecutionPlan(
      quote: QuoteResponse(
        expectedOutputAmount: BigInt.from(1),
        minOutputAmount: BigInt.from(1),
        routerAddress: router,
        allowanceTarget: router,
        calldata: Uint8List(0),
        nativeValue: BigInt.zero,
        priceImpactPct: 0.1,
        gasEstimate: BigInt.from(200000),
        approvalNeeded: withApprove,
        providerName: '0x AllowanceHolder',
        quoteTimestamp: DateTime.now().toUtc(),
        routeSummary: 'USDT → BNB',
        extraSummary: const {'gasPriceWei': '1000000000'},
      ),
      approveStep: withApprove ? _approve(spender: router) : null,
      swapStep: _swap(router: router),
    );

AssistantResponse _txPreview(TransactionRequest tx) => AssistantResponse(
      message: 'Please review',
      type: ResponseType.preview,
      pendingTransaction: tx,
      executionPath: ExecutionPath.localProtected,
    );

AssistantResponse _swapPreview(SwapExecutionPlan plan) => AssistantResponse(
      message: 'Review the swap',
      type: ResponseType.preview,
      pendingTransaction: plan.swapStep,
      swapPlan: plan,
      executionPath: ExecutionPath.localProtected,
    );

AssistantResponse _sent(String hash) => AssistantResponse(
      message: 'sent',
      type: ResponseType.action,
      detail: hash,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final executor = AiOnchainExecutor.instance;
  final gate = AiActionGate.instance;

  late List<String> calls;
  late List<bool> trustedFlags;
  late int cards;
  late bool cardAnswer;
  late List<String> notifications;

  void useSettings({AiMode mode = AiMode.fullAutonomy, bool pin = true}) {
    AiControlService.instance.setSettingsForTest(AiControlSettings(
      mode: mode,
      dailyLimit: 10000,
      aiPinConfirm: pin,
    ));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    IBITIVaultService.instance.setVaultCreatedForTest(
      evmAddress: _owner,
      evmCardAddresses: [_owner, _card2],
    );
    await EPKPolicyManager.instance.resumeProtection();
    await PolicyProfileStore.instance.addTrustedAddress(_trusted);
    DelegationController.instance.resetUsageForTest();
    TxUsdValuer.priceOverrideForTest = (_) => 1.0;
    useSettings();

    calls = [];
    trustedFlags = [];
    cards = 0;
    cardAnswer = true;
    notifications = [];

    gate.resetForTest();
    gate.foregroundOverride = () => true;
    gate.confirmUiOverride = (s) async {
      cards++;
      return cardAnswer;
    };
    gate.notifyOverride = (title, body) => notifications.add(title);

    executor.resetForTest();
    executor.privySessionOverride = () async => true;
    executor.preflightOverride = (_) => null;
    executor.txRunnerOverride = (tx, path, {required requireTrustedTarget}) async {
      calls.add(tx.type.name);
      trustedFlags.add(requireTrustedTarget);
      return _sent('0xabc');
    };
    executor.swapStepRunnerOverride =
        (step, path, {required requireTrustedTarget}) async {
      calls.add(step.type.name);
      trustedFlags.add(requireTrustedTarget);
      return _sent(step.type == TransactionType.approve ? '0xa11' : '0x5a5');
    };
    executor.receiptWaiterOverride = (tx, hash) async {
      calls.add('wait:$hash');
      return true;
    };
  });

  tearDown(() async {
    executor.resetForTest();
    gate.resetForTest();
    TxUsdValuer.priceOverrideForTest = null;
    await PolicyProfileStore.instance.removeTrustedAddress(_trusted);
  });

  group('summaryFor', () {
    test('a send names the recipient, network and USD value', () {
      final s = AiOnchainExecutor.summaryFor(_txPreview(_send()),
          source: 'generalChat');
      expect(s.kind, AiActionKind.onChainSend);
      expect(s.toAddress, _trusted);
      expect(s.network, 'bsc');
      expect(s.valueUsd, 10);
      expect(s.amountLabel, '10 USDT');
      expect(s.source, 'generalChat');
    });

    test('a revoke maps to AiActionKind.revoke with no value', () {
      final s =
          AiOnchainExecutor.summaryFor(_txPreview(_revoke()), source: 'voice');
      expect(s.kind, AiActionKind.revoke);
      expect(s.valueUsd, 0.0);
      expect(s.toAddress, _stranger);
    });

    test('stablecoin → coin is a buy through the router', () {
      final s = AiOnchainExecutor.summaryFor(_swapPreview(_plan()),
          source: 'marketChat');
      expect(s.kind, AiActionKind.onChainBuy);
      expect(s.isBuy, isTrue);
      expect(s.toAddress, _allowanceHolder);
      expect(s.feeLabel, isNotNull);
    });

    test('coin → stablecoin is a sell (no buy-side position cap)', () {
      final s = AiOnchainExecutor.summaryForTx(_swap(from: 'BNB', to: 'USDT'),
          source: 'voice');
      expect(s.kind, AiActionKind.onChainSell);
      expect(s.isBuy, isFalse);
    });

    test('the delegate queue is a delegated trade', () {
      final s = AiOnchainExecutor.summaryForTx(_swap(), source: 'delegate');
      expect(s.kind, AiActionKind.delegatedTrade);
    });

    test('an unknown price stays unknown (never a quantity as dollars)', () {
      TxUsdValuer.priceOverrideForTest = (_) => null;
      final s = AiOnchainExecutor.summaryForTx(
          _send(symbol: 'CAKE', amount: 2), source: 'voice');
      expect(s.valueUsd, isNull);
    });
  });

  group('no-PIN hard check before signing (C4)', () {
    String? check(
      TransactionRequest tx, {
      PolicyProfile? profile,
      bool epk = true,
      String chain = 'bsc',
    }) =>
        GuardianExecutionController.aiNoPinBlockReason(
          tx,
          profile: profile ??
              PolicyProfile.safe().copyWith(trustedAddresses: [_trusted]),
          epkActive: epk,
          activeChainKey: chain,
          ownAddresses: [_owner, _card2],
        );

    test('a new address is refused in every policy profile', () {
      for (final profile in [
        PolicyProfile.safe(),
        PolicyProfile.defi(),
        const PolicyProfile(
          mode: PolicyMode.advanced,
          sendLimitUsd: 2500,
          swapLimitUsd: 10000,
          approveLimitUsd: 5000,
          allowUnknownContracts: true,
        ),
      ]) {
        expect(check(_send(to: _stranger), profile: profile), isNotNull);
      }
    });

    test('trusted addresses, own cards and self pass', () {
      expect(check(_send(to: _trusted)), isNull);
      expect(check(_send(to: _card2)), isNull);
      expect(check(_send(to: _owner)), isNull);
    });

    test('EPK paused or another network stops it', () {
      expect(check(_send(), epk: false), isNotNull);
      expect(check(_send(), chain: 'eth'), isNotNull);
    });

    test('an unknown USD value stops it', () {
      TxUsdValuer.priceOverrideForTest = (_) => null;
      expect(check(_send(symbol: 'CAKE')), isNotNull);
    });

    test('swaps and approvals pass only official routers or trusted contracts',
        () {
      expect(check(_swap()), isNull);
      expect(check(_approve()), isNull);
      expect(check(_swap(router: _unknownRouter)), isNotNull);
      expect(check(_approve(spender: _unknownRouter)), isNotNull);
      expect(
        check(
          _swap(router: _unknownRouter),
          profile: PolicyProfile.safe().copyWith(
            trustedContracts: [_unknownRouter],
          ),
        ),
        isNull,
      );
    });

    test('a revoke is never stopped (EPK paused, other network)', () {
      expect(check(_revoke(), epk: false, chain: 'eth'), isNull);
    });
  });

  group('executePreview', () {
    test('refuses outside «Автономный» and shows no card', () async {
      for (final mode in [AiMode.manual, AiMode.guarded]) {
        useSettings(mode: mode);
        final r = await executor.executePreview(_txPreview(_send()),
            source: 'voice', announce: false);
        expect(r.executed, isFalse);
        expect(r.blocked, isTrue);
      }
      expect(cards, 0);
      expect(calls, isEmpty);
    });

    test('refuses a plan built for another network (C8)', () async {
      final r = await executor.executePreview(
          _txPreview(_send(chainKey: 'eth')),
          source: 'voice',
          announce: false);
      expect(r.blocked, isTrue);
      expect(cards, 0);
      expect(calls, isEmpty);
    });

    test('a controller refusal comes before any card', () async {
      executor.preflightOverride =
          (tx) => AssistantResponse.error('over the cap');
      final r = await executor.executePreview(_txPreview(_send()),
          source: 'voice', announce: false);
      expect(r.blocked, isTrue);
      expect(r.message, contains('over the cap'));
      expect(cards, 0);
      expect(calls, isEmpty);
    });

    test('PIN on + declined card: nothing runs, the lock is free again',
        () async {
      cardAnswer = false;
      final r = await executor.executePreview(_txPreview(_send()),
          source: 'generalChat', announce: false);
      expect(r.cancelled, isTrue);
      expect(calls, isEmpty);
      expect(notifications, isEmpty);

      cardAnswer = true;
      final again = await executor.executePreview(_txPreview(_send()),
          source: 'generalChat', announce: false);
      expect(again.executed, isTrue);
      expect(cards, 2);
    });

    test('PIN on + confirmed card: one send, signed after the PIN', () async {
      final r = await executor.executePreview(_txPreview(_send()),
          source: 'generalChat', announce: false);
      expect(r.executed, isTrue);
      expect(r.txHash, '0xabc');
      expect(cards, 1);
      expect(calls, ['send']);
      expect(trustedFlags, [false]);
      expect(notifications, hasLength(1));
    });

    test('PIN off + trusted recipient: no card, hard check on, notification',
        () async {
      useSettings(pin: false);
      final r = await executor.executePreview(_txPreview(_send()),
          source: 'voice', announce: false);
      expect(r.executed, isTrue);
      expect(cards, 0);
      expect(calls, ['send']);
      expect(trustedFlags, [true]);
      expect(notifications, hasLength(1));
    });

    test('PIN off + new address: the card + PIN come back (D6)', () async {
      useSettings(pin: false);
      final r = await executor.executePreview(_txPreview(_send(to: _stranger)),
          source: 'voice', announce: false);
      expect(r.executed, isTrue);
      expect(cards, 1);
      expect(trustedFlags, [false]);
    });

    test('swap: approve → own receipt wait → swap under ONE card', () async {
      final r = await executor.executePreview(_swapPreview(_plan()),
          source: 'marketChat', announce: false);
      expect(r.executed, isTrue);
      expect(cards, 1);
      expect(calls, ['approve', 'wait:0xa11', 'swap']);
      expect(r.txHash, '0x5a5');
      expect(notifications, hasLength(1));
    });

    test('an approval that is not mined stops the swap', () async {
      executor.receiptWaiterOverride = (tx, hash) async => false;
      final r = await executor.executePreview(_swapPreview(_plan()),
          source: 'marketChat', announce: false);
      expect(r.executed, isFalse);
      expect(r.failed, isTrue);
      expect(calls, ['approve']);
      expect(notifications, isEmpty);
    });

    test('a failed send is reported as failed, without a notification',
        () async {
      executor.txRunnerOverride =
          (tx, path, {required requireTrustedTarget}) async =>
              AssistantResponse.error('rejected');
      final r = await executor.executePreview(_txPreview(_send()),
          source: 'voice', announce: false);
      expect(r.failed, isTrue);
      expect(notifications, isEmpty);
    });

    test('a declined sign-in cancels and frees the lock', () async {
      executor.privySessionOverride = () async => false;
      final r = await executor.executePreview(_txPreview(_send()),
          source: 'voice', announce: false);
      expect(r.cancelled, isTrue);
      expect(calls, isEmpty);

      executor.privySessionOverride = () async => true;
      final again = await executor.executePreview(_txPreview(_send()),
          source: 'voice', announce: false);
      expect(again.executed, isTrue);
    });

    test('a withdrawn request (delegate Cancel) never runs', () async {
      final r = await executor.executePreview(_txPreview(_send()),
          source: 'delegate', stillWanted: () => false, announce: false);
      expect(r.cancelled, isTrue);
      expect(calls, isEmpty);
    });

    test('a revoke runs even with EPK paused (D11)', () async {
      useSettings(pin: false);
      await EPKPolicyManager.instance.emergencyPause();
      final r = await executor.executePreview(_txPreview(_revoke()),
          source: 'generalChat', announce: false);
      expect(r.executed, isTrue);
      expect(calls, ['revoke']);
    });

    test('a second AI operation while one is open is rejected (busy)',
        () async {
      AiExecResult? second;
      gate.confirmUiOverride = (s) async {
        cards++;
        // While this card is open, another AI operation asks.
        second = await executor.executePreview(_txPreview(_send()),
            source: 'voice', announce: false);
        return true;
      };
      final first = await executor.executePreview(_txPreview(_send()),
          source: 'generalChat', announce: false);
      expect(first.executed, isTrue);
      expect(second, isNotNull);
      expect(second!.deferred, isTrue);
      expect(second!.gateOutcome, AiGateOutcome.busy);
      expect(cards, 1);
      expect(calls, ['send']);
    });
  });
}
