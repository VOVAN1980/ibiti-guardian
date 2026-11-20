// AiOnchainExecutor: on-chain operations the AI runs in «Автономный» mode,
// always through AiActionGate, plus the controller's no-PIN hard check (C4).
//
// Run: flutter test test/services/execution/ai_onchain_executor_test.dart

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/models/swap_execution_plan.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/audit_log_service.dart';
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
const _cake = '0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82';

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
  String? targetAddress,
}) =>
    TransactionRequest(
      type: TransactionType.swap,
      fromAddress: _owner,
      toAddress: router,
      routerAddress: router,
      tokenSymbol: from,
      tokenContract: _usdt,
      targetTokenSymbol: to,
      targetTokenAddress: targetAddress,
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

    test('a trade names the received token contract (which token)', () {
      final buy = AiOnchainExecutor.summaryForTx(
          _swap(to: 'CAKE', targetAddress: _cake),
          source: 'voice');
      expect(buy.kind, AiActionKind.onChainBuy);
      expect(buy.title, contains('CAKE'));
      expect(buy.title, contains('0x0E09…cE82'));

      final delegated = AiOnchainExecutor.summaryForTx(
          _swap(to: 'CAKE', targetAddress: _cake),
          source: 'delegate');
      expect(delegated.title, contains('0x0E09…cE82'));

      final sell = AiOnchainExecutor.summaryForTx(
          _swap(from: 'CAKE', to: 'USDT', targetAddress: _usdt),
          source: 'voice');
      expect(sell.kind, AiActionKind.onChainSell);
      expect(sell.title, contains('0x55d3…7955'));
    });

    test('the native coin has no contract to show', () {
      for (final address in [
        '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE',
        'native',
        null,
      ]) {
        final s = AiOnchainExecutor.summaryForTx(
            _swap(to: 'BNB', targetAddress: address),
            source: 'voice');
        expect(s.title, isNot(contains('…')), reason: '$address');
        expect(s.title, contains('BNB'));
      }
    });

    test('a send title names the recipient, not the amount again', () {
      final s = AiOnchainExecutor.summaryFor(_txPreview(_send(amount: 5)),
          source: 'voice');
      expect(s.amountLabel, '5 USDT');
      expect(s.title, contains('0x1111…1111'));
      expect(s.title, isNot(contains('5 USDT')));
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

    test('a declined card is a «нет»: declined, not deferred', () async {
      cardAnswer = false;
      final r = await executor.executePreview(_txPreview(_send()),
          source: 'delegate', announce: false);
      expect(r.cancelled, isTrue);
      expect(r.declined, isTrue);
      expect(r.deferred, isFalse);
    });

    test('a mode switch that closes the card is not a «нет»', () async {
      gate.confirmUiOverride = (_) {
        useSettings(mode: AiMode.guarded);
        return Completer<bool>().future;
      };
      final r = await executor.executePreview(_txPreview(_send()),
          source: 'delegate', announce: false);
      expect(r.cancelled, isTrue);
      expect(r.declined, isFalse);
      expect(r.deferred, isFalse);
      expect(calls, isEmpty);
      expect(gate.isBusy, isFalse);
    });

    test('a card closed without an answer is deferred, not declined',
        () async {
      gate.cardTimeoutOverride = const Duration(milliseconds: 20);
      gate.confirmUiOverride = (_) => Completer<bool>().future;
      final r = await executor.executePreview(_txPreview(_send()),
          source: 'delegate', announce: false);
      expect(r.executed, isFalse);
      expect(r.interrupted, isTrue);
      expect(r.deferred, isTrue);
      expect(r.cancelled, isFalse);
      expect(r.declined, isFalse);
      expect(r.blocked, isFalse);
      expect(calls, isEmpty);
      expect(gate.isBusy, isFalse);
    });
  });

  group('checked again before every dispatch (D13, D14)', () {
    test("a Cancel in the queue during the approve receipt wait stops the "
        'swap', () async {
      var wanted = true;
      executor.receiptWaiterOverride = (tx, hash) async {
        calls.add('wait:$hash');
        wanted = false; // the user taps Cancel in the queue meanwhile
        return true;
      };
      final r = await executor.executePreview(_swapPreview(_plan()),
          source: 'delegate', stillWanted: () => wanted, announce: false);
      expect(r.executed, isFalse);
      expect(r.cancelled, isTrue);
      expect(r.declined, isFalse);
      expect(calls, ['approve', 'wait:0xa11']);
      expect(r.message, contains('approval'));
      expect(notifications, isEmpty);
      expect(gate.isBusy, isFalse);
      expect(AuditLogService.instance.entries.first.actionLabel,
          'AI_EXECUTION_FAILED');
    });

    test('the mode switched to «Ручной» during the wait: no swap', () async {
      executor.receiptWaiterOverride = (tx, hash) async {
        calls.add('wait:$hash');
        useSettings(mode: AiMode.guarded);
        return true;
      };
      final r = await executor.executePreview(_swapPreview(_plan()),
          source: 'marketChat', announce: false);
      expect(r.executed, isFalse);
      expect(r.cancelled, isTrue);
      expect(calls, ['approve', 'wait:0xa11']);
      expect(gate.isBusy, isFalse);
    });

    test('EPK paused during the wait: the swap is refused', () async {
      executor.receiptWaiterOverride = (tx, hash) async {
        calls.add('wait:$hash');
        await EPKPolicyManager.instance.emergencyPause();
        return true;
      };
      final r = await executor.executePreview(_swapPreview(_plan()),
          source: 'marketChat', announce: false);
      expect(r.executed, isFalse);
      expect(r.blocked, isTrue);
      expect(calls, ['approve', 'wait:0xa11']);
      expect(gate.isBusy, isFalse);
    });

    test('the lock lapsed during a long sign-in: nothing is sent', () async {
      executor.privySessionOverride = () async {
        gate.ageLockForTest(const Duration(minutes: 4));
        return true;
      };
      final r = await executor.executePreview(_txPreview(_send()),
          source: 'voice', announce: false);
      expect(r.executed, isFalse);
      expect(r.cancelled, isTrue);
      expect(calls, isEmpty);
      expect(notifications, isEmpty);
      expect(gate.isBusy, isFalse);
    });

    test('a Cancel during the sign-in wins', () async {
      var wanted = true;
      executor.privySessionOverride = () async {
        wanted = false;
        return true;
      };
      final r = await executor.executePreview(_txPreview(_send()),
          source: 'delegate', stillWanted: () => wanted, announce: false);
      expect(r.cancelled, isTrue);
      expect(calls, isEmpty);
    });

    test('the lock is kept alive while the approve receipt is awaited',
        () async {
      executor.keepAliveInterval = const Duration(milliseconds: 5);
      executor.receiptWaiterOverride = (tx, hash) async {
        calls.add('wait:$hash');
        gate.ageLockForTest(const Duration(minutes: 2, seconds: 50));
        // The keep-alive timer refreshes the lock meanwhile …
        await Future<void>.delayed(const Duration(milliseconds: 60));
        // … so another 2:50 later it is still live (5:40 without it).
        gate.ageLockForTest(const Duration(minutes: 2, seconds: 50));
        expect(gate.isBusy, isTrue);
        return true;
      };
      final r = await executor.executePreview(_swapPreview(_plan()),
          source: 'marketChat', announce: false);
      expect(r.executed, isTrue);
      expect(calls, ['approve', 'wait:0xa11', 'swap']);
      expect(gate.isBusy, isFalse);
    });
  });

  group('the lock is always freed (D13)', () {
    test('the sign-in check throws: deferred, lock free', () async {
      executor.privySessionOverride = () async => throw StateError('down');
      final r = await executor.executePreview(_txPreview(_send()),
          source: 'voice', announce: false);
      expect(r.executed, isFalse);
      expect(r.deferred, isTrue);
      expect(calls, isEmpty);
      expect(gate.isBusy, isFalse);

      executor.privySessionOverride = () async => true;
      final again = await executor.executePreview(_txPreview(_send()),
          source: 'voice', announce: false);
      expect(again.executed, isTrue);
    });

    test('the runner throws: failed, lock free', () async {
      executor.txRunnerOverride =
          (tx, path, {required requireTrustedTarget}) async =>
              throw StateError('boom');
      final r = await executor.executePreview(_txPreview(_send()),
          source: 'voice', announce: false);
      expect(r.failed, isTrue);
      expect(gate.isBusy, isFalse);
    });
  });

  group('limit hint (D6)', () {
    setUp(() {
      executor.preflightOverride = (tx) => AssistantResponse.error('refused');
    });

    test('a buy over the position cap gets the raise-the-limit hint',
        () async {
      final r = await executor.executePreview(
          _txPreview(_swap(to: 'CAKE', amount: 150)),
          source: 'voice',
          announce: false);
      expect(r.blocked, isTrue);
      expect(r.message, contains('Raise the threshold'));
    });

    test('a sell or a send over the position cap does not (buys only)',
        () async {
      final sell = await executor.executePreview(
          _txPreview(_swap(from: 'CAKE', to: 'USDT', amount: 150)),
          source: 'voice',
          announce: false);
      expect(sell.message, isNot(contains('Raise the threshold')));
      final send = await executor.executePreview(
          _txPreview(_send(amount: 150)),
          source: 'voice',
          announce: false);
      expect(send.message, isNot(contains('Raise the threshold')));
    });

    test('a refusal outside «AI Мандат» gets the hint too', () async {
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.fullAutonomy,
        dailyLimit: 10000,
        mandate: AutonomyMandate(allowedNetworks: ['eth']),
      ));
      final r = await executor.executePreview(_txPreview(_send()),
          source: 'voice', announce: false);
      expect(r.blocked, isTrue);
      expect(r.message, contains('Raise the threshold'));
    });
  });

  group('waitForReceipt', () {
    setUp(() {
      executor.receiptWaiterOverride = null;
      executor.receiptPollInterval = const Duration(milliseconds: 5);
      executor.receiptPollTimeout = const Duration(milliseconds: 40);
    });

    test('a stalled poll cannot hold the wait past its deadline', () async {
      executor.receiptFetchOverride = (tx, hash) => Completer<bool?>().future;
      final watch = Stopwatch()..start();
      final mined = await executor.waitForReceipt(_approve(), '0xa11',
          timeout: const Duration(milliseconds: 200));
      expect(mined, isFalse);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a stalled poll is dropped and the next one sees the receipt',
        () async {
      var polls = 0;
      executor.receiptFetchOverride = (tx, hash) {
        polls++;
        return polls == 1 ? Completer<bool?>().future : Future.value(true);
      };
      final mined = await executor.waitForReceipt(_approve(), '0xa11',
          timeout: const Duration(seconds: 5));
      expect(mined, isTrue);
      expect(polls, 2);
    });

    test('not mined yet keeps polling; a reverted receipt is false',
        () async {
      var polls = 0;
      executor.receiptFetchOverride = (tx, hash) async {
        polls++;
        return polls < 3 ? null : false;
      };
      final mined = await executor.waitForReceipt(_approve(), '0xa11',
          timeout: const Duration(seconds: 5));
      expect(mined, isFalse);
      expect(polls, 3);
    });
  });
}
