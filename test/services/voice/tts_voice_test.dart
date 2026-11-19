import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/app_settings.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/services/voice/ai_voice.dart';
import 'package:ibiti_guardian/services/voice/tts_service.dart';

/// The assistant has exactly two voices: male (cedar) and female (marin).
/// TTS always speaks with the one chosen in Settings, whatever the
/// personality, and in Russian the voice is described in its own gender.
void main() {
  void useVoice(String? voiceId, {bool stable = false}) {
    SettingsService.instance.settingsForTest = AppSettings(
      preferredAiVoiceId: voiceId,
      useStableVoice: stable,
    );
  }

  tearDown(() => SettingsService.instance.settingsForTest = AppSettings());

  group('AiVoice.normalize', () {
    test('the two voices are cedar (male) and marin (female)', () {
      expect(AiVoice.male, 'cedar');
      expect(AiVoice.female, 'marin');
      expect(AiVoice.all, ['cedar', 'marin']);
    });

    test('older male and unknown ids become cedar', () {
      for (final id in ['cedar', 'verse', 'echo', 'ash', 'onyx', 'fable']) {
        expect(AiVoice.normalize(id), AiVoice.male, reason: id);
      }
      expect(AiVoice.normalize('not-a-voice'), AiVoice.male);
    });

    test('older female ids become marin', () {
      for (final id in ['marin', 'coral', 'shimmer', 'sage', 'nova']) {
        expect(AiVoice.normalize(id), AiVoice.female, reason: id);
      }
    });

    test('no saved voice is cedar', () {
      expect(AiVoice.normalize(null), AiVoice.male);
      expect(AiVoice.normalize(''), AiVoice.male);
    });

    test('case and spaces do not matter', () {
      expect(AiVoice.normalize(' Marin '), AiVoice.female);
      expect(AiVoice.normalize('VERSE'), AiVoice.male);
    });
  });

  group('TtsService.voiceFor', () {
    test('gpt-4o-mini-tts gets the chosen voice as is', () {
      expect(TtsService.voiceFor('cedar', stable: false), 'cedar');
      expect(TtsService.voiceFor('marin', stable: false), 'marin');
    });

    test('tts-1 (Stable voice mode) gets onyx for cedar, nova for marin', () {
      expect(TtsService.voiceFor('cedar', stable: true), 'onyx');
      expect(TtsService.voiceFor('marin', stable: true), 'nova');
    });

    test('an older saved id is spoken with one of the two voices', () {
      expect(TtsService.voiceFor('verse', stable: false), 'cedar');
      expect(TtsService.voiceFor('coral', stable: false), 'marin');
      expect(TtsService.voiceFor('echo', stable: true), 'onyx');
      expect(TtsService.voiceFor('shimmer', stable: true), 'nova');
      expect(TtsService.voiceFor(null, stable: false), 'cedar');
      expect(TtsService.voiceFor(null, stable: true), 'onyx');
    });

    test('never more than two voices per model', () {
      const ids = <String?>[
        'verse', 'cedar', 'marin', 'alloy', 'echo', 'fable', 'nova',
        'onyx', 'shimmer', 'coral', 'sage', 'ash', null,
      ];
      expect(ids.map((id) => TtsService.voiceFor(id, stable: false)).toSet(),
          {'cedar', 'marin'});
      expect(ids.map((id) => TtsService.voiceFor(id, stable: true)).toSet(),
          {'onyx', 'nova'});
    });

    test('follows the voice chosen in Settings', () {
      useVoice('marin');
      expect(TtsService.voiceFor(AiVoice.current, stable: false), 'marin');

      useVoice('cedar', stable: true);
      expect(TtsService.voiceFor(AiVoice.current, stable: true), 'onyx');

      useVoice(null);
      expect(TtsService.voiceFor(AiVoice.current, stable: false), 'cedar');
    });
  });

  group('TtsService.instructionsFor', () {
    const character = 'Объясняет ясно и точно, без выдумок';

    test('Russian with the female voice is feminine', () {
      final text = TtsService.instructionsFor(
          russian: true, female: true, character: character);

      expect(text, contains('тёплая, уверенная, внимательная собеседница'));
      expect(text, isNot(contains('тёплый')));
      expect(text, isNot(contains('собеседник')));
    });

    test('Russian with the male voice is masculine', () {
      final text = TtsService.instructionsFor(
          russian: true, female: false, character: character);

      expect(text, contains('тёплый, уверенный, внимательный собеседник'));
      expect(text, isNot(contains('тёплая')));
      expect(text, isNot(contains('собеседница')));
    });

    test('Russian is read naturally, like a native speaker', () {
      for (final female in [true, false]) {
        final text = TtsService.instructionsFor(
            russian: true, female: female, character: character);

        expect(text, contains('как носитель языка'));
        expect(text, contains('без акцента'));
        expect(text, contains('Характер: $character.'));
      }
    });

    test('follows the gender of the voice chosen in Settings', () {
      useVoice('coral');
      expect(
          TtsService.instructionsFor(
              russian: true, female: AiVoice.isFemale, character: character),
          contains('собеседница'));

      useVoice('verse');
      expect(
          TtsService.instructionsFor(
              russian: true, female: AiVoice.isFemale, character: character),
          contains('собеседник,'));
    });

    test('English is neutral and the same for both voices', () {
      const en = 'Clear, accurate answers, never guesses';
      final female = TtsService.instructionsFor(
          russian: false, female: true, character: en);
      final male = TtsService.instructionsFor(
          russian: false, female: false, character: en);

      expect(female, male);
      expect(female, contains('warm, confident and attentive'));
      expect(female, contains('Character: $en.'));
      expect(female.toLowerCase(), isNot(contains('female')));
      expect(female.toLowerCase(), isNot(contains(' male')));
    });
  });
}
