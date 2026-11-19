import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/sound_settings.dart';

/// The app plays only its own sounds (start-up and wallet top-up). Alarm and
/// siren sounds left over from an older app were removed; settings saved by
/// older builds must still load.
void main() {
  test('settings saved by an older build still load', () {
    final s = SoundSettings.fromJson({
      'soundEnabled': false,
      'vibrationEnabled': true,
      'criticalAlarmEnabled': true,
      'panicAlarmEnabled': false,
      'selectedAlertSoundId': 'cyber',
      'selectedCriticalSoundId': 'lion_roar',
      'selectedPanicSoundId': 'panic_ultra',
      'topUpSoundEnabled': true,
      'selectedTopUpSoundId': 'coins_3',
    });
    expect(s.soundEnabled, false);
    expect(s.singleVibrationEnabled, true);
    expect(s.doubleVibrationEnabled, true);
    // Its "Sound effects" switch was off, which muted the coins too.
    expect(s.topUpSoundEnabled, false);
    expect(s.selectedTopUpSoundId, 'coins_3');
    expect(s.toJson().keys, isNot(contains('selectedCriticalSoundId')));
  });

  test('the old single vibration switch carries over to both new ones', () {
    final off = SoundSettings.fromJson({'vibrationEnabled': false});
    expect(off.singleVibrationEnabled, false);
    expect(off.doubleVibrationEnabled, false);
    final fresh = SoundSettings.fromJson({});
    expect(fresh.singleVibrationEnabled, true);
    expect(fresh.doubleVibrationEnabled, true);
    expect(fresh.topUpSoundEnabled, true);
    final saved = SoundSettings.fromJson(
        SoundSettings(doubleVibrationEnabled: false).toJson());
    expect(saved.singleVibrationEnabled, true);
    expect(saved.doubleVibrationEnabled, false);
    expect(saved.toJson().keys, isNot(contains('vibrationEnabled')));
  });

  test('coin sound and start-up sound are separate in the new format', () {
    final s = SoundSettings.fromJson(
        SoundSettings(soundEnabled: false).toJson());
    expect(s.soundEnabled, false);
    expect(s.topUpSoundEnabled, true);
    expect(SoundSettings.fromJson({'soundEnabled': true}).topUpSoundEnabled,
        true);
  });

  test('an unknown top-up sound falls back to the first coin sound', () {
    expect(SoundSettings.fromJson({'selectedTopUpSoundId': 'lion_roar'})
        .selectedTopUpSoundId, 'coins_1');
    expect(SoundSettings.fromJson({}).selectedTopUpSoundId, 'coins_1');
  });

  test('every sound the app plays is bundled', () {
    for (final id in SoundSettings.topUpSounds) {
      expect(File('assets/sounds/$id.mp3').existsSync(), true, reason: id);
      // The top-up notification plays the Android raw copy.
      expect(File('android/app/src/main/res/raw/$id.mp3').existsSync(), true,
          reason: id);
    }
    for (final f in ['opening_crackle.wav', 'opening_whoosh.wav']) {
      expect(File('assets/sounds/$f').existsSync(), true, reason: f);
    }
  });

  test('no alarm or siren sounds are left in the app', () {
    final left = [
      ...Directory('assets/sounds').listSync(),
      ...Directory('android/app/src/main/res/raw').listSync(),
    ]
        .map((e) => e.uri.pathSegments.last)
        .where((n) => RegExp(r'alert_|critical_|panic|emergency|lion')
            .hasMatch(n))
        .toList();
    expect(left, isEmpty);
  });
}
