import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/services/voice/tts_service.dart';
import 'package:ibiti_guardian/services/voice/ai_voice.dart';

/// Thin voice orchestrator facade.
///
/// Routes speak() calls to [TtsService] (gpt-4o-mini-tts).
/// Manages voice preference persistence and persona mode selection.
///
/// Previously proxied through RealtimeSessionManager (WebRTC) —
/// that path was removed as dead/expensive code in the WebRTC cleanup.
class VoiceGreetingService extends ChangeNotifier {
  VoiceGreetingService._();
  static final instance = VoiceGreetingService._();

  static const _log = GuardianLogger('VoiceGreeting');

  final TtsService _tts = TtsService.instance;

  /// The voices offered in Settings: exactly two, male (cedar) first, then
  /// female (marin). See [AiVoice].
  static const List<String> voiceIds = AiVoice.all;

  /// Label of [voiceId] in the Settings voice picker.
  static String voiceLabel(String voiceId, {required bool isRussian}) {
    final female = AiVoice.normalize(voiceId) == AiVoice.female;
    if (isRussian) return female ? 'Женский' : 'Мужской';
    return female ? 'Female' : 'Male';
  }

  /// The id init() saves in place of an older [saved] id (older builds
  /// offered 11 voices), or null when [saved] is already one of the two.
  @visibleForTesting
  static String? migratedVoiceId(String? saved) {
    final voice = AiVoice.normalize(saved);
    return saved == voice ? null : voice;
  }

  /// True when TTS is actively speaking.
  bool get isSpeaking => _tts.isCurrentlySpeaking;

  /// The voice chosen in Settings: [AiVoice.male] or [AiVoice.female].
  String get selectedVoiceId => AiVoice.current;

  Future<void> init() async {
    final saved = SettingsService.instance.settings.preferredAiVoiceId;
    final migrated = migratedVoiceId(saved);
    if (migrated != null) {
      await SettingsService.instance
          .updateAiSettings(preferredAiVoiceId: migrated);
    }
    _log.d('init: voice=$selectedVoiceId');
  }

  /// Speak text through TtsService (gpt-4o-mini-tts).
  Future<void> speak(String text) async {
    final cleanText = _normalizeForSpeech(text);
    if (cleanText.isEmpty) return;
    await _tts.speak(cleanText);
  }

  /// Stop current playback.
  Future<void> stop() async {
    await _tts.stop();
  }

  /// Update voice in settings (always one of the two, see [AiVoice]).
  Future<void> updateVoice(String voiceId) async {
    final normalized = AiVoice.normalize(voiceId);
    await SettingsService.instance
        .updateAiSettings(preferredAiVoiceId: normalized);
    notifyListeners();
  }

  VoicePersonaMode _personaMode = VoicePersonaMode.companion;
  VoicePersonaMode get currentPersonaMode => _personaMode;

  /// Persona mode — retained for API compatibility.
  /// With the TTS pipeline, persona is embedded in TtsService instructions
  /// rather than a live session update.
  void setPersonaMode(VoicePersonaMode mode) {
    _personaMode = mode;
    _log.d('Persona mode set: ${mode.name}');
  }

  /// Simplifies text for spoken output.
  String _normalizeForSpeech(String text) {
    if (text.isEmpty) return text;
    var result = text;
    result = result.replaceAll(RegExp(r'\*\*|\*|__|_'), '');
    result = result.replaceAllMapped(
        RegExp(r'\[([^\]]+)\]\([^\)]+\)'), (m) => m.group(1) ?? '');
    result = result.replaceAll(' → ', ' to ');
    result = result.replaceAll('→', ' to ');
    result = result.replaceAllMapped(RegExp(r'0x[a-fA-F0-9]{40}'), (match) {
      final addr = match.group(0)!;
      return 'адрес …${addr.substring(addr.length - 4)}';
    });
    result = result.replaceAllMapped(RegExp(r'(\d+)\.(\d{3})\d+'), (match) {
      return '${match.group(1)}.${match.group(2)}';
    });
    result = result.replaceAll('…', '').replaceAll('...', '');
    result = result.replaceAll('✓', '').replaceAll('✔', '');
    result = result.replaceAll('⚠️', '').replaceAll('❗', '');
    return result.trim();
  }
}

/// Voice persona modes — used to adjust operator instructions.
enum VoicePersonaMode { companion, analyst, operator, alert }
