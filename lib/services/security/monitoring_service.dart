import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/models/security_event.dart';

import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/services/pro/pro_service.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/services/security/approval_scan_service.dart';
import 'package:ibiti_guardian/services/security/security_event_service.dart';
import 'package:ibiti_guardian/services/security/monitoring_state_service.dart';
import 'package:ibiti_guardian/config/chains.dart';
import 'package:ibiti_guardian/services/localization_service.dart';

import 'package:workmanager/workmanager.dart';

class MonitoringService {
  static final MonitoringService instance = MonitoringService._internal();
  MonitoringService._internal();

  static const _log = GuardianLogger('Monitoring');

  static const String _backgroundTaskName =
      'IBITI Guardian_background_monitoring';
  bool _isInitialized = false;
  bool _isChecking = false;

  // No longer needed here as it's persisted in MonitoringStateService
  // final Map<String, Set<String>> _lastRisks = {};

  Future<void> init() async {
    if (_isInitialized) return;
    await MonitoringStateService.instance.init();
    _isInitialized = true;

    // Schedule background tasks on init
    await scheduleBackgroundTask();

    // Re-schedule when PRO status or settings change
    ProService.instance.addListener(() => scheduleBackgroundTask());
    SettingsService.instance.addListener(() => scheduleBackgroundTask());
  }

  Future<void> scheduleBackgroundTask() async {
    final bool isPro = ProService.instance.isProActive();
    final settings = SettingsService.instance.settings;

    if (!isPro || !settings.autoMonitoringEnabled) {
      await Workmanager().cancelByUniqueName(_backgroundTaskName);
      _log.d('Background tasks cancelled');
      return;
    }

    // WorkManager minimum periodic frequency is 15 minutes
    final interval =
        Duration(minutes: settings.monitoringIntervalMinutes.clamp(15, 1440));

    await Workmanager().registerPeriodicTask(
      _backgroundTaskName,
      'periodic_check',
      frequency: interval,
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
    );

    // Update next scan time (rough estimate based on now + interval)
    await MonitoringStateService.instance.updateScanTimestamps(
      MonitoringStateService.instance.lastScanTime ?? DateTime.now(),
      DateTime.now().add(interval),
    );

    _log.d('Background tasks scheduled every ${interval.inMinutes} mins');
  }

  Future<void> runMonitoringNow() async {
    if (_isChecking) return;
    _isChecking = true;

    try {
      if (!ProService.instance.isProActive()) {
        _log.d('Skip: PRO subscription not active');
        return;
      }

      final settings = SettingsService.instance.settings;
      if (!settings.autoMonitoringEnabled && !kDebugMode) {
        _log.d('Skip: Auto-monitoring disabled');
        return;
      }

      final vaultAddress = IBITIVaultService.instance.address;
      if (vaultAddress.isEmpty) {
        _log.d('Skip: Vault address empty');
        return;
      }

      _log.d('Starting check');

      await _runWalletCheck(vaultAddress);

      // Update last scan time after successful run
      final nextScan = DateTime.now().add(Duration(
          minutes: SettingsService.instance.settings.monitoringIntervalMinutes
              .clamp(15, 1440)));
      await MonitoringStateService.instance
          .updateScanTimestamps(DateTime.now(), nextScan);
    } finally {
      _isChecking = false;
    }
  }

  Future<void> _runWalletCheck(String address) async {
    final allRiskyKeys = <String>{};
    final supportedChains = [1, 56, 137, 42161, 10, 8453];
    final t = LocalizationService.instance;

    final List<Future<void>> scans = [];
    for (final chainId in supportedChains) {
      scans.add(() async {
        try {
          final chainName = ChainConfig.getChainName(chainId);
          final approvals =
              await ApprovalScanService.scan(address, chainId: chainId);

          // Filter risky ones
          final riskyApprovals =
              approvals.where((a) => a.assessment.shouldRevoke).toList();

          synchronized(allRiskyKeys, () {
            for (final a in riskyApprovals) {
              allRiskyKeys.add("${chainId}_${a.spenderAddress}_${a.token}");
            }
          });

          // Detect NEW risks using persisted state
          final newRisks = riskyApprovals.where((a) {
            return MonitoringStateService.instance.isNewRisk(
              address,
              a.spenderAddress,
              a.token,
              chainId,
            );
          }).toList();

          if (newRisks.isNotEmpty) {
            for (final risk in newRisks) {
              final title = t.t('notifyTitleRisk', {'chainName': chainName});
              final message = t.t('notifyMsgRisk', {
                'symbol': risk.tokenSymbol,
                'chainName': chainName,
              });

              SecurityEventService.instance.emit(
                SecurityEvent(
                  type: SecurityEventType.highRiskApproval,
                  severity: risk.assessment.score >= 90 ? 'critical' : 'high',
                  timestamp: DateTime.now(),
                  walletAddress: address,
                  title: title,
                  message: message,
                  metadata: {
                    'spender': risk.spenderAddress,
                    'token': risk.token,
                    'symbol': risk.tokenSymbol,
                    'chainId': chainId,
                    'chainName': chainName,
                    'riskScore': risk.assessment.score,
                  },
                ),
              );
            }
          }
        } catch (e) {
          _log.e('Error check on chain $chainId', e);
        }
      }());

      // Staggered launch: wait enough to avoid request burst but stay parallel
      await Future.delayed(const Duration(milliseconds: 150));
    }

    await Future.wait(scans);

    // Update state with CURRENT keys to detect NEW ones in next run
    await MonitoringStateService.instance.updateRisks(address, allRiskyKeys);
  }

  // Simple thread-safe-ish helper for the parallel set update
  void synchronized(dynamic lock, Function action) {
    action(); // Sets in Dart are fine for this level of concurrency within one isolate loop
  }

  void stop() {
    Workmanager().cancelByUniqueName(_backgroundTaskName);
    _isChecking = false;
    _log.d('Background monitoring stopped');
  }
}
