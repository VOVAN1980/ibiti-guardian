import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_interface.dart';
import 'package:ibiti_guardian/services/exchanges/mexc_exchange_service.dart';
import 'package:ibiti_guardian/services/exchanges/binance_exchange_service.dart';
import 'package:ibiti_guardian/services/exchanges/gateio_exchange_service.dart';
import 'package:ibiti_guardian/services/exchanges/okx_exchange_service.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

const _log = GuardianLogger('ExchangeReg');

// ─── Exchange Registry ─────────────────────────────────────────────────────────

/// Central manager for all exchange connections.
/// Exposes a ChangeNotifier so UI rebuilds on tick updates.
///
/// Usage:
///   ExchangeRegistry.instance.selectExchange(ExchangeId.mexc)
///   ExchangeRegistry.instance.active.tickerStream
class ExchangeRegistry extends ChangeNotifier {
  ExchangeRegistry._();
  static final ExchangeRegistry instance = ExchangeRegistry._();

  final Map<ExchangeId, ExchangeService> _services = {
    ExchangeId.mexc: MexcExchangeService.instance,
    ExchangeId.binance: BinanceExchangeService.instance,
    ExchangeId.gateio: GateioExchangeService.instance,
    ExchangeId.okx: OkxExchangeService.instance,
  };

  ExchangeId _activeId = ExchangeId.binance;
  StreamSubscription? _activeSub;
  Timer? _notifyThrottle;

  ExchangeId get activeId => _activeId;
  ExchangeService get active => _services[_activeId]!;

  /// Get service for a specific exchange directly.
  ExchangeService serviceFor(ExchangeId id) => _services[id]!;

  List<ExchangeId> get availableExchanges => _services.keys.toList();

  /// Check if a symbol is tradable on ANY connected exchange.
  /// Returns true if at least one connected exchange has an active ticker for this symbol.
  bool isTradable(String symbol) {
    final upper = symbol.toUpperCase();
    for (final svc in _services.values) {
      if (!svc.isConnected) continue;
      for (final t in svc.currentTickers) {
        if (t.baseAsset == upper) return true;
      }
    }
    return false;
  }

  /// Returns which exchanges have this symbol, for display.
  List<String> exchangesFor(String symbol) {
    final upper = symbol.toUpperCase();
    final result = <String>[];
    for (final entry in _services.entries) {
      if (!entry.value.isConnected) continue;
      for (final t in entry.value.currentTickers) {
        if (t.baseAsset == upper) {
          result.add(entry.key.displayName);
          break;
        }
      }
    }
    return result;
  }

  /// New listing events from all exchanges.
  final List<NewListingEvent> recentNewListings = [];

  /// Switch to a different exchange and connect if needed.
  Future<void> selectExchange(ExchangeId id) async {
    if (!_services.containsKey(id)) return;
    _activeId = id;

    // Re-subscribe to the new active stream.
    _activeSub?.cancel();
    _activeSub = active.tickerStream.listen((_) {
      _throttledNotify();
      _checkNewListings();
    });

    // Connect if not connected.
    if (!active.isConnected) {
      _log.i('Connecting ${id.displayName}...');
      unawaited(active.connect());
    }

    notifyListeners();
  }

  /// Notify listeners at most once per second — exchange WS fires thousands/sec.
  void _throttledNotify() {
    _notifyThrottle ??= Timer(const Duration(seconds: 1), () {
      _notifyThrottle = null;
      notifyListeners();
    });
  }

  /// Connect all exchanges in background — parallel, resilient.
  /// If one exchange fails, others still connect fine.
  Future<void> connectAll() async {
    final futures = <Future>[];
    for (final entry in _services.entries) {
      futures.add(_connectOne(entry.key, entry.value));
    }
    await Future.wait(futures);
    notifyListeners();
  }

  Future<void> _connectOne(ExchangeId id, ExchangeService svc) async {
    try {
      await svc.connect().timeout(const Duration(seconds: 15));
      _log.i('${id.displayName} syncing...');

      svc.tickerStream.listen((_) {
        if (id == _activeId) _throttledNotify();
        _checkNewListings();

        // Log readiness transition on first data.
        if (!_readyExchanges.contains(id) && svc.totalPairs > 0) {
          _readyExchanges.add(id);
          _log.i('${id.displayName} ready (${svc.totalPairs} pairs)');
        }
      });
    } catch (e) {
      _log.e('Connect failed: ${id.displayName}', e);
      // Exchange failed — don't block others.
    }
  }

  /// Track which exchanges have data ready.
  final Set<ExchangeId> _readyExchanges = {};

  /// True if exchange has data and can be displayed.
  bool isReady(ExchangeId id) {
    final svc = _services[id];
    return svc != null && svc.isConnected && svc.totalPairs > 0;
  }

  void _checkNewListings() {
    for (final svc in _services.values) {
      final listings = svc.newListings;
      for (final t in listings) {
        recentNewListings.insert(
          0,
          NewListingEvent(
            exchange: svc.id.displayName,
            ticker: t,
            detectedAt: DateTime.now(),
          ),
        );
        _log.i('NEW LISTING: ${t.symbol} on ${svc.id.displayName}');
      }
      // Keep at most 20 recent events.
      if (recentNewListings.length > 20) {
        recentNewListings.removeRange(20, recentNewListings.length);
      }
    }
  }

  Future<void> disconnectAll() async {
    _activeSub?.cancel();
    for (final svc in _services.values) {
      await svc.disconnect();
    }
  }
}
