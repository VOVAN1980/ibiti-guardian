import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WalletSettingsState {
  final bool hideZeroBalance;
  final bool spamFilter;
  final bool requireBioForSend;
  final String currency;
  final bool balanceVisible;
  final String gasTier;
  final String defaultNetwork;

  const WalletSettingsState({
    required this.hideZeroBalance,
    required this.spamFilter,
    required this.requireBioForSend,
    required this.currency,
    required this.balanceVisible,
    required this.gasTier,
    required this.defaultNetwork,
  });

  factory WalletSettingsState.defaults() => const WalletSettingsState(
        hideZeroBalance: true,
        spamFilter: true,
        requireBioForSend: true,
        currency: 'USD',
        balanceVisible: true,
        gasTier: 'Standard',
        defaultNetwork: 'BNB Chain',
      );

  WalletSettingsState copyWith({
    bool? hideZeroBalance,
    bool? spamFilter,
    bool? requireBioForSend,
    String? currency,
    bool? balanceVisible,
    String? gasTier,
    String? defaultNetwork,
  }) {
    return WalletSettingsState(
      hideZeroBalance: hideZeroBalance ?? this.hideZeroBalance,
      spamFilter: spamFilter ?? this.spamFilter,
      requireBioForSend: requireBioForSend ?? this.requireBioForSend,
      currency: currency ?? this.currency,
      balanceVisible: balanceVisible ?? this.balanceVisible,
      gasTier: gasTier ?? this.gasTier,
      defaultNetwork: defaultNetwork ?? this.defaultNetwork,
    );
  }

  Map<String, dynamic> toJson() => {
        'hideZeroBalance': hideZeroBalance,
        'spamFilter': spamFilter,
        'requireBioForSend': requireBioForSend,
        'currency': currency,
        'balanceVisible': balanceVisible,
        'gasTier': gasTier,
        'defaultNetwork': defaultNetwork,
      };

  factory WalletSettingsState.fromJson(Map<String, dynamic> json) {
    final defaults = WalletSettingsState.defaults();
    return WalletSettingsState(
      hideZeroBalance:
          json['hideZeroBalance'] as bool? ?? defaults.hideZeroBalance,
      spamFilter: json['spamFilter'] as bool? ?? defaults.spamFilter,
      requireBioForSend:
          json['requireBioForSend'] as bool? ?? defaults.requireBioForSend,
      currency: json['currency'] as String? ?? defaults.currency,
      balanceVisible:
          json['balanceVisible'] as bool? ?? defaults.balanceVisible,
      gasTier: json['gasTier'] as String? ?? defaults.gasTier,
      defaultNetwork:
          json['defaultNetwork'] as String? ?? defaults.defaultNetwork,
    );
  }
}

class WalletSettingsService extends ChangeNotifier {
  WalletSettingsService._internal() {
    _load();
  }

  static final WalletSettingsService instance =
      WalletSettingsService._internal();

  static const _log = GuardianLogger('WalletSettings');

  static const _prefsKey = 'wallet_settings_v1';

  WalletSettingsState _state = WalletSettingsState.defaults();
  bool _isLoaded = false;

  WalletSettingsState get state => _state;
  bool get isLoaded => _isLoaded;

  bool get hideZeroBalance => _state.hideZeroBalance;
  bool get spamFilter => _state.spamFilter;
  bool get requireBioForSend => _state.requireBioForSend;
  String get currency => _state.currency;
  bool get balanceVisible => _state.balanceVisible;
  String get gasTier => _state.gasTier;
  String get defaultNetwork => _state.defaultNetwork;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        _state = WalletSettingsState.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        );
      }
    } catch (e) {
      _log.e('load error', e);
    } finally {
      _isLoaded = true;
      notifyListeners();
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(_state.toJson()));
    } catch (e) {
      _log.e('save error', e);
    }
  }

  Future<void> update({
    bool? hideZeroBalance,
    bool? spamFilter,
    bool? requireBioForSend,
    String? currency,
    bool? balanceVisible,
    String? gasTier,
    String? defaultNetwork,
  }) async {
    _state = _state.copyWith(
      hideZeroBalance: hideZeroBalance,
      spamFilter: spamFilter,
      requireBioForSend: requireBioForSend,
      currency: currency,
      balanceVisible: balanceVisible,
      gasTier: gasTier,
      defaultNetwork: defaultNetwork,
    );
    notifyListeners();
    await _save();
  }
}
