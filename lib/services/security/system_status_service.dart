import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ibiti_guardian/services/alerts/notification_service.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

/// What can be wrong, shown when the user taps the red "System status" card.
enum SystemProblem {
  /// A Safe Scan found approvals that should be revoked.
  riskyApprovals,

  /// The Privy sign-in session expired: transfers can't be signed.
  sessionExpired,

  /// Android notifications are blocked: no top-up, price or key messages.
  notificationsOff,
}

/// Risky approvals found by the latest Safe Scan of one wallet on one network.
class RiskyScan {
  final String wallet;
  final int chainId;
  final int count;
  const RiskyScan(this.wallet, this.chainId, this.count);
}

/// "System status" on the wallet screen: safe (green) or danger (red).
///
/// Built only from real state: the latest Safe Scan of each wallet and
/// network (kept across restarts, updated after a revoke), the Privy session,
/// and the Android notification permission.
class SystemStatusService extends ChangeNotifier with WidgetsBindingObserver {
  static final SystemStatusService instance = SystemStatusService._();
  SystemStatusService._();

  static const _log = GuardianLogger('SystemStatus');
  static const String _prefsKey = 'system_status_risky_by_scan';

  /// Off in unit tests, where there is no notification plugin.
  @visibleForTesting
  bool checkNotifications = true;

  /// Risky approvals per "wallet|chainId".
  final Map<String, int> _riskyByScan = {};
  bool _notificationsOff = false;
  Future<void>? _loading;

  int get riskyApprovals => _riskyByScan.values.fold(0, (a, b) => a + b);

  /// Where the risky approvals are, for the "What's wrong" sheet.
  List<RiskyScan> get riskyScans => [
        for (final e in _riskyByScan.entries)
          RiskyScan(e.key.split('|').first,
              int.tryParse(e.key.split('|').last) ?? 0, e.value),
      ];

  List<SystemProblem> get problems => [
        if (riskyApprovals > 0) SystemProblem.riskyApprovals,
        if (IBITIVaultService.instance.privySessionExpired)
          SystemProblem.sessionExpired,
        if (_notificationsOff) SystemProblem.notificationsOff,
      ];

  bool get isSafe => problems.isEmpty;

  /// Loads the saved scan results and starts watching the session and the
  /// notification permission. Safe to call more than once.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        final map = jsonDecode(raw);
        if (map is Map) {
          map.forEach((k, v) {
            if (k is String && v is int && v > 0) _riskyByScan[k] = v;
          });
        }
      }
    } catch (e) {
      _log.e('Saved scan results not loaded', e);
    }
    IBITIVaultService.instance.addListener(_onVaultChanged);
    WidgetsBinding.instance.addObserver(this);
    await refreshNotifications();
    notifyListeners();
  }

  /// Re-reads the state the card shows (e.g. after signing in again).
  void refresh() => notifyListeners();

  /// Rechecks the Android notification permission (only Android can tell).
  Future<void> refreshNotifications() async {
    if (!checkNotifications ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      final off = !await NotificationService.instance.isPermissionGranted();
      if (off != _notificationsOff) {
        _notificationsOff = off;
        notifyListeners();
      }
    } catch (e) {
      _log.e('Notification permission check failed', e);
    }
  }

  /// Asks Android for the notification permission, then rechecks.
  Future<void> requestNotifications() async {
    await NotificationService.instance.requestPermission();
    await refreshNotifications();
  }

  /// Records the risky approvals left on [wallet] / [chainId]: after a full
  /// Safe Scan, or after a revoke.
  Future<void> recordScan(String wallet, int chainId, int riskyCount) async {
    await load();
    final key = '${wallet.toLowerCase()}|$chainId';
    if (riskyCount > 0) {
      _riskyByScan[key] = riskyCount;
    } else {
      _riskyByScan.remove(key);
    }
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(_riskyByScan));
    } catch (e) {
      _log.e('Scan result not saved', e);
    }
  }

  void _onVaultChanged() => notifyListeners();

  /// Signed out / wallet reset: the old wallet's results no longer apply.
  /// Called from IBITIVaultService.logout().
  Future<void> clear() async {
    _riskyByScan.clear();
    notifyListeners();
    await _save();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user may have changed the permission in Android settings.
    if (state == AppLifecycleState.resumed) refreshNotifications();
  }

  @visibleForTesting
  void resetForTest() {
    if (_loading != null) {
      IBITIVaultService.instance.removeListener(_onVaultChanged);
      WidgetsBinding.instance.removeObserver(this);
    }
    _riskyByScan.clear();
    _notificationsOff = false;
    _loading = null;
    checkNotifications = false;
  }
}
