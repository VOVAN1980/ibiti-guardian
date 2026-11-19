import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/services/update_service.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:workmanager/workmanager.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      await UpdateService.instance.initBackground();
      return Future.value(true);
    } catch (e) {
      const log = GuardianLogger('Workmanager');
      log.e('Task failed', e);
      return Future.value(false);
    }
  });
}

/// Initializes Workmanager and registers the daily update check (only while
/// UpdateService.enabled is true; it is off until the app is published).
/// BootScreen runs it first among the deferred services (MonitoringService
/// registers its task after it). It used to run at launch, where its work on
/// the Android main thread held up the first frames.
Future<void> setupBackgroundTasks() async {
  // Workmanager is only supported on Android/iOS.
  if (defaultTargetPlatform != TargetPlatform.android &&
      defaultTargetPlatform != TargetPlatform.iOS) {
    return;
  }
  await Workmanager().initialize(
    callbackDispatcher,
    isInDebugMode: kDebugMode,
  );
  // The update check is off (UpdateService.enabled): remove the daily task
  // that older builds registered, and don't register it again.
  if (!UpdateService.enabled) {
    await Workmanager().cancelByUniqueName("1");
    return;
  }
  await Workmanager().registerPeriodicTask(
    "1",
    "app_update_check",
    frequency: const Duration(hours: 24),
    initialDelay: const Duration(minutes: 5),
    constraints: Constraints(
      networkType: NetworkType.connected,
    ),
  );
}
