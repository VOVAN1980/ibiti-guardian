import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ibiti_guardian/models/app_settings.dart';
import 'package:ibiti_guardian/models/notification_settings.dart';
import 'package:ibiti_guardian/models/sound_settings.dart';
import 'package:ibiti_guardian/models/jarvis_personality.dart';

class SettingsService extends ChangeNotifier {
  static final SettingsService instance = SettingsService._internal();
  SettingsService._internal();

  static const String _key = 'app_settings';
  AppSettings _settings = AppSettings();

  AppSettings get settings => _settings;

  @visibleForTesting
  set settingsForTest(AppSettings value) {
    _settings = value;
  }

  Future<void> init() async {
    await load();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_key);
    if (jsonStr != null) {
      try {
        final Map<String, dynamic> jsonMap = json.decode(jsonStr);
        _settings = AppSettings.fromJson(jsonMap);
      } catch (e) {
        _settings = AppSettings();
      }
    } else {
      _settings = AppSettings();
    }
    notifyListeners();
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = json.encode(_settings.toJson());
    await prefs.setString(_key, jsonStr);
    notifyListeners();
  }

  Future<void> updateNotificationSettings(
      NotificationSettings newSettings) async {
    _settings = _settings.copyWith(notificationSettings: newSettings);
    await save();
  }

  Future<void> updateSoundSettings(SoundSettings newSettings) async {
    _settings = _settings.copyWith(soundSettings: newSettings);
    await save();
  }

  Future<void> updateLanguage(String languageCode) async {
    _settings = _settings.copyWith(
      languageCode: languageCode,
      hasSelectedLanguage: true,
    );
    await save();
  }

  Future<void> finishPushRequest() async {
    _settings = _settings.copyWith(hasRequestedPush: true);
    await save();
  }

  Future<void> updateMonitoringSettings({
    bool? autoMonitoringEnabled,
    int? monitoringIntervalMinutes,
    bool? multiWalletMonitoringEnabled,
  }) async {
    _settings = _settings.copyWith(
      autoMonitoringEnabled: autoMonitoringEnabled,
      monitoringIntervalMinutes: monitoringIntervalMinutes,
      multiWalletMonitoringEnabled: multiWalletMonitoringEnabled,
    );
    await save();
  }

  Future<void> updateQuietMode({
    bool? enabled,
    String? start,
    String? end,
  }) async {
    _settings = _settings.copyWith(
      quietModeEnabled: enabled,
      quietModeStart: start,
      quietModeEnd: end,
    );
    await save();
  }

  Future<void> updateAiSettings({
    bool? isNeuralOperatorEnabled,
    String? geminiApiKey,
    String? openaiApiKey,
    String? selectedMascotPath,
    String? preferredAiVoiceId,
    bool? useStableVoice,
  }) async {
    _settings = _settings.copyWith(
      isNeuralOperatorEnabled: isNeuralOperatorEnabled,
      geminiApiKey: geminiApiKey,
      openaiApiKey: openaiApiKey,
      selectedMascotPath: selectedMascotPath,
      preferredAiVoiceId: preferredAiVoiceId,
      useStableVoice: useStableVoice,
    );
    await save();
  }

  Future<void> updateJarvisPersonality(JarvisPersonality personality) async {
    _settings = _settings.copyWith(jarvisPersonality: personality);
    await save();
  }
}
