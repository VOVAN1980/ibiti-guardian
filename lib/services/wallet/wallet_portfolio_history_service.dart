import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/models/portfolio_summary.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PortfolioHistoryPoint {
  final DateTime timestamp;
  final double totalUsd;

  const PortfolioHistoryPoint({
    required this.timestamp,
    required this.totalUsd,
  });

  factory PortfolioHistoryPoint.fromJson(Map<String, dynamic> json) {
    return PortfolioHistoryPoint(
      timestamp: DateTime.parse(json['timestamp'] as String),
      totalUsd: (json['totalUsd'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'totalUsd': totalUsd,
      };
}

class WalletPortfolioHistoryService extends ChangeNotifier {
  WalletPortfolioHistoryService._internal() {
    _load();
  }

  static final WalletPortfolioHistoryService instance =
      WalletPortfolioHistoryService._internal();

  static const _log = GuardianLogger('PortfolioHistory');

  static const _storageKey = 'wallet_portfolio_history_v1';
  final Map<String, List<PortfolioHistoryPoint>> _history = {};

  bool _isReady = false;
  bool get isReady => _isReady;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        _history
          ..clear()
          ..addEntries(decoded.entries.map((entry) {
            final points = (entry.value as List)
                .map(
                  (item) => PortfolioHistoryPoint.fromJson(
                    Map<String, dynamic>.from(item as Map),
                  ),
                )
                .toList()
              ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
            return MapEntry(entry.key, points);
          }));
      }
    } catch (e) {
      _log.e('load error', e);
    } finally {
      _isReady = true;
      notifyListeners();
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = _history.map(
        (key, value) => MapEntry(
          key,
          value.map((point) => point.toJson()).toList(),
        ),
      );
      await prefs.setString(_storageKey, jsonEncode(encoded));
    } catch (e) {
      _log.e('save error', e);
    }
  }

  String _key(String address, String chainKey) =>
      '${address.toLowerCase()}::$chainKey';

  Future<void> recordSummary(PortfolioSummary summary) async {
    if (summary.address.isEmpty || summary.chainKey.isEmpty) return;
    final key = _key(summary.address, summary.chainKey);
    final list = List<PortfolioHistoryPoint>.from(_history[key] ?? const []);
    final now = DateTime.now();
    final point = PortfolioHistoryPoint(
      timestamp: now,
      totalUsd: summary.totalBalanceUsd,
    );

    if (list.isNotEmpty) {
      final last = list.last;
      final recent =
          now.difference(last.timestamp) < const Duration(minutes: 10);
      final sameValue = (last.totalUsd - point.totalUsd).abs() < 0.01;
      if (recent && sameValue) {
        return;
      }
    }

    list.add(point);
    final cutoff = now.subtract(const Duration(days: 90));
    list.removeWhere((entry) => entry.timestamp.isBefore(cutoff));
    _history[key] = list;
    notifyListeners();
    await _save();
  }

  List<PortfolioHistoryPoint> pointsForRange(
    String address,
    String chainKey,
    Duration range,
  ) {
    final key = _key(address, chainKey);
    final list = _history[key] ?? const [];
    final cutoff = DateTime.now().subtract(range);
    return list.where((point) => !point.timestamp.isBefore(cutoff)).toList();
  }
}
