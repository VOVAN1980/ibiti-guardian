import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/audit_log_entry.dart';
import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/services/audit_log_service.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/services/security/ai_action_gate.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// AiActionGate: «Советник» / «Ручной» / «Автономный» × PIN setting ×
/// trusted / new address × limits × unknown price × revoke exemptions ×
/// one AI money action at a time.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const self = '0x9999999999999999999999999999999999999999';
  const goldCard = '0x1111111111111111111111111111111111111111';
  const trusted = '0xAbCdEf0000000000000000000000000000000001';
  const stranger = '0x2222222222222222222222222222222222222222';
  const zeroExRouter = '0x0000000000001fF3684f28c67538d4D072C22734';

  final gate = AiActionGate.instance;
  late List<String> notified;
  late int cardsShown;

  AiActionSummary send({String to = trusted, double? usd = 20}) =>
      AiActionSummary(
        kind: AiActionKind.onChainSend,
        title: 'Send 20 USDT',
        amountLabel: '20 USDT',
        valueUsd: usd,
        toAddress: to,
        network: 'bsc',
        assetSymbol: 'USDT',
        source: 'voice',
      );

  AiActionSummary cex({
    bool isBuy = true,
    double? usd = 10,
    String symbol = 'SOL',
    String venue = 'mexc',
  }) =>
      AiActionSummary(
        kind: AiActionKind.cexOrder,
        title: '${isBuy ? 'Buy' : 'Sell'} $symbol on MEXC',
        amountLabel: '10 USDT',
        valueUsd: usd,
        isBuy: isBuy,
        venue: venue,
        assetSymbol: symbol,
        feeLabel: '≈0.1% exchange fee',
        source: 'marketChat',
      );

  AiActionSummary swap({String? to = zeroExRouter, double? usd = 15}) =>
      AiActionSummary(
        kind: AiActionKind.onChainSwap,
        title: 'Swap 15 USDT → BNB',
        amountLabel: '15 USDT',
        valueUsd: usd,
        toAddress: to,
        network: 'bsc',
        venue: '0x',
        assetSymbol: 'USDT',
        targetSymbol: 'BNB',
        source: 'generalChat',
      );

  const revoke = AiActionSummary(
    kind: AiActionKind.revoke,
    title: 'Revoke 2 approvals',
    amountLabel: '2 approvals',
    valueUsd: 0,
    network: 'bsc',
    source: 'voice',
  );

  void setMode(
    AiMode mode, {
    bool pin = false,
    List<AiAction>? actions,
    AutonomyMandate mandate = const AutonomyMandate(),
    double daily = 1000,
    DateTime? expiry,
  }) {
    AiControlService.instance.setSettingsForTest(AiControlSettings(
      mode: mode,
      allowedActions: actions ?? AiAction.values,
      dailyLimit: daily,
      aiPinConfirm: pin,
      mandate: mandate,
      permissionsExpiry: expiry,
    ));
  }

  /// Card + PIN stand-in that answers [yes] and counts how often it is shown.
  void cardAnswers(bool yes) {
    gate.confirmUiOverride = (_) async {
      cardsShown++;
      return yes;
    };
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    IBITIVaultService.instance.setVaultCreatedForTest(
      evmAddress: self,
      evmCardAddresses: [self, goldCard],
    );
    await EPKPolicyManager.instance.resumeProtection();

    final store = PolicyProfileStore.instance;
    for (final a in [...store.current.trustedAddresses]) {
      await store.removeTrustedAddress(a);
    }
    for (final a in [...store.current.trustedContracts]) {
      await store.removeTrustedContract(a);
    }
    await store.addTrustedAddress(trusted);

    DelegationController.instance.resetUsageForTest();
    setMode(AiMode.fullAutonomy);

    gate.resetForTest();
    notified = [];
    cardsShown = 0;
    gate.notifyOverride = (title, body) => notified.add(title);
  });

  tearDown(() => gate.resetForTest());

  group('«Советник» (manual): advice only', () {
    test('every kind is adviseOnly; no card, no lock', () async {
      setMode(AiMode.manual);
      cardAnswers(true);
      for (final s in [send(), cex(), swap(), revoke]) {
        expect(gate.precheck(s).outcome, AiGateOutcome.adviseOnly);
        final d = await gate.confirm(s);
        expect(d.outcome, AiGateOutcome.adviseOnly);
        expect(d.mayExecute, isFalse);
        expect(d.reason, isNotNull);
      }
      expect(cardsShown, 0);

      setMode(AiMode.fullAutonomy);
      expect((await gate.confirm(cex())).outcome, AiGateOutcome.execute,
          reason: 'advice took no lock');
    });
  });

  group('«Ручной» (guarded): the AI prepares, the user confirms', () {
    test('every kind is prepareOnly; the gate shows no card', () async {
      setMode(AiMode.guarded);
      cardAnswers(true);
      for (final s in [send(), cex(), swap(), revoke]) {
        final d = await gate.confirm(s);
        expect(d.outcome, AiGateOutcome.prepareOnly);
        expect(d.mayExecute, isFalse);
      }
      expect(cardsShown, 0);
    });

    test('the PIN setting is ignored outside «Автономный»', () {
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
          mode: AiMode.guarded, aiPinConfirm: false));
      expect(AiControlService.instance.settings.pinRequiredForAi, isTrue);
    });
  });

  group('«Автономный», PIN OFF (D6)', () {
    test('trusted recipient, known value: runs without the card', () async {
      cardAnswers(true);
      final d = await gate.confirm(send());
      expect(d.outcome, AiGateOutcome.execute);
      expect(d.withoutPin, isTrue);
      expect(cardsShown, 0);

      await gate.reportExecuted(send(), d, success: true, detail: '0xabc');
      expect(notified, hasLength(1));
      expect(notified.single, contains('Send 20 USDT'));
      final audit = AuditLogService.instance.entries.first;
      expect(audit.actionLabel, 'AI_EXECUTED_NO_PIN');
      expect(audit.executionSource, ExecutionSource.ai);
    });

    test('own card and own wallet count as trusted', () async {
      for (final to in [goldCard, self, self.toUpperCase().replaceFirst('0X', '0x')]) {
        final d = await gate.confirm(send(to: to));
        expect(d.withoutPin, isTrue, reason: to);
        gate.release(d);
      }
    });

    test('a new address shows the card + PIN', () async {
      cardAnswers(true);
      final d = await gate.confirm(send(to: stranger));
      expect(cardsShown, 1);
      expect(d.mayExecute, isTrue);
      expect(d.pinConfirmed, isTrue);
      gate.release(d);

      cardAnswers(false);
      final no = await gate.confirm(send(to: stranger));
      expect(no.outcome, AiGateOutcome.cancelled);
      expect(no.mayExecute, isFalse);
    });

    test('an unknown USD value shows the card + PIN', () async {
      cardAnswers(true);
      final d = await gate.confirm(send(usd: null));
      expect(cardsShown, 1);
      expect(d.pinConfirmed, isTrue);
    });

    test('exchange orders need no address', () async {
      final d = await gate.confirm(cex());
      expect(d.withoutPin, isTrue);
    });

    test('official swap routers are trusted for swaps, not as a send target',
        () async {
      cardAnswers(true);
      final d = await gate.confirm(swap());
      expect(d.withoutPin, isTrue);
      gate.release(d);

      final toRouter = await gate.confirm(send(to: zeroExRouter));
      expect(cardsShown, 1, reason: 'a router is not a send recipient');
      expect(toRouter.pinConfirmed, isTrue);
      gate.release(toRouter);

      final unknownRouter = await gate.confirm(swap(to: stranger));
      expect(cardsShown, 2);
      gate.release(unknownRouter);
      expect(AiActionGate.isOfficialSwapRouter(zeroExRouter.toLowerCase()),
          isTrue);
    });

    test('a locked vault shows the card + PIN', () async {
      IBITIVaultService.instance.lock();
      cardAnswers(true);
      final d = await gate.confirm(cex());
      expect(cardsShown, 1);
      expect(d.pinConfirmed, isTrue);
    });

    test('in the background nothing runs by itself', () async {
      gate.foregroundOverride = () => false;
      final d = await gate.confirm(send());
      expect(d.outcome, AiGateOutcome.unavailable);
      expect(d.mayExecute, isFalse);
      // The lock was released.
      gate.foregroundOverride = () => true;
      expect((await gate.confirm(send())).withoutPin, isTrue);
    });

    test('a failed execution: audit, no notification', () async {
      final d = await gate.confirm(cex());
      await gate.reportExecuted(cex(), d, success: false, detail: 'rejected');
      expect(notified, isEmpty);
      expect(AuditLogService.instance.entries.first.actionLabel,
          'AI_EXECUTION_FAILED');
    });
  });

  group('«Автономный», PIN ON (D5, default)', () {
    setUp(() => setMode(AiMode.fullAutonomy, pin: true));

    test('card + PIN, then execute; the notification follows', () async {
      cardAnswers(true);
      final d = await gate.confirm(send());
      expect(cardsShown, 1);
      expect(d.mayExecute, isTrue);
      expect(d.pinConfirmed, isTrue);
      expect(d.withoutPin, isFalse);

      await gate.reportExecuted(send(), d, success: true, historyId: 'h1');
      expect(notified, hasLength(1));
      expect(AuditLogService.instance.entries.first.actionLabel,
          'AI_EXECUTED_PIN');
    });

    test('Cancel on the card: nothing runs', () async {
      cardAnswers(false);
      final d = await gate.confirm(cex());
      expect(d.outcome, AiGateOutcome.cancelled);
      expect(d.reason, isNotNull);
      expect(notified, isEmpty);
    });

    test('no screen to show the card on: unavailable', () async {
      final d = await gate.confirm(cex());
      expect(d.outcome, AiGateOutcome.unavailable);
    });

    test('default settings keep the PIN on', () {
      expect(const AiControlSettings(mode: AiMode.fullAutonomy).pinRequiredForAi,
          isTrue);
    });
  });

  group('limits, mandate and EPK hold in every case (D6, D7)', () {
    for (final pin in [false, true]) {
      test('daily trading limit used up → refused (PIN ${pin ? 'ON' : 'OFF'})',
          () async {
        setMode(AiMode.fullAutonomy, pin: pin);
        cardAnswers(true);
        DelegationController.instance.commitUsage(995);
        final d = await gate.confirm(send());
        expect(d.outcome, AiGateOutcome.blocked);
        expect(d.reason, contains('\$20.00'));
        expect(cardsShown, 0, reason: 'never a card for a refused action');
      });
    }

    test('max position: buys only', () async {
      final buy = await gate.confirm(cex(usd: 150));
      expect(buy.outcome, AiGateOutcome.blocked);
      expect(buy.reason, contains('\$100.00'));

      final sell = await gate.confirm(cex(isBuy: false, usd: 150));
      expect(sell.withoutPin, isTrue);
    });

    test('mandate assets (CEX pair base), networks and venues', () async {
      setMode(AiMode.fullAutonomy,
          mandate: const AutonomyMandate(allowedAssets: ['BTC']));
      expect((await gate.confirm(cex(symbol: 'SOLUSDT'))).outcome,
          AiGateOutcome.blocked);
      final btc = await gate.confirm(cex(symbol: 'BTCUSDT'));
      expect(btc.withoutPin, isTrue);
      gate.release(btc);

      setMode(AiMode.fullAutonomy,
          mandate: const AutonomyMandate(allowedNetworks: ['eth']));
      expect(gate.precheck(send()).outcome, AiGateOutcome.blocked);

      setMode(AiMode.fullAutonomy,
          mandate: const AutonomyMandate(allowedVenues: ['okx']));
      final venue = gate.precheck(cex());
      expect(venue.outcome, AiGateOutcome.blocked);
      expect(venue.reason, contains('MEXC'));
    });

    test('expired AI permissions → refused', () async {
      setMode(AiMode.fullAutonomy,
          expiry: DateTime.now().subtract(const Duration(minutes: 1)));
      expect((await gate.confirm(cex())).outcome, AiGateOutcome.blocked);
    });

    test('an action turned off in AI Center → refused', () async {
      setMode(AiMode.fullAutonomy, actions: const [AiAction.send]);
      expect((await gate.confirm(cex())).outcome, AiGateOutcome.blocked);
      expect((await gate.confirm(send())).withoutPin, isTrue);
    });

    test('EPK paused blocks on-chain actions, not exchange orders', () async {
      await EPKPolicyManager.instance.emergencyPause();
      expect((await gate.confirm(send())).outcome, AiGateOutcome.blocked);
      expect((await gate.confirm(swap())).outcome, AiGateOutcome.blocked);
      expect((await gate.confirm(cex())).withoutPin, isTrue);
    });
  });

  group('revoke only lowers allowances (D11)', () {
    test('EPK pause, used-up budget and a narrow mandate never block it',
        () async {
      await EPKPolicyManager.instance.emergencyPause();
      DelegationController.instance.commitUsage(1000);
      setMode(AiMode.fullAutonomy,
          mandate: const AutonomyMandate(
              allowedAssets: ['BTC'], allowedNetworks: ['eth']));
      final d = await gate.confirm(revoke);
      expect(d.mayExecute, isTrue);
      expect(d.withoutPin, isTrue);
    });

    test('expired permissions: still runs, after the card + PIN', () async {
      setMode(AiMode.fullAutonomy,
          expiry: DateTime.now().subtract(const Duration(minutes: 1)));
      cardAnswers(true);
      final d = await gate.confirm(revoke);
      expect(cardsShown, 1);
      expect(d.mayExecute, isTrue);
    });

    test('revoke turned off for the AI: card + PIN, not a refusal', () async {
      setMode(AiMode.fullAutonomy, actions: const [AiAction.swap]);
      cardAnswers(true);
      final d = await gate.confirm(revoke);
      expect(cardsShown, 1);
      expect(d.pinConfirmed, isTrue);
    });

    test('«Ручной» prepares, «Советник» only advises', () async {
      setMode(AiMode.guarded);
      expect((await gate.confirm(revoke)).outcome, AiGateOutcome.prepareOnly);
      setMode(AiMode.manual);
      expect((await gate.confirm(revoke)).outcome, AiGateOutcome.adviseOnly);
    });
  });

  group('one AI money action at a time (D13)', () {
    test('a second request while the card is open is rejected', () async {
      setMode(AiMode.fullAutonomy, pin: true);
      final answer = Completer<bool>();
      gate.confirmUiOverride = (_) => answer.future;

      final first = gate.confirm(cex());
      await pumpEventQueue();
      expect(gate.hasOpenCard, isTrue);

      final second = await gate.confirm(send());
      expect(second.outcome, AiGateOutcome.busy);
      expect(second.reason, isNotNull);
      // precheck takes no lock and is not affected.
      expect(gate.precheck(send()).outcome, AiGateOutcome.execute);

      answer.complete(false);
      expect((await first).outcome, AiGateOutcome.cancelled);
      expect(gate.hasOpenCard, isFalse);

      cardAnswers(true);
      expect((await gate.confirm(send())).mayExecute, isTrue);
    });

    test('the lock is held through execution until the report', () async {
      final d = await gate.confirm(cex());
      expect(d.withoutPin, isTrue);
      expect((await gate.confirm(send())).outcome, AiGateOutcome.busy);

      await gate.reportExecuted(cex(), d, success: true);
      expect((await gate.confirm(send())).withoutPin, isTrue);
    });

    test('release() frees the lock and is idempotent', () async {
      final d = await gate.confirm(cex());
      gate.release(d);
      gate.release(d);
      final next = await gate.confirm(send());
      expect(next.withoutPin, isTrue);
      // Releasing an old decision does not free the new holder.
      gate.release(d);
      expect((await gate.confirm(cex())).outcome, AiGateOutcome.busy);
    });
  });

  group('decisions are bound to the action', () {
    test('matches the same action only, at most the confirmed value',
        () async {
      final d = await gate.confirm(send());
      expect(d.matches(send()), isTrue);
      expect(d.matches(send(usd: 10)), isTrue, reason: 'lower is fine');
      expect(d.matches(send(usd: 30)), isFalse);
      expect(d.matches(send(to: goldCard)), isFalse);
      expect(d.matches(send(usd: null)), isFalse);
      expect(d.matches(cex()), isFalse);

      await gate.reportExecuted(send(), d, success: true);
      expect(d.matches(send()), isFalse, reason: 'one-shot');
    });

    test('a precheck decision never authorizes anything', () {
      final pre = gate.precheck(send());
      expect(pre.mayExecute, isTrue);
      expect(pre.matches(send()), isFalse);
    });

    test('side and venue are part of the binding', () async {
      final d = await gate.confirm(cex());
      expect(d.matches(cex()), isTrue);
      expect(d.matches(cex(isBuy: false)), isFalse);
      expect(d.matches(cex(venue: 'okx')), isFalse);
      gate.release(d);
      expect(d.matches(cex()), isFalse);
    });
  });

  group('state is checked again after the PIN', () {
    setUp(() => setMode(AiMode.fullAutonomy, pin: true));

    test('mode dropped to «Советник» during the card → no execution',
        () async {
      gate.confirmUiOverride = (_) async {
        setMode(AiMode.manual);
        return true;
      };
      final d = await gate.confirm(cex());
      expect(d.mayExecute, isFalse);
      expect(d.outcome, isNot(AiGateOutcome.execute));
    });

    test('budget used up while the card was open → refused', () async {
      gate.confirmUiOverride = (_) async {
        DelegationController.instance.commitUsage(1000);
        return true;
      };
      final d = await gate.confirm(cex());
      expect(d.outcome, AiGateOutcome.blocked);
      // The lock is free again.
      DelegationController.instance.resetUsageForTest();
      cardAnswers(true);
      expect((await gate.confirm(cex())).mayExecute, isTrue);
    });

    test('a mode change closes an open card', () async {
      final never = Completer<bool>();
      gate.confirmUiOverride = (_) => never.future;
      final pending = gate.confirm(cex());
      await pumpEventQueue();
      expect(gate.hasOpenCard, isTrue);

      AiControlService.instance.setSettingsForTest(
          const AiControlSettings(mode: AiMode.guarded));
      final d = await pending;
      expect(d.outcome, AiGateOutcome.cancelled);
      expect(gate.hasOpenCard, isFalse);
    });
  });

  group('voice answers the open card (D5, D15)', () {
    setUp(() => setMode(AiMode.fullAutonomy, pin: true));

    test('«да» confirms', () async {
      final never = Completer<bool>();
      gate.confirmUiOverride = (_) => never.future;
      final pending = gate.confirm(cex());
      await pumpEventQueue();
      expect(gate.hasOpenCard, isTrue);
      gate.answerByVoice(true);
      final d = await pending;
      expect(d.mayExecute, isTrue);
      expect(d.pinConfirmed, isTrue);
    });

    test('«нет» cancels', () async {
      final never = Completer<bool>();
      gate.confirmUiOverride = (_) => never.future;
      final pending = gate.confirm(cex());
      await pumpEventQueue();
      gate.answerByVoice(false);
      expect((await pending).outcome, AiGateOutcome.cancelled);
    });

    test('without an open card a voice answer does nothing', () {
      expect(gate.hasOpenCard, isFalse);
      gate.answerByVoice(true);
      expect(gate.hasOpenCard, isFalse);
    });
  });
}
