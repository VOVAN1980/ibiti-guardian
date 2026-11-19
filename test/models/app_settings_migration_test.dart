import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/app_settings.dart';

/// Settings saved by an older build (DrainShield's monitoring fields, all
/// eight notification switches, the single vibration switch) must still load:
/// if parsing threw, every setting would fall back to defaults.
void main() {
  test('settings saved by an older build still load', () {
    final s = AppSettings.fromJson({
      'languageCode': 'ru',
      'hasSelectedLanguage': true,
      'autoMonitoringEnabled': true,
      'monitoringIntervalMinutes': 30,
      'multiWalletMonitoringEnabled': true,
      'notificationSettings': {
        'criticalThreatAlerts': true,
        'highRiskApprovalAlerts': false,
        'unlimitedApprovalAlerts': true,
        'threatDatabaseAlerts': true,
        'panicAlerts': true,
        'revokeResultAlerts': false,
        'subscriptionReminders': true,
        'monitoringHealthAlerts': true,
      },
      'soundSettings': {
        'soundEnabled': true,
        'vibrationEnabled': false,
        'topUpSoundEnabled': true,
        'selectedTopUpSoundId': 'coins_2',
      },
      'useStableVoice': true,
    });
    expect(s.languageCode, 'ru');
    expect(s.hasSelectedLanguage, true);
    expect(s.useStableVoice, true);
    expect(s.notificationSettings.revokeResultAlerts, false);
    expect(s.soundSettings.singleVibrationEnabled, false);
    expect(s.soundSettings.doubleVibrationEnabled, false);
    expect(s.soundSettings.topUpSoundEnabled, true);
    expect(s.soundSettings.selectedTopUpSoundId, 'coins_2');
    final json = s.toJson();
    expect(json.keys, isNot(contains('autoMonitoringEnabled')));
    expect((json['notificationSettings'] as Map).keys,
        isNot(contains('subscriptionReminders')));
  });

  test('new settings round-trip', () {
    final s = AppSettings.fromJson(AppSettings().toJson());
    expect(s.notificationSettings.revokeResultAlerts, true);
    expect(s.soundSettings.singleVibrationEnabled, true);
    expect(s.soundSettings.doubleVibrationEnabled, true);
    expect(s.soundSettings.topUpSoundEnabled, true);
  });
}
