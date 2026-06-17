import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:ibiti_guardian/services/threat_intelligence_service.dart';
import 'package:ibiti_guardian/services/pro/pro_service.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';

enum SystemHealthState {
  protected, // All good, monitoring active (PRO)
  monitoringPaused, // Monitoring disabled or FREE mode
  subscriptionInactive, // PRO required for full 24/7 protection
  networkDegraded, // No internet
  threatIntelStale, // Feed not synced for > 24h
  initializing // Startup
}

class SystemHealthService extends ChangeNotifier {
  static final SystemHealthService instance = SystemHealthService._internal();
  SystemHealthService._internal();

  SystemHealthState _state = SystemHealthState.initializing;
  SystemHealthState get state => _state;

  bool _isOnline = true;
  bool get isOnline => _isOnline;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  Future<void> init() async {
    // Initial connectivity check
    final results = await Connectivity().checkConnectivity();
    _updateOnlineStatus(results);

    // Listen for changes
    _connectivitySub =
        Connectivity().onConnectivityChanged.listen(_updateOnlineStatus);

    // Listen to other services
    ThreatIntelligenceService.instance.addListener(_refreshState);
    ProService.instance.addListener(_refreshState);
    SettingsService.instance.addListener(_refreshState);

    _refreshState();
  }

  void _updateOnlineStatus(List<ConnectivityResult> results) {
    _isOnline =
        results.isNotEmpty && !results.contains(ConnectivityResult.none);
    _refreshState();
  }

  void _refreshState() {
    if (!_isOnline) {
      _state = SystemHealthState.networkDegraded;
    } else {
      final intel = ThreatIntelligenceService.instance;
      final pro = ProService.instance;
      final settings = SettingsService.instance.settings;

      if (intel.isStale && intel.source != IntelSource.remote) {
        _state = SystemHealthState.threatIntelStale;
      } else if (!pro.isProActive()) {
        _state = SystemHealthState.subscriptionInactive;
      } else if (!settings.autoMonitoringEnabled) {
        _state = SystemHealthState.monitoringPaused;
      } else {
        _state = SystemHealthState.protected;
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    ThreatIntelligenceService.instance.removeListener(_refreshState);
    ProService.instance.removeListener(_refreshState);
    SettingsService.instance.removeListener(_refreshState);
    super.dispose();
  }
}
