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

  String get _model {
    final useStable = SettingsService.instance.settings.useStableVoice;
    return useStable ? 'tts-1' : 'gpt-4o-mini-tts';
  }

  // All OpenAI TTS voices supported directly — no mapping needed.
  // verse, cedar, marin are the newest generation voices.
  // Old mapping (verse→onyx, cedar→echo, marin→nova) caused the user to
  // hear a completely different voice than the one they selected.
  static const _validVoices = {
    'verse', 'cedar', 'marin', // new generation (best quality)
    'alloy', 'echo', 'fable', 'nova', // classic
    'onyx', 'shimmer', 'coral', 'sage', // classic
  };

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

  String _resolveVoice() {
    final saved = SettingsService.instance.settings.preferredAiVoiceId;
    // If user explicitly picked a voice → use it.
    // Otherwise → use the active personality's preferred voice.
    final personalityVoice = _activePersonality.ttsVoice;
    var voice = (saved != null && _validVoices.contains(saved.toLowerCase()))
        ? saved.toLowerCase()
        : personalityVoice;

    // If using stable model (tts-1), map new-gen voices to their closest classic equivalents.
    final useStable = SettingsService.instance.settings.useStableVoice;
    if (useStable) {
      if (voice == 'verse') voice = 'onyx';
      else if (voice == 'cedar') voice = 'echo';
      else if (voice == 'marin') voice = 'nova';
      else if (voice == 'coral') voice = 'alloy';
      else if (voice == 'sage') voice = 'alloy';
    }

    _log.d('_resolveVoice: saved=$saved personality=${_activePersonality.name} model=$_model → using=$voice');
    return voice;
  }

  String _resolveInstructions() {
    final appLang =
        SettingsService.instance.settings.languageCode.trim().toLowerCase();
    final personality = _activePersonality;
    final isRu = appLang.startsWith('ru');
    final personalityDesc = isRu ? personality.descriptionRu() : personality.descriptionEn();

    if (isRu) {
      return 'Ты — голосовой ассистент IBITI Guardian. '
          'Твой стиль и характер общения: $personalityDesc. '
          'ВАЖНО: Сохраняй ОДИН И ТОТ ЖЕ тон, тембр и стиль речи в КАЖДОМ ответе. '
          'Не меняй характер голоса между фразами. '
          // ── Произношение и акцент ──
          'Говори ТОЛЬКО на чистом русском языке, без иностранного акцента. '
          'Произноси слова естественно, как носитель русского языка. '
          'Используй живые интонации: повышай тон в вопросах, понижай в утверждениях. '
          'Делай микропаузы между предложениями для естественности. '
          // ── Числа и термины ──
          'Цифры произноси чётко и полностью по-русски: '
          '"три доллара", "пятьсот", "ноль целых пять десятых". '
          'Проценты: "плюс двенадцать процентов", не "plus 12 percent". '
          'Суммы в долларах: "три доллара", "пятьдесят центов". '
          // ── Крипто-термины ──
          'Слово IBITI произноси как "Ибити". '
          'USDT — как "Ю-эс-ди-ти". BNB — как "Би-эн-би". '
          'BTC — как "Биткоин". ETH — как "Эфириум". '
          'SOL — как "Солана". TRON — как "Трон". '
          // ── Запреты ──
          'Никогда не переходи на английский язык. '
          'Не читай технические хеши и адреса вслух — вместо них говори '
          '"транзакция отправлена" или "адрес скопирован". '
          'Не используй слова-паразиты: "ну", "как бы", "типа". '
          // ── Чёткость произношения ──
          'КРИТИЧЕСКИ ВАЖНО: произноси КАЖДЫЙ СЛОГ каждого слова полностью и чётко. '
          'Никогда не глотай и не пропускай звуки. '
          'Слово "ордер" — произноси "ор-дер", не "ор-р". '
          'Слово "доллар" — произноси "дол-лар", не "до-ар". '
          'Между словами делай небольшие паузы. '
          // ── Ритм ──
          'Уверенный, спокойный, ровный тон. '
          'Говори в среднем темпе — не слишком быстро, не слишком медленно.';
    }
    return 'You are IBITI Guardian voice assistant. '
        'Your speaking style and persona character: $personalityDesc. '
        'IMPORTANT: Keep the EXACT SAME tone, pitch, and speaking style in EVERY response. '
        'Never change your voice character between phrases. '
        'Speak ONLY in English with a clear, natural American accent. '
        'Use natural intonation: rise on questions, fall on statements. '
        'Brief pauses between sentences for natural rhythm. '
        // ── Numbers ──
        'Read numbers clearly and fully: "three dollars", "five hundred". '
        'Percentages: "plus twelve percent", not "plus 12%". '
        // ── Crypto terms ──
        'Pronounce IBITI as "ih-BIT-ee". '
        'USDT as "U-S-D-T". BNB as "B-N-B". '
        // ── Restrictions ──
        'Never switch to another language. '
        'Do not read technical hashes or addresses aloud. '
        // ── Clarity ──
        'CRITICAL: pronounce EVERY syllable of every word fully and clearly. '
        'Never skip or swallow sounds. '
        'Calm, confident, even tone. Medium speaking pace.';
  }

  // ── Streaming TTS ─────────────────────────────────────────────────────────
  // Accepts a stream of text chunks, fires TTS for each concurrently with
  // playback, and plays audio chunks in order via a StreamController queue.

  /// Play speech from a stream of text chunks.
  /// Each chunk fires a TTS request; audio plays as soon as ready.
  /// First chunk plays immediately; subsequent chunks queue behind.
  Future<void> speakStream(Stream<String> chunks) async {
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
    final instructions = _resolveInstructions();
    final model = _model;
    final personality = _activePersonality.name;
    final language = SettingsService.instance.settings.languageCode;

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
        'speed': 1.0,
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
  Future<void> speak(String text) async {
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
    final instructions = _resolveInstructions();
    final model = _model;
    final personality = _activePersonality.name;
    final language = SettingsService.instance.settings.languageCode;

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
        'speed': 1.0,
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
