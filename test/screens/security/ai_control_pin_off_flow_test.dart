// AI-Центр, «Подтверждать действия ИИ ПИН-кодом» (owner decision D4):
//   • shown only while «Автономный» is selected;
//   • turning it OFF: a PIN or biometrics must be set up (otherwise it is
//     refused and stays ON) → a warning → the notification permission is
//     checked, and asked for (a second warning when Android blocks it) → the
//     PIN / biometrics (VaultUnlockScreen.requireAuth) → only then OFF;
//   • turning it ON is free.
//
// The notification permission goes through the real plugin channel; the PIN
// screen is the real VaultUnlockScreen (a correct PIN pops it with true,
// exactly what its _unlockAndGo does in the modal mode).
//
// Run: flutter test test/screens/security/ai_control_pin_off_flow_test.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/screens/security/ai_control_screen.dart';
import 'package:ibiti_guardian/screens/vault/vault_unlock_screen.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('dexterous.com/flutter/local_notifications');
const _wallet = '0x7777777777777777777777777777777777777777';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final vault = IBITIVaultService.instance;
  final ai = AiControlService.instance;
  final t = LocalizationService.instance;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final pinSwitch = find.byKey(const ValueKey('aiPinConfirmSwitch'));

  /// Notification-plugin calls, in order.
  late List<String> calls;
  late bool notificationsEnabled;
  late bool permissionGranted;

  // The dialog titles the screen shows (its defaults: no language loaded).
  String warnTitle() => t.t('aiPinConfirmOffWarnTitle',
      {'default': 'Let the AI act without your PIN?'});
  String notifTitle() =>
      t.t('aiPinConfirmNotifOffTitle', {'default': 'Notifications are off'});

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    // A vault without a PIN or biometrics; «Автономный», PIN setting ON.
    vault.setVaultCreatedForTest(evmAddress: _wallet);
    ai.setSettingsForTest(const AiControlSettings(
      mode: AiMode.fullAutonomy,
      allowedActions: AiAction.values,
    ));

    AndroidFlutterLocalNotificationsPlugin.registerWith();
    calls = [];
    notificationsEnabled = true;
    permissionGranted = true;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'areNotificationsEnabled':
          return notificationsEnabled;
        case 'requestNotificationsPermission':
          return permissionGranted;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    ai.setSettingsForTest(const AiControlSettings());
    vault.setVaultCreatedForTest(evmAddress: '');
  });

  Future<void> openAiCenter(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: AIControlScreen()));
    await tester.pumpAndSettle();
    expect(pinSwitch, findsOneWidget);
    await tester.ensureVisible(pinSwitch);
    await tester.pumpAndSettle();
  }

  Future<void> tapSwitch(WidgetTester tester) async {
    await tester.tap(pinSwitch);
    await tester.pumpAndSettle();
  }

  Finder dialogButton(Type type) => find.descendant(
      of: find.byType(AlertDialog), matching: find.byType(type));

  /// «Отключить» / «Всё равно продолжить» (the dialog's FilledButton).
  Future<void> proceed(WidgetTester tester) async {
    await tester.tap(dialogButton(FilledButton));
    await tester.pumpAndSettle();
  }

  /// «Отмена» (the dialog's TextButton).
  Future<void> cancelDialog(WidgetTester tester) async {
    await tester.tap(dialogButton(TextButton));
    await tester.pumpAndSettle();
  }

  /// The PIN screen answers: true = the right PIN / biometrics (what
  /// VaultUnlockScreen does after a correct PIN in the modal mode), false =
  /// closed without it.
  Future<void> answerPin(WidgetTester tester, bool ok) async {
    final pinScreen = find.byType(VaultUnlockScreen);
    expect(pinScreen, findsOneWidget);
    Navigator.of(tester.element(pinScreen)).pop(ok);
    await tester.pumpAndSettle();
  }

  testWidgets('the switch is shown only in «Автономный»', (tester) async {
    for (final mode in [AiMode.manual, AiMode.guarded]) {
      ai.setSettingsForTest(AiControlSettings(mode: mode));
      await tester.pumpWidget(const MaterialApp(home: AIControlScreen()));
      await tester.pumpAndSettle();
      expect(pinSwitch, findsNothing, reason: mode.name);
    }
  });

  testWidgets('without a PIN or biometrics it cannot be turned off',
      (tester) async {
    await openAiCenter(tester);

    await tapSwitch(tester);

    expect(find.byType(SnackBar), findsOneWidget, reason: 'says why');
    expect(find.byType(AlertDialog), findsNothing, reason: 'no warning');
    expect(find.byType(VaultUnlockScreen), findsNothing);
    expect(calls, isNot(contains('areNotificationsEnabled')));
    expect(ai.settings.aiPinConfirm, isTrue);
  });

  testWidgets('turning it ON is free: no warning, no permission check, no PIN',
      (tester) async {
    ai.setSettingsForTest(const AiControlSettings(
      mode: AiMode.fullAutonomy,
      allowedActions: AiAction.values,
      aiPinConfirm: false,
    ));
    await openAiCenter(tester);

    await tapSwitch(tester);

    expect(ai.settings.aiPinConfirm, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(VaultUnlockScreen), findsNothing);
    expect(calls, isEmpty);
  });

  group('with a PIN set up', () {
    setUp(() => vault.setPinEnabled(true));

    testWidgets('OFF: the warning comes first; «Отмена» keeps it ON',
        (tester) async {
      await openAiCenter(tester);

      await tapSwitch(tester);
      expect(find.text(warnTitle()), findsOneWidget);
      expect(calls, isNot(contains('areNotificationsEnabled')),
          reason: 'the permission is checked after the warning');
      expect(find.byType(VaultUnlockScreen), findsNothing);

      await cancelDialog(tester);
      expect(ai.settings.aiPinConfirm, isTrue);
      expect(find.byType(VaultUnlockScreen), findsNothing);
      expect(calls, isNot(contains('areNotificationsEnabled')));
    });

    testWidgets(
        'OFF: warning → notification check → PIN; closing the PIN screen '
        'keeps it ON', (tester) async {
      await openAiCenter(tester);
      await tapSwitch(tester);

      await proceed(tester); // «Отключить»
      // Notifications are on: checked, not asked, no second warning.
      expect(calls, contains('areNotificationsEnabled'));
      expect(calls, isNot(contains('requestNotificationsPermission')));
      expect(find.text(notifTitle()), findsNothing);
      // Then the PIN — still ON while it is open.
      expect(find.byType(VaultUnlockScreen), findsOneWidget);
      expect(ai.settings.aiPinConfirm, isTrue);

      await answerPin(tester, false);
      expect(ai.settings.aiPinConfirm, isTrue);
    });

    testWidgets('OFF: the right PIN turns it off', (tester) async {
      await openAiCenter(tester);
      await tapSwitch(tester);
      await proceed(tester);

      await answerPin(tester, true);

      expect(ai.settings.aiPinConfirm, isFalse);
      expect(ai.settings.mode, AiMode.fullAutonomy);
    });

    testWidgets(
        'OFF: notifications blocked → asks Android, then warns; «Отмена» '
        'keeps it ON without the PIN', (tester) async {
      notificationsEnabled = false;
      permissionGranted = false;
      await openAiCenter(tester);
      await tapSwitch(tester);

      await proceed(tester);
      expect(
          calls.where((c) =>
              c == 'areNotificationsEnabled' ||
              c == 'requestNotificationsPermission'),
          ['areNotificationsEnabled', 'requestNotificationsPermission']);
      expect(find.text(notifTitle()), findsOneWidget);
      expect(find.byType(VaultUnlockScreen), findsNothing);

      await cancelDialog(tester);
      expect(find.byType(VaultUnlockScreen), findsNothing);
      expect(ai.settings.aiPinConfirm, isTrue);
    });

    testWidgets(
        'OFF: notifications blocked, «Всё равно продолжить» → the PIN still '
        'decides', (tester) async {
      notificationsEnabled = false;
      permissionGranted = false;
      await openAiCenter(tester);
      await tapSwitch(tester);
      await proceed(tester); // the warning
      await proceed(tester); // notifications are off: continue anyway

      expect(find.byType(VaultUnlockScreen), findsOneWidget);
      expect(ai.settings.aiPinConfirm, isTrue);
      await answerPin(tester, true);
      expect(ai.settings.aiPinConfirm, isFalse);
    });

    testWidgets(
        'OFF: Android grants the permission when asked → no second warning, '
        'the PIN next', (tester) async {
      notificationsEnabled = false;
      permissionGranted = true;
      await openAiCenter(tester);
      await tapSwitch(tester);

      await proceed(tester);
      expect(calls, contains('requestNotificationsPermission'));
      expect(find.text(notifTitle()), findsNothing);
      expect(find.byType(VaultUnlockScreen), findsOneWidget);

      await answerPin(tester, false);
      expect(ai.settings.aiPinConfirm, isTrue);
    });

    testWidgets(
        'OFF: the mode left «Автономный» while the PIN screen was open → '
        'stays ON', (tester) async {
      await openAiCenter(tester);
      await tapSwitch(tester);
      await proceed(tester);
      expect(find.byType(VaultUnlockScreen), findsOneWidget);

      ai.setSettingsForTest(const AiControlSettings(mode: AiMode.guarded));
      await answerPin(tester, true);

      expect(ai.settings.aiPinConfirm, isTrue);
    });
  });

  group('with biometrics only', () {
    setUp(() => vault.setBiometricsEnabled(true));

    testWidgets('biometrics count as set up: the warning, not a refusal',
        (tester) async {
      await openAiCenter(tester);

      await tapSwitch(tester);

      expect(find.byType(SnackBar), findsNothing);
      expect(find.text(warnTitle()), findsOneWidget);
      await cancelDialog(tester);
      expect(ai.settings.aiPinConfirm, isTrue);
    });
  });
}
