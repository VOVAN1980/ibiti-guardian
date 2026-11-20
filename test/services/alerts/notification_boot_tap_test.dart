// D16 (critique C6): a notification tap — the one that launched the app
// (boot) or one while the app runs — must NEVER remove the unlock screen or
// reset the navigation stack. It waits until the vault is unlocked and the
// main screen is up, then opens its screen ON TOP (for «ИИ выполнил: …»: the
// 'ai_action' UICommand the main screen turns into the transaction history).
//
// Driven through the real plugin channel (no hooks in NotificationService):
// the boot tap comes from getNotificationAppLaunchDetails, a live tap from
// the platform's didReceiveNotificationResponse call.
//
// Run: flutter test test/services/alerts/notification_boot_tap_test.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/app/guardian_app_shell.dart';
import 'package:ibiti_guardian/main.dart' show navigatorKey;
import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/services/alerts/notification_service.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_bus.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('dexterous.com/flutter/local_notifications');
const _wallet = '0x5555555555555555555555555555555555555555';
const _lockScreenText = 'UNLOCK SCREEN (stand-in)';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final vault = IBITIVaultService.instance;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// What getNotificationAppLaunchDetails answers (null = not launched by a
  /// notification).
  Map<String, Object?>? launch;

  String payloadFor(String historyId) => jsonEncode(
      {'type': 'ai_action', 'historyId': historyId, 'kind': 'cexOrder'});

  Map<String, Object?> responseFor(String historyId) => {
        'notificationId': 7000,
        'actionId': null,
        'input': null,
        'notificationResponseType': 0, // selectedNotification
        'payload': payloadFor(historyId),
      };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    // The app has a PIN and sits on the unlock screen.
    vault.setVaultCreatedForTest(evmAddress: _wallet);
    await vault.setPinEnabled(true);
    vault.lock();
    GuardianAppShell.debugIsMountedOverride = false;

    AndroidFlutterLocalNotificationsPlugin.registerWith();
    launch = null;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'initialize':
          return true;
        case 'requestNotificationsPermission':
        case 'areNotificationsEnabled':
          return true;
        case 'getNotificationAppLaunchDetails':
          return launch;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    GuardianAppShell.debugIsMountedOverride = null;
    vault.setVaultCreatedForTest(evmAddress: '');
  });

  /// Commands the main screen would receive (subscribed in the test zone, so
  /// pump delivers them).
  List<UICommand> listenCommands() {
    final commands = <UICommand>[];
    final sub = UICommandBus.instance.commands.listen(commands.add);
    addTearDown(sub.cancel);
    return commands;
  }

  /// The app's navigator with only the unlock screen on it.
  Future<void> showUnlockScreen(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      home: const Scaffold(body: Center(child: Text(_lockScreenText))),
    ));
  }

  /// The unlock screen is still the only route: nothing removed it and
  /// nothing was opened over it.
  void expectOnlyUnlockScreen() {
    expect(find.text(_lockScreenText), findsOneWidget);
    expect(navigatorKey.currentState!.canPop(), isFalse);
  }

  /// A tap on a shown notification while the app runs.
  Future<void> tapNotification(String historyId) async {
    await messenger.handlePlatformMessage(
      _channel.name,
      _channel.codec.encodeMethodCall(
          MethodCall('didReceiveNotificationResponse', responseFor(historyId))),
      null,
    );
  }

  testWidgets(
      'boot tap: waits for the unlock and the main screen, then opens on top',
      (tester) async {
    final commands = listenCommands();
    launch = {
      'notificationLaunchedApp': true,
      'notificationResponse': responseFor('cex:mexc:1'),
    };
    await showUnlockScreen(tester);
    await NotificationService.instance.init();

    // The boot tap is routed 1 s after start: the app is locked → it waits.
    await tester.pump(const Duration(seconds: 2));
    expect(commands, isEmpty, reason: 'locked: nothing opens');
    expectOnlyUnlockScreen();

    // Unlocked, but the main screen is not up yet: it still waits.
    vault.unlock();
    await tester.pump(const Duration(milliseconds: 600));
    expect(commands, isEmpty);
    expectOnlyUnlockScreen();

    // The main screen is up: the entry opens on top, once.
    GuardianAppShell.debugIsMountedOverride = true;
    await tester.pump(const Duration(milliseconds: 400));
    expect(commands, hasLength(1));
    expect(commands.single.type, UICommandType.openModal);
    expect(commands.single.target, 'ai_action');
    expect(commands.single.payload?['historyId'], 'cex:mexc:1');
    expect(find.text(_lockScreenText), findsOneWidget,
        reason: 'routing never resets the stack');

    await tester.pump(const Duration(seconds: 6));
    expect(commands, hasLength(1), reason: 'routed exactly once');
  });

  testWidgets(
      'boot tap: without the main screen it is dropped, the unlock screen '
      'stays', (tester) async {
    final commands = listenCommands();
    launch = {
      'notificationLaunchedApp': true,
      'notificationResponse': responseFor('cex:mexc:2'),
    };
    await showUnlockScreen(tester);
    await NotificationService.instance.init();
    await tester.pump(const Duration(seconds: 2));
    expectOnlyUnlockScreen();

    vault.unlock();
    // It waits up to 5 s for the main screen, then gives up.
    await tester.pump(const Duration(seconds: 6));
    expect(commands, isEmpty);
    expectOnlyUnlockScreen();
  });

  testWidgets(
      'a tap while the app is locked again (main screen under the lock) waits '
      'for the unlock; only the latest tap opens, once', (tester) async {
    final commands = listenCommands();
    await showUnlockScreen(tester);
    await NotificationService.instance.init();
    await tester.pump();
    // The main screen is mounted under the lock screen.
    GuardianAppShell.debugIsMountedOverride = true;

    await tapNotification('tx:first');
    await tapNotification('tx:second');
    await tester.pump(const Duration(seconds: 1));
    expect(commands, isEmpty, reason: 'locked: nothing opens');
    expectOnlyUnlockScreen();

    vault.unlock();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(commands, hasLength(1));
    expect(commands.single.target, 'ai_action');
    expect(commands.single.payload?['historyId'], 'tx:second');
    expect(find.text(_lockScreenText), findsOneWidget);
  });

  testWidgets('a tap in the unlocked app opens on top at once', (tester) async {
    final commands = listenCommands();
    vault.unlock();
    GuardianAppShell.debugIsMountedOverride = true;
    await showUnlockScreen(tester); // here: the current screen of the app
    await NotificationService.instance.init();
    await tester.pump();

    await tapNotification('cex:okx:3');
    await tester.pump();
    expect(commands, hasLength(1));
    expect(commands.single.payload?['historyId'], 'cex:okx:3');
    expect(find.text(_lockScreenText), findsOneWidget,
        reason: 'the current screen is kept');
    expect(navigatorKey.currentState!.canPop(), isFalse);
  });
}
