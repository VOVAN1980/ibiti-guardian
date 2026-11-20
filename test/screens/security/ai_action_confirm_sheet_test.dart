import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/main.dart' show navigatorKey;
import 'package:ibiti_guardian/screens/security/widgets/ai_action_confirm_sheet.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/services/security/ai_action_gate.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The AI confirmation card: what / amount / venue / fee, Cancel / Confirm,
/// cannot be tapped away, and the gate can close it (voice «да» / «нет»).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const order = AiActionSummary(
    kind: AiActionKind.cexOrder,
    title: 'Buy SOL on MEXC',
    amountLabel: '10 USDT',
    valueUsd: 10,
    venue: 'mexc',
    assetSymbol: 'SOL',
    feeLabel: '≈0.1% exchange fee',
    source: 'voice',
  );

  const confirmKey = ValueKey('aiActionCardConfirm');
  const cancelKey = ValueKey('aiActionCardCancel');

  Future<void> pumpOpener(
    WidgetTester tester,
    void Function(BuildContext context) onOpen,
  ) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => onOpen(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('AiActionConfirmSheet', () {
    testWidgets('shows the operation; Confirm → true, Cancel → false',
        (tester) async {
      bool? result;
      await pumpOpener(tester, (context) async {
        result = await AiActionConfirmSheet.show(context, order);
      });

      expect(find.text('Buy SOL on MEXC'), findsOneWidget);
      expect(find.text('10 USDT'), findsOneWidget);
      expect(find.text('MEXC'), findsOneWidget);
      expect(find.text('≈0.1% exchange fee'), findsOneWidget);

      // Tapping outside does not close it.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byKey(confirmKey), findsOneWidget);

      await tester.tap(find.byKey(confirmKey));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(find.byKey(confirmKey), findsNothing);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(cancelKey));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });

    testWidgets('the gate closes it with its answer', (tester) async {
      final answer = ValueNotifier<bool?>(null);
      bool? result;
      await pumpOpener(tester, (context) async {
        result = await AiActionConfirmSheet.show(context, order,
            note: 'New address', answer: answer);
      });
      expect(find.text('New address'), findsOneWidget);

      answer.value = true;
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(find.byKey(confirmKey), findsNothing);
    });
  });

  group('AiActionGate with the real card', () {
    final gate = AiActionGate.instance;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      // A vault without a PIN or biometrics.
      IBITIVaultService.instance.setVaultCreatedForTest(
          evmAddress: '0x9999999999999999999999999999999999999999');
      DelegationController.instance.resetUsageForTest();
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.fullAutonomy,
        allowedActions: AiAction.values,
        dailyLimit: 1000,
      ));
      gate.resetForTest();
      gate.foregroundOverride = () => true;
      gate.notifyOverride = (_, __) {};
    });

    tearDown(() => gate.resetForTest());

    Future<void> pumpApp(WidgetTester tester) => tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigatorKey,
            home: const Scaffold(body: SizedBox.shrink()),
          ),
        );

    testWidgets('Cancel on the card: cancelled, the lock is free',
        (tester) async {
      await pumpApp(tester);
      final pending = gate.confirm(order);
      await tester.pumpAndSettle();
      expect(gate.hasOpenCard, isTrue);
      expect(find.text('Buy SOL on MEXC'), findsOneWidget);

      await tester.tap(find.byKey(cancelKey));
      await tester.pumpAndSettle();
      final d = await pending;
      expect(d.outcome, AiGateOutcome.cancelled);
      expect(gate.hasOpenCard, isFalse);
    });

    testWidgets('«да» by voice closes the card; the PIN still follows',
        (tester) async {
      await pumpApp(tester);
      final pending = gate.confirm(order);
      await tester.pumpAndSettle();
      expect(gate.hasOpenCard, isTrue);

      gate.answerByVoice(true);
      await tester.pumpAndSettle();
      expect(find.byKey(confirmKey), findsNothing);

      // No PIN / biometrics set up: requireAuth asks to set one up; closing
      // that dialog means the PIN was not confirmed — nothing runs.
      expect(find.text('swapCancel'), findsOneWidget);
      await tester.tap(find.text('swapCancel'));
      await tester.pumpAndSettle();
      final d = await pending;
      expect(d.mayExecute, isFalse);
      expect(d.outcome, AiGateOutcome.cancelled);
    });
  });
}
