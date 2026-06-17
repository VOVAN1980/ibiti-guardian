import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CustomTokenEntry {
  final String name;
  final String symbol;
  final String address;
  final int decimals;
  final int chainId;
  final String? logoUrl;

  const CustomTokenEntry({
    required this.name,
    required this.symbol,
    required this.address,
    required this.decimals,
    required this.chainId,
    this.logoUrl,
  });

  factory CustomTokenEntry.fromJson(Map<String, dynamic> json) {
    return CustomTokenEntry(
      name: json['name'] as String,
      symbol: json['symbol'] as String,
      address: json['address'] as String,
      decimals: json['decimals'] as int,
      chainId: json['chainId'] as int,
      logoUrl: json['logoUrl'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'symbol': symbol,
        'address': address,
        'decimals': decimals,
        'chainId': chainId,
        'logoUrl': logoUrl,
      };

  WalletAsset toWalletAsset() {
    return WalletAsset(
      name: name,
      symbol: symbol,
      address: address,
      balance: 0,
      logoUrl: logoUrl,
      priceUsd: 0,
      valueUsd: 0,
      decimals: decimals,
      chainId: chainId,
    );
  }
}

class TokenManagerService extends ChangeNotifier {
  TokenManagerService._internal() {
    _load();
  }

  static final TokenManagerService instance = TokenManagerService._internal();

  static const _log = GuardianLogger('TokenManager');

  static const _hiddenKey = 'wallet_hidden_tokens_v1';
  static const _pinnedKey = 'wallet_pinned_tokens_v1';
  static const _customKey = 'wallet_custom_tokens_v1';

  final Set<String> _hidden = <String>{};
  final Set<String> _pinned = <String>{};
  final List<CustomTokenEntry> _customTokens = <CustomTokenEntry>[];

  Set<String> get hidden => Set.unmodifiable(_hidden);
  Set<String> get pinned => Set.unmodifiable(_pinned);
  List<CustomTokenEntry> get customTokens => List.unmodifiable(_customTokens);

  bool isHidden(String tokenId) => _hidden.contains(tokenId.toLowerCase());
  bool isPinned(String tokenId) => _pinned.contains(tokenId.toLowerCase());

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hiddenRaw = prefs.getString(_hiddenKey);
      final pinnedRaw = prefs.getString(_pinnedKey);
      final customRaw = prefs.getString(_customKey);

      if (hiddenRaw != null) {
        final values = (jsonDecode(hiddenRaw) as List).cast<String>();
        _hidden
          ..clear()
          ..addAll(values.map((e) => e.toLowerCase()));
      }
      if (pinnedRaw != null) {
        final values = (jsonDecode(pinnedRaw) as List).cast<String>();
        _pinned
          ..clear()
          ..addAll(values.map((e) => e.toLowerCase()));
      }
      if (customRaw != null) {
        final values = (jsonDecode(customRaw) as List)
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList();
        _customTokens
          ..clear()
          ..addAll(values.map(CustomTokenEntry.fromJson));
      }
      notifyListeners();
    } catch (e) {
      _log.e('load error', e);
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_hiddenKey, jsonEncode(_hidden.toList()));
      await prefs.setString(_pinnedKey, jsonEncode(_pinned.toList()));
      await prefs.setString(
        _customKey,
        jsonEncode(_customTokens.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      _log.e('save error', e);
    }
  }

  Future<void> toggleHidden(String tokenId) async {
    final normalized = tokenId.toLowerCase();
    if (_hidden.contains(normalized)) {
      _hidden.remove(normalized);
    } else {
      _hidden.add(normalized);
      _pinned.remove(normalized);
    }
    notifyListeners();
    await _save();
  }

  Future<void> togglePinned(String tokenId) async {
    final normalized = tokenId.toLowerCase();
    if (_pinned.contains(normalized)) {
      _pinned.remove(normalized);
    } else {
      _pinned.add(normalized);
      _hidden.remove(normalized);
    }
    notifyListeners();
    await _save();
  }

  Future<void> addCustomToken(CustomTokenEntry entry) async {
    _customTokens.removeWhere(
      (token) =>
          token.address.toLowerCase() == entry.address.toLowerCase() &&
          token.chainId == entry.chainId,
    );
    _customTokens.insert(0, entry);
    notifyListeners();
    await _save();
  }

  Future<void> removeCustomToken(String address, int chainId) async {
    _customTokens.removeWhere(
      (token) =>
          token.address.toLowerCase() == address.toLowerCase() &&
          token.chainId == chainId,
    );
    notifyListeners();
    await _save();
  }

  List<WalletAsset> mergeCustomTokens(List<WalletAsset> assets, int chainId) {
    final merged = [...assets];
    for (final custom
        in _customTokens.where((token) => token.chainId == chainId)) {
      final exists = merged.any(
        (asset) => asset.address.toLowerCase() == custom.address.toLowerCase(),
      );
      if (!exists) {
        merged.add(custom.toWalletAsset());
      }
    }
    return merged;
  }
}
