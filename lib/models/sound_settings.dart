/// Sound and vibration settings.
///
/// The app plays only its own sounds: the start-up sound and the coin sound
/// on a wallet top-up. Notifications vibrate like ordinary phone
/// notifications: once for ordinary ones (prices, reminders, revoke results),
/// twice for a wallet top-up. Settings saved by older builds (alarm and siren
/// choices, the single "vibration" switch) still load.
class SoundSettings {
  static const List<String> topUpSounds = ['coins_1', 'coins_2', 'coins_3'];

  /// Start-up sound.
  final bool soundEnabled;

  /// One short vibration for ordinary notifications.
  final bool singleVibrationEnabled;

  /// Two short vibrations for a wallet top-up.
  final bool doubleVibrationEnabled;

  /// Coin sound on a wallet top-up.
  final bool topUpSoundEnabled;
  final String selectedTopUpSoundId;

  SoundSettings({
    this.soundEnabled = true,
    this.singleVibrationEnabled = true,
    this.doubleVibrationEnabled = true,
    this.topUpSoundEnabled = true,
    this.selectedTopUpSoundId = 'coins_1',
  });

  Map<String, dynamic> toJson() => {
        'soundEnabled': soundEnabled,
        'singleVibrationEnabled': singleVibrationEnabled,
        'doubleVibrationEnabled': doubleVibrationEnabled,
        'topUpSoundEnabled': topUpSoundEnabled,
        'selectedTopUpSoundId': selectedTopUpSoundId,
      };

  factory SoundSettings.fromJson(Map<String, dynamic> json) {
    final topUp = json['selectedTopUpSoundId'];
    // Older builds had one switch for all vibration, and their "Sound
    // effects" switch muted the coin sound too.
    final bool oldFormat = !json.containsKey('singleVibrationEnabled');
    final bool oldVibration = json['vibrationEnabled'] ?? true;
    final bool soundOn = json['soundEnabled'] ?? true;
    final bool topUpOn = json['topUpSoundEnabled'] ?? true;
    return SoundSettings(
      soundEnabled: soundOn,
      singleVibrationEnabled: json['singleVibrationEnabled'] ?? oldVibration,
      doubleVibrationEnabled: json['doubleVibrationEnabled'] ?? oldVibration,
      topUpSoundEnabled: oldFormat ? topUpOn && soundOn : topUpOn,
      selectedTopUpSoundId:
          topUpSounds.contains(topUp) ? topUp as String : topUpSounds.first,
    );
  }

  SoundSettings copyWith({
    bool? soundEnabled,
    bool? singleVibrationEnabled,
    bool? doubleVibrationEnabled,
    bool? topUpSoundEnabled,
    String? selectedTopUpSoundId,
  }) =>
      SoundSettings(
        soundEnabled: soundEnabled ?? this.soundEnabled,
        singleVibrationEnabled:
            singleVibrationEnabled ?? this.singleVibrationEnabled,
        doubleVibrationEnabled:
            doubleVibrationEnabled ?? this.doubleVibrationEnabled,
        topUpSoundEnabled: topUpSoundEnabled ?? this.topUpSoundEnabled,
        selectedTopUpSoundId:
            selectedTopUpSoundId ?? this.selectedTopUpSoundId,
      );
}
