import 'dart:async';

import 'package:ibiti_guardian/services/alerts/notification_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_interface.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_registry.dart';
import 'package:ibiti_guardian/services/wallet/market_price_alert_service.dart';
import 'package:ibiti_guardian/services/alerts/sound_service.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

// ─── Price Alert Monitor ────────────────────────────────────────────────────────
//
// Subscribes to live exchange ticker streams and checks every price update
// against the user's active alerts.
//
// When an alert triggers:
//   1. Push notification via NotificationService
//   2. Alert sound via AudioManager
//   3. Alert is removed (one-shot)
//
// Cooldown: 60s per symbol to prevent rapid-fire notifications when
// price oscillates around the target.
//
// Lifecycle: start() at app launch, stop() on dispose.
// ─────────────────────────────────────────────────────────────────────────────────

const _log = GuardianLogger('PriceAlertMonitor');

class PriceAlertMonitor {
  PriceAlertMonitor._();
  static final PriceAlertMonitor instance = PriceAlertMonitor._();

  final List<StreamSubscription> _subs = [];
  bool _running = false;

  /// Per-symbol cooldown to prevent spam when price bounces around target.
  final Map<String, DateTime> _cooldowns = {};
  static const _cooldownDuration = Duration(seconds: 60);

  bool get isRunning => _running;

  /// Start monitoring all exchange ticker streams for alert triggers.
  /// Safe to call multiple times — ignores if already running.
  void start() {
    if (_running) return;
    _running = true;

    final registry = ExchangeRegistry.instance;
    for (final id in registry.availableExchanges) {
      final svc = registry.serviceFor(id);
      final sub = svc.tickerStream.listen(
        (tickers) => _checkTickers(tickers),
        onError: (e) => _log.e('Stream error', e),
      );
      _subs.add(sub);
    }

    _log.i('Started — monitoring ${_subs.length} exchange streams');
  }

  /// Stop all subscriptions.
  void stop() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    _cooldowns.clear();
    _running = false;
    _log.i('Stopped');
  }

  // ── Core check logic ──────────────────────────────────────────────────────

  void _checkTickers(List<LiveTicker> tickers) {
    final alertService = MarketPriceAlertService.instance;
    final allAlerts = alertService.allAlerts;
    if (allAlerts.isEmpty) return;

    for (final ticker in tickers) {
      if (ticker.lastPrice <= 0) continue;

      final symbol = ticker.baseAsset.toUpperCase();
      final alerts = allAlerts[symbol];
      if (alerts == null || alerts.isEmpty) continue;

      // Check cooldown
      final lastFired = _cooldowns[symbol];
      if (lastFired != null &&
          DateTime.now().difference(lastFired) < _cooldownDuration) {
        continue;
      }

      // Check each alert for this symbol
      for (final alert in alerts) {
        // Grace period: don't fire alerts within 15s of creation.
        // Prevents instant-fire when price already crossed target at set time.
        final age = DateTime.now().difference(alert.createdAt).inSeconds;
        if (age < 15) {
          _log.i('[DIAG] $symbol: grace period (${age}s < 15s)');
          continue;
        }

        final triggered = alert.isAbove
            ? ticker.lastPrice >= alert.targetPrice
            : ticker.lastPrice <= alert.targetPrice;

        _log.i('[DIAG] $symbol: price=${ticker.lastPrice}, '
            'target=${alert.targetPrice}, '
            'isAbove=${alert.isAbove}, triggered=$triggered');

        if (triggered) {
          _fireAlert(alert, ticker.lastPrice);
          break; // One fire per symbol per tick batch
        }
      }
    }
  }

  Future<void> _fireAlert(MarketPriceAlert alert, double currentPrice) async {
    final symbol = alert.symbol;
    final direction = alert.isAbove ? '▲' : '▼';
    final l = LocalizationService.instance;
    final verb = alert.isAbove
        ? l.t('priceAlertNotifRoseAbove')
        : l.t('priceAlertNotifFellBelow');

    _log.i('FIRED: $symbol $direction \$${alert.targetPrice} '
        '(current: \$$currentPrice)');

    // 1. Set cooldown BEFORE async operations
    _cooldowns[symbol] = DateTime.now();

    // 2. Show a clean, tappable notification (like SMS — default system sound)
    try {
      await NotificationService.instance.showPriceAlert(
        title: l.t('priceAlertNotifTitle', {
          'direction': direction,
          'symbol': symbol,
        }),
        body: l.t('priceAlertNotifBody', {
          'symbol': symbol,
          'verb': verb,
          'target': alert.targetPrice.toStringAsFixed(2),
          'current': currentPrice.toStringAsFixed(2),
        }),
        payload: {
          'type': 'price_alert',
          'symbol': symbol,
          'targetPrice': alert.targetPrice,
          'currentPrice': currentPrice,
          'isAbove': alert.isAbove,
        },
      );
    } catch (e) {
      _log.e('Notification failed', e);
    }

    // 3. Play alert sound + vibration
    try {
      SoundService.instance.playAlert();
    } catch (e) {
      _log.e('Sound/vibration failed', e);
    }

    // 4. Remove the one-shot alert
    await MarketPriceAlertService.instance.removeAlert(symbol, alert.isAbove);
  }
}
