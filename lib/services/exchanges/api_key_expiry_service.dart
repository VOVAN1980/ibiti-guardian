import 'dart:ui' show PlatformDispatcher;

import 'package:ibiti_guardian/services/alerts/notification_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_account_store.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Reminds the user to renew exchange API keys before the exchange switches
/// them off.
///
/// MEXC and Gate.io disable keys that aren't bound to an IP address after
/// 90 days. MEXC offers "Extend" (another 90 days) in a key's last 5 days,
/// under API management → My API keys; Gate.io has no extension, so a new
/// key is needed. The app's keys can't be IP-bound (the phone's address
/// keeps changing). The exchange doesn't tell us when a key was created, so
/// the clock starts when the key is connected in the app, or when the user
/// says they renewed it.
///
/// OKX and Binance have no fixed lifetime; they delete IP-unbound keys
/// after a stretch of inactivity (OKX: 14 days), which using the exchange
/// through the app avoids — so they are not tracked here.
class ApiKeyExpiryService {
  ApiKeyExpiryService._();
  static final ApiKeyExpiryService instance = ApiKeyExpiryService._();

  static const _log = GuardianLogger('ApiKeyExpiry');

  static const _lifetimes = {
    'mexc': Duration(days: 90),
    'gateio': Duration(days: 90),
  };
  static const _names = {'mexc': 'MEXC', 'gateio': 'Gate.io'};

  /// Exchanges whose keys can be extended instead of replaced.
  static const _extendable = {'mexc'};

  /// Notification ids: 4 days before (inside MEXC's renewal window) and
  /// 1 day before.
  static const _notifyIds = {
    'mexc': (7201, 7202),
    'gateio': (7211, 7212),
  };

  static const _prefsPrefix = 'cex_key_started_at_';

  final Map<String, DateTime> _startedAt = {};
  bool _loaded = false;

  bool tracks(String exchangeId) => _lifetimes.containsKey(exchangeId);

  bool canExtend(String exchangeId) => _extendable.contains(exchangeId);

  /// Estimated expiry, or null if the exchange doesn't expire keys or no
  /// start date is known yet.
  DateTime? expiresAt(String exchangeId) {
    final start = _startedAt[exchangeId];
    final lifetime = _lifetimes[exchangeId];
    if (start == null || lifetime == null) return null;
    return start.add(lifetime);
  }

  /// Whole days left (0 or less: probably expired), or null if unknown.
  int? daysLeft(String exchangeId) {
    final expiry = expiresAt(exchangeId);
    if (expiry == null) return null;
    return (expiry.difference(DateTime.now()).inHours / 24).ceil();
  }

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    for (final id in _lifetimes.keys) {
      final raw = prefs.getString('$_prefsPrefix$id');
      final at = raw == null ? null : DateTime.tryParse(raw);
      if (at != null) _startedAt[id] = at;
    }
    _loaded = true;
  }

  /// A key was connected, or the user renewed it on the exchange: the
  /// lifetime starts over from now.
  Future<void> markStarted(String exchangeId) async {
    if (!tracks(exchangeId)) return;
    await load();
    final now = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefsPrefix$exchangeId', now.toIso8601String());
    _startedAt[exchangeId] = now;
    _log.i('$exchangeId key clock started, expires ~${expiresAt(exchangeId)}');
    await _schedule(exchangeId);
  }

  /// The key was removed from the app.
  Future<void> forget(String exchangeId) async {
    if (!tracks(exchangeId)) return;
    await load();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefsPrefix$exchangeId');
    _startedAt.remove(exchangeId);
    final ids = _notifyIds[exchangeId]!;
    await NotificationService.instance.cancelReminder(ids.$1);
    await NotificationService.instance.cancelReminder(ids.$2);
  }

  /// At launch: (re)schedules reminders, so clearing notifications elsewhere
  /// doesn't lose them. A key connected before this existed starts its
  /// clock today.
  Future<void> refreshReminders() async {
    await load();
    for (final id in _lifetimes.keys) {
      final connected = await ExchangeAccountStore.instance.isConnected(id);
      if (!connected) {
        if (_startedAt.containsKey(id)) await forget(id);
      } else if (!_startedAt.containsKey(id)) {
        await markStarted(id);
      } else {
        await _schedule(id);
      }
    }
  }

  Future<void> _schedule(String exchangeId) async {
    final expiry = expiresAt(exchangeId);
    final ids = _notifyIds[exchangeId];
    if (expiry == null || ids == null) return;
    final name = _names[exchangeId] ?? exchangeId;
    final isRu = _isRu();
    final extend = canExtend(exchangeId);

    for (final (id, daysBefore) in [(ids.$1, 4), (ids.$2, 1)]) {
      final day = expiry.subtract(Duration(days: daysBefore));
      final when = isRu
          ? (daysBefore == 1 ? '1 день' : '$daysBefore дня')
          : '$daysBefore day${daysBefore == 1 ? '' : 's'}';
      final title = isRu
          ? (extend ? 'Продлите API-ключ $name' : 'Замените API-ключ $name')
          : (extend
              ? 'Renew your $name API key'
              : 'Replace your $name API key');
      final body = extend
          ? (isRu
              ? 'Ключ $name отключится примерно через $when. '
                  'Продлите его на $name: «Управление API» → «Мои ключи API» → '
                  '«Продлить». Затем в приложении: «Политика» → $name Spot → '
                  '«Уже продлил».'
              : 'The $name key switches off in about $when. Extend it on '
                  '$name: API Management → My API Keys → Extend. Then in the '
                  'app: Policy → $name Spot → "Already renewed".')
          : (isRu
              ? 'Ключ $name отключится примерно через $when, продлить его '
                  'нельзя. Создайте на $name новый ключ (чтение и спотовая '
                  'торговля, без вывода) и подключите: «Политика» → $name Spot.'
              : 'The $name key switches off in about $when and cannot be '
                  'extended. Create a new key on $name (read and spot trading, '
                  'no withdrawals) and connect it: Policy → $name Spot.');
      await NotificationService.instance.scheduleReminder(
        id: id,
        when: DateTime(day.year, day.month, day.day, 10),
        title: title,
        body: body,
      );
    }
  }

  bool _isRu() {
    final code = SettingsService.instance.settings.languageCode.trim();
    final lang =
        code.isNotEmpty ? code : PlatformDispatcher.instance.locale.languageCode;
    return lang == 'ru' || lang == 'uk';
  }
}
