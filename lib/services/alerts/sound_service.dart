import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:vibration/vibration.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';

class SoundService {
  static final SoundService instance = SoundService._();
  SoundService._();

  static const _log = GuardianLogger('SoundService');

  final AudioPlayer _player = AudioPlayer();
  Timer? _stopTimer;

  Future<void> init() async {
    // Preload sounds if needed
  }

  // Alerts have no sound of their own: their notification vibrates. The app
  // plays only the boot sounds and the coin sound on a wallet top-up.

  Future<void> playSound(String fileName) async {
    await _stopAndPlay('sounds/$fileName', intensive: false, duration: 2000);
  }

  /// Play the user's selected wallet top-up sound (coins).
  Future<void> playTopUp() async {
    final settings = SettingsService.instance.settings.soundSettings;
    if (!settings.topUpSoundEnabled) return;

    final soundId = settings.selectedTopUpSoundId;
    await _stopAndPlay('sounds/$soundId.mp3', intensive: false, duration: 3000);
  }

  Future<void> previewTopUpSound(String soundId) async {
    await _stopAndPlay('sounds/$soundId.mp3', intensive: false, duration: 3000);
  }

  Future<void> _stopAndPlay(
    String assetPath, {
    int duration = 30000,
    bool intensive = false,
  }) async {
    try {
      // 1. Cancel everything first to ensure immediate stop of previous action
      _stopTimer?.cancel();
      await _player.stop();
      await Vibration.cancel();

      final settings = SettingsService.instance.settings.soundSettings;
      final soundOn = settings.soundEnabled;
      final vibeOn = settings.vibrationEnabled;

      // 2. If neither sound nor vibration is enabled, we are done
      if (!soundOn && !vibeOn) return;

      // 3. Start audio if enabled
      if (soundOn) {
        await _player.play(AssetSource(assetPath));
      }

      // 4. Start vibration if enabled
      if (vibeOn) {
        await _startVibration(intensive: intensive, isAudioMuted: !soundOn);
      }

      // 5. Timer stops both after duration
      _stopTimer = Timer(Duration(milliseconds: duration), () {
        _player.stop();
        Vibration.cancel();
      });
    } catch (e) {
      _log.e('Error in sound/vibration action', e);
    }
  }

  Future<void> testVibration() async {
    final settings = SettingsService.instance.settings.soundSettings;
    if (!settings.vibrationEnabled) return;
    await _startVibration(
        intensive: true, isAudioMuted: !settings.soundEnabled);
  }

  Future<void> _startVibration(
      {required bool intensive, bool isAudioMuted = false}) async {
    try {
      final hasVibrator = await Vibration.hasVibrator();
      if (hasVibrator == true) {
        if (intensive && isAudioMuted) {
          // Fallback continuous vibration (30 sec) because audio is off
          Vibration.vibrate(
            pattern: [0, 500, 200, 500],
            intensities: [0, 255, 0, 255],
            repeat: 0,
          );
        } else if (intensive) {
          // Intense burst, but audio is playing so no continuous loop
          Vibration.vibrate(
            pattern: [0, 500, 200, 500, 200, 500],
            intensities: [0, 255, 0, 255, 0, 255],
          );
        } else {
          // Standard notifications: short 2-beat vibration
          Vibration.vibrate(pattern: [0, 200, 100, 200]);
        }
      }
    } catch (e) {
      _log.e('Vibration error', e);
    }
  }

  Future<void> stopAll() async {
    try {
      _stopTimer?.cancel();
      _stopTimer = null;
      await _player.stop();
      await Vibration.cancel();
    } catch (e) {
      _log.e('Error stopping sound/vibration', e);
    }
  }

  Future<void> stopVibration() async {
    try {
      await Vibration.cancel();
    } catch (e) {
      _log.e('Error stopping vibration', e);
    }
  }
}
