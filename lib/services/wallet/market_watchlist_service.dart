import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MarketWatchlistService extends ChangeNotifier {
  MarketWatchlistService._internal() {
    _load();
  }

  static final MarketWatchlistService instance =
      MarketWatchlistService._internal();

  static const _log = GuardianLogger('MarketWatchlist');

  static const _storageKey = 'wallet_market_watchlist_v1';
  final Set<String> _watchlist = <String>{};

  Set<String> get ids => Set.unmodifiable(_watchlist);

  bool contains(String assetId) => _watchlist.contains(assetId);

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw != null) {
        final values = (jsonDecode(raw) as List).cast<String>();
        _watchlist
          ..clear()
          ..addAll(values);
      }
      notifyListeners();
    } catch (e) {
      _log.e('load error', e);
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(_watchlist.toList()));
    } catch (e) {
      _log.e('save error', e);
    }
  }

  Future<void> toggle(String assetId) async {
    if (_watchlist.contains(assetId)) {
      _watchlist.remove(assetId);
    } else {
      _watchlist.add(assetId);
    }
    notifyListeners();
    await _save();
  }
}
