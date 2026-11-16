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
    expect(s.vibrationEnabled, true);
    expect(s.topUpSoundEnabled, true);
    expect(s.selectedTopUpSoundId, 'coins_3');
    expect(s.toJson().keys, isNot(contains('selectedCriticalSoundId')));
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
