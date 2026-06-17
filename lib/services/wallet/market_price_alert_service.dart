import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Price Alert Model ──────────────────────────────────────────────────────────

class MarketPriceAlert {
  final String symbol; // Primary key: 'BTC', 'ETH', etc.
  final String assetId; // CoinGecko ID ('' for exchange-only tokens)
  final double targetPrice;
  final bool isAbove; // true = alert when price >= target
  final DateTime createdAt;

  const MarketPriceAlert({
    required this.symbol,
    required this.assetId,
    required this.targetPrice,
    required this.isAbove,
    required this.createdAt,
  });

  factory MarketPriceAlert.fromJson(Map<String, dynamic> json) {
    return MarketPriceAlert(
      symbol: (json['symbol'] as String? ?? '').toUpperCase(),
      assetId: json['assetId'] as String? ?? '',
      targetPrice: (json['targetPrice'] as num).toDouble(),
      isAbove: json['isAbove'] as bool,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'assetId': assetId,
        'targetPrice': targetPrice,
        'isAbove': isAbove,
        'createdAt': createdAt.toIso8601String(),
      };

  /// Unique key for dedup: one alert per direction per symbol.
  String get key => '${symbol}_${isAbove ? 'above' : 'below'}';
}

// ─── Price Alert Service ────────────────────────────────────────────────────────
//
// Stores and manages price alerts, indexed by SYMBOL (not CoinGecko ID).
// This ensures exchange-only tokens work correctly.
//
// Persistence: SharedPreferences (JSON map keyed by symbol).
// ─────────────────────────────────────────────────────────────────────────────────

class MarketPriceAlertService extends ChangeNotifier {
  MarketPriceAlertService._internal() {
    _load();
  }

  static final MarketPriceAlertService instance =
      MarketPriceAlertService._internal();

  static const _log = GuardianLogger('PriceAlert');

  static const _storageKey = 'wallet_market_price_alerts_v2';
  final Map<String, List<MarketPriceAlert>> _alertsBySymbol = {};

  // ── Queries ─────────────────────────────────────────────────────────────────

  /// Get alerts for a specific symbol (e.g. 'BTC').
  List<MarketPriceAlert> alertsFor(String symbol) =>
      List.unmodifiable(_alertsBySymbol[symbol.toUpperCase()] ?? const []);

  /// Get alerts by CoinGecko ID (backward compat, searches all buckets).
  List<MarketPriceAlert> alertsForId(String assetId) {
    if (assetId.isEmpty) return const [];
    final result = <MarketPriceAlert>[];
    for (final bucket in _alertsBySymbol.values) {
      result.addAll(bucket.where((a) => a.assetId == assetId));
    }
    return result;
  }

  /// Check if a symbol has any active alerts.
  bool hasAlerts(String symbol) =>
      (_alertsBySymbol[symbol.toUpperCase()] ?? const []).isNotEmpty;

  /// All active alerts across all symbols (for the monitor).
  Map<String, List<MarketPriceAlert>> get allAlerts =>
      Map.unmodifiable(_alertsBySymbol);

  /// Total alert count.
  int get totalAlertCount =>
      _alertsBySymbol.values.fold(0, (sum, list) => sum + list.length);

  // ── Mutations ───────────────────────────────────────────────────────────────

  /// Add or update an alert.
  /// One alert per direction per symbol: setting "BTC above $80k" replaces
  /// any previous "BTC above" alert.
  Future<void> upsertAlert(MarketPriceAlert alert) async {
    final sym = alert.symbol.toUpperCase();
    final bucket = <MarketPriceAlert>[
      ...(_alertsBySymbol[sym] ?? const <MarketPriceAlert>[]),
    ];
    bucket.removeWhere((entry) => entry.isAbove == alert.isAbove);
    bucket.add(alert);
    bucket.sort((a, b) => a.targetPrice.compareTo(b.targetPrice));
    _alertsBySymbol[sym] = bucket;
    notifyListeners();
    await _save();
    _log.i('Alert set: ${alert.symbol} ${alert.isAbove ? "above" : "below"} '
        '\$${alert.targetPrice}');
  }

  /// Remove an alert by symbol and direction.
  Future<void> removeAlert(String symbol, bool isAbove) async {
    final sym = symbol.toUpperCase();
    final bucket = <MarketPriceAlert>[
      ...(_alertsBySymbol[sym] ?? const <MarketPriceAlert>[]),
    ];
    bucket.removeWhere((entry) => entry.isAbove == isAbove);
    if (bucket.isEmpty) {
      _alertsBySymbol.remove(sym);
    } else {
      _alertsBySymbol[sym] = bucket;
    }
    notifyListeners();
    await _save();
  }

  /// Remove all alerts for a symbol.
  Future<void> removeAllForSymbol(String symbol) async {
    _alertsBySymbol.remove(symbol.toUpperCase());
    notifyListeners();
    await _save();
  }

  // ── Persistence ─────────────────────────────────────────────────────────────

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw != null) {
        final decoded = (jsonDecode(raw) as Map<String, dynamic>).map(
          (key, value) => MapEntry(
            key.toUpperCase(),
            (value as List)
                .map((entry) =>
                    MarketPriceAlert.fromJson(Map<String, dynamic>.from(entry)))
                .toList(),
          ),
        );
        _alertsBySymbol
          ..clear()
          ..addAll(decoded);
      }
      notifyListeners();
    } catch (e) {
      _log.e('load error', e);
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = _alertsBySymbol.map(
        (key, value) => MapEntry(
          key,
          value.map((alert) => alert.toJson()).toList(),
        ),
      );
      await prefs.setString(_storageKey, jsonEncode(payload));
    } catch (e) {
      _log.e('save error', e);
    }
  }
}
