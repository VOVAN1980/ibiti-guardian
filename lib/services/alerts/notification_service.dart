import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;
import 'package:ibiti_guardian/main.dart'; // Import navigatorKey
import 'package:ibiti_guardian/app/guardian_app_shell.dart';
import 'package:ibiti_guardian/screens/market_command/market_token_detail_screen.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/services/localization_service.dart';

class NotificationService {
  static final NotificationService instance = NotificationService._();
  NotificationService._();

  static const _log = GuardianLogger('Notification');

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings initializationSettingsDarwin =
        DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    const InitializationSettings initializationSettings =
        InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsDarwin,
    );

    tz.initializeTimeZones();

    await _notifications.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: _onTap,
    );

    // Remove the channels of older builds. They played alarm and siren sounds
    // that are no longer in the app; alerts now just vibrate.
    final android = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      for (final old in _retiredChannels) {
        try {
          await android.deleteNotificationChannel(channelId: old);
        } catch (e) {
          // Channel may not exist — expected.
          _log.d('Channel delete $old: $e');
        }
      }
    }

    // Request notification permission (required on Android 13+ / SDK 33).
    // On older Android, notifications are allowed by default.
    final androidImpl = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl != null) {
      final granted = await androidImpl.requestNotificationsPermission();
      _log.i(
          'Notification permission: ${granted == true ? "granted" : "denied/skipped"}');
    }

    // Check for cold-start notification
    final details = await _notifications.getNotificationAppLaunchDetails();
    if (details != null && details.didNotificationLaunchApp) {
      final payload = details.notificationResponse?.payload;
      if (payload != null && payload.isNotEmpty) {
        try {
          final data = json.decode(payload);
          // Wait a bit for navigationKey to be ready
          Future.delayed(
              const Duration(seconds: 1), () => _handleRouting(data));
        } catch (e) {
          _log.e('Cold start payload error', e);
        }
      }
    }
  }

  Future<bool> isPermissionGranted() async {
    final status = await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.areNotificationsEnabled();
    return status ?? false;
  }

  void _onTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;

    try {
      final Map<String, dynamic> data = json.decode(payload);
      _handleRouting(data);
    } catch (e) {
      _log.e('Failed to parse payload', e);
    }
  }

  void _handleRouting(Map<String, dynamic> data) {
    final type = data['type'];
    final state = navigatorKey.currentState;
    if (state == null) {
      _log.w('Navigator state is null, cannot route');
      return;
    }

    switch (type) {
      case 'price_alert':
        // Deep-link directly to the token's detail screen.
        final symbol = data['symbol'] as String?;
        if (symbol != null && symbol.isNotEmpty) {
          _log.d('Price alert tap — routing to detail: $symbol');
          _goToTokenDetail(state, symbol);
        } else {
          _goHome(state);
        }
        break;
      case 'security_alert':
        _log.d('Security alert tap — routing to Guardian Security tab');
        _goHome(state);
        break;
      case 'subscription_expiry':
        _log.d('Subscription alert tap — routing home');
        _goHome(state);
        break;
      default:
        _goHome(state);
    }
  }

  void _goHome(NavigatorState state) {
    state.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const GuardianAppShell()),
      (route) => false,
    );
  }

  /// Deep-link to token detail from a price alert notification tap.
  /// Resolves the asset from the market cache by symbol.
  void _goToTokenDetail(NavigatorState state, String symbol) {
    // Find the asset in the cached market list
    final markets = MarketDataService.instance.cachedMarkets;
    MarketAsset? asset;
    try {
      asset = markets.firstWhere(
        (a) => a.symbol.toUpperCase() == symbol.toUpperCase(),
      );
    } catch (_) {
      asset = null;
    }

    if (asset == null) {
      // Asset not in cache — go home, user can search manually
      _log.w('Price alert tap: $symbol not in cache, going home');
      _goHome(state);
      return;
    }

    // Navigate: clear stack to home, then push detail on top
    state.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const GuardianAppShell()),
      (route) => false,
    );
    // Small delay to let shell settle before pushing detail
    Future.delayed(const Duration(milliseconds: 300), () {
      navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => MarketTokenDetailScreen(asset: asset!),
        ),
      );
    });
  }

  /// Channels created by older builds, removed at start-up.
  static const List<String> _retiredChannels = [
    'price_alerts_standard',
    'price_alerts_cyber',
    'price_alerts_minimal',
    'price_alerts_default',
    'app_updates',
    'critical_v2_alarm_1',
    'critical_v2_alarm_premium',
    'critical_v2_siren',
    'critical_v2_lion_roar',
    'warning_v2_standard',
    'warning_v2_cyber',
    'warning_v2_minimal',
  ];

  /// Alerts have no sound of their own: they vibrate like an ordinary
  /// notification. Android fixes a channel's vibration when the channel is
  /// first created, so "vibration off" uses its own channel.
  static String _alertChannel(String base, bool vibrate) =>
      vibrate ? base : '${base}_novib';

  // ── Price alert notification ID counter (unique per alert) ──────────────
  int _priceAlertIdCounter = 500;

  /// Show a price alert as a normal, tappable notification.
  /// No sound; vibrates when vibration is on in the app's settings.
  Future<void> showPriceAlert({
    required String title,
    required String body,
    required Map<String, dynamic> payload,
  }) async {
    _log.d('showPriceAlert called: $title');

    // ── Permission gate: warn loudly if Android notifications are blocked ──
    final permitted = await isPermissionGranted();
    if (!permitted) {
      _log.e('⚠ NOTIFICATIONS BLOCKED by Android OS! '
          'User must re-enable in Settings → Apps → Guardian → Notifications');
      // Try to request permission (works on Android 13+)
      final android = _notifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final granted = await android?.requestNotificationsPermission() ?? false;
      if (!granted) {
        _log.e(
            'Permission request denied/unavailable. Notification WILL NOT show.');
        // Still try to show — on older Android it might work without explicit permission
      }
    }

    final id = _priceAlertIdCounter++;
    final vibrate =
        SettingsService.instance.settings.soundSettings.vibrationEnabled;

    try {
      final AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
        _alertChannel('price_alerts_v3', vibrate),
        'Price Alerts',
        channelDescription: 'Market price target notifications',
        importance: Importance.high,
        priority: Priority.high,
        playSound: false,
        enableVibration: vibrate,
        autoCancel: true,
      );

      final NotificationDetails platformDetails = NotificationDetails(
        android: androidDetails,
        iOS: const DarwinNotificationDetails(
          presentSound: false,
          presentAlert: true,
          presentBadge: true,
        ),
      );

      await _notifications.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: platformDetails,
        payload: json.encode(payload),
      );
      _log.d('Price alert notification shown');
    } catch (e) {
      _log.e('Price alert notification failed', e);
    }
  }

  Future<void> showUpdateNotification(String version) async {
    if (_isQuietMode()) return;

    final String title = LocalizationService.instance.t('settingsUpdateTitle');
    final String body = LocalizationService.instance
        .t('settingsUpdateNewMsg', {'version': version});

    final vibrate =
        SettingsService.instance.settings.soundSettings.vibrationEnabled;

    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      _alertChannel('app_updates_v2', vibrate),
      'Software Updates',
      channelDescription: 'Notifications for new app versions',
      importance: Importance.max,
      priority: Priority.high,
      playSound: false,
      enableVibration: vibrate,
    );

    final NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(
        presentSound: false,
        presentAlert: true,
      ),
    );

    await _notifications.show(
      id: 999, // Unique ID for update notifications
      title: title,
      body: body,
      notificationDetails: platformDetails,
      payload: json.encode({'type': 'app_update', 'version': version}),
    );
  }

  Future<void> showCriticalAlert(String title, String body,
      {Map<String, dynamic>? payload}) async {
    if (_isQuietMode()) {
      _log.d('Muted by Quiet Mode: $title');
      return;
    }

    final vibrate =
        SettingsService.instance.settings.soundSettings.vibrationEnabled;

    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      _alertChannel('critical_v3', vibrate),
      'Critical Threats',
      channelDescription: 'Alerts about critical threats',
      importance: Importance.max,
      priority: Priority.high,
      enableVibration: vibrate,
      playSound: false,
      color: const Color(0xFFFF4B4B),
    );

    final NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(
        presentSound: false,
        presentAlert: true,
        presentBadge: true,
      ),
    );

    await _notifications.show(
      id: 0,
      title: title,
      body: body,
      notificationDetails: platformDetails,
      payload: payload != null ? json.encode(payload) : null,
    );
  }

  bool _isQuietMode() {
    final settings = SettingsService.instance.settings;
    if (!settings.quietModeEnabled) return false;

    try {
      final now = DateTime.now();
      final startParts =
          settings.quietModeStart.split(':').map(int.parse).toList();
      final endParts = settings.quietModeEnd.split(':').map(int.parse).toList();

      final startTime =
          DateTime(now.year, now.month, now.day, startParts[0], startParts[1]);
      var endTime =
          DateTime(now.year, now.month, now.day, endParts[0], endParts[1]);

      if (endTime.isBefore(startTime)) {
        // Quiet mode spans midnight
        if (now.isAfter(startTime)) {
          return true;
        }
        if (now.isBefore(endTime)) {
          return true;
        }
        return false;
      } else {
        return now.isAfter(startTime) && now.isBefore(endTime);
      }
    } catch (e) {
      _log.e('Error checking quiet mode', e);
      return false;
    }
  }

  Future<void> showWarningAlert(String title, String body,
      {Map<String, dynamic>? payload}) async {
    if (_isQuietMode()) return;

    final vibrate =
        SettingsService.instance.settings.soundSettings.vibrationEnabled;

    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      _alertChannel('warning_v3', vibrate),
      'Security Warnings',
      channelDescription: 'Alerts for high-risk approvals',
      importance: Importance.high,
      priority: Priority.high,
      enableVibration: vibrate,
      playSound: false,
    );

    final NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(
        presentSound: false,
        presentAlert: true,
      ),
    );

    await _notifications.show(
      id: 1,
      title: title,
      body: body,
      notificationDetails: platformDetails,
      payload: payload != null ? json.encode(payload) : null,
    );
  }

  Future<void> showInfoAlert(String title, String body,
      {Map<String, dynamic>? payload}) async {
    if (_isQuietMode()) return;
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'general_info',
      'General Information',
      channelDescription: 'Status updates and scan results',
      importance: Importance.low,
      priority: Priority.low,
    );

    const NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(),
    );

    await _notifications.show(
      id: 2,
      title: title,
      body: body,
      notificationDetails: platformDetails,
      payload: payload != null ? json.encode(payload) : null,
    );
  }

  /// One-off reminder at [when], replacing any earlier one with [id].
  /// Inexact (Android may shift it a little), so no exact-alarm permission
  /// is needed. Past times are skipped.
  Future<void> scheduleReminder({
    required int id,
    required DateTime when,
    required String title,
    required String body,
  }) async {
    try {
      await _notifications.cancel(id: id);
      if (!when.isAfter(DateTime.now())) return;
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'api_key_reminders',
          'API key reminders',
          channelDescription: 'Reminders to renew exchange API keys',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      );
      await _notifications.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: tz.TZDateTime.from(when, tz.local),
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } catch (e) {
      _log.e('Reminder $id not scheduled', e);
    }
  }

  Future<void> cancelReminder(int id) async {
    try {
      await _notifications.cancel(id: id);
    } catch (_) {}
  }

  Future<void> scheduleSubscriptionExpiry(DateTime expiryDate) async {
    // Cancel any previous expiry notifications to avoid duplicates
    // We'll use specific IDs for expiry: 107 (7 days), 103 (3 days), 101 (1 day)
    await _notifications.cancel(id: 107);
    await _notifications.cancel(id: 103);
    await _notifications.cancel(id: 101);

    final now = DateTime.now();

    void scheduleAt(int daysBefore, int id) async {
      final scheduledDate = expiryDate.subtract(Duration(days: daysBefore));
      // Set to 10:00 AM on that day
      final finalScheduled = DateTime(
        scheduledDate.year,
        scheduledDate.month,
        scheduledDate.day,
        10,
        0,
      );

      if (finalScheduled.isAfter(now)) {
        const AndroidNotificationDetails androidDetails =
            AndroidNotificationDetails(
          'subscription_alerts',
          'Subscription Alerts',
          channelDescription: 'Reminders for subscription renewal',
          importance: Importance.high,
          priority: Priority.high,
        );

        const NotificationDetails platformDetails = NotificationDetails(
          android: androidDetails,
          iOS: DarwinNotificationDetails(),
        );

        final daysLeft = daysBefore == 0 ? "today" : "in $daysBefore days";
        final body = daysBefore == 0
            ? "Your PRO subscription expires today! Renew now to keep your wallets protected."
            : "Your PRO subscription will expire $daysLeft. Don't forget to renew!";

        await _notifications.zonedSchedule(
          id: id,
          title: 'Subscription Reminder',
          body: body,
          scheduledDate: tz.TZDateTime.from(finalScheduled, tz.local),
          notificationDetails: platformDetails,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        );
      }
    }

    scheduleAt(7, 107);
    scheduleAt(3, 103);
    scheduleAt(1, 101);
  }

  Future<void> cancelAll() async {
    await _notifications.cancelAll();
  }

  // ── Wallet top-up notification ─────────────────────────────────────────────

  static int _topUpIdCounter = 5000;
  String? _lastTopUpSoundId;

  /// Show a notification when wallet balance increases.
  Future<void> showTopUpNotification({
    required String title,
    required String body,
    required String chainLabel,
  }) async {
    final id = _topUpIdCounter++;
    final soundSettings = SettingsService.instance.settings.soundSettings;
    if (!soundSettings.topUpSoundEnabled) return;

    final soundId = soundSettings.selectedTopUpSoundId;
    final channelId = 'wallet_topup_$soundId';

    // Delete old channel if sound changed (Android caches channel sound)
    if (_lastTopUpSoundId != null && _lastTopUpSoundId != soundId) {
      final android = _notifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      try {
        await android?.deleteNotificationChannel(
            channelId: 'wallet_topup_$_lastTopUpSoundId');
      } catch (_) {}
    }
    _lastTopUpSoundId = soundId;

    final androidDetails = AndroidNotificationDetails(
      channelId,
      'Пополнение кошелька',
      channelDescription: 'Уведомления о пополнении кошелька',
      importance: Importance.high,
      priority: Priority.high,
      playSound: soundSettings.soundEnabled,
      sound: soundSettings.soundEnabled
          ? RawResourceAndroidNotificationSound(soundId)
          : null,
      enableVibration: soundSettings.vibrationEnabled,
      autoCancel: true,
      icon: '@mipmap/ic_launcher',
    );

    final platformDetails = NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );

    await _notifications.show(
      id: id,
      title: title,
      body: '$body\n$chainLabel',
      notificationDetails: platformDetails,
    );
    _log.d('Top-up notification shown: $body ($chainLabel)');
  }
}
