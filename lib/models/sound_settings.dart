class SoundSettings {
  static const List<String> alertSounds = ['standard', 'cyber', 'minimal'];
  static const List<String> criticalSounds = [
    'alarm_1',
    'alarm_premium',
    'siren',
    'lion_roar',
  ];
  static const List<String> panicSounds = [
    'panic_ultra',
    'emergency',
    'lion_roar',
  ];
  static const List<String> topUpSounds = ['coins_1', 'coins_2', 'coins_3'];

  final bool soundEnabled;
  final bool vibrationEnabled;
  final bool criticalAlarmEnabled;
  final bool panicAlarmEnabled;
  final String selectedAlertSoundId;
  final String selectedCriticalSoundId;
  final String selectedPanicSoundId;
  final bool topUpSoundEnabled;
  final String selectedTopUpSoundId;

  SoundSettings({
    this.soundEnabled = true,
    this.vibrationEnabled = true,
    this.criticalAlarmEnabled = true,
    this.panicAlarmEnabled = true,
    this.selectedAlertSoundId = 'standard',
    this.selectedCriticalSoundId = 'alarm_1',
    this.selectedPanicSoundId = 'panic_ultra',
    this.topUpSoundEnabled = true,
    this.selectedTopUpSoundId = 'coins_1',
  });

  Map<String, dynamic> toJson() => {
        'soundEnabled': soundEnabled,
        'vibrationEnabled': vibrationEnabled,
        'criticalAlarmEnabled': criticalAlarmEnabled,
        'panicAlarmEnabled': panicAlarmEnabled,
        'selectedAlertSoundId': selectedAlertSoundId,
        'selectedCriticalSoundId': selectedCriticalSoundId,
        'selectedPanicSoundId': selectedPanicSoundId,
        'topUpSoundEnabled': topUpSoundEnabled,
        'selectedTopUpSoundId': selectedTopUpSoundId,
      };

  factory SoundSettings.fromJson(Map<String, dynamic> json) {
    // Helper to validate and fallback
    String normalize(String? value, List<String> allowed) {
      if (value != null && allowed.contains(value)) return value;
      return allowed.first;
    }

    return SoundSettings(
      soundEnabled: json['soundEnabled'] ?? true,
      vibrationEnabled: json['vibrationEnabled'] ?? true,
      criticalAlarmEnabled: json['criticalAlarmEnabled'] ?? true,
      panicAlarmEnabled: json['panicAlarmEnabled'] ?? true,
      selectedAlertSoundId: normalize(
        json['selectedAlertSoundId'],
        alertSounds,
      ),
      selectedCriticalSoundId: normalize(
        json['selectedCriticalSoundId'],
        criticalSounds,
      ),
      selectedPanicSoundId: normalize(
        json['selectedPanicSoundId'],
        panicSounds,
      ),
      topUpSoundEnabled: json['topUpSoundEnabled'] ?? true,
      selectedTopUpSoundId: normalize(
        json['selectedTopUpSoundId'],
        topUpSounds,
      ),
    );
  }

  SoundSettings copyWith({
    bool? soundEnabled,
    bool? vibrationEnabled,
    bool? criticalAlarmEnabled,
    bool? panicAlarmEnabled,
    String? selectedAlertSoundId,
    String? selectedCriticalSoundId,
    String? selectedPanicSoundId,
    bool? topUpSoundEnabled,
    String? selectedTopUpSoundId,
  }) =>
      SoundSettings(
        soundEnabled: soundEnabled ?? this.soundEnabled,
        vibrationEnabled: vibrationEnabled ?? this.vibrationEnabled,
        criticalAlarmEnabled: criticalAlarmEnabled ?? this.criticalAlarmEnabled,
        panicAlarmEnabled: panicAlarmEnabled ?? this.panicAlarmEnabled,
        selectedAlertSoundId: selectedAlertSoundId ?? this.selectedAlertSoundId,
        selectedCriticalSoundId:
            selectedCriticalSoundId ?? this.selectedCriticalSoundId,
        selectedPanicSoundId: selectedPanicSoundId ?? this.selectedPanicSoundId,
        topUpSoundEnabled: topUpSoundEnabled ?? this.topUpSoundEnabled,
        selectedTopUpSoundId:
            selectedTopUpSoundId ?? this.selectedTopUpSoundId,
      );
}
