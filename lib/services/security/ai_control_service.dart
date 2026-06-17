import 'package:flutter/material.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/market/automation_engine.dart'
    as market_auto;
import 'package:ibiti_guardian/services/security/monitoring_service.dart';
import 'dart:convert';

enum AiMode { manual, guarded, fullAutonomy }

enum AiAction {
  revoke,
  send,
  swap,
  approve,
  policyUpdate,
  contactPayments,
  scheduledActions,

  /// Can open any modal / screen (wallet, market, safe, panic, etc.)
  openWindows,

  /// Can close / dismiss any modal or screen
  closeWindows,
}

enum AiTrustedScope { trustedOnly, trustedPlusApproved, anyTarget }

enum AiPermissionDuration { oneHour, oneDay, oneWeek, untilRevoked }

class AiControlSettings {
  final AiMode mode;
  final List<AiAction> allowedActions;
  final double perTxLimit;
  final double dailyLimit;
  final double perContractLimit;
  final double perRecipientLimit;
  final double minTradeBalance;
  final AiTrustedScope trustedScope;
  final AiPermissionDuration duration;
  final DateTime? permissionsExpiry;
  final AutonomyMandate mandate;

  /// Selected funding source network key (e.g. 'bsc', 'eth').
  /// Empty string means no source selected.
  final String fundingNetwork;

  /// List of active funding/trading source keys (e.g. 'bsc', 'mexc', 'binance', 'gateio', 'bybit').
  final List<String> activeSources;

  const AiControlSettings({
    this.mode = AiMode.guarded,
    this.allowedActions = const [
      AiAction.openWindows,
      AiAction.closeWindows,
      AiAction.revoke,
      AiAction.send,
      AiAction.swap,
      AiAction.approve,
      AiAction.contactPayments,
    ],
    this.perTxLimit = 50.0,
    this.dailyLimit = 500.0,
    this.perContractLimit = 100.0,
    this.perRecipientLimit = 50.0,
    this.minTradeBalance = 10.0,
    this.trustedScope = AiTrustedScope.trustedPlusApproved,
    this.duration = AiPermissionDuration.oneDay,
    this.permissionsExpiry,
    this.mandate = const AutonomyMandate(),
    this.fundingNetwork = '',
    this.activeSources = const ['bsc'],
  });

  /// Human-readable funding source label for the Market card.
  String get fundingSourceLabel {
    if (activeSources.isEmpty) return 'из политики';
    return activeSources.map((s) {
      if (s == 'gateio') return 'GATE.IO';
      return s.toUpperCase();
    }).join(', ');
  }

  bool get isActive =>
      mode != AiMode.manual &&
      (permissionsExpiry == null ||
          DateTime.now().isBefore(permissionsExpiry!));

  AiControlSettings copyWith({
    AiMode? mode,
    List<AiAction>? allowedActions,
    double? perTxLimit,
    double? dailyLimit,
    double? perContractLimit,
    double? perRecipientLimit,
    double? minTradeBalance,
    AiTrustedScope? trustedScope,
    AiPermissionDuration? duration,
    DateTime? permissionsExpiry,
    AutonomyMandate? mandate,
    String? fundingNetwork,
    List<String>? activeSources,
    bool clearExpiry = false,
  }) {
    return AiControlSettings(
      mode: mode ?? this.mode,
      allowedActions: allowedActions ?? this.allowedActions,
      perTxLimit: perTxLimit ?? this.perTxLimit,
      dailyLimit: dailyLimit ?? this.dailyLimit,
      perContractLimit: perContractLimit ?? this.perContractLimit,
      perRecipientLimit: perRecipientLimit ?? this.perRecipientLimit,
      minTradeBalance: minTradeBalance ?? this.minTradeBalance,
      trustedScope: trustedScope ?? this.trustedScope,
      duration: duration ?? this.duration,
      mandate: mandate ?? this.mandate,
      fundingNetwork: fundingNetwork ?? this.fundingNetwork,
      activeSources: activeSources ?? this.activeSources,
      permissionsExpiry:
          clearExpiry ? null : (permissionsExpiry ?? this.permissionsExpiry),
    );
  }

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'allowedActions': allowedActions.map((e) => e.name).toList(),
        'perTxLimit': perTxLimit,
        'dailyLimit': dailyLimit,
        'perContractLimit': perContractLimit,
        'perRecipientLimit': perRecipientLimit,
        'minTradeBalance': minTradeBalance,
        'trustedScope': trustedScope.name,
        'duration': duration.name,
        'permissionsExpiry': permissionsExpiry?.toIso8601String(),
        'mandate': mandate.toJson(),
        'fundingNetwork': fundingNetwork,
        'activeSources': activeSources,
      };

  factory AiControlSettings.fromJson(Map<String, dynamic> json) {
    return AiControlSettings(
      mode: AiMode.values.firstWhere(
        (e) => e.name == json['mode'],
        orElse: () => AiMode.guarded,
      ),
      allowedActions: (json['allowedActions'] as List?)
              ?.map((e) => AiAction.values
                  .firstWhere((a) => a.name == e, orElse: () => AiAction.send))
              .toList() ??
          const [AiAction.send, AiAction.approve, AiAction.revoke],
      perTxLimit: (json['perTxLimit'] ?? 50.0).toDouble(),
      dailyLimit: (json['dailyLimit'] ?? 500.0).toDouble(),
      perContractLimit: (json['perContractLimit'] ?? 100.0).toDouble(),
      perRecipientLimit: (json['perRecipientLimit'] ?? 50.0).toDouble(),
      minTradeBalance: (json['minTradeBalance'] ?? 10.0).toDouble(),
      trustedScope: AiTrustedScope.values.firstWhere(
          (e) => e.name == json['trustedScope'],
          orElse: () => AiTrustedScope.trustedPlusApproved),
      duration: AiPermissionDuration.values.firstWhere(
          (e) => e.name == json['duration'],
          orElse: () => AiPermissionDuration.oneDay),
      mandate: json['mandate'] is Map<String, dynamic>
          ? AutonomyMandate.fromJson(json['mandate'] as Map<String, dynamic>)
          : json['mandate'] is Map
              ? AutonomyMandate.fromJson(
                  (json['mandate'] as Map).cast<String, dynamic>())
              : const AutonomyMandate(),
      permissionsExpiry: json['permissionsExpiry'] != null
          ? DateTime.tryParse(json['permissionsExpiry'])
          : null,
      fundingNetwork: (() {
        final net = json['fundingNetwork'] as String?;
        if (net == 'gate.io') return 'gateio';
        if (net == 'bybit') return 'okx';
        return net ?? '';
      })(),
      activeSources: (json['activeSources'] as List?)
              ?.cast<String>()
              .map((s) {
                final name = s == 'gate.io' ? 'gateio' : s;
                return name == 'bybit' ? 'okx' : name;
              })
              .toList() ??
          (json['fundingNetwork'] != null && (json['fundingNetwork'] as String).isNotEmpty
              ? [(() {
                  final net = json['fundingNetwork'] as String;
                  final mapped = net == 'gate.io' ? 'gateio' : net;
                  return mapped == 'bybit' ? 'okx' : mapped;
                })()]
              : const ['bsc']),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AiControlService
// ─────────────────────────────────────────────────────────────────────────────

class AiControlService extends ChangeNotifier {
  static final AiControlService instance = AiControlService._internal();
  AiControlService._internal();

  final _storage = const FlutterSecureStorage();
  static const _key = 'ai_control_settings';
  static const _modeBackupKey = 'ai_control_mode_backup';
  static const _permModelVersionKey = 'ai_control_perm_model_v';

  AiControlSettings _settings = const AiControlSettings();
  AiControlSettings get settings => _settings;

  void setSettingsForTest(AiControlSettings settings) {
    _settings = settings;
    notifyListeners();
  }

  static const _log = GuardianLogger('AiControl');

  bool _isLoaded = false;
  bool get isLoaded => _isLoaded;

  Future<void> init() async {
    // ── Step 1: Read full settings blob from SecureStorage ──────────────────
    String? secureData;
    try {
      secureData = await _storage.read(key: _key);
    } catch (e) {
      _log.e('SecureStorage read error', e);
    }

    if (secureData == null || secureData.isEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        secureData = prefs.getString(_key);
        if (secureData != null && secureData.isNotEmpty) {
          _log.i('Restored settings from SharedPreferences backup');
        }
      } catch (e) {
        _log.e('Prefs settings backup read error', e);
      }
    }

    if (secureData != null && secureData.isNotEmpty) {
      try {
        _settings = AiControlSettings.fromJson(
          Map<String, dynamic>.from(jsonDecode(secureData) as Map),
        );
      } catch (e) {
        _log.e('Failed to parse AiControlSettings', e);
      }
    }

    // ── Step 2: Apply SharedPreferences mode backup ──────────────────────────
    // If SecureStorage failed (null/empty) and SharedPreferences settings backup also failed,
    // restore mode from the fast backup.
    try {
      final prefs = await SharedPreferences.getInstance();
      final modeBackup = prefs.getString(_modeBackupKey);
      if (modeBackup != null && modeBackup.isNotEmpty) {
        final backedUpMode = AiMode.values.firstWhere(
          (e) => e.name == modeBackup,
          orElse: () => _settings.mode, // keep current if backup unrecognised
        );
        // Only override when SecureStorage was empty/failed — avoids overwriting
        // a fully valid SecureStorage read with a potentially older backup value.
        if (secureData == null || secureData.isEmpty) {
          _settings = _settings.copyWith(mode: backedUpMode);
          _log.i('Restored mode from backup: ${backedUpMode.name}');
        }
      }
    } catch (e) {
      _log.e('Prefs backup read error', e);
    }

    _isLoaded = true;

    // ── Step 3: One-time permission model migration ─────────────────────────
    // v3: Window permissions now respected via allowedActions only.
    // Removes stale legacy presets from pre-v3 model.
    try {
      final prefs = await SharedPreferences.getInstance();
      final currentVersion = prefs.getInt(_permModelVersionKey) ?? 0;
      if (currentVersion < 3) {
        final preset = _defaultActionsFor(_settings.mode);
        _settings = _settings.copyWith(allowedActions: preset);
        await _save();
        await prefs.setInt(_permModelVersionKey, 3);
        _log.i('Migrated permissions to v3 for mode=${_settings.mode.name}');
      }
    } catch (e) {
      _log.e('Permission migration error', e);
    }

    notifyListeners();
  }

  Future<void> _save() async {
    final settingsJson = jsonEncode(_settings.toJson());
    // Write full settings to SecureStorage.
    try {
      await _storage.write(key: _key, value: settingsJson);
    } catch (e) {
      _log.e('SecureStorage write error', e);
    }
    // Always mirror full settings to SharedPreferences backup so the next init() can
    // recover even if SecureStorage fails on the next boot.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, settingsJson);
      await prefs.setString(_modeBackupKey, _settings.mode.name);
    } catch (e) {
      _log.e('Prefs backup write error', e);
    }
    notifyListeners();
  }

  Future<void> updateMode(AiMode mode) async {
    // Auto-preset allowed actions whenever mode changes.
    final presetActions = _defaultActionsFor(mode);
    _settings = _settings.copyWith(mode: mode, allowedActions: presetActions);
    await _save();
  }

  /// Default allowed actions for each mode (preset on mode switch).
  static List<AiAction> _defaultActionsFor(AiMode mode) {
    switch (mode) {
      case AiMode.manual:
        // Read-only: no window management, no execution
        return const [];
      case AiMode.guarded:
        // UI control + prepare/confirm execution, user must confirm.
        // AiAction.approve = ERC-20 token approval preparation (not auto-signing).
        return const [
          AiAction.openWindows,
          AiAction.closeWindows,
          AiAction.revoke,
          AiAction.send,
          AiAction.swap,
          AiAction.approve,
          AiAction.contactPayments,
        ];
      case AiMode.fullAutonomy:
        // Everything — still bounded by policy/EPK
        return AiAction.values;
    }
  }

  /// Maximum actions allowed by each mode (ceiling).
  /// User can toggle OFF within ceiling, but never ON above it.
  static List<AiAction> _ceilingFor(AiMode mode) {
    switch (mode) {
      case AiMode.manual:
        return const []; // Nothing allowed
      case AiMode.guarded:
        // Everything except scheduled & policyUpdate.
        // approve = ERC-20 token approval preparation, NOT autonomous signing.
        return const [
          AiAction.openWindows,
          AiAction.closeWindows,
          AiAction.revoke,
          AiAction.send,
          AiAction.swap,
          AiAction.approve,
          AiAction.contactPayments,
        ];
      case AiMode.fullAutonomy:
        return AiAction.values; // No ceiling
    }
  }

  Future<void> toggleAction(AiAction action, bool allowed) async {
    // Enforce mode ceiling: cannot enable above what the mode allows
    if (allowed) {
      final ceiling = _ceilingFor(_settings.mode);
      if (!ceiling.contains(action)) return;
    }
    final actions = List<AiAction>.from(_settings.allowedActions);
    if (allowed && !actions.contains(action)) {
      actions.add(action);
    } else if (!allowed) {
      actions.remove(action);
    }
    _settings = _settings.copyWith(allowedActions: actions);
    await _save();
  }

  Future<void> updateLimits({
    double? perTx,
    double? daily,
    double? perContract,
    double? perRecipient,
  }) async {
    _settings = _settings.copyWith(
      perTxLimit: perTx,
      dailyLimit: daily,
      perContractLimit: perContract,
      perRecipientLimit: perRecipient,
    );
    await _save();
    _syncEpkLimits();
  }

  Future<void> updateMinTradeBalance(double balance) async {
    _settings = _settings.copyWith(minTradeBalance: balance);
    await _save();
  }

  Future<void> updateScope(AiTrustedScope scope) async {
    _settings = _settings.copyWith(trustedScope: scope);
    await _save();
  }

  Future<void> updateMandate(AutonomyMandate mandate) async {
    _settings = _settings.copyWith(mandate: mandate);
    await _save();
  }

  /// Update the selected funding source network and optionally clamp
  /// dailyLimit to the available USDT balance.
  Future<void> updateFundingSource({
    required String network,
    double? clampDailyLimitTo,
  }) async {
    var newDailyLimit = _settings.dailyLimit;
    if (clampDailyLimitTo != null && newDailyLimit > clampDailyLimitTo) {
      newDailyLimit = clampDailyLimitTo;
    }
    _settings = _settings.copyWith(
      fundingNetwork: network,
      dailyLimit: newDailyLimit,
    );
    await _save();
    _syncEpkLimits();
  }

  /// Update the active funding sources list.
  Future<void> updateActiveSources(List<String> sources) async {
    _settings = _settings.copyWith(
      activeSources: sources,
      fundingNetwork: sources.isNotEmpty ? sources.first : '',
    );
    await _save();
    _syncEpkLimits();
  }

  Future<void> updateDuration(AiPermissionDuration duration) async {
    DateTime? expiry;
    final now = DateTime.now();
    switch (duration) {
      case AiPermissionDuration.oneHour:
        expiry = now.add(const Duration(hours: 1));
        break;
      case AiPermissionDuration.oneDay:
        expiry = now.add(const Duration(days: 1));
        break;
      case AiPermissionDuration.oneWeek:
        expiry = now.add(const Duration(days: 7));
        break;
      case AiPermissionDuration.untilRevoked:
        expiry = null;
        break;
    }
    _settings = _settings.copyWith(
      duration: duration,
      permissionsExpiry: expiry,
      clearExpiry: expiry == null,
    );
    await _save();
  }

  Future<void> emergencyStop() async {
    _settings = _settings.copyWith(
      mode: AiMode.manual,
      allowedActions: [],
      permissionsExpiry: null,
      clearExpiry: true,
    );
    await _save();
    _syncEpkLimits();

    // ── Cascade: stop all autonomous subsystems ─────────────────────────────
    try {
      market_auto.AutomationEngine.instance.stop();
      MonitoringService.instance.stop();
      _log.i('Emergency stop activated — AI manual, automation stopped, '
          'background monitoring cancelled');
    } catch (e) {
      _log.e('Emergency stop cascade error', e);
    }
  }

  /// Pushes AI limits into EPKPolicyManager so on-chain enforcement
  /// always matches the values visible in AI Center and EPK Center.
  void _syncEpkLimits() {
    EPKPolicyManager.instance.updateLimits(
      perTx: _settings.perTxLimit,
      daily: _settings.dailyLimit,
    );
  }
}
