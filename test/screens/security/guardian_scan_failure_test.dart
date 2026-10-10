import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/approval.dart';
import 'package:ibiti_guardian/screens/security/guardian_control_screen.dart';
import 'package:ibiti_guardian/screens/security/guardian_flow_controller.dart';
import 'package:ibiti_guardian/services/ankr/ankr_config_service.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/security/approval_scan_service.dart';
import 'package:ibiti_guardian/services/security/approval_source.dart';
import 'package:ibiti_guardian/services/transaction_queue.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';

const _wallet = '0x1111111111111111111111111111111111111111';
ApprovalData _approval() => ApprovalData(
    token: '0x2222222222222222222222222222222222222222',
    spenderAddress: '0x3333333333333333333333333333333333333333',
    spender: 'Test spender',
    allowance: BigInt.from(10),
    tokenSymbol: 'TEST',
    walletAddress: _wallet);

class _Source implements ApprovalSource {
  int calls = 0;
  final responses = <Completer<List<ApprovalData>>>[];
  @override
  Future<List<ApprovalData>> fetch(String wallet,
      {required int chainId, String? targetTokenAddress}) {
    expect(wallet, _wallet);
    expect(chainId, 56);
    expect(targetTokenAddress, isNull);
    return responses[calls++].future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Source source;
  late RevokeJob untouchedJob;
  final lastScan = DateTime.utc(2026, 10, 9);
  String text(String key) => LocalizationService.instance.t(key);

  setUp(() async {
    await LocalizationService.instance.load(const Locale('ru'));
    IBITIVaultService.instance.setVaultCreatedForTest(evmAddress: _wallet);
    AnkrConfigService.instance.setKeyForTest('');
    source = _Source();
    ApprovalScanService.sourceOverride = source;
    ApprovalScanService.lastRiskScore = 17;
    ApprovalScanService.hasRiskyApprovals = true;
    ApprovalScanService.lastScanTime = lastScan;
    ApprovalScanService.lastScannedApprovals = [];
    // A scan must not clear, submit or otherwise touch the existing queue.
    TransactionQueue().clear();
    TransactionQueue().addJobs([_approval()]);
    untouchedJob = TransactionQueue().currentJobs.single;
  });
  tearDown(() {
    ApprovalScanService.sourceOverride = null;
    AnkrConfigService.instance.setKeyForTest('');
    IBITIVaultService.instance.setVaultCreatedForTest(evmAddress: '');
    ApprovalScanService.lastRiskScore = null;
    ApprovalScanService.hasRiskyApprovals = false;
    ApprovalScanService.lastScanTime = null;
    ApprovalScanService.lastScannedApprovals = [];
    TransactionQueue().clear();
  });

  void noExecution() {
    expect(TransactionQueue().isRunning, false);
    expect(TransactionQueue().currentJobs, [untouchedJob]);
    expect(untouchedJob.status, RevokeJobStatus.pending);
    expect(untouchedJob.txHash, isNull);
  }

  void noGreenResult() {
    for (final key in [
      'guardianStepNoRisks',
      'guardianStepNoCriticals',
      'guardianStepNoAction',
      'guardianStepComplete',
      'guardianSafeBtnOk',
      'guardianPanicBtnOk',
      'guardianResNoApprovalsTitle',
      'guardianExecRevokingAuth',
      'guardianExecNoTxStarted',
    ]) {
      expect(find.text(text(key)), findsNothing, reason: key);
    }
  }

  Future<void> open(WidgetTester tester, GuardianMode mode) async {
    // Complete the fake config future in the widget test's FakeAsync zone.
    AnkrConfigService.instance.setKeyForTest('');
    tester.view.physicalSize = const Size(576, 1280);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: GuardianControlScreen()));
    await tester.tap(find.text(text(mode == GuardianMode.safe
        ? 'guardianSafeReview'
        : 'guardianPanicRevoke')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(source.calls, 1,
        reason: 'the modal must actually reach the read source');
  }

  Future<void> finishUi(WidgetTester tester) async {
    // The existing success animation deliberately advances one step at a time.
    // Never pumpAndSettle while the scanning pulse is intentionally repeating.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 800));
    }
  }

  for (final mode in GuardianMode.values) {
    test('failed ${mode.name} model never claims a no-risk scenario', () {
      final controller = GuardianFlowController();
      controller.model =
          GuardianFlowModel(mode: mode, state: GuardianFlowState.failed);
      expect(controller.model.scenario, isNull);
      controller.confirmAction();
      expect(controller.model.state, GuardianFlowState.failed);
      noExecution();
      controller.dispose();
    });

    testWidgets('${mode.name} timeout shows an error, not success or revoking',
        (tester) async {
      final pending = Completer<List<ApprovalData>>();
      source.responses.add(pending);
      await open(tester, mode);
      pending.completeError(const ApprovalSourceException('scan_timeout'));
      await tester.pump();
      expect(find.text(text('guardianErrFailedTitle')), findsNWidgets(2));
      expect(find.text(text('errorTimeout')), findsOneWidget);
      expect(find.text(text('guardianBtnRetry')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      noGreenResult();
      // A previously scheduled visual catch-up must not turn failure green.
      await finishUi(tester);
      noGreenResult();
      expect(tester.takeException(), isNull);
      expect(ApprovalScanService.lastRiskScore, 17);
      expect(ApprovalScanService.hasRiskyApprovals, true);
      expect(ApprovalScanService.lastScanTime, lastScan);
      noExecution();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump(const Duration(milliseconds: 400));
    });
  }

  testWidgets('a completed empty scan is the only way to show no approvals',
      (tester) async {
    final pending = Completer<List<ApprovalData>>();
    source.responses.add(pending);
    await open(tester, GuardianMode.safe);
    expect(find.text(text('guardianResNoApprovalsTitle')), findsNothing);
    pending.complete([]);
    await tester.pump();
    await finishUi(tester);
    expect(find.text(text('guardianResNoApprovalsTitle')), findsOneWidget);
    expect(find.text(text('guardianStepNoRisks')), findsOneWidget);
    expect(find.text(text('guardianSafeBtnOk')), findsOneWidget);
    expect(find.text('Понятно'), findsOneWidget);
    expect(find.text('Активных разрешений токенов: 0 (сеть BNB Chain)'),
        findsOneWidget);
    expect(find.text('Проверены разрешения токенов в выбранной сети.'),
        findsOneWidget);
    expect(find.textContaining('Проверено контрактов'), findsNothing);
    expect(find.textContaining('я в безопасности'), findsNothing);
    expect(find.text(text('guardianErrFailedTitle')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(ApprovalScanService.lastRiskScore, 100);
    expect(ApprovalScanService.hasRiskyApprovals, false);
    expect(ApprovalScanService.lastScanTime, isNot(lastScan));
    noExecution();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('retry resets failed visuals, performs one read, then succeeds',
      (tester) async {
    final first = Completer<List<ApprovalData>>();
    final retry = Completer<List<ApprovalData>>();
    source.responses.addAll([first, retry]);
    await open(tester, GuardianMode.safe);
    first.completeError(const ApprovalSourceException('scan_timeout'));
    await tester.pump();
    final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, text('guardianBtnRetry')));
    // Duplicate clicks from the previous frame may not start a second scan.
    await tester.tap(find.text(text('guardianBtnRetry')));
    button.onPressed!();
    await tester.pump();
    expect(source.calls, 2);
    expect(find.text(text('guardianErrFailedTitle')), findsNothing);
    expect(find.text(text('guardianStepNoRisks')), findsNothing);
    expect(find.text(text('guardianSafeBtnOk')), findsNothing);
    retry.complete([]);
    await tester.pump();
    await finishUi(tester);
    expect(find.text(text('guardianResNoApprovalsTitle')), findsOneWidget);
    expect(find.text(text('guardianSafeBtnOk')), findsOneWidget);
    noExecution();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('a repeated failure never becomes green and preserves old risks',
      (tester) async {
    final first = Completer<List<ApprovalData>>();
    final retry = Completer<List<ApprovalData>>();
    source.responses.addAll([first, retry]);
    await open(tester, GuardianMode.safe);
    first.completeError(const ApprovalSourceException('scan_timeout'));
    await tester.pump();
    await tester.tap(find.text(text('guardianBtnRetry')));
    await tester.pump();
    retry.completeError(const ApprovalSourceException('http_503'));
    await tester.pump();
    await finishUi(tester);
    noGreenResult();
    expect(find.text(text('errorApiFailed')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(ApprovalScanService.lastRiskScore, 17);
    expect(ApprovalScanService.lastScanTime, lastScan);
    noExecution();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets(
      'closing during a read ignores late completion without notifying UI',
      (tester) async {
    final pending = Completer<List<ApprovalData>>();
    source.responses.add(pending);
    await open(tester, GuardianMode.safe);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump(const Duration(milliseconds: 400));
    pending.completeError(const ApprovalSourceException('scan_timeout'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    expect(find.text(text('guardianBtnRetry')), findsNothing);
    expect(ApprovalScanService.lastRiskScore, 17);
    noExecution();
  });

  testWidgets(
      'a completed risky scan still offers review but never auto-executes',
      (tester) async {
    final pending = Completer<List<ApprovalData>>();
    source.responses.add(pending);
    await open(tester, GuardianMode.safe);
    pending.complete([_approval()]);
    await tester.pump();
    await finishUi(tester);
    expect(find.text(text('guardianStepReviewRisks')), findsOneWidget);
    expect(find.text(text('guardianStepNoRisks')), findsNothing);
    expect(find.text(text('guardianResNoApprovalsTitle')), findsNothing);
    expect(find.text(text('guardianErrFailedTitle')), findsNothing);
    noExecution();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump(const Duration(milliseconds: 400));
  });
}
