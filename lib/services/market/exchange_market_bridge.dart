import 'dart:async';
import 'package:ibiti_guardian/services/exchanges/exchange_interface.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_registry.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/market/market_live_engine.dart';
import 'package:ibiti_guardian/services/market/exchange_trade_flow_tape.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

const _log = GuardianLogger('ExchangeBridge');

// ─── Exchange → MarketDataService Bridge ──────────────────────────────────────

/// Subscribes to ALL exchange ticker streams and injects live prices
/// into [MarketDataService] so that the Scout, AI, and AutomationEngine
/// automatically see real-time data without any other changes.
///
/// This is a one-way data bridge — no new architecture, no new models.
/// It simply converts [LiveTicker] → [MarketAsset] and merges into the
/// existing cache, preserving CoinGecko metadata (images, sparklines)
/// where available.
class ExchangeMarketBridge {
  ExchangeMarketBridge._();
  static final ExchangeMarketBridge instance = ExchangeMarketBridge._();

  final List<StreamSubscription> _subs = [];
  bool _running = false;

  bool get isRunning => _running;

  /// Start listening to all exchange ticker streams.
  /// Safe to call multiple times — silently ignores if already running.
  void start() {
    if (_running) return;
    _running = true;

    final registry = ExchangeRegistry.instance;

    for (final id in registry.availableExchanges) {
      final svc = registry.serviceFor(id);
      final sub = svc.tickerStream.listen(
        (tickers) => _onTickers(tickers, id),
        onError: (e) => _log.e('Stream error from ${id.displayName}', e),
      );
      _subs.add(sub);
    }

    _log.i('Started — bridging ${_subs.length} exchange streams');

    // Start trade flow tape monitoring
    ExchangeTradeFlowTape.instance.start();
  }

  /// Stop all subscriptions.
  void stop() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    _running = false;
    _log.i('Stopped');
  }

  // ── Core: convert + merge ──────────────────────────────────────────────────

  void _onTickers(List<LiveTicker> tickers, ExchangeId source) {
    if (tickers.isEmpty) return;

    final converted = <String, MarketAsset>{};

    for (final t in tickers) {
      // Skip zero-price, zero-volume, or extremely illiquid tickers (<$50K daily volume).
      // Lower threshold than before ($500K) to capture MEXC moonshots.
      if (t.lastPrice <= 0 || t.quoteVolume24h < 50000) continue;

      final symbol = t.baseAsset.toUpperCase();
      // Key by source+pair for true identity — prevents cross-exchange conflicts.
      final key = '${source.name}:${t.symbol}';

      // If we already processed this pair from this batch, keep the one
      // with higher volume.
      final existing = converted[key];
      if (existing != null && existing.volume >= t.quoteVolume24h) continue;

      converted[key] = MarketAsset(
        // Use lowercase baseAsset as id (matches CoinGecko convention).
        id: t.baseAsset.toLowerCase(),
        symbol: symbol,
        name: t.baseAsset,
        imageUrl: '',
        price: t.lastPrice,
        change24h: t.priceChangePercent24h,
        marketCap: 0,
        volume: t.quoteVolume24h,
        rank: 0,
        sparkline: const [],
        high24h: t.highPrice24h,
        low24h: t.lowPrice24h,
        change7d: 0,
        change30d: 0,
        networkGroup: 'Multi-chain',
        sourceId: source.name,
        sourcePair: t.symbol,
        sourceUpdatedAt: DateTime.now(),
      );
    }

    if (converted.isNotEmpty) {
      MarketDataService.instance.mergeExchangeData(converted);
    }

    // ── Push every ticker into MarketLiveEngine for:
    //    1. TokenDetail live notifier subscriptions
    //    2. IBITI Perception snapshot reads
    //    3. Any future consumer of live data ──
    final engine = MarketLiveEngine.instance;
    for (final t in tickers) {
      if (t.lastPrice <= 0) continue;
      engine.pushTick(source.name, t.symbol, t);
    }
  }
}
