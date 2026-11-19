import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';

/// Plays the app's own sounds: the start-up sound and the coin sound on a
/// wallet top-up. It never vibrates: vibration belongs to notifications
/// (see NotificationService).
class SoundService {
  static final SoundService instance = SoundService._();
  SoundService._();

  static const _log = GuardianLogger('SoundService');

  final AudioPlayer _player = AudioPlayer();
  Timer? _stopTimer;

  Future<void> init() async {}

  /// Start-up sound; plays when "Start-up sound" is on.
  Future<void> playSound(String fileName) async {
    if (!SettingsService.instance.settings.soundSettings.soundEnabled) return;
    await _stopAndPlay('sounds/$fileName', duration: 2000);
  }

  /// The user's selected wallet top-up sound (coins), when it is on.
  /// Returns whether it started playing.
  Future<bool> playTopUp() async {
    final settings = SettingsService.instance.settings.soundSettings;
    if (!settings.topUpSoundEnabled) return false;
    return _stopAndPlay('sounds/${settings.selectedTopUpSoundId}.mp3',
        duration: 3000);
  }

  /// Plays a coin sound in Settings when the user picks it.
  Future<void> previewTopUpSound(String soundId) async {
    await _stopAndPlay('sounds/$soundId.mp3', duration: 3000);
  }

  Future<bool> _stopAndPlay(String assetPath, {required int duration}) async {
    try {
      _stopTimer?.cancel();
      await _player.stop();
      await _player.play(AssetSource(assetPath));
      _stopTimer = Timer(Duration(milliseconds: duration), _player.stop);
      return true;
    } catch (e) {
      _log.e('Error playing $assetPath', e);
      return false;
    }
  }

  Future<void> stopAll() async {
    try {
      _stopTimer?.cancel();
      _stopTimer = null;
      await _player.stop();
    } catch (e) {
      _log.e('Error stopping sound', e);
    }
  }
}
