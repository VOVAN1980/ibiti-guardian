import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:workmanager/workmanager.dart';

/// Guardian has no background tasks any more. Older builds registered two
/// periodic Workmanager tasks: the daily update check ("1") and DrainShield's
/// wallet monitoring. This build only removes them from the phone; after it
/// has run once on every device, the workmanager plugin can be deleted.
@pragma('vm:entry-point')
void callbackDispatcher() {
  // A task registered by an older build that fires before the cleanup below.
  Workmanager().executeTask((task, inputData) async => true);
}

const String _oldUpdateTask = '1';
const String _oldMonitoringTask = 'IBITI Guardian_background_monitoring';

/// Cancels the periodic tasks that older builds registered.
/// BootScreen runs it among the deferred services, after the intro.
Future<void> setupBackgroundTasks() async {
  // Workmanager is only supported on Android/iOS.
  if (defaultTargetPlatform != TargetPlatform.android &&
      defaultTargetPlatform != TargetPlatform.iOS) {
    return;
  }
  try {
    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: kDebugMode,
    );
    await Workmanager().cancelByUniqueName(_oldUpdateTask);
    await Workmanager().cancelByUniqueName(_oldMonitoringTask);
  } catch (e) {
    const GuardianLogger('Workmanager').e('Cleanup of old tasks failed', e);
  }
}
