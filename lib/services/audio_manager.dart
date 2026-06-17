import 'dart:collection';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/services/voice/tts_service.dart';
import 'package:ibiti_guardian/services/voice/speech_normalizer.dart';
import 'package:ibiti_guardian/services/alerts/sound_service.dart';

/// Unified audio coordinator — ensures only ONE audio source plays at a time,
/// respects priority levels, and queues sequential TTS utterances.
///
/// Priority rules:
/// - Higher priority ALWAYS interrupts lower priority.
/// - Same priority: TTS queues, alerts replace.
/// - Lower priority is silently dropped while higher is active.
///
/// Usage:
///   await AudioManager.instance.speakTts('Transaction confirmed');
///   await AudioManager.instance.playAlert();
///   await AudioManager.instance.stopAll();
class AudioManager {
  AudioManager._();
  static final instance = AudioManager._();

  static const _log = GuardianLogger('AudioManager');

  final _tts = TtsService.instance;
  final _sound = SoundService.instance;

  /// Current active source priority.
  AudioPriority _activePriority = AudioPriority.none;

  /// TTS queue — sequential utterances without cutting each other.
  final Queue<String> _ttsQueue = Queue<String>();
  bool _isSpeakingTts = false;

  // ── TTS (priority: normal) ──────────────────────────────────────────────────

  /// Speak text via OpenAI TTS. Queues if already speaking.
  /// Will NOT interrupt alerts or panic sounds.
  /// Text is automatically normalized for natural speech.
  Future<void> speakTts(String text, {String lang = 'en'}) async {
    if (text.isEmpty) return;

    // If higher-priority audio is playing, drop silently.
    if (_activePriority.index > AudioPriority.normal.index) {
      _log.d('TTS dropped — ${_activePriority.name} is active');
      return;
    }

    // Normalize for natural speech before queueing.
    final normalized = SpeechNormalizer.normalize(text, lang: lang);
    if (normalized.isEmpty) return;

    _ttsQueue.addLast(normalized);
    if (!_isSpeakingTts) {
      await _drainTtsQueue();
    }
  }

  Future<void> _drainTtsQueue() async {
    _isSpeakingTts = true;
    _activePriority = AudioPriority.normal;

    while (_ttsQueue.isNotEmpty) {
      // If a higher priority source took over mid-queue, abort.
      if (_activePriority.index > AudioPriority.normal.index) {
        _ttsQueue.clear();
        break;
      }

      final text = _ttsQueue.removeFirst();
      try {
        await _tts.speak(text);
      } catch (e) {
        _log.e('TTS queue item failed', e);
      }
    }

    _isSpeakingTts = false;
    if (_activePriority == AudioPriority.normal) {
      _activePriority = AudioPriority.none;
    }
  }

  // ── Alerts (priority: high) ─────────────────────────────────────────────────

  /// Play an alert sound. Interrupts TTS but not panic.
  Future<void> playAlert() async {
    if (!_acquire(AudioPriority.high)) return;
    try {
      await _sound.playAlert();
    } finally {
      _release(AudioPriority.high);
    }
  }

  /// Play a critical alarm. Interrupts TTS but not panic.
  Future<void> playCritical() async {
    if (!_acquire(AudioPriority.high)) return;
    try {
      await _sound.playCritical();
    } finally {
      _release(AudioPriority.high);
    }
  }

  // ── Panic (priority: critical — NOTHING interrupts this) ────────────────────

  /// Play a panic alarm. Interrupts EVERYTHING.
  Future<void> playPanic() async {
    if (!_acquire(AudioPriority.critical)) return;
    try {
      await _sound.playPanic();
    } finally {
      _release(AudioPriority.critical);
    }
  }

  // ── Low priority (preview, boot sounds) ─────────────────────────────────────

  /// Play a generic sound file. Lowest priority — interrupted by anything.
  Future<void> playSound(String fileName) async {
    if (!_acquire(AudioPriority.low)) return;
    try {
      await _sound.playSound(fileName);
    } finally {
      _release(AudioPriority.low);
    }
  }

  /// Preview sounds from settings.
  Future<void> previewAlertSound(String soundId) async {
    if (!_acquire(AudioPriority.low)) return;
    try {
      await _sound.previewAlertSound(soundId);
    } finally {
      _release(AudioPriority.low);
    }
  }

  Future<void> previewCriticalSound(String soundId) async {
    if (!_acquire(AudioPriority.low)) return;
    try {
      await _sound.previewCriticalSound(soundId);
    } finally {
      _release(AudioPriority.low);
    }
  }

  Future<void> previewPanicSound(String soundId) async {
    if (!_acquire(AudioPriority.low)) return;
    try {
      await _sound.previewPanicSound(soundId);
    } finally {
      _release(AudioPriority.low);
    }
  }

  // ── Top-up sound (priority: low) ────────────────────────────────────────────

  /// Play the wallet top-up coin sound. Low priority — doesn't interrupt anything.
  Future<void> playTopUp() async {
    if (!_acquire(AudioPriority.low)) return;
    try {
      await _sound.playTopUp();
    } finally {
      _release(AudioPriority.low);
    }
  }

  Future<void> previewTopUpSound(String soundId) async {
    if (!_acquire(AudioPriority.low)) return;
    try {
      await _sound.previewTopUpSound(soundId);
    } finally {
      _release(AudioPriority.low);
    }
  }

  // ── Control ─────────────────────────────────────────────────────────────────

  /// Stop ALL audio immediately. Clears TTS queue.
  Future<void> stopAll() async {
    _log.d('stopAll');
    _ttsQueue.clear();
    _isSpeakingTts = false;
    _activePriority = AudioPriority.none;
    await Future.wait([
      _tts.stop(),
      _sound.stopAll(),
    ]);
  }

  bool get isSpeaking => _tts.isCurrentlySpeaking;

  // ── Priority engine ─────────────────────────────────────────────────────────

  /// Try to acquire the audio channel at [priority].
  /// Returns true if acquired. Stops lower-priority audio if needed.
  bool _acquire(AudioPriority priority) {
    // Same or lower priority than active — blocked.
    if (_activePriority.index > priority.index) {
      _log.d('${priority.name} blocked — ${_activePriority.name} is active');
      return false;
    }

    // Higher priority — stop current audio.
    if (_activePriority != AudioPriority.none &&
        _activePriority.index < priority.index) {
      _log.d('${priority.name} interrupts ${_activePriority.name}');
      _ttsQueue.clear();
      _tts.stop();
      _sound.stopAll();
    }

    _activePriority = priority;
    return true;
  }

  /// Release the channel if we're still the active source.
  void _release(AudioPriority priority) {
    if (_activePriority == priority) {
      _activePriority = AudioPriority.none;
    }
  }
}

/// Audio priority levels.
/// Higher index = higher priority = cannot be interrupted by lower.
enum AudioPriority {
  none, // 0 — nothing playing
  low, // 1 — preview, boot sounds
  normal, // 2 — TTS voice responses
  high, // 3 — security alerts, critical alarms
  critical, // 4 — panic alarm — NOTHING interrupts this
}
