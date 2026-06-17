import 'package:ibiti_guardian/models/notification_settings.dart';
import 'package:ibiti_guardian/models/sound_settings.dart';
import 'package:ibiti_guardian/models/jarvis_personality.dart';

class AppSettings {
  final String languageCode;
  final bool hasSelectedLanguage;
  final bool hasRequestedPush;
  final NotificationSettings notificationSettings;
  final SoundSettings soundSettings;
  final bool autoMonitoringEnabled;
  final int monitoringIntervalMinutes;
  final bool multiWalletMonitoringEnabled;
  final bool quietModeEnabled;
  final String quietModeStart; // HH:mm
  final String quietModeEnd; // HH:mm
  final bool isNeuralOperatorEnabled;
  final String? geminiApiKey; // kept for backward-compat / migration
  final String? openaiApiKey;
  final String selectedMascotPath;
  final String? preferredAiVoiceId;
  final JarvisPersonality jarvisPersonality;
  final bool useStableVoice;

  AppSettings({
    this.languageCode = '',
    this.hasSelectedLanguage = false,
    this.hasRequestedPush = false,
    NotificationSettings? notificationSettings,
    SoundSettings? soundSettings,
    this.autoMonitoringEnabled = false,
    this.monitoringIntervalMinutes = 60,
    this.multiWalletMonitoringEnabled = false,
    this.quietModeEnabled = false,
    this.quietModeStart = "22:00",
    this.quietModeEnd = "08:00",
    this.isNeuralOperatorEnabled = true, // Default to true if key exists
    this.geminiApiKey,
    this.openaiApiKey,
    this.selectedMascotPath = 'assets/mascot/neural/female_premium.png',
    this.preferredAiVoiceId,
    this.jarvisPersonality = JarvisPersonality.jarvis,
    this.useStableVoice = false,
  })  : notificationSettings = notificationSettings ?? NotificationSettings(),
        soundSettings = soundSettings ?? SoundSettings();

  AppSettings copyWith({
    String? languageCode,
    bool? hasSelectedLanguage,
    bool? hasRequestedPush,
    NotificationSettings? notificationSettings,
    SoundSettings? soundSettings,
    bool? autoMonitoringEnabled,
    int? monitoringIntervalMinutes,
    bool? multiWalletMonitoringEnabled,
    bool? quietModeEnabled,
    String? quietModeStart,
    String? quietModeEnd,
    bool? isNeuralOperatorEnabled,
    String? geminiApiKey,
    String? openaiApiKey,
    String? selectedMascotPath,
    String? preferredAiVoiceId,
    JarvisPersonality? jarvisPersonality,
    bool? useStableVoice,
  }) {
    return AppSettings(
      languageCode: languageCode ?? this.languageCode,
      hasSelectedLanguage: hasSelectedLanguage ?? this.hasSelectedLanguage,
      hasRequestedPush: hasRequestedPush ?? this.hasRequestedPush,
      notificationSettings: notificationSettings ?? this.notificationSettings,
      soundSettings: soundSettings ?? this.soundSettings,
      autoMonitoringEnabled:
          autoMonitoringEnabled ?? this.autoMonitoringEnabled,
      monitoringIntervalMinutes:
          monitoringIntervalMinutes ?? this.monitoringIntervalMinutes,
      multiWalletMonitoringEnabled:
          multiWalletMonitoringEnabled ?? this.multiWalletMonitoringEnabled,
      quietModeEnabled: quietModeEnabled ?? this.quietModeEnabled,
      quietModeStart: quietModeStart ?? this.quietModeStart,
      quietModeEnd: quietModeEnd ?? this.quietModeEnd,
      isNeuralOperatorEnabled:
          isNeuralOperatorEnabled ?? this.isNeuralOperatorEnabled,
      geminiApiKey: geminiApiKey ?? this.geminiApiKey,
      openaiApiKey: openaiApiKey ?? this.openaiApiKey,
      selectedMascotPath: selectedMascotPath ?? this.selectedMascotPath,
      preferredAiVoiceId: preferredAiVoiceId ?? this.preferredAiVoiceId,
      jarvisPersonality: jarvisPersonality ?? this.jarvisPersonality,
      useStableVoice: useStableVoice ?? this.useStableVoice,
    );
  }

  Map<String, dynamic> toJson() => {
        'languageCode': languageCode,
        'hasSelectedLanguage': hasSelectedLanguage,
        'hasRequestedPush': hasRequestedPush,
        'notificationSettings': notificationSettings.toJson(),
        'soundSettings': soundSettings.toJson(),
        'autoMonitoringEnabled': autoMonitoringEnabled,
        'monitoringIntervalMinutes': monitoringIntervalMinutes,
        'multiWalletMonitoringEnabled': multiWalletMonitoringEnabled,
        'quietModeEnabled': quietModeEnabled,
        'quietModeStart': quietModeStart,
        'quietModeEnd': quietModeEnd,
        'isNeuralOperatorEnabled': isNeuralOperatorEnabled,
        'geminiApiKey': geminiApiKey,
        'openaiApiKey': openaiApiKey,
        'selectedMascotPath': selectedMascotPath,
        'preferredAiVoiceId': preferredAiVoiceId,
        'jarvisPersonality': jarvisPersonality.name,
        'useStableVoice': useStableVoice,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        languageCode: json['languageCode'] ?? '',
        hasSelectedLanguage: json['hasSelectedLanguage'] ?? false,
        hasRequestedPush: json['hasRequestedPush'] ?? false,
        notificationSettings: json['notificationSettings'] != null
          ? NotificationSettings.fromJson(json['notificationSettings'])
          : null,
        soundSettings: json['soundSettings'] != null
          ? SoundSettings.fromJson(json['soundSettings'])
          : null,
        autoMonitoringEnabled: json['autoMonitoringEnabled'] ?? false,
        monitoringIntervalMinutes: json['monitoringIntervalMinutes'] ?? 60,
        multiWalletMonitoringEnabled:
            json['multiWalletMonitoringEnabled'] ?? false,
        quietModeEnabled: json['quietModeEnabled'] ?? false,
        quietModeStart: json['quietModeStart'] ?? "22:00",
        quietModeEnd: json['quietModeEnd'] ?? "08:00",
        isNeuralOperatorEnabled: json['isNeuralOperatorEnabled'] ?? true,
        geminiApiKey: json['geminiApiKey'],
        openaiApiKey: json['openaiApiKey'],
        selectedMascotPath: json['selectedMascotPath'] ??
            'assets/mascot/neural/female_premium.png',
        preferredAiVoiceId: json['preferredAiVoiceId'],
        jarvisPersonality: _parsePersonality(json['jarvisPersonality']),
        useStableVoice: json['useStableVoice'] ?? false,
      );

  static JarvisPersonality _parsePersonality(dynamic value) {
    if (value is String) {
      return JarvisPersonality.values.firstWhere(
        (p) => p.name == value,
        orElse: () => JarvisPersonality.jarvis,
      );
    }
    return JarvisPersonality.jarvis;
  }
}
