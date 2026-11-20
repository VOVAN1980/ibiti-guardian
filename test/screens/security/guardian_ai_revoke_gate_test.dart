// Safe / Panic opened by the AI (owner decision D11): «Советник» = review
// only; «Ручной» = the tap + PIN; «Автономный» = AiActionGate (the card + PIN,
// or no PIN when «Подтверждать действия ИИ ПИН-кодом» is off). An EPK pause or
// expired AI permissions never block a revoke. Opened by the user: the tap is
// the confirmation, unchanged in every mode.
//
// Run: flutter test test/screens/security/guardian_ai_revoke_gate_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/approval.dart';
import 'package:ibiti_guardian/screens/security/guardian_control_screen.dart';
import 'package:ibiti_guardian/screens/security/guardian_flow_controller.dart';
import 'package:ibiti_guardian/services/ankr/ankr_config_service.dart';
import 'package:ibiti_guardian/services/audit_log_service.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/security/ai_action_gate.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/security/approval_scan_service.dart';
import 'package:ibiti_guardian/services/security/approval_source.dart';
import 'package:ibiti_guardian/services/transaction_queue.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _wallet = '0x1111111111111111111111111111111111111111';
const _token = '0x2222222222222222222222222222222222222222';

/// A risky approval: Safe mode lists and preselects it.
ApprovalData _approval() => ApprovalData(
    token: _token,
    spenderAddress: '0x3333333333333333333333333333333333333333',
    spender: 'Test spender',
    allowance: BigInt.from(10),
    tokenSymbol: 'TEST',
    walletAddress: _wallet);

/// Answers every scan at once with one risky approval.
class _Source implements ApprovalSource {
  @override
  Future<List<ApprovalData>> fetch(String wallet,
          {required int chainId, String? targetTokenAddress}) async =>
      [_approval()];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final gate = AiActionGate.instance;
  late List<String> notified;
  late int cardsShown;
  late int pinAsked;
  late int auditBefore;

  const revokeSummary = AiActionSummary(
    kind: AiActionKind.revoke,
    title: 'Revoke approvals (1)',
    amountLabel: '1 approvals',
    valueUsd: 0,
    network: 'bsc',
    source: 'ui',
  );

  void setMode(AiMode mode, {bool pin = true, DateTime? expiry}) {
    AiControlService.instance.setSettingsForTest(AiControlSettings(
      mode: mode,
      allowedActions: AiAction.values,
      aiPinConfirm: pin,
      permissionsExpiry: expiry,
    ));
  }

  /// The AI card + its PIN (one stand-in, as in AiActionGate).
  void cardAnswers(bool yes) {
    gate.confirmUiOverride = (_) async {
      cardsShown++;
      return yes;
    };
  }

  /// The PIN of a «Ручной» revoke.
  void pinAnswers(bool yes) {
    GuardianControlScreen.debugAuthOverride = () async {
      pinAsked++;
      return yes;
    };
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await LocalizationService.instance.load(const Locale('ru'));
    IBITIVaultService.instance.setVaultCreatedForTest(evmAddress: _wallet);
    await EPKPolicyManager.instance.resumeProtection();
    AnkrConfigService.instance.setKeyForTest('');
    ApprovalScanService.sourceOverride = _Source();
    TransactionQueue().clear();

    gate.resetForTest();
    gate.foregroundOverride = () => true;
    notified = [];
    cardsShown = 0;
    pinAsked = 0;
    gate.notifyOverride = (title, body) => notified.add(title);
    auditBefore = AuditLogService.instance.entries.length;
    cardAnswers(true);
    pinAnswers(true);
    setMode(AiMode.guarded);
  });

  tearDown(() {
    gate.resetForTest();
    GuardianControlScreen.debugAuthOverride = null;
    ApprovalScanService.sourceOverride = null;
    ApprovalScanService.lastRiskScore = null;
    ApprovalScanService.hasRiskyApprovals = false;
    ApprovalScanService.lastScanTime = null;
    ApprovalScanService.lastScannedApprovals = [];
    AnkrConfigService.instance.setKeyForTest('');
    IBITIVaultService.instance.setVaultCreatedForTest(evmAddress: '');
    TransactionQueue().clear();
  });

  bool revokeStarted() =>
      TransactionQueue().currentJobs.any((j) => j.approval.token == _token);

  /// AI audit entries written during this test (newest first).
  List<String> aiAuditLabels() => AuditLogService.instance.entries
      .take(AuditLogService.instance.entries.length - auditBefore)
      .where((e) => e.actionLabel.startsWith('AI_'))
      .map((e) => e.actionLabel)
      .toList();

  Future<void> sizeView(WidgetTester tester) async {
    tester.view.physicalSize = const Size(576, 1280);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Scan → review; the step animation advances one step per 800 ms.
  Future<void> toReview(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 800));
    }
    expect(find.byType(ElevatedButton), findsOneWidget);
  }

  /// Safe opened by the AI (GuardianControlScreen.showAiModal).
  Future<void> openByAi(WidgetTester tester) async {
    AnkrConfigService.instance.setKeyForTest('');
    await sizeView(tester);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () =>
                  GuardianControlScreen.showAiModal(context, mode: 'safe'),
              child: const Text('open by AI'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open by AI'));
    await toReview(tester);
  }

  /// Safe opened by the user from the «Safe/Panic» screen.
  Future<void> openByUser(WidgetTester tester) async {
    AnkrConfigService.instance.setKeyForTest('');
    await sizeView(tester);
    await tester.pumpWidget(const MaterialApp(home: GuardianControlScreen()));
    await tester.tap(find.text(LocalizationService.instance
        .t('guardianSafeReview', {'default': 'Safe'})));
    await toReview(tester);
  }

  ElevatedButton revokeButton(WidgetTester tester) =>
      tester.widget<ElevatedButton>(find.byType(ElevatedButton));

  /// Taps revoke and lets the (failing, offline) revoke queue and the step
  /// animation finish, so no timer is left when the test ends.
  Future<void> tapRevoke(WidgetTester tester) async {
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  group('opened by the user: unchanged', () {
    for (final mode in AiMode.values) {
      testWidgets('${mode.name}: the tap revokes, no PIN, no AI card',
          (tester) async {
        setMode(mode);
        await openByUser(tester);
        expect(
            find.text(LocalizationService.instance
                .t('guardianBtnRevokeSelected', {'count': '1'})),
            findsOneWidget);

        await tapRevoke(tester);

        expect(revokeStarted(), isTrue);
        expect(pinAsked, 0);
        expect(cardsShown, 0);
        expect(aiAuditLabels(), isEmpty);
      });
    }
  });

  group('opened by the AI', () {
    testWidgets('«Советник»: review only, the button is off', (tester) async {
      setMode(AiMode.manual);
      await openByAi(tester);

      expect(revokeButton(tester).onPressed, isNull);
      expect(
          find.text(LocalizationService.instance.t('guardianBtnAdvisorReview',
              {'default': 'Advisor: review only'})),
          findsOneWidget);
      expect(revokeStarted(), isFalse);
    });

    testWidgets('«Ручной»: the PIN comes before the revoke', (tester) async {
      await openByAi(tester);
      expect(
          find.text(LocalizationService.instance.t('guardianBtnPinRevokeSafe',
              {'count': '1', 'default': 'Revoke selected with PIN (1)'})),
          findsOneWidget);

      await tapRevoke(tester);

      expect(pinAsked, 1);
      expect(cardsShown, 0, reason: 'no AI card in «Ручной»');
      expect(revokeStarted(), isTrue);
    });

    testWidgets('«Ручной»: no PIN = nothing is revoked', (tester) async {
      pinAnswers(false);
      await openByAi(tester);

      await tapRevoke(tester);

      expect(pinAsked, 1);
      expect(revokeStarted(), isFalse);
      expect(revokeButton(tester).onPressed, isNotNull,
          reason: 'the user may try again');
    });

    testWidgets('«Ручной» without a PIN set up: asks to set one, no revoke',
        (tester) async {
      GuardianControlScreen.debugAuthOverride = null;
      await openByAi(tester);

      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // What VaultUnlockScreen.requireAuth shows when nothing is set up.
      expect(
          find.text(LocalizationService.instance.t('securityRequiredTitle')),
          findsOneWidget);
      await tester
          .tap(find.text(LocalizationService.instance.t('swapCancel')));
      await tester.pump(const Duration(milliseconds: 300));

      expect(revokeStarted(), isFalse);
    });

    testWidgets('«Автономный», PIN ON: the card + PIN first, then the revoke',
        (tester) async {
      setMode(AiMode.fullAutonomy, pin: true);
      await openByAi(tester);
      expect(
          find.text(LocalizationService.instance.t('guardianBtnPinRevokeSafe',
              {'count': '1', 'default': 'Revoke selected with PIN (1)'})),
          findsOneWidget);

      await tapRevoke(tester);

      expect(cardsShown, 1);
      expect(pinAsked, 0, reason: 'the gate asks the PIN with its card');
      expect(revokeStarted(), isTrue);
      // The offline revoke fails: reported to the gate (audit), no
      // «ИИ выполнил», and the AI money-action lock is free again.
      expect(aiAuditLabels(), contains('AI_EXECUTION_FAILED'));
      expect(notified, isEmpty);
      final next = await gate.confirm(revokeSummary);
      expect(next.outcome, AiGateOutcome.execute);
      gate.release(next);
    });

    testWidgets('«Автономный», PIN ON, card declined: nothing is revoked',
        (tester) async {
      setMode(AiMode.fullAutonomy, pin: true);
      cardAnswers(false);
      await openByAi(tester);

      await tapRevoke(tester);

      expect(cardsShown, 1);
      expect(revokeStarted(), isFalse);
      expect(aiAuditLabels(), isEmpty);
      final next = await gate.confirm(revokeSummary);
      expect(next.outcome, isNot(AiGateOutcome.busy));
      gate.release(next);
    });

    testWidgets('«Автономный», PIN OFF: no card, no PIN', (tester) async {
      setMode(AiMode.fullAutonomy, pin: false);
      await openByAi(tester);
      expect(
          find.text(LocalizationService.instance
              .t('guardianBtnRevokeSelected', {'count': '1'})),
          findsOneWidget);

      await tapRevoke(tester);

      expect(cardsShown, 0);
      expect(pinAsked, 0);
      expect(revokeStarted(), isTrue);
      expect(aiAuditLabels(), contains('AI_EXECUTION_FAILED'));
    });

    testWidgets('«Автономный»: a paused EPK does not block a revoke',
        (tester) async {
      setMode(AiMode.fullAutonomy, pin: false);
      await tester.runAsync(EPKPolicyManager.instance.emergencyPause);
      expect(EPKPolicyManager.instance.state.isActive, isFalse);
      await openByAi(tester);

      await tapRevoke(tester);

      expect(revokeStarted(), isTrue);
      expect(cardsShown, 0);
    });

    testWidgets('«Автономный»: expired AI permissions ask the card, not block',
        (tester) async {
      setMode(AiMode.fullAutonomy,
          pin: false, expiry: DateTime.now().subtract(const Duration(days: 1)));
      await openByAi(tester);

      await tapRevoke(tester);

      expect(cardsShown, 1);
      expect(revokeStarted(), isTrue);
    });

    testWidgets('«Автономный»: another AI action running = the PIN decides',
        (tester) async {
      setMode(AiMode.fullAutonomy, pin: false);
      final held = await gate.confirm(revokeSummary);
      expect(held.mayExecute, isTrue);
      await openByAi(tester);

      await tapRevoke(tester);

      expect(pinAsked, 1);
      expect(revokeStarted(), isTrue);
      gate.release(held);
    });
  });

  group('GuardianFlowController.confirmAction', () {
    test('returns false and never reports when nothing can start', () {
      final controller = GuardianFlowController();
      var reported = 0;
      controller.model = const GuardianFlowModel(
          mode: GuardianMode.safe, state: GuardianFlowState.failed);
      expect(controller.confirmAction(onFinished: (_) => reported++), isFalse);
      controller.model = const GuardianFlowModel(
          mode: GuardianMode.safe, state: GuardianFlowState.readyReview);
      expect(controller.confirmAction(onFinished: (_) => reported++), isFalse,
          reason: 'nothing selected');
      expect(reported, 0);
      expect(TransactionQueue().currentJobs, isEmpty);
      controller.dispose();
    });

    test('reports the finished queue exactly once', () async {
      final controller = GuardianFlowController();
      final results = <RevokeProgress>[];
      final approval = _approval();
      controller.model = GuardianFlowModel(
        mode: GuardianMode.safe,
        state: GuardianFlowState.readyReview,
        all: [approval],
        warnings: [approval],
        selected: [approval],
      );

      expect(controller.confirmAction(onFinished: results.add), isTrue);
      // The offline revoke fails; the queue waits 600 ms between jobs.
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(results, hasLength(1));
      expect(results.single.total, 1);
      expect(results.single.successCount, 0);
      expect(results.single.failedCount, 1);
      controller.dispose();
    });
  });
}
