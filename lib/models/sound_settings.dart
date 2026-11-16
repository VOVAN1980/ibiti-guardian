/// Sound and vibration settings.
///
/// The app plays only its own sounds: the boot sounds and the coin sound on a
/// wallet top-up. Alerts and notifications use ordinary vibration. Settings
/// saved by older builds (alarm and siren choices) are ignored when loaded.
class SoundSettings {
  static const List<String> topUpSounds = ['coins_1', 'coins_2', 'coins_3'];

  final bool soundEnabled;
  final bool vibrationEnabled;
  final bool topUpSoundEnabled;
  final String selectedTopUpSoundId;

  SoundSettings({
    this.soundEnabled = true,
    this.vibrationEnabled = true,
    this.topUpSoundEnabled = true,
    this.selectedTopUpSoundId = 'coins_1',
  });

  Map<String, dynamic> toJson() => {
        'soundEnabled': soundEnabled,
        'vibrationEnabled': vibrationEnabled,
        'topUpSoundEnabled': topUpSoundEnabled,
        'selectedTopUpSoundId': selectedTopUpSoundId,
      };

  factory SoundSettings.fromJson(Map<String, dynamic> json) {
    final topUp = json['selectedTopUpSoundId'];
    return SoundSettings(
      soundEnabled: json['soundEnabled'] ?? true,
      vibrationEnabled: json['vibrationEnabled'] ?? true,
      topUpSoundEnabled: json['topUpSoundEnabled'] ?? true,
      selectedTopUpSoundId:
          topUpSounds.contains(topUp) ? topUp as String : topUpSounds.first,
    );
  }

  SoundSettings copyWith({
    bool? soundEnabled,
    bool? vibrationEnabled,
    bool? topUpSoundEnabled,
    String? selectedTopUpSoundId,
  }) =>
      SoundSettings(
        soundEnabled: soundEnabled ?? this.soundEnabled,
        vibrationEnabled: vibrationEnabled ?? this.vibrationEnabled,
        topUpSoundEnabled: topUpSoundEnabled ?? this.topUpSoundEnabled,
        selectedTopUpSoundId:
            selectedTopUpSoundId ?? this.selectedTopUpSoundId,
      );
}
