import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

/// Removes data that DrainShield-era features left on the phone. Nothing reads
/// it any more: the security-event database, and the saved state of the
/// threat feed, the spender manifest and background monitoring.
/// Runs once (then remembers it in [_doneKey]); failures are only logged.
Future<void> cleanUpLegacyData() async {
  const log = GuardianLogger('LegacyCleanup');
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_doneKey) == true) return;

    for (final key in _oldPrefsKeys) {
      await prefs.remove(key);
    }
    // If the database can't be removed now, try again next launch.
    await deleteDatabase(p.join(await getDatabasesPath(), 'IBITI Guardian.db'));
    await prefs.setBool(_doneKey, true);
    log.i('Old DrainShield-era data removed');
  } catch (e) {
    log.e('Cleanup of old data failed', e);
  }
}

const String _doneKey = 'legacy_cleanup_v1';

const List<String> _oldPrefsKeys = [
  'threat_cache',
  'threat_last_sync',
  'spender_manifest_cache',
  'monitoring_last_scan_time',
  'monitoring_next_scan_time',
  'monitoring_last_risks',
  'pro_status',
];
