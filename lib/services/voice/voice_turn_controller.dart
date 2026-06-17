import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/services/assistant/guardian_assistant_service.dart';
import 'package:ibiti_guardian/services/voice/mic_recorder_service.dart';
import 'package:ibiti_guardian/services/voice/transcription_service.dart';
import 'package:ibiti_guardian/services/voice/tts_service.dart';
import 'package:ibiti_guardian/services/voice/speech_formatter.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/services/assistant/assistant_session_context.dart';

/// State of a single voice interaction turn.
enum VoiceTurnState {
  idle, // Waiting. No active session, no billing.
  recording, // User is holding down the button, mic is live.
  transcribing, // Audio uploaded to Whisper, awaiting text.
  thinking, // GuardianAssistantService is processing the transcript.
  speaking, // TTS audio is playing back.
  error, // Something went wrong; shows error briefly then → idle.
}

/// Orchestrates the push-to-talk pipeline:
///   hold → record → transcribe → process → speak → idle
///
/// Primary voice orchestrator — push-to-talk pipeline:
/// - No WebRTC, no persistent connections, no background billing.
/// - Pays only for what is actually used.
///
/// ── Async-zombie guard (turnId) ──────────────────────────────────────────────
/// Every public call that kicks off a pipeline captures the current [_turnId].
/// After each await, the captured id is compared to [_turnId]. If they differ,
/// cancel() was called on this turn — the pipeline exits silently without
/// changing state or starting TTS.
///
/// Used as: `VoiceTurnController.instance`
class VoiceTurnController extends ChangeNotifier {
  VoiceTurnController._();
  static final VoiceTurnController instance = VoiceTurnController._();

  static const _log = GuardianLogger('VoiceTurn');

  /// App language check — used for user-facing error messages.
  bool get _isRu =>
      SettingsService.instance.settings.languageCode.startsWith('ru');

  // ── Services ─────────────────────────────────────────────────────────────────
  // MicRecorderService is created here because it holds per-turn resources
  // (AudioRecorder, timer). It is NOT a singleton, so we own it.
  final MicRecorderService _mic = MicRecorderService();
  // TtsService and TranscriptionService are singletons — we must NEVER call
  // dispose() on them. Use their stop() methods for cleanup only.
  final TranscriptionService _stt = TranscriptionService.instance;
  final TtsService _tts = TtsService.instance;

  // ── State ─────────────────────────────────────────────────────────────────────
  VoiceTurnState _state = VoiceTurnState.idle;
  VoiceTurnState get state => _state;

  String? _lastTranscript;
  String? get lastTranscript => _lastTranscript;

  String? _lastResponse;
  String? get lastResponse => _lastResponse;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  bool get isIdle => _state == VoiceTurnState.idle;
  bool get canStartRecording =>
      _state == VoiceTurnState.idle || _state == VoiceTurnState.error;

  /// Amplitude stream for waveform visualisation (0.0–1.0).
  Stream<double> get amplitude => _mic.amplitude;

  // ── Async-zombie guard ────────────────────────────────────────────────────────
  // Monotonically incremented on every cancel(). Any in-flight pipeline
  // that sees a mismatch knows it was superseded and must abort silently.
  int _turnId = 0;

  // ── Persistent Voice Session ─────────────────────────────────────────────────
  // A "session" spans multiple PTT turns. While a session is active, the
  // floating mic bubble is visible across all screens. The session ends
  // when the user explicitly closes it, says "завершить сессию", or after
  // [_kInactivityTimeout] of silence.
  static const _kInactivityTimeout = Duration(minutes: 2, seconds: 30);

  final ValueNotifier<bool> sessionNotifier = ValueNotifier<bool>(false);
  bool get isSessionActive => sessionNotifier.value;
  Timer? _inactivityTimer;

  /// Start a persistent voice session. Called automatically on first PTT.
  /// [timeout] overrides the default inactivity timeout (e.g. for context bubbles).
  void startSession({Duration? timeout}) {
    if (sessionNotifier.value) return;
    _sessionTimeout = timeout;
    sessionNotifier.value = true;
    _resetInactivityTimer();
    _log.d('Voice session started');
  }

  /// End the voice session. Hides the floating bubble.
  void endSession() {
    if (!sessionNotifier.value) return;
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
    _lastTranscript = null;
    _lastResponse = null;
    sessionNotifier.value = false;
    notifyListeners();
    _log.d('Voice session ended');
  }

  // Custom timeout for this session (null = use default).
  Duration? _sessionTimeout;

  /// Reset the inactivity timer. Called on every PTT interaction.
  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    final duration = _sessionTimeout ?? _kInactivityTimeout;
    _inactivityTimer = Timer(duration, () {
      _log.d('Session inactivity timeout — ending session');
      endSession();
    });
  }

  // ── Anti-spam debounce ─────────────────────────────────────────────────────────
  DateTime _lastTurnEnd = DateTime(0);

  // ── Public API ────────────────────────────────────────────────────────────────

  /// Start recording (user pressed the button).
  Future<void> startRecording() async {
    if (!canStartRecording) {
      _log.d('startRecording ignored — state: ${_state.name}');
      return;
    }
    // Anti-spam: prevent rapid hold→stop→hold chains
    if (DateTime.now().difference(_lastTurnEnd).inMilliseconds < 800) {
      _log.d('startRecording debounced');
      return;
    }
    _lastTranscript = null;
    _lastResponse = null;
    _errorMessage = null;
    _setState(VoiceTurnState.recording);

    // Reset session inactivity on every PTT interaction.
    if (isSessionActive) _resetInactivityTimer();

    try {
      await _mic.start();
    } catch (e) {
      // Safety: ensure mic is fully released even if start() threw midway.
      // Without this, the OS mic resource can stay locked for the session.
      try {
        await _mic.cancel();
      } catch (e) {
        _log.w('mic cancel cleanup failed', e);
      }
      _setError(_isRu ? 'Ошибка микрофона: $e' : 'Microphone error: $e');
    }
  }

  /// Stop recording and run the full STT→LLM→TTS pipeline.
  Future<void> stopRecording() async {
    if (_state != VoiceTurnState.recording) return;

    // Capture this turn's id BEFORE the first await.
    final myTurn = _turnId;

    _setState(VoiceTurnState.transcribing);
    _lastTranscript = '…'; // Immediate visual feedback
    notifyListeners();

    // Track turn count for session context.
    if (isSessionActive) {
      AssistantSessionContext.instance.incrementTurn();
    }

    Uint8List? audioBytes;
    try {
      audioBytes = await _mic.stop();
    } catch (e) {
      _log.e('mic stop error', e);
    }

    // Guard: did cancel() arrive while we were stopping the mic?
    if (_turnId != myTurn) return;

    if (audioBytes == null || audioBytes.isEmpty) {
      _setError(_isRu
          ? 'Запись не получена. Попробуйте ещё раз.'
          : 'No audio recorded. Please try again.');
      return;
    }

    await _runPipeline(audioBytes, myTurn);
  }

  /// Cancel any active turn immediately and return to idle.
  /// Increments _turnId — all in-flight pipelines see the mismatch and abort.
  Future<void> cancel() async {
    _turnId++; // Invalidate any in-flight pipeline.

    if (_state == VoiceTurnState.recording) {
      await _mic.cancel();
    }
    // Stop TTS for ALL non-idle states — including if app went to background
    // mid-speaking. Prevents zombie audio playing in the background.
    await _tts.stop();

    _setState(VoiceTurnState.idle);
  }

  // ── Pipeline ──────────────────────────────────────────────────────────────────

  // Outer safety timeouts — last line of defence.
  // Inner services (TranscriptionService, TtsService) have their own HTTP
  // timeouts, but those don't cover DNS hangs, stuck Futures, or bugs in
  // service code. These outer limits guarantee the UI never freezes.
  static const _sttTimeout = Duration(seconds: 15);
  static const _llmTimeout = Duration(seconds: 30);
  static const _ttsTimeout = Duration(seconds: 45);

  Future<void> _runPipeline(Uint8List audioBytes, int myTurn) async {
    final pipelineStart = DateTime.now();

    // ── Step 1: Transcribe ────────────────────────────────────────────────────
    final langCode = SettingsService.instance.settings.languageCode
        .trim()
        .toLowerCase()
        .split('_')
        .first;

    final sttStart = DateTime.now();
    String? transcript;
    try {
      transcript = await _stt
          .transcribe(audioBytes, languageCode: langCode)
          .timeout(_sttTimeout);
    } on TimeoutException {
      _log.w('STT timeout after ${_sttTimeout.inSeconds}s');
      if (_turnId == myTurn) {
        _setError(_isRu
            ? 'Таймаут распознавания. Попробуйте снова.'
            : 'Speech recognition timed out. Try again.');
      }
      return;
    } on SttRateLimitException {
      _log.w('STT rate limited (429)');
      if (_turnId == myTurn) {
        _setError(_isRu
            ? 'API перегружен. Подождите несколько секунд и попробуйте снова.'
            : 'API rate limited. Wait a few seconds and try again.');
      }
      return;
    } catch (e) {
      _log.e('STT error', e);
      if (_turnId == myTurn) {
        _setError(_isRu
            ? 'Ошибка распознавания речи.'
            : 'Speech recognition failed.');
      }
      return;
    }
    final sttMs = DateTime.now().difference(sttStart).inMilliseconds;
    _log.i('[VoiceLatency] sttDone ms=$sttMs');

    // Guard after every await.
    if (_turnId != myTurn) {
      _log.d('Turn $myTurn superseded after transcribe — aborting');
      return;
    }

    if (transcript == null || transcript.isEmpty) {
      _setError(_isRu
          ? 'Не удалось распознать речь. Говорите чётче.'
          : 'Could not recognize speech. Please speak more clearly.');
      return;
    }

    _lastTranscript = transcript;
    _log.d('Transcript received: "$transcript"');

    // ── Step 2: Process through Guardian pipeline ─────────────────────────────
    _setState(VoiceTurnState.thinking);

    final llmStart = DateTime.now();
    String speechText;
    try {
      final response = await GuardianAssistantService.instance
          .process(transcript, languageCode: langCode, source: AssistantInputSource.voice)
          .timeout(_llmTimeout);

      // Guard after every await.
      if (_turnId != myTurn) {
        _log.d('Turn $myTurn superseded after LLM — aborting');
        return;
      }

      final rawText = response.speechText.isNotEmpty
          ? response.speechText
          : response.message;

      // Smart truncation: cut at sentence boundary, not mid-word.
      speechText = _smartTruncate(rawText, 1200);

      // Normalize for natural speech: numbers, crypto, markdown, pauses.
      speechText = SpeechFormatter.normalize(speechText, lang: langCode);
      _lastResponse = speechText;
    } on TimeoutException {
      _log.w('LLM timeout after ${_llmTimeout.inSeconds}s');
      if (_turnId == myTurn) {
        _setError(_isRu
            ? 'AI не ответил вовремя. Попробуйте снова.'
            : 'AI did not respond in time. Try again.');
      }
      return;
    } catch (e) {
      _log.e('GuardianAssistantService error', e);
      if (_turnId == myTurn) {
        _setError(
            _isRu ? 'Ошибка обработки запроса.' : 'Request processing failed.');
      }
      return;
    }
    final llmMs = DateTime.now().difference(llmStart).inMilliseconds;
    _log.i('[VoiceLatency] assistantDone ms=$llmMs chars=${speechText.length}');

    if (speechText.isEmpty) {
      if (_turnId == myTurn) _setState(VoiceTurnState.idle);
      return;
    }

    // ── Step 3: Speak (single-shot TTS) ────────────────────────────────────
    // Single API call = one voice generation = consistent tone throughout.
    // Previously used speakStream (chunked), which caused voice/tembre
    // changes between chunks and audible pauses while loading next chunk.
    if (_turnId != myTurn) return; // Final guard before TTS
    _setState(VoiceTurnState.speaking);

    final ttsStart = DateTime.now();
    try {
      await _tts.speak(speechText).timeout(_ttsTimeout);
    } on TimeoutException {
      _log.w('TTS timeout after ${_ttsTimeout.inSeconds}s');
      await _tts.stop();
    } catch (e) {
      _log.e('TTS error', e);
    }
    final ttsMs = DateTime.now().difference(ttsStart).inMilliseconds;
    final totalMs = DateTime.now().difference(pipelineStart).inMilliseconds;
    _log.i('[VoiceLatency] ttsDone ms=$ttsMs | total=$totalMs '
        '(stt=$sttMs llm=$llmMs tts=$ttsMs)');

    // Return to idle only if this turn is still the active one.
    if (_turnId == myTurn && _state == VoiceTurnState.speaking) {
      _setState(VoiceTurnState.idle);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────────

  /// Truncate text at a sentence boundary (. ! ?) instead of mid-word.
  /// Falls back to last space if no sentence end is found within [maxChars].
  static String _smartTruncate(String text, int maxChars) {
    if (text.length <= maxChars) return text;

    // Search for last sentence-ending punctuation within the limit.
    int cutAt = -1;
    for (int i = maxChars; i >= maxChars ~/ 2; i--) {
      final c = text[i];
      if (c == '.' || c == '!' || c == '?') {
        cutAt = i + 1; // Include the punctuation.
        break;
      }
    }

    // Fallback: cut at last space to avoid splitting a word.
    if (cutAt < 0) {
      cutAt = text.lastIndexOf(' ', maxChars);
      if (cutAt < maxChars ~/ 2) cutAt = maxChars; // Give up, hard cut.
    }

    return text.substring(0, cutAt).trimRight();
  }

  void _setState(VoiceTurnState s) {
    if (_state == s) return;
    _state = s;
    // Track when turn ends for debounce
    if (s == VoiceTurnState.idle || s == VoiceTurnState.error) {
      _lastTurnEnd = DateTime.now();
    }
    _log.d('→ ${s.name}');
    notifyListeners();
  }

  void _setError(String message) {
    _errorMessage = message;
    _setState(VoiceTurnState.error);
    // Auto-recover to idle after 3 seconds.
    // Use a local snapshot of _turnId so a new turn clears the error immediately.
    final errorTurn = _turnId;
    Future.delayed(const Duration(seconds: 3), () {
      if (_turnId == errorTurn && _state == VoiceTurnState.error) {
        _setState(VoiceTurnState.idle);
      }
    });
  }

  /// Permanently release resources owned exclusively by this controller.
  /// DO NOT call dispose() on singleton services (_stt, _tts) — they are
  /// shared and must survive for the lifetime of the app.
  ///
  /// This override exists only because ChangeNotifier requires it.
  /// In practice, VoiceTurnController.instance lives for the entire app
  /// lifecycle and this method is never called by Flutter's widget tree.
  @override
  void dispose() {
    // Only dispose the non-singleton MicRecorderService which we own.
    _mic.dispose();
    _inactivityTimer?.cancel();
    sessionNotifier.dispose();
    // Do NOT call _tts.dispose() or _stt.dispose() — they are singletons.
    super.dispose();
  }
}
