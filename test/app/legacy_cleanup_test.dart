import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ibiti_guardian/app/legacy_cleanup.dart';

/// Old DrainShield-era settings are removed; other settings stay.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('removes the old keys and keeps the rest', () async {
    SharedPreferences.setMockInitialValues({
      'threat_cache': '[]',
      'threat_last_sync': 1,
      'spender_manifest_cache': '{}',
      'monitoring_last_scan_time': 'x',
      'monitoring_next_scan_time': 'x',
      'monitoring_last_risks': '{}',
      'pro_status': '{}',
      'app_settings': 'keep me',
    });
    await cleanUpLegacyData();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isNot(contains('threat_cache')));
    expect(prefs.getKeys(), isNot(contains('monitoring_last_risks')));
    expect(prefs.getKeys(), isNot(contains('pro_status')));
    expect(prefs.getString('app_settings'), 'keep me');
    // Unit tests have no sqflite, so the database step fails: the cleanup is
    // not marked done and runs again next launch.
    expect(prefs.getBool('legacy_cleanup_v1'), isNot(true));
  });
}
