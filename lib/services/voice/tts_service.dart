import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/services/assistant/api_key_provider.dart';
import 'package:ibiti_guardian/models/jarvis_personality.dart';
import 'package:ibiti_guardian/services/assistant/voice_greeting_service.dart';
import 'package:ibiti_guardian/services/voice/ai_voice.dart';

/// Converts text to speech using OpenAI gpt-4o-mini-tts and plays it back.
///
/// Supports two modes:
///   1. `speak(text)` — legacy, plays full text as single chunk.
///   2. `speakStream(chunks)` — streaming, plays chunks as they arrive
///      with concurrent prefetch for seamless audio.
///
/// Cost: $0.60/1M input chars + $12/1M audio output tokens.
/// A typical 100-word response ≈ $0.0001 — the primary voice pipeline.
class TtsService {
  TtsService._();
  static final instance = TtsService._();

  static const _log = GuardianLogger('TTS');

  static const _endpoint = 'https://api.openai.com/v1/audio/speech';
  static const double speechRate = 0.98;

  String get _model {
    final useStable = SettingsService.instance.settings.useStableVoice;
    return useStable ? 'tts-1' : 'gpt-4o-mini-tts';
  }

  // The two voices offered in Settings (AiVoice): male cedar, female marin.
  // An older saved id is mapped to one of them by AiVoice.normalize. The
  // personality never picks the voice.
  static const _validVoices = {AiVoice.male, AiVoice.female};

  // tts-1 (Stable voice mode) has no cedar or marin: the closest classic
  // voice of the same gender.
  static const _stableVoices = {AiVoice.male: 'onyx', AiVoice.female: 'nova'};

  /// The voice sent to OpenAI for the saved [voiceId]: one of the two
  /// Settings voices, or its tts-1 equivalent when [stable].
  @visibleForTesting
  static String voiceFor(String? voiceId, {required bool stable}) {
    var voice = AiVoice.normalize(voiceId);
    if (!_validVoices.contains(voice)) voice = AiVoice.male;
    return stable ? (_stableVoices[voice] ?? 'onyx') : voice;
  }

  /// Voice instructions for gpt-4o-mini-tts. [character] is the personality
  /// description. In Russian the voice is described in the grammatical
  /// gender of the chosen voice ([female]); the English text is neutral.
  @visibleForTesting
  static String instructionsFor({
    required bool russian,
    required bool female,
    required String character,
  }) {
    // Earlier instructions asked for pauses between words, every syllable
    // pronounced separately and an even tone, which is exactly what made
    // the voice sound robotic. Numbers already arrive as words
    // (SpeechFormatter), so the voice only has to read them naturally.
    if (russian) {
      final person = female
          ? 'тёплая, уверенная, внимательная собеседница'
          : 'тёплый, уверенный, внимательный собеседник';
      return 'Ты — голос ассистента IBITI Guardian. '
          'Характер: $character. '
          'Говори как живой человек: $person, а не диктор и не робот. '
          'Интонация идёт от смысла: в вопросе голос поднимается, в '
          'утверждении спокойно опускается; суммы, итоги и предупреждения '
          'чуть выделяй голосом. '
          'Паузы делай только там, где в тексте точка, запятая или тире, а '
          'внутри фразы говори слитно и плавно, без остановок между словами. '
          'Темп обычный разговорный: не торопись и не растягивай слова. '
          'Числа в тексте уже записаны словами — читай их как написано, '
          'ясно и до конца, с естественным ударением: «три целых восемьдесят '
          'семь сотых», «шестнадцать центов», «плюс двенадцать процентов». '
          'Названия монет латиницей произноси так, как их называют трейдеры. '
          'Читай русский текст естественно, как носитель языка: с '
          'правильными ударениями и живой русской интонацией, без акцента и '
          'не переходи на английский. '
          'Сохраняй один и тот же голос и манеру во всех ответах.';
    }
    return 'You are the voice of the IBITI Guardian assistant. '
        'Character: $character. '
        'Sound like a real person: warm, confident and attentive, not a '
        'newsreader and not a robot. '
        'Let the meaning drive the intonation: rise on questions, settle on '
        'statements, and give amounts, totals and warnings a little emphasis. '
        'Pause only where the text has a period, comma or dash; within a '
        'phrase, speak smoothly with no gaps between words. '
        'Normal conversational pace: never rushed, never drawn out. '
        'Numbers are already written as words; read them as written, clearly '
        'and completely, with natural stress. '
        'Pronounce IBITI as "ih-BIT-ee" and coin tickers the way traders say '
        'them. '
        'Speak natural English only, and keep the same voice and manner in '
        'every reply.';
  }

  final AudioPlayer _player = AudioPlayer();
  bool _isSpeaking = false;
  ValueNotifier<bool> isSpeaking = ValueNotifier(false);

  /// Cancel flag — checked at every step to enable instant stop.
  bool _cancelled = false;

  /// Audio chunk queue for streaming playback.
  StreamController<Uint8List>? _chunkQueue;

  JarvisPersonality get _activePersonality {
    try {
      final mode = VoiceGreetingService.instance.currentPersonaMode;
      switch (mode) {
        case VoicePersonaMode.companion:
          return SettingsService.instance.settings.jarvisPersonality;
        case VoicePersonaMode.analyst:
          return JarvisPersonality.analyst;
        case VoicePersonaMode.operator:
          return JarvisPersonality.silent;
        case VoicePersonaMode.alert:
          return JarvisPersonality.jarvis;
      }
    } catch (_) {
      return SettingsService.instance.settings.jarvisPersonality;
    }
  }

  /// Always the voice chosen in Settings ([AiVoice.current]).
  String _resolveVoice() {
    final useStable = SettingsService.instance.settings.useStableVoice;
    final voice = voiceFor(AiVoice.current, stable: useStable);
    _log.d('_resolveVoice: saved='
        '${SettingsService.instance.settings.preferredAiVoiceId} '
        'model=$_model → using=$voice');
    return voice;
  }

  String _resolveInstructions({String? languageCode}) {
    final appLang =
        (languageCode ?? SettingsService.instance.settings.languageCode)
            .trim()
            .toLowerCase();
    final personality = _activePersonality;
    final isRu = appLang.startsWith('ru');
    return instructionsFor(
      russian: isRu,
      female: AiVoice.isFemale,
      character:
          isRu ? personality.descriptionRu() : personality.descriptionEn(),
    );
  }

  // ── Streaming TTS ─────────────────────────────────────────────────────────
  // Accepts a stream of text chunks, fires TTS for each concurrently with
  // playback, and plays audio chunks in order via a StreamController queue.

  /// Play speech from a stream of text chunks.
  /// Each chunk fires a TTS request; audio plays as soon as ready.
  /// First chunk plays immediately; subsequent chunks queue behind.
  Future<void> speakStream(
    Stream<String> chunks, {
    String? languageCode,
  }) async {
    final apiKey = await ApiKeyProvider.getOpenAiKey();
    if (apiKey == null) {
      _log.w('No API key — cannot speak');
      return;
    }

    await stop();
    _cancelled = false;
    _isSpeaking = true;

    final queue = StreamController<Uint8List>();
    _chunkQueue = queue;

    // Start the playback consumer (plays chunks in order).
    final playbackDone = _consumeQueue(queue.stream);

    // Fire TTS requests for each chunk, add results to queue.
    final voice = _resolveVoice();
    final instructions = _resolveInstructions(languageCode: languageCode);
    final model = _model;
    final personality = _activePersonality.name;
    final language =
        languageCode ?? SettingsService.instance.settings.languageCode;

    _log.i('==== TTS STREAM REQUEST AUDIT ====');
    _log.i('Model: $model');
    _log.i('Voice: $voice');
    _log.i('Personality: $personality');
    _log.i('Language: $language');
    _log.i('Instructions: "$instructions"');
    _log.i('Engine: OpenAI TTS (no system fallback)');
    _log.i('==================================');

    int chunkIndex = 0;

    try {
      final iterator = StreamIterator(chunks);
      Future<Uint8List?>? nextTtsFuture;

      if (await iterator.moveNext()) {
        nextTtsFuture =
            _fetchTts(iterator.current, voice, instructions, apiKey);
      }

      while (nextTtsFuture != null) {
        if (_cancelled) break;

        final currentFuture = nextTtsFuture;
        nextTtsFuture = null;

        if (await iterator.moveNext()) {
          nextTtsFuture =
              _fetchTts(iterator.current, voice, instructions, apiKey);
        }

        chunkIndex++;
        _log.d('TTS chunk #$chunkIndex completed');

        final audioBytes = await currentFuture;
        if (_cancelled) break;

        if (audioBytes != null) {
          queue.add(audioBytes);
        }
      }
    } catch (e) {
      _log.e('speakStream chunk loop error', e);
    }

    // Signal end of chunks.
    if (!queue.isClosed) {
      await queue.close();
    }

    // Wait for all audio to finish playing.
    await playbackDone;

    if (!_cancelled) {
      _isSpeaking = false;
      isSpeaking.value = false;
    }
  }

  /// Consumes audio chunks from the queue and plays them sequentially.
  Future<void> _consumeQueue(Stream<Uint8List> audioStream) async {
    bool firstChunk = true;

    await for (final bytes in audioStream) {
      if (_cancelled) break;

      try {
        // Try BytesSource first (works on Android).
        // Falls back to file-based playback if it fails.
        try {
          await _player.play(BytesSource(bytes));
        } catch (_) {
          // BytesSource not supported — write to temp file.
          final dir = await getTemporaryDirectory();
          final file = File('${dir.path}/guardian_tts_chunk.mp3');
          await file.writeAsBytes(bytes);
          await _player.play(DeviceFileSource(file.path));
        }

        if (firstChunk) {
          // NOW audio is actually playing → signal mouth animation.
          isSpeaking.value = true;
          firstChunk = false;
        }

        // Wait for this chunk to finish playing.
        try {
          await _player.onPlayerComplete.first.timeout(
            const Duration(seconds: 30),
          );
        } on TimeoutException {
          _log.d('Chunk playback timeout — continuing');
        }
      } catch (e) {
        _log.e('_consumeQueue playback error', e);
      }
    }
  }

  /// Fetch TTS audio bytes for a text chunk.
  Future<Uint8List?> _fetchTts(
      String text, String voice, String instructions, String apiKey) async {
    try {
      final truncated =
          text.length > 1000 ? '${text.substring(0, 1000)}…' : text;

      final bodyObj = {
        'model': _model,
        'input': truncated,
        'voice': voice,
        'response_format': 'mp3',
        'speed': speechRate,
      };
      if (_model == 'gpt-4o-mini-tts') {
        bodyObj['instructions'] = instructions;
      }

      final response = await http
          .post(
            Uri.parse(_endpoint),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(bodyObj),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        _log.e('TTS HTTP ${response.statusCode}');
        return null;
      }

      return response.bodyBytes;
    } catch (e) {
      _log.e('_fetchTts error', e);
      return null;
    }
  }

  // ── Legacy single-shot TTS ────────────────────────────────────────────────

  /// Speak [text]. Returns after playback completes.
  /// Truncates to 1000 chars to keep latency and cost bounded.
  Future<void> speak(String text, {String? languageCode}) async {
    if (text.isEmpty) return;
    final apiKey = await ApiKeyProvider.getOpenAiKey();
    if (apiKey == null) {
      _log.w('No API key — cannot speak');
      return;
    }

    // Stop any existing playback.
    await stop();

    final truncated = text.length > 1200 ? '${text.substring(0, 1200)}…' : text;
    final voice = _resolveVoice();
    final instructions = _resolveInstructions(languageCode: languageCode);
    final model = _model;
    final personality = _activePersonality.name;
    final language =
        languageCode ?? SettingsService.instance.settings.languageCode;

    _log.i('==== TTS REQUEST AUDIT ====');
    _log.i('Model: $model');
    _log.i('Voice: $voice');
    _log.i('Personality: $personality');
    _log.i('Language: $language');
    _log.i('Instructions: "$instructions"');
    _log.i('Engine: OpenAI TTS (no system fallback)');
    _log.i('===========================');

    _log.d('Speaking (${truncated.length} chars, voice=$voice)');

    try {
      _isSpeaking = true;
      // NOTE: isSpeaking.value stays false here intentionally.
      // We only set it to true AFTER audio actually starts playing,
      // so the Orb mouth animation is synchronized with real audio.

      final bodyObj = {
        'model': _model,
        'input': truncated,
        'voice': voice,
        'response_format': 'mp3',
        'speed': speechRate,
      };
      if (_model == 'gpt-4o-mini-tts') {
        bodyObj['instructions'] = instructions;
      }

      final response = await http
          .post(
            Uri.parse(_endpoint),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(bodyObj),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        _log.e('HTTP ${response.statusCode}');
        return;
      }

      // Write mp3 to temp file then play — audioplayers needs a file source.
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/guardian_tts.mp3');
      await file.writeAsBytes(response.bodyBytes);

      await _player.play(DeviceFileSource(file.path));
      // NOW audio is actually playing → signal mouth animation.
      isSpeaking.value = true;

      // Wait for playback to complete (with timeout safety net).
      try {
        await _player.onPlayerComplete.first.timeout(
          const Duration(seconds: 60),
        );
      } on TimeoutException catch (_) {
        _log.d('Playback timeout — continuing');
      }

      _log.d('Playback complete');
    } catch (e) {
      _log.e('speak() error', e);
    } finally {
      _isSpeaking = false;
      isSpeaking.value = false;
    }
  }

  /// Stop current playback immediately.
  /// Cancels streaming queue, stops player, resets state.
  Future<void> stop() async {
    _cancelled = true;

    // Close the chunk queue to unblock _consumeQueue.
    if (_chunkQueue != null && !_chunkQueue!.isClosed) {
      _chunkQueue!.close();
    }
    _chunkQueue = null;

    try {
      await _player.stop();
    } catch (e) {
      _log.w('player stop failed', e);
    }
    _isSpeaking = false;
    isSpeaking.value = false;
  }

  bool get isCurrentlySpeaking => _isSpeaking;

  void dispose() {
    _player.dispose();
    isSpeaking.dispose();
  }
}
