import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MonitoringStateService extends ChangeNotifier {
  static final MonitoringStateService instance =
      MonitoringStateService._internal();
  MonitoringStateService._internal();

  static const _log = GuardianLogger('MonitoringState');

  static const String _lastScanTimeKey = 'monitoring_last_scan_time';
  static const String _nextScanTimeKey = 'monitoring_next_scan_time';
  static const String _lastRisksKey = 'monitoring_last_risks';

  DateTime? _lastScanTime;
  DateTime? _nextScanTime;
  // Map<walletAddress, Set<fingerprint>>
  final Map<String, Set<String>> _lastRisks = {};

  DateTime? get lastScanTime => _lastScanTime;
  DateTime? get nextScanTime => _nextScanTime;

  bool get isStale {
    if (_lastScanTime == null) return false;
    // If last scan was more than twice the expected interval ago, consider it stale
    // (Assuming max interval is 24h, but we can be more specific)
    return DateTime.now().difference(_lastScanTime!).inHours > 26;
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    final lastScanStr = prefs.getString(_lastScanTimeKey);
    if (lastScanStr != null) {
      _lastScanTime = DateTime.tryParse(lastScanStr);
    }

    final nextScanStr = prefs.getString(_nextScanTimeKey);
    if (nextScanStr != null) {
      _nextScanTime = DateTime.tryParse(nextScanStr);
    }

    final risksJson = prefs.getString(_lastRisksKey);
    if (risksJson != null) {
      try {
        final Map<String, dynamic> decoded = json.decode(risksJson);
        decoded.forEach((address, fingerprints) {
          if (fingerprints is List) {
            _lastRisks[address.toLowerCase()] =
                fingerprints.map((e) => e.toString()).toSet();
          }
        });
      } catch (e) {
        _log.e('Error loading risks', e);
      }
    }
    notifyListeners();
  }

  Future<void> updateScanTimestamps(DateTime last, DateTime next) async {
    _lastScanTime = last;
    _nextScanTime = next;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastScanTimeKey, last.toIso8601String());
    await prefs.setString(_nextScanTimeKey, next.toIso8601String());
    notifyListeners();
  }

  bool isNewRisk(String walletAddress, String spenderAddress,
      String tokenAddress, int chainId) {
    final key =
        "${chainId}_${spenderAddress.toLowerCase()}_${tokenAddress.toLowerCase()}";
    final walletKey = walletAddress.toLowerCase();

    final previousRisks = _lastRisks[walletKey] ?? {};
    return !previousRisks.contains(key);
  }

  /// Checks if a spender address is already flagged in ANY OTHER wallet.
  bool isSpenderRepeatedInOtherWallets(String spenderAddress,
      [String? currentWalletAddress]) {
    final addr = spenderAddress.toLowerCase();
    final currentKey = currentWalletAddress?.toLowerCase();

    for (final entry in _lastRisks.entries) {
      if (currentKey != null && entry.key == currentKey) continue;

      for (final riskKey in entry.value) {
        // riskKey format: "chainId_spenderAddress_tokenAddress"
        final parts = riskKey.split('_');
        if (parts.length >= 2 && parts[1] == addr) return true;
      }
    }
    return false;
  }

  Future<void> updateRisks(
      String walletAddress, Set<String> currentRiskKeys) async {
    _lastRisks[walletAddress.toLowerCase()] = currentRiskKeys;
    await _saveRisks();
    notifyListeners();
  }

  Future<void> _saveRisks() async {
    final prefs = await SharedPreferences.getInstance();
    final Map<String, List<String>> toEncode = {};
    _lastRisks.forEach((key, value) {
      toEncode[key] = value.toList();
    });
    await prefs.setString(_lastRisksKey, json.encode(toEncode));
  }
}
