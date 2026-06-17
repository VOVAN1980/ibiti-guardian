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

    // Clean up orphaned channels from old dynamic-ID scheme.
    // Previously we created 'price_alerts_standard', 'price_alerts_cyber', etc.
    // Now we use a single 'price_alerts' channel.
    final android = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      for (final old in [
        'price_alerts_standard',
        'price_alerts_cyber',
        'price_alerts_minimal'
      ]) {
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

  // ── Price alert notification ID counter (unique per alert) ──────────────
  int _priceAlertIdCounter = 500;

  /// Tracks last used sound so we can delete the old Android channel on change.
  String? _lastAlertSoundId;

  /// Show a price alert as a normal, tappable notification.
  /// Respects existing SoundSettings: sound on/off, vibration on/off,
  /// and user-selected alert sound from app settings.
  /// Falls back to default sound if custom sound fails.
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
    final soundSettings = SettingsService.instance.settings.soundSettings;
    final encodedPayload = json.encode(payload);

    // Try with user's custom sound first
    try {
      final soundId = soundSettings.selectedAlertSoundId;
      final resourceName = _mapSoundToResource('alert', soundId);
      final channelId = 'price_alerts_$soundId';

      // Android caches channel sound — if user changed sound, delete old channel.
      if (_lastAlertSoundId != null && _lastAlertSoundId != soundId) {
        final android = _notifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        try {
          await android?.deleteNotificationChannel(
              channelId: 'price_alerts_$_lastAlertSoundId');
          _log.d('Deleted old channel: price_alerts_$_lastAlertSoundId');
        } catch (e) {
          _log.d('old channel delete: $e');
        }
      }
      _lastAlertSoundId = soundId;

      final AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
        channelId,
        'Price Alerts',
        channelDescription: 'Market price target notifications',
        importance: Importance.high,
        priority: Priority.high,
        playSound: soundSettings.soundEnabled,
        sound: soundSettings.soundEnabled
            ? RawResourceAndroidNotificationSound(resourceName)
            : null,
        enableVibration: soundSettings.vibrationEnabled,
        autoCancel: true,
      );

      final NotificationDetails platformDetails = NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(
          presentSound: soundSettings.soundEnabled,
          presentAlert: true,
          presentBadge: true,
        ),
      );

      await _notifications.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: platformDetails,
        payload: encodedPayload,
      );
      _log.d('Price alert notification shown successfully (custom sound)');
      return;
    } catch (e) {
      _log.e('Custom sound notification failed, trying fallback', e);
    }

    // Fallback: simple notification with default system sound
    try {
      const AndroidNotificationDetails fallback = AndroidNotificationDetails(
        'price_alerts_default',
        'Price Alerts',
        channelDescription: 'Market price target notifications',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        autoCancel: true,
      );

      const NotificationDetails fallbackDetails = NotificationDetails(
        android: fallback,
        iOS: DarwinNotificationDetails(
          presentSound: true,
          presentAlert: true,
          presentBadge: true,
        ),
      );

      await _notifications.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: fallbackDetails,
        payload: encodedPayload,
      );
      _log.d('Price alert notification shown (fallback/default sound)');
    } catch (e) {
      _log.e('BOTH notification attempts failed!', e);
    }
  }

  Future<void> showUpdateNotification(String version) async {
    if (_isQuietMode()) return;

    final String title = LocalizationService.instance.t('settingsUpdateTitle');
    final String body = LocalizationService.instance
        .t('settingsUpdateNewMsg', {'version': version});

    final soundSettings = SettingsService.instance.settings.soundSettings;
    final soundId =
        soundSettings.selectedAlertSoundId; // Using alert sound for updates
    final resourceName = _mapSoundToResource('alert', soundId);

    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'app_updates',
      'Software Updates',
      channelDescription: 'Notifications for new app versions',
      importance: Importance.max,
      priority: Priority.high,
      playSound: soundSettings.soundEnabled,
      sound: soundSettings.soundEnabled
          ? RawResourceAndroidNotificationSound(resourceName)
          : null,
    );

    final NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(
        presentSound: true,
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

    final soundSettings = SettingsService.instance.settings.soundSettings;
    final soundId = soundSettings.selectedCriticalSoundId;
    final resourceName = _mapSoundToResource('critical', soundId);

    // Dynamic channel ID to force sound update on Android
    final channelId = 'critical_v2_$soundId';

    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      channelId,
      'Critical Threats',
      channelDescription: 'Emergency alerts with custom sound',
      importance: Importance.max,
      priority: Priority.high,
      enableVibration: soundSettings.vibrationEnabled,
      playSound: soundSettings.soundEnabled,
      sound: soundSettings.soundEnabled
          ? RawResourceAndroidNotificationSound(resourceName)
          : null,
      color: const Color(0xFFFF4B4B),
    );

    final NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(
        presentSound: true,
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

  String _mapSoundToResource(String type, String soundId) {
    if (soundId == 'lion_roar') return 'lion_roar';

    switch (type) {
      case 'critical':
        return 'critical_$soundId';
      case 'alert':
        return 'alert_$soundId';
      case 'panic':
        // Some panic sounds share names or are dedicated
        if (soundId == 'panic_ultra' || soundId == 'emergency') return soundId;
        return soundId;
      default:
        return 'alert_standard';
    }
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

    final soundSettings = SettingsService.instance.settings.soundSettings;
    final soundId = soundSettings.selectedAlertSoundId;
    final resourceName = _mapSoundToResource('alert', soundId);

    // Dynamic channel ID
    final channelId = 'warning_v2_$soundId';

    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      channelId,
      'Security Warnings',
      channelDescription: 'Alerts for high-risk approvals',
      importance: Importance.high,
      priority: Priority.high,
      enableVibration: soundSettings.vibrationEnabled,
      playSound: soundSettings.soundEnabled,
      sound: soundSettings.soundEnabled
          ? RawResourceAndroidNotificationSound(resourceName)
          : null,
    );

    final NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(
        presentSound: true,
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
