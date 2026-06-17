import 'dart:async';
import 'dart:collection';

import 'package:ibiti_guardian/services/alerts/notification_service.dart';
import 'package:ibiti_guardian/services/alerts/sound_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_interface.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_registry.dart';
import 'package:ibiti_guardian/services/market/rocket_alert_settings.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/market/watchlist_service.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

// ─── Rocket Alert Service ──────────────────────────────────────────────────────
//
// Monitors live exchange ticker streams for rapid price spikes ("rockets").
//
// A rocket is defined as:
//   price change ≥ thresholdPct% within windowMinutes
//
// When detected:
//   1. Push notification via NotificationService.showPriceAlert()
//   2. Alert sound + vibration via SoundService.playAlert()
//
// NEVER auto-trades. NEVER buys or sells. NEVER returns old JARVIS auto-trading.
// This is a pure notification service — user decides what to do.
//
// Architecture:
//   - Subscribes to exchange ticker streams (same as PriceAlertMonitor)
//   - Keeps a rolling price history per symbol (last N minutes)
//   - On each tick, checks if price moved ≥ threshold vs oldest price in window
//   - Cooldown per symbol prevents spam
//
// Lifecycle: start() at app launch, stop() on dispose.
// ─────────────────────────────────────────────────────────────────────────────────

const _log = GuardianLogger('RocketAlert');

class RocketAlertService {
  RocketAlertService._();
  static final RocketAlertService instance = RocketAlertService._();

  final List<StreamSubscription> _subs = [];
  bool _running = false;

  Timer? _batchTimer;
  final List<_PendingRocket> _pendingRockets = [];
  DateTime _lastBatchAlert = DateTime.fromMillisecondsSinceEpoch(0);

  /// Rolling price history per symbol: symbol → list of (timestamp, price).
  final Map<String, Queue<_PricePoint>> _history = {};

  /// Per-symbol cooldown to prevent spam.
  final Map<String, DateTime> _cooldowns = {};

  bool get isRunning => _running;

  // ── Lifecycle ───────────────────────────────────────────────────────────

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

  void stop() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    _history.clear();
    _cooldowns.clear();
    _batchTimer?.cancel();
    _batchTimer = null;
    _pendingRockets.clear();
    _running = false;
    SoundService.instance.stopAll();
    _log.i('Stopped');
  }

  // ── Core check logic ──────────────────────────────────────────────────

  // ── Diagnostic counters ─────────────────────────────────────────────
  int _diagBatchCount = 0;
  int _diagTickerTotal = 0;
  int _diagSkippedScope = 0;
  DateTime _diagLastLog = DateTime.now();

  // ── Cached favorites set (rebuilt every 5s, not per-ticker) ─────────
  Set<String>? _favSymbolsCache;
  DateTime _favCacheTime = DateTime(2000);

  Set<String> _getFavoriteSymbols() {
    final now = DateTime.now();
    if (_favSymbolsCache != null &&
        now.difference(_favCacheTime).inSeconds < 5) {
      return _favSymbolsCache!;
    }
    // Build set once — O(n) but only every 5 seconds
    final entries = WatchlistService.instance.entries;
    final result = <String>{};
    for (final e in entries) {
      if (e.startsWith('sym:')) {
        result.add(e.substring(4).toUpperCase());
      }
    }
    // Also add symbols from CoinGecko IDs
    final cached = MarketDataService.instance.cachedMarkets;
    for (final asset in cached) {
      if (entries.contains(asset.id)) {
        result.add(asset.symbol.toUpperCase());
      }
    }
    _favSymbolsCache = result;
    _favCacheTime = now;
    return result;
  }

  void _checkTickers(List<LiveTicker> tickers) {
    final settings = RocketAlertSettings.instance;
    if (!settings.enabled) return;

    final sw = Stopwatch()..start();
    final now = DateTime.now();
    final windowDuration = Duration(minutes: settings.windowMinutes);
    final cooldownDuration = Duration(minutes: settings.cooldownMinutes);

    // Pre-compute favorites set ONCE per batch, not per ticker
    final favSymbols = settings.scope == RocketAlertScope.favorites
        ? _getFavoriteSymbols()
        : null;

    int processed = 0;
    int skippedScope = 0;

    for (final ticker in tickers) {
      if (ticker.lastPrice <= 0) continue;

      final symbol = ticker.baseAsset.toUpperCase();

      // ── Scope filter (O(1) Set lookup instead of O(n) cachedMarkets) ──
      if (favSymbols != null && !favSymbols.contains(symbol)) {
        skippedScope++;
        continue;
      }

      processed++;

      // ── Update rolling history ───────────────────────────────────────
      final history = _history.putIfAbsent(symbol, () => Queue<_PricePoint>());
      history.addLast(_PricePoint(now, ticker.lastPrice));

      // Prune entries older than window
      final cutoff = now.subtract(windowDuration);
      while (history.isNotEmpty && history.first.time.isBefore(cutoff)) {
        history.removeFirst();
      }

      // Need at least 2 data points to compare
      if (history.length < 2) continue;

      // ── Check for rocket ─────────────────────────────────────────────
      final oldestPrice = history.first.price;
      if (oldestPrice <= 0) continue;

      final changePct = ((ticker.lastPrice - oldestPrice) / oldestPrice) * 100;

      if (changePct >= settings.thresholdPct) {
        // ── Cooldown guard ─────────────────────────────────────────────
        final lastFired = _cooldowns[symbol];
        // Enforce a strict minimum 15-minute cooldown per symbol
        final effectiveCooldown = cooldownDuration.inMinutes < 15 
            ? const Duration(minutes: 15) 
            : cooldownDuration;

        if (lastFired != null && now.difference(lastFired) < effectiveCooldown) {
          continue;
        }

        _pendingRockets.add(_PendingRocket(
          symbol, 
          changePct, 
          ticker.lastPrice, 
          settings.windowMinutes,
        ));
        _cooldowns[symbol] = now;

        if (_batchTimer == null || !_batchTimer!.isActive) {
          _batchTimer = Timer(const Duration(seconds: 30), _processBatch);
        }
      }
    }

    sw.stop();

    // ── Diagnostic logging (every 10 seconds) ────────────────────────
    _diagBatchCount++;
    _diagTickerTotal += tickers.length;
    _diagSkippedScope += skippedScope;

    if (now.difference(_diagLastLog).inSeconds >= 10) {
      _log.i('[PERF] batches=$_diagBatchCount '
          'tickers=$_diagTickerTotal '
          'skippedScope=$_diagSkippedScope '
          'processed=$processed '
          'historyKeys=${_history.length} '
          'lastBatchMs=${sw.elapsedMilliseconds} '
          'scope=${settings.scope.name}');
      _diagBatchCount = 0;
      _diagTickerTotal = 0;
      _diagSkippedScope = 0;
      _diagLastLog = now;
    }

    // ── Warn if batch took too long ─────────────────────────────────
    if (sw.elapsedMilliseconds > 50) {
      _log.w('[PERF] ⚠️ SLOW BATCH: ${sw.elapsedMilliseconds}ms '
          'tickers=${tickers.length} processed=$processed '
          'historyKeys=${_history.length}');
    }
  }

  void _processBatch() {
    _batchTimer = null;
    if (_pendingRockets.isEmpty) return;

    final now = DateTime.now();
    // Global 60-sec cooldown
    if (now.difference(_lastBatchAlert) < const Duration(seconds: 60)) {
      _log.i('Skipping batch alert due to global 60-sec cooldown.');
      _pendingRockets.clear();
      return;
    }
    
    _lastBatchAlert = now;

    // Sort by largest change percentage
    _pendingRockets.sort((a, b) => b.changePct.compareTo(a.changePct));

    if (_pendingRockets.length == 1) {
      final r = _pendingRockets.first;
      _fireSingleRocketAlert(r.symbol, r.price, r.changePct, r.windowMinutes);
    } else {
      _fireBatchedRocketAlert(List.from(_pendingRockets));
    }

    _pendingRockets.clear();
  }

  Future<void> _fireSingleRocketAlert(
    String symbol,
    double price,
    double changePct,
    int windowMinutes,
  ) async {
    _log.i('🚀 ROCKET: $symbol +${changePct.toStringAsFixed(1)}% '
        'in ${windowMinutes}m (price: \$$price)');

    // 1. Push notification
    try {
      await NotificationService.instance.showPriceAlert(
        title: '🚀 Rocket — $symbol',
        body: '$symbol +${changePct.toStringAsFixed(1)}% '
            'in ${windowMinutes}m. '
            'Price: \$${price < 1 ? price.toStringAsFixed(6) : price.toStringAsFixed(2)}',
        payload: {
          'type': 'price_alert',
          'symbol': symbol,
          'currentPrice': price,
          'changePct': changePct,
          'isRocket': true,
        },
      );
    } catch (e) {
      _log.e('Notification failed', e);
    }
    // Sound + vibration is handled automatically via Android native channel
  }

  Future<void> _fireBatchedRocketAlert(List<_PendingRocket> rockets) async {
    _log.i('🚀 BATCH ROCKET: ${rockets.length} symbols');

    final buffer = StringBuffer();
    for (int i = 0; i < rockets.length; i++) {
      if (i >= 5) {
        buffer.write('...и ещё ${rockets.length - 5}');
        break;
      }
      final r = rockets[i];
      buffer.write('${r.symbol} +${r.changePct.toStringAsFixed(1)}%');
      if (i < rockets.length - 1 && i < 4) {
        buffer.write(', ');
      }
    }

    try {
      await NotificationService.instance.showPriceAlert(
        title: '🚀 ${rockets.length} монет двинулись',
        body: buffer.toString(),
        payload: {
          'type': 'market_summary',
          'isRocket': true,
        },
      );
    } catch (e) {
      _log.e('Batched notification failed', e);
    }
    // Sound + vibration is handled automatically via Android native channel
  }

  // ── Memory management ──────────────────────────────────────────────────

  /// Prune symbols that haven't had a tick in 30 minutes.
  /// Called periodically or on app lifecycle.
  void pruneStaleHistory() {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 30));
    _history.removeWhere((_, history) {
      return history.isEmpty || history.last.time.isBefore(cutoff);
    });
  }
}

/// A single price data point in the rolling window.
class _PricePoint {
  final DateTime time;
  final double price;
  const _PricePoint(this.time, this.price);
}

class _PendingRocket {
  final String symbol;
  final double changePct;
  final double price;
  final int windowMinutes;

  _PendingRocket(this.symbol, this.changePct, this.price, this.windowMinutes);
}
