import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/app_settings.dart';
import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/services/assistant/guardian_assistant_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/services/voice/speech_formatter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Russian policy limits use user-facing Russian names', () async {
    SettingsService.instance.settingsForTest = AppSettings(
      openaiApiKey: null,
      isNeuralOperatorEnabled: false,
    );
    AiControlService.instance.setSettingsForTest(
      const AiControlSettings(
        mode: AiMode.fullAutonomy,
        allowedActions: [
          AiAction.openWindows,
          AiAction.policyUpdate,
          AiAction.send,
          AiAction.swap,
        ],
        dailyLimit: 750,
        minTradeBalance: 25,
        mandate: AutonomyMandate(
          maxPositionUsd: 200,
          maxGasUsd: 15,
          maxSlippageBps: 75,
          maxDailyLossUsd: 80,
          maxDrawdownPct: 2.5,
          maxOpenPositions: 4,
          stopAfterLosses: 2,
        ),
      ),
    );

    final response = await GuardianAssistantService.instance.process(
      'Какие у нас есть лимиты в политике?',
      languageCode: 'ru',
      source: AssistantInputSource.voice,
    );

    expect(response.message, contains('Текущий режим ИИ: полная автономия'));
    expect(response.message, contains('Лимит одного перевода'));
    expect(response.message, contains('Лимит одного обмена'));
    expect(response.message, contains('Лимит разрешения токена'));
    expect(response.message, contains('Максимальный размер одной позиции'));
    expect(response.message, contains('Максимальная комиссия сети'));
    expect(response.message, contains('Максимальное проскальзывание'));
    expect(response.message, contains('открытие экранов и окон'));
    expect(response.message, contains('изменение политики'));
    expect(response.message, isNot(contains('fullAutonomy')));
    expect(response.message, isNot(contains('openWindows')));
    expect(response.message, isNot(contains('policyUpdate')));
    expect(response.message, isNot(contains('any')));
    expect(response.uiCommands, isEmpty);

    final spoken = SpeechFormatter.normalize(response.speechText, lang: 'ru');
    expect(spoken, isNot(matches(RegExp(r'\d'))));
  });
}
