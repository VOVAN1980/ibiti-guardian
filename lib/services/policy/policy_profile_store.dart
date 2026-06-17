import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';

/// Persistent storage for the user's execution policy.
///
/// Phase 5 requirements: Simple load, basic updates, no complex UI editor overhead.
/// Defaults strictly to `PolicyMode.safe`.
class PolicyProfileStore extends ChangeNotifier {
  PolicyProfileStore._();
  static final instance = PolicyProfileStore._();

  static const _profileKey = 'guardian_policy_profileV1';

  PolicyProfile _currentProfile = PolicyProfile.safe();

  /// Holds the active profile in memory.
  PolicyProfile get current => _currentProfile;

  /// Loads the profile from local storage. If missing, saves and returns `Safe` mode.
  Future<PolicyProfile> load() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_profileKey);

    if (jsonStr == null) {
      _currentProfile = PolicyProfile.safe();
      await _save(_currentProfile);
      return _currentProfile;
    }

    try {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final modeStr = map['mode'] as String? ?? 'safe';

      final mode = PolicyMode.values.firstWhere(
        (e) => e.name == modeStr,
        orElse: () => PolicyMode.safe,
      );

      _currentProfile = PolicyProfile(
        mode: mode,
        sendLimitUsd: (map['sendLimitUsd'] as num?)?.toDouble() ?? 50.0,
        swapLimitUsd: (map['swapLimitUsd'] as num?)?.toDouble() ?? 500.0,
        approveLimitUsd: (map['approveLimitUsd'] as num?)?.toDouble() ?? 100.0,
        allowUnknownContracts: map['allowUnknownContracts'] as bool? ?? false,
        allowUnlimitedApprove: map['allowUnlimitedApprove'] as bool? ?? false,
        trustedAddresses: List<String>.from(map['trustedAddresses'] ?? []),
        trustedContracts: List<String>.from(map['trustedContracts'] ?? []),
        actionExpiries: (map['actionExpiries'] as Map<String, dynamic>?)?.map(
                (key, val) => MapEntry(key, DateTime.parse(val.toString()))) ??
            {},
      );
    } catch (e) {
      // Corrupt save -> Default to safe
      _currentProfile = PolicyProfile.safe();
    }

    await _syncDependents();
    notifyListeners();
    return _currentProfile;
  }

  /// Updates constraints for a specific action type
  Future<void> updateLimit(String actionType, double limit,
      {DateTime? expiry}) async {
    PolicyProfile updated = _currentProfile;
    if (actionType == 'SEND') {
      updated = updated.copyWith(sendLimitUsd: limit);
    } else if (actionType == 'SWAP') {
      updated = updated.copyWith(swapLimitUsd: limit);
    } else if (actionType == 'APPROVE') {
      updated = updated.copyWith(approveLimitUsd: limit);
    }

    final newExpiries = Map<String, DateTime>.from(updated.actionExpiries);
    if (expiry != null) {
      newExpiries[actionType] = expiry;
    } else {
      newExpiries.remove(actionType);
    }
    updated = updated.copyWith(actionExpiries: newExpiries);

    _currentProfile = updated;
    await _save(_currentProfile);
    await _syncDependents();
    notifyListeners();
  }

  Future<void> setMode(PolicyMode mode) async {
    final trustedAddresses =
        List<String>.from(_currentProfile.trustedAddresses);
    final trustedContracts =
        List<String>.from(_currentProfile.trustedContracts);
    final actionExpiries =
        Map<String, DateTime>.from(_currentProfile.actionExpiries);

    final preset = switch (mode) {
      PolicyMode.safe => PolicyProfile.safe(),
      PolicyMode.defi => PolicyProfile.defi(),
      PolicyMode.advanced => const PolicyProfile(
          mode: PolicyMode.advanced,
          sendLimitUsd: 2500.0,
          swapLimitUsd: 10000.0,
          approveLimitUsd: 5000.0,
          allowUnknownContracts: true,
          allowUnlimitedApprove: false,
        ),
    };

    _currentProfile = preset.copyWith(
      trustedAddresses: trustedAddresses,
      trustedContracts: trustedContracts,
      actionExpiries: actionExpiries,
    );
    await _save(_currentProfile);
    await _syncDependents();
    notifyListeners();
  }

  /// Adds a specific address to the trusted list, bypassing static unknown warnings.
  Future<void> addTrustedAddress(String address) async {
    final addr = address.toLowerCase();
    final updated = List<String>.from(_currentProfile.trustedAddresses);
    if (!updated.contains(addr)) {
      updated.add(addr);
      _currentProfile = _currentProfile.copyWith(trustedAddresses: updated);
      await _save(_currentProfile);
      await _syncDependents();
      notifyListeners();
    }
  }

  /// Adds a specific contract address to the trusted list.
  Future<void> addTrustedContract(String address) async {
    final addr = address.toLowerCase();
    final updated = List<String>.from(_currentProfile.trustedContracts);
    if (!updated.contains(addr)) {
      updated.add(addr);
      _currentProfile = _currentProfile.copyWith(trustedContracts: updated);
      await _save(_currentProfile);
      await _syncDependents();
      notifyListeners();
    }
  }

  /// Removes an address from the trusted list.
  Future<void> removeTrustedAddress(String address) async {
    final addr = address.toLowerCase();
    final updated = List<String>.from(_currentProfile.trustedAddresses);
    if (updated.remove(addr)) {
      _currentProfile = _currentProfile.copyWith(trustedAddresses: updated);
      await _save(_currentProfile);
      await _syncDependents();
      notifyListeners();
    }
  }

  /// Removes a contract from the trusted list.
  Future<void> removeTrustedContract(String address) async {
    final addr = address.toLowerCase();
    final updated = List<String>.from(_currentProfile.trustedContracts);
    if (updated.remove(addr)) {
      _currentProfile = _currentProfile.copyWith(trustedContracts: updated);
      await _save(_currentProfile);
      await _syncDependents();
      notifyListeners();
    }
  }

  Future<void> setAllowUnknownContracts(bool allowed) async {
    _currentProfile = _currentProfile.copyWith(allowUnknownContracts: allowed);
    await _save(_currentProfile);
    await _syncDependents();
    notifyListeners();
  }

  Future<void> setAllowUnlimitedApprove(bool allowed) async {
    _currentProfile = _currentProfile.copyWith(allowUnlimitedApprove: allowed);
    await _save(_currentProfile);
    await _syncDependents();
    notifyListeners();
  }

  Future<void> _syncDependents() async {
    final unifiedPerTx = [
      _currentProfile.sendLimitUsd,
      _currentProfile.swapLimitUsd,
      _currentProfile.approveLimitUsd,
    ].reduce((a, b) => a < b ? a : b);
    final unifiedDaily = _currentProfile.sendLimitUsd;

    final ai = AiControlService.instance.settings;
    if (ai.perTxLimit != unifiedPerTx || ai.dailyLimit != unifiedDaily) {
      await AiControlService.instance.updateLimits(
        daily: unifiedDaily,
        perTx: unifiedPerTx,
      );
    }

    final epk = EPKPolicyManager.instance.state;
    if (epk.perTxLimit != unifiedPerTx || epk.dailyLimit != unifiedDaily) {
      EPKPolicyManager.instance.updateLimits(
        daily: unifiedDaily,
        perTx: unifiedPerTx,
      );
    }
  }

  Future<void> _save(PolicyProfile p) async {
    final prefs = await SharedPreferences.getInstance();
    final map = {
      'mode': p.mode.name,
      'sendLimitUsd': p.sendLimitUsd,
      'swapLimitUsd': p.swapLimitUsd,
      'approveLimitUsd': p.approveLimitUsd,
      'allowUnknownContracts': p.allowUnknownContracts,
      'allowUnlimitedApprove': p.allowUnlimitedApprove,
      'trustedAddresses': p.trustedAddresses,
      'trustedContracts': p.trustedContracts,
      'actionExpiries':
          p.actionExpiries.map((k, v) => MapEntry(k, v.toIso8601String())),
    };
    await prefs.setString(_profileKey, jsonEncode(map));
  }
}
