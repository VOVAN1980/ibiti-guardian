import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/services/audit_log_service.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/audit_log_entry.dart';
import 'package:ibiti_guardian/models/execution_result.dart';

/// Balance-based reconciliation layer for the daily spending system.
///
/// Problem solved: if a tx confirms AFTER the reservation TTL expires,
/// the budget was already rolled back but real money was spent.
/// This creates a drift between tracked usage and actual wallet state.
///
/// Solution: periodically compare the wallet's cached USD balance change
/// against tracked daily spend. If drift exceeds [_driftThreshold],
/// force-correct the usage counter and log a reconciliation event.
///
/// Usage:
/// ```dart
/// // On app startup:
/// SpendReconciler.instance.snapshotDayStart();
///
/// // Every 60s (or on balance refresh):
/// final drift = SpendReconciler.instance.reconcile();
/// if (drift != null) print('Corrected drift: \$$drift');
/// ```
class SpendReconciler {
  SpendReconciler._();
  static final instance = SpendReconciler._();

  static const _log = GuardianLogger('Reconciler');

  /// Minimum drift ($) before triggering a reconciliation correction.
  /// Below this, normal rounding / price fluctuation noise is ignored.
  static const double _driftThreshold = 5.0;

  /// Snapshot of wallet USD balance at the start of the tracking day.
  double? _dayStartBalanceUsd;

  /// Date when the snapshot was taken (for daily reset).
  DateTime? _snapshotDate;

  /// Tracks how many corrections were applied today (telemetry).
  int _correctionsToday = 0;

  /// Take a balance snapshot at the start of each tracking day.
  /// Called on app startup and whenever the delegation day resets.
  void snapshotDayStart() {
    final balance = _currentBalanceUsd();
    if (balance == null) {
      _log.d('Cannot snapshot — no cached portfolio balance available.');
      return;
    }

    _dayStartBalanceUsd = balance;
    _snapshotDate = DateTime.now();
    _correctionsToday = 0;
    _log.d('Day-start balance snapshot: \$${balance.toStringAsFixed(2)}');
  }

  /// Run reconciliation check. Call this periodically (e.g. every 60s)
  /// or after a significant event (e.g. balance refresh).
  ///
  /// Returns the drift amount if a correction was applied, or null if clean.
  double? reconcile() {
    // Guard: need a snapshot to compare against.
    if (_dayStartBalanceUsd == null) {
      snapshotDayStart();
      return null;
    }

    // Guard: reset on new day.
    final now = DateTime.now();
    if (_snapshotDate != null &&
        (now.day != _snapshotDate!.day ||
            now.month != _snapshotDate!.month ||
            now.year != _snapshotDate!.year)) {
      snapshotDayStart();
      return null;
    }

    final currentBalance = _currentBalanceUsd();
    if (currentBalance == null) return null;

    // Actual spend = how much the balance decreased.
    // Positive if balance went down (money spent).
    // Negative if balance went up (received deposit).
    final actualSpendUsd = _dayStartBalanceUsd! - currentBalance;

    // Only reconcile outflows (positive spend).
    // If balance went UP, we can't know if it's from a swap output
    // or an inbound transfer — ignore it.
    if (actualSpendUsd <= 0) return null;

    final delegation = DelegationController.instance;
    // Direct getter — no string parsing. Immune to localization/format changes.
    final trackedUsage = delegation.usedTodayUsd;

    final drift = actualSpendUsd - trackedUsage;

    // Only correct positive drift = we spent more than tracked.
    // This happens when a tx confirmed after reservation TTL expired.
    if (drift > _driftThreshold) {
      _correctionsToday++;
      _log.w('Reconciliation drift detected (#$_correctionsToday): '
          'actual=\$${actualSpendUsd.toStringAsFixed(2)}, '
          'tracked=\$${trackedUsage.toStringAsFixed(2)}, '
          'drift=+\$${drift.toStringAsFixed(2)}');

      // Force-correct the tracker.
      delegation.commitUsage(drift);

      AuditLogService.instance.record(
        intentType: IntentType.unknown,
        actionLabel: 'RECONCILIATION_CORRECTION',
        summary: 'Balance drift +\$${drift.toStringAsFixed(2)} detected. '
            'Usage corrected from \$${trackedUsage.toStringAsFixed(2)} '
            'to \$${(trackedUsage + drift).toStringAsFixed(2)}. '
            '(Correction #$_correctionsToday today)',
        executionSource: ExecutionSource.system,
        result: ExecutionResult.success(
          txHash: '',
          pathLabel: 'reconciler',
          message: 'Drift: +\$${drift.toStringAsFixed(2)}',
        ),
      );

      return drift;
    }

    return null;
  }

  /// Telemetry: how many corrections have been applied today.
  int get correctionsToday => _correctionsToday;

  /// Whether a valid day-start snapshot exists.
  bool get hasSnapshot => _dayStartBalanceUsd != null;

  // ── Private ─────────────────────────────────────────────────────────────────

  /// Get current total wallet USD balance from the cached portfolio.
  /// Uses VaultPortfolioListener (already cached from last refresh)
  /// to avoid triggering network fetches.
  double? _currentBalanceUsd() {
    final summary = VaultPortfolioListener.instance.summary;
    return summary?.totalBalanceUsd;
  }
}
