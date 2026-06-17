import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Rocket Alert Settings ──────────────────────────────────────────────────────
//
// Configurable settings for rocket (sudden price spike) notifications.
//
// These control WHEN the user is notified about rapid price movements.
// NEVER auto-trades. ALWAYS notifyOnly.
// ─────────────────────────────────────────────────────────────────────────────────

/// Scope of which assets to monitor for rockets.
enum RocketAlertScope {
  /// Only watchlisted/favorited tokens.
  favorites,

  /// All tokens in the live exchange feed.
  allMarket,
}

class RocketAlertSettings extends ChangeNotifier {
  RocketAlertSettings._();
  static final RocketAlertSettings instance = RocketAlertSettings._();

  static const _prefix = 'rocket_alert_';

  // ── State ───────────────────────────────────────────────────────────────

  bool _enabled = false;

  /// Minimum price change (%) to trigger a rocket alert.
  double _thresholdPct = 10.0;

  /// Time window in minutes — price must rise [thresholdPct] within this window.
  int _windowMinutes = 5;

  /// Which assets to watch.
  RocketAlertScope _scope = RocketAlertScope.favorites;

  /// Minimum minutes between two rocket alerts for the same symbol.
  int _cooldownMinutes = 15;

  // ── Getters ─────────────────────────────────────────────────────────────

  bool get enabled => _enabled;
  double get thresholdPct => _thresholdPct;
  int get windowMinutes => _windowMinutes;
  RocketAlertScope get scope => _scope;
  int get cooldownMinutes => _cooldownMinutes;

  // ── Setters (with persistence) ──────────────────────────────────────────

  void setEnabled(bool v) {
    if (_enabled == v) return;
    _enabled = v;
    _save();
    notifyListeners();
  }

  void setThresholdPct(double v) {
    if (v <= 0 || v > 100) return;
    _thresholdPct = v;
    _save();
    notifyListeners();
  }

  void setWindowMinutes(int v) {
    if (v <= 0) return;
    _windowMinutes = v;
    _save();
    notifyListeners();
  }

  void setScope(RocketAlertScope v) {
    _scope = v;
    _save();
    notifyListeners();
  }

  void setCooldownMinutes(int v) {
    if (v < 1) return;
    _cooldownMinutes = v;
    _save();
    notifyListeners();
  }

  // ── Persistence ────────────────────────────────────────────────────────

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool('${_prefix}enabled') ?? false;
    _thresholdPct = prefs.getDouble('${_prefix}threshold_pct') ?? 10.0;
    _windowMinutes = prefs.getInt('${_prefix}window_minutes') ?? 5;
    _cooldownMinutes = prefs.getInt('${_prefix}cooldown_minutes') ?? 15;
    final scopeStr = prefs.getString('${_prefix}scope') ?? 'favorites';
    _scope = scopeStr == 'allMarket'
        ? RocketAlertScope.allMarket
        : RocketAlertScope.favorites;
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('${_prefix}enabled', _enabled);
    await prefs.setDouble('${_prefix}threshold_pct', _thresholdPct);
    await prefs.setInt('${_prefix}window_minutes', _windowMinutes);
    await prefs.setInt('${_prefix}cooldown_minutes', _cooldownMinutes);
    await prefs.setString('${_prefix}scope', _scope.name);
  }

  /// Human-readable summary for UI.
  String get summary {
    if (!_enabled) return 'Off';
    return '≥${_thresholdPct.toStringAsFixed(0)}% in ${_windowMinutes}m '
        '(${_scope == RocketAlertScope.favorites ? "★ Favorites" : "All Market"})';
  }
}
