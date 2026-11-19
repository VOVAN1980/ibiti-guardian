import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/assistant/voice_greeting_service.dart';
import 'package:ibiti_guardian/services/voice/ai_voice.dart';

/// Settings offers exactly two voices («Мужской» cedar, «Женский» marin), and
/// a voice saved by an older build is moved to one of them on start.
void main() {
  group('Settings voice picker', () {
    test('offers exactly two voices, male first', () {
      expect(VoiceGreetingService.voiceIds, [AiVoice.male, AiVoice.female]);
      expect(VoiceGreetingService.voiceIds, ['cedar', 'marin']);
    });

    test('labels in Russian', () {
      expect(
          VoiceGreetingService.voiceIds.map(
              (id) => VoiceGreetingService.voiceLabel(id, isRussian: true)),
          ['Мужской', 'Женский']);
    });

    test('labels in English', () {
      expect(
          VoiceGreetingService.voiceIds.map(
              (id) => VoiceGreetingService.voiceLabel(id, isRussian: false)),
          ['Male', 'Female']);
    });
  });

  group('init() migration of an older saved voice', () {
    test('older male ids and no voice are saved as cedar', () {
      for (final id in ['verse', 'echo', 'ash', 'onyx', 'fable']) {
        expect(VoiceGreetingService.migratedVoiceId(id), 'cedar', reason: id);
      }
      expect(VoiceGreetingService.migratedVoiceId(null), 'cedar');
    });

    test('older female ids are saved as marin', () {
      for (final id in ['coral', 'shimmer', 'sage', 'nova']) {
        expect(VoiceGreetingService.migratedVoiceId(id), 'marin', reason: id);
      }
      expect(VoiceGreetingService.migratedVoiceId('Marin'), 'marin');
    });

    test('a current voice is left as it is', () {
      expect(VoiceGreetingService.migratedVoiceId('cedar'), isNull);
      expect(VoiceGreetingService.migratedVoiceId('marin'), isNull);
    });
  });
}
