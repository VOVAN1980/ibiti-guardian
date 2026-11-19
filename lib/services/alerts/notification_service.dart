import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;
import 'package:ibiti_guardian/main.dart'; // Import navigatorKey
import 'package:ibiti_guardian/app/guardian_app_shell.dart';
import 'package:ibiti_guardian/screens/market_command/market_token_detail_screen.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/models/sound_settings.dart';

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

    // Remove the channels of older builds: DrainShield's alarm, siren,
    // subscription and update channels, and the channels made before the
    // single/double vibration settings (Android fixes a channel's sound and
    // vibration when it is created).
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
    await syncChannelsWithSettings();

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
    'app_updates_v2',
    'app_updates_v2_novib',
    'critical_v3',
    'critical_v3_novib',
    'general_info',
    'subscription_alerts',
    'price_alerts_v3',
    'price_alerts_v3_novib',
    'warning_v3',
    'warning_v3_novib',
    'api_key_reminders',
    'wallet_topup_coins_1',
    'wallet_topup_coins_2',
    'wallet_topup_coins_3',
  ];

  /// One short vibration: ordinary notifications (prices, reminders,
  /// revoke results).
  static final Int64List _singleBuzz = Int64List.fromList([0, 250]);

  /// Two short vibrations: a wallet top-up.
  static final Int64List _doubleBuzz = Int64List.fromList([0, 200, 150, 200]);

  /// Ordinary notifications have no sound of their own; they vibrate once
  /// when "Single vibration" is on. Android fixes a channel's vibration when
  /// the channel is first created, so each setting has its own channel.
  static bool get _singleOn =>
      SettingsService.instance.settings.soundSettings.singleVibrationEnabled;
  static String _ordinaryChannel(String base) =>
      _singleOn ? '${base}_single' : '${base}_novib';

  static const List<String> _ordinaryBases = [
    'price_alerts_v4',
    'warning_v4',
    'api_key_reminders_v2',
  ];

  /// Top-up channel for the current settings: with the chosen coin sound, or
  /// silent (the app is open and plays the coins itself).
  static String _topUpChannel({required bool withSound}) {
    final s = SettingsService.instance.settings.soundSettings;
    final sound = withSound && s.topUpSoundEnabled;
    return 'wallet_topup_v4_${sound ? s.selectedTopUpSoundId : 'silent'}_'
        '${s.doubleVibrationEnabled ? 'double' : 'novib'}';
  }

  /// Removes the channels of settings that are no longer chosen, so Android's
  /// notification settings show each kind once. Called at start-up and when
  /// the sound and vibration settings change. The channels of the current
  /// settings stay, so notifications already shown are kept.
  Future<void> syncChannelsWithSettings() async {
    final android = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    final keep = {
      for (final base in _ordinaryBases) _ordinaryChannel(base),
      _topUpChannel(withSound: true),
      _topUpChannel(withSound: false),
    };
    final all = <String>[
      for (final base in _ordinaryBases) ...['${base}_single', '${base}_novib'],
      for (final sound in [...SoundSettings.topUpSounds, 'silent'])
        for (final vib in ['double', 'novib']) 'wallet_topup_v4_${sound}_$vib',
    ];
    for (final id in all.where((id) => !keep.contains(id))) {
      try {
        await android.deleteNotificationChannel(channelId: id);
      } catch (e) {
        _log.d('Channel delete $id: $e');
      }
    }
  }

  // ── Price alert notification ID counter (unique per alert) ──────────────
  int _priceAlertIdCounter = 500;

  /// Show a price alert as a normal, tappable notification.
  /// No sound; one vibration when "Single vibration" is on.
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
    final vibrate = _singleOn;

    try {
      final AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
        _ordinaryChannel('price_alerts_v4'),
        'Price Alerts',
        channelDescription: 'Market price target notifications',
        importance: Importance.high,
        priority: Priority.high,
        playSound: false,
        enableVibration: vibrate,
        vibrationPattern: vibrate ? _singleBuzz : null,
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

    final vibrate = _singleOn;

    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      _ordinaryChannel('warning_v4'),
      'Security',
      channelDescription: 'Results of permission revokes',
      importance: Importance.high,
      priority: Priority.high,
      enableVibration: vibrate,
      vibrationPattern: vibrate ? _singleBuzz : null,
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
      final vibrate = _singleOn;
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          _ordinaryChannel('api_key_reminders_v2'),
          'API key reminders',
          channelDescription: 'Reminders to renew exchange API keys',
          importance: Importance.high,
          priority: Priority.high,
          playSound: false,
          enableVibration: vibrate,
          vibrationPattern: vibrate ? _singleBuzz : null,
        ),
        iOS: const DarwinNotificationDetails(),
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

  // ── Wallet top-up notification ─────────────────────────────────────────────

  static int _topUpIdCounter = 5000;

  /// Show a notification when the wallet balance increases: the coin sound
  /// when "Coin sound" is on, two vibrations when "Double vibration" is on.
  /// [withSound] is false while the app is open, because the app plays the
  /// coin sound itself then (one chime, not two).
  Future<void> showTopUpNotification({
    required String title,
    required String body,
    required String chainLabel,
    bool withSound = true,
  }) async {
    final id = _topUpIdCounter++;
    final soundSettings = SettingsService.instance.settings.soundSettings;
    final soundId = soundSettings.selectedTopUpSoundId;
    final sound = withSound && soundSettings.topUpSoundEnabled;
    final vibrate = soundSettings.doubleVibrationEnabled;

    // Android fixes a channel's sound and vibration when it is created, so
    // every combination has its own channel (see syncChannelsWithSettings).
    final channelId = _topUpChannel(withSound: withSound);

    final androidDetails = AndroidNotificationDetails(
      channelId,
      'Пополнение кошелька',
      channelDescription: 'Уведомления о пополнении кошелька',
      importance: Importance.high,
      priority: Priority.high,
      playSound: sound,
      sound: sound ? RawResourceAndroidNotificationSound(soundId) : null,
      enableVibration: vibrate,
      vibrationPattern: vibrate ? _doubleBuzz : null,
      autoCancel: true,
      icon: '@mipmap/ic_launcher',
    );

    final platformDetails = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: sound,
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
