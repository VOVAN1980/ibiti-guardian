import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/automation_trigger.dart';
import 'package:ibiti_guardian/services/market/automation_dispatch_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// «Подтверждать действия ИИ ПИН-кодом» (AiControlSettings.aiPinConfirm):
/// default ON, stored in the settings JSON, reset to ON when leaving
/// «Автономный» and on emergency stop, and never OFF from the plaintext
/// backup.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const settingsKey = 'ai_control_settings';
  const permModelKey = 'ai_control_perm_model_v';
  final service = AiControlService.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({permModelKey: 3});
    FlutterSecureStorage.setMockInitialValues({});
    service.setSettingsForTest(const AiControlSettings());
  });

  group('settings JSON', () {
    test('ON by default', () {
      expect(const AiControlSettings().aiPinConfirm, isTrue);
    });

    test('a missing key means ON (older builds and backups)', () {
      final s = AiControlSettings.fromJson({'mode': 'fullAutonomy'});
      expect(s.mode, AiMode.fullAutonomy);
      expect(s.aiPinConfirm, isTrue);
      expect(AiControlSettings.fromJson({'aiPinConfirm': null}).aiPinConfirm,
          isTrue);
      expect(AiControlSettings.fromJson({'aiPinConfirm': 'no'}).aiPinConfirm,
          isTrue,
          reason: 'only an explicit false turns it off');
    });

    test('OFF survives a toJson / fromJson round trip', () {
      const off =
          AiControlSettings(mode: AiMode.fullAutonomy, aiPinConfirm: false);
      final json = jsonDecode(jsonEncode(off.toJson())) as Map<String, dynamic>;
      expect(json['aiPinConfirm'], isFalse);
      expect(AiControlSettings.fromJson(json).aiPinConfirm, isFalse);
    });

    test('copyWith keeps the setting unless it is given', () {
      const off =
          AiControlSettings(mode: AiMode.fullAutonomy, aiPinConfirm: false);
      expect(off.copyWith(dailyLimit: 10).aiPinConfirm, isFalse);
      expect(off.copyWith(clearExpiry: true).aiPinConfirm, isFalse);
      expect(off.copyWith(aiPinConfirm: true).aiPinConfirm, isTrue);
    });

    test('pinRequiredForAi: always outside «Автономный»', () {
      for (final mode in [AiMode.manual, AiMode.guarded]) {
        expect(
            AiControlSettings(mode: mode, aiPinConfirm: false).pinRequiredForAi,
            isTrue);
        expect(AiControlSettings(mode: mode).pinRequiredForAi, isTrue);
      }
      expect(
          const AiControlSettings(mode: AiMode.fullAutonomy).pinRequiredForAi,
          isTrue);
      expect(
          const AiControlSettings(
                  mode: AiMode.fullAutonomy, aiPinConfirm: false)
              .pinRequiredForAi,
          isFalse);
    });
  });

  group('AiControlService', () {
    test('setAiPinConfirm(false) stores OFF in «Автономный» and mirrors it',
        () async {
      service.setSettingsForTest(
          const AiControlSettings(mode: AiMode.fullAutonomy));
      await service.setAiPinConfirm(false);
      expect(service.settings.aiPinConfirm, isFalse);
      expect(service.settings.pinRequiredForAi, isFalse);

      final prefs = await SharedPreferences.getInstance();
      final mirrored =
          jsonDecode(prefs.getString(settingsKey)!) as Map<String, dynamic>;
      expect(mirrored['aiPinConfirm'], isFalse);
    });

    test('OFF is ignored outside «Автономный»; ON is always allowed',
        () async {
      service.setSettingsForTest(const AiControlSettings(mode: AiMode.guarded));
      await service.setAiPinConfirm(false);
      expect(service.settings.aiPinConfirm, isTrue);

      service.setSettingsForTest(const AiControlSettings(
          mode: AiMode.fullAutonomy, aiPinConfirm: false));
      await service.setAiPinConfirm(true);
      expect(service.settings.aiPinConfirm, isTrue);
    });

    test('leaving «Автономный» turns it back ON', () async {
      service.setSettingsForTest(const AiControlSettings(
          mode: AiMode.fullAutonomy, aiPinConfirm: false));
      await service.updateMode(AiMode.fullAutonomy);
      expect(service.settings.aiPinConfirm, isFalse,
          reason: 'staying in «Автономный» keeps the choice');

      await service.updateMode(AiMode.guarded);
      expect(service.settings.aiPinConfirm, isTrue);
      await service.updateMode(AiMode.fullAutonomy);
      expect(service.settings.aiPinConfirm, isTrue,
          reason: 'coming back to «Автономный» starts with the PIN');
    });

    test('emergency stop turns it back ON and cancels the delegate queue',
        () async {
      service.setSettingsForTest(const AiControlSettings(
          mode: AiMode.fullAutonomy, aiPinConfirm: false));
      final dispatch = AutomationDispatchService.instance;
      final item = dispatch.enqueue(
        trigger: AutomationTrigger(
          id: 'delegate_test',
          assetSymbol: 'SOL',
          type: TriggerType.manualDelegate,
          requestedAction: TriggerAction.execute,
          createdAt: DateTime.now(),
        ),
        reason: 'test',
        currentPrice: 100,
      );
      expect(item, isNotNull);
      expect(dispatch.pendingCount, greaterThan(0));

      await service.emergencyStop();
      expect(service.settings.mode, AiMode.manual);
      expect(service.settings.aiPinConfirm, isTrue);
      expect(dispatch.pendingCount, 0);
      expect(
          dispatch.allItems.firstWhere((i) => i.id == item!.id).isTerminal,
          isTrue);
    });

    test('settings from the plaintext backup always come back ON', () async {
      SharedPreferences.setMockInitialValues({
        permModelKey: 3,
        settingsKey: jsonEncode(const AiControlSettings(
                mode: AiMode.fullAutonomy, aiPinConfirm: false)
            .toJson()),
      });
      FlutterSecureStorage.setMockInitialValues({});
      await service.init();
      expect(service.settings.mode, AiMode.fullAutonomy);
      expect(service.settings.aiPinConfirm, isTrue);
    });

    test('settings from the encrypted store keep OFF', () async {
      final json = jsonEncode(
          const AiControlSettings(mode: AiMode.fullAutonomy, aiPinConfirm: false)
              .toJson());
      FlutterSecureStorage.setMockInitialValues({settingsKey: json});
      SharedPreferences.setMockInitialValues({permModelKey: 3});
      await service.init();
      expect(service.settings.mode, AiMode.fullAutonomy);
      expect(service.settings.aiPinConfirm, isFalse);
    });
  });
}
