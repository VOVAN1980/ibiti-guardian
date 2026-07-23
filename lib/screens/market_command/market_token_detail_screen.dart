import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_account_store.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_order_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/screens/market_command/widgets/connect_exchange_modal.dart';
import 'package:ibiti_guardian/screens/market_command/widgets/cex_spot_trade_modal.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/exchanges/okx_exchange_service.dart';
import 'package:ibiti_guardian/services/market/market_live_engine.dart';
import 'package:ibiti_guardian/services/market/watchlist_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_chart_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_interface.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/wallet/market_price_alert_service.dart';
import 'package:ibiti_guardian/screens/wallet/components/wallet_trade_modal.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/models/candle.dart';
import 'package:ibiti_guardian/widgets/candle_chart.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/utils/price_formatter.dart';
import 'package:ibiti_guardian/models/automation_trigger.dart';
import 'package:ibiti_guardian/services/market/automation_engine.dart';

// ─── Market Token Detail Screen ─────────────────────────────────────────────────
//
// Full market card for any token — opened from:
//   • Search results (0A)
//   • Exchange Terminal ticker row
//   • Market list row
//   • Watchlist row
//
// Shows: price, 24h change, sparkline chart (7d), market metrics,
//        exchange cross-reference, Buy/Sell/Swap/★ buttons.
// ─────────────────────────────────────────────────────────────────────────────────

class MarketTokenDetailScreen extends StatefulWidget {
  /// The [MarketAsset] provides basic info (symbol, price, id).
  /// Detail data is fetched on-screen via [MarketDataService.fetchDetail].
  final MarketAsset asset;

  const MarketTokenDetailScreen({super.key, required this.asset});

  @override
  State<MarketTokenDetailScreen> createState() =>
      _MarketTokenDetailScreenState();
}

class _MarketTokenDetailScreenState extends State<MarketTokenDetailScreen> {
  static const _log = GuardianLogger('TokenDetail');
  MarketAssetDetail? _detail;
  final ValueNotifier<List<Candle>> _chartCandles = ValueNotifier([]);
  final ValueNotifier<ChartStyle> _chartStyle = ValueNotifier(ChartStyle.candle);
  int _chartRequestNonce = 0;
  bool _loadingChart = true;
  String _chartRange = '7D';

  // ── Live ticker via ValueNotifier ─────────────────────────────────────
  // UI components subscribe via ValueListenableBuilder.
  // NO setState() on tick path → chart/description/buttons don't rebuild.
  final ValueNotifier<LiveTicker?> _liveTicker = ValueNotifier(null);
  final ValueNotifier<int> _tickNonce = ValueNotifier(0);

  /// Stored reference to engine notifier — never call notifierFor() in dispose.
  ValueNotifier<LiveTicker?>? _engineNotifier;

  Timer? _priceTimer;

  // ScreenContext throttle — AI doesn't need 10 updates/sec
  DateTime _lastContextPush = DateTime(2000);
  static const _contextThrottle = Duration(milliseconds: 1000);

  /// Effective asset: merges live data on top of widget.asset.
  /// Used for non-live sections (chart range, alert sheet, swap).
  MarketAsset get asset {
    final t = _liveTicker.value;
    final b = widget.asset;
    final liveId = _liveSourceId.isNotEmpty ? _liveSourceId : b.sourceId;
    final livePair = _liveSourcePair.isNotEmpty ? _liveSourcePair : b.sourcePair;
    if (t == null) {
      return MarketAsset(
        id: b.id,
        symbol: b.symbol,
        name: b.name,
        imageUrl: b.imageUrl,
        price: b.price,
        change24h: b.change24h,
        marketCap: b.marketCap,
        volume: b.volume,
        rank: b.rank,
        sparkline: b.sparkline,
        high24h: b.high24h,
        low24h: b.low24h,
        change7d: b.change7d,
        change30d: b.change30d,
        networkGroup: b.networkGroup,
        sourceId: liveId,
        sourcePair: livePair,
        sourceUpdatedAt: DateTime.now(),
      );
    }
    return MarketAsset(
      id: b.id,
      symbol: b.symbol,
      name: b.name,
      imageUrl: b.imageUrl,
      price: t.lastPrice,
      change24h: t.priceChangePercent24h,
      marketCap: b.marketCap,
      volume: t.quoteVolume24h,
      rank: b.rank,
      sparkline: b.sparkline,
      high24h: t.highPrice24h,
      low24h: t.lowPrice24h,
      change7d: b.change7d,
      change30d: b.change30d,
      networkGroup: b.networkGroup,
      sourceId: liveId,
      sourcePair: livePair,
      sourceUpdatedAt: DateTime.now(),
    );
  }

  /// Whether this detail screen has a live exchange feed.
  bool get _isLive =>
      const {'binance', 'mexc', 'gateio', 'okx'}.contains(_liveSourceId);

  @override
  void initState() {
    super.initState();

    // Audit log: what source is this detail opening with?
    _log.i('[MarketUI] open detail '
        'symbol=${widget.asset.symbol} '
        'sourceId=${widget.asset.sourceId} '
        'sourcePair=${widget.asset.sourcePair}');

    // Set up live exchange stream + fallback timer
    _setupLiveStream();

    // For live-rockets and new coins on exchanges, default to 5m timeframe and Candle mode
    if (_isLive) {
      _chartRange = '5m';
      _chartCandles.value = [];
      _loadingChart = true;
      _chartStyle.value = ChartStyle.candle;
    } else {
      _chartStyle.value = ChartStyle.line;
      // Show sparkline immediately if available (from CoinGecko cache)
      if (widget.asset.sparkline.isNotEmpty) {
        _chartCandles.value = _pricesToCandles(widget.asset.sparkline);
        _loadingChart = false;
      }
    }

    // Load chart and detail IN PARALLEL
    _loadChart();
    _loadDetail();

    // Publish full focus context for AI.
    ScreenContextService.instance.setFocusedToken(
      widget.asset.symbol.toUpperCase(),
      name: widget.asset.name,
      price: widget.asset.price,
      change24h: widget.asset.change24h,
      volume24h: widget.asset.volume,
      high24h: widget.asset.high24h,
      low24h: widget.asset.low24h,
      marketCap: widget.asset.marketCap,
      chartRange: _chartRange,
    );
  }

  // Resolved live source — may differ from widget.asset if auto-discovered.
  String _liveSourceId = '';
  String _liveSourcePair = '';

  void _setupLiveStream() {
    var src = widget.asset.sourceId;
    var pair = widget.asset.sourcePair;

    // ── Auto-discovery: if sourceId is empty or not a live exchange,
    //    scan MarketLiveEngine cache for a matching symbol. ──
    if (!const {'binance', 'mexc', 'gateio', 'okx'}.contains(src) ||
        pair.isEmpty) {
      final sym = widget.asset.symbol.toUpperCase();
      final candidates = [
        'binance:${sym}USDT',
        'mexc:${sym}USDT',
        'gateio:${sym}USDT',
        'gateio:${sym}_USDT',
        'okx:${sym}USDT',
        'okx:${sym}USDC',
      ];
      for (final k in candidates) {
        final t = MarketLiveEngine.instance.latestByKey(k);
        if (t != null && t.lastPrice > 0) {
          final colon = k.indexOf(':');
          src = k.substring(0, colon);
          pair = k.substring(colon + 1);
          _log.i('Auto-discovered live source: src=$src pair=$pair '
              'for symbol=$sym');
          break;
        }
      }
    }

    _liveSourceId = src;
    _liveSourcePair = pair;

    if (!const {'binance', 'mexc', 'gateio', 'okx'}.contains(src) ||
        pair.isEmpty) {
      _log.d('No live source for ${widget.asset.symbol} '
          '(src=$src pair=$pair) — static mode');
      return;
    }

    _log.i('Live stream via MarketLiveEngine: src=$src pair=$pair');

    // ── Store notifier reference — never re-query in dispose. ──
    _engineNotifier = MarketLiveEngine.instance.notifierFor(src, pair);
    _engineNotifier!.addListener(_onEngineNotify);

    // ── Frame 0: read notifier initial value. ──
    final initial = _engineNotifier!.value;
    if (initial != null) {
      _applyTickSingle(initial);
      _log.i('Notifier initial value price=${initial.lastPrice}');
    } else {
      _log.d('Notifier initial value=null (no tick yet for $src:$pair)');
    }
  }

  void _onEngineNotify() {
    if (!mounted) return;
    final t = _engineNotifier?.value;
    if (t == null) return;
    _applyTickSingle(t);
  }

  void _applyTickSingle(LiveTicker t) {
    if (t.lastPrice <= 0) return;

    final prev = _liveTicker.value;
    if (prev?.lastPrice == t.lastPrice &&
        prev?.priceChangePercent24h == t.priceChangePercent24h &&
        prev?.highPrice24h == t.highPrice24h &&
        prev?.lowPrice24h == t.lowPrice24h &&
        prev?.quoteVolume24h == t.quoteVolume24h) {
      return; // No change — skip
    }

    // Update ValueNotifiers — only header/metrics rebuild, NOT the page.
    _liveTicker.value = t;
    _tickNonce.value++;

    // Live Chart update (stretches the latest candle / appends a new one)
    _updateLiveCandle(t);

    // Audit: only first 3 ticks
    if (_tickNonce.value <= 3) {
      _log.i('[TokenDetailUI] applied $_liveSourceId:$_liveSourcePair '
          'price=${t.lastPrice} '
          'change=${t.priceChangePercent24h} '
          'tick=${_tickNonce.value}');
    }

    // Keep AI context in sync — throttled to 1s max.
    final now = DateTime.now();
    if (now.difference(_lastContextPush) >= _contextThrottle) {
      _lastContextPush = now;
      ScreenContextService.instance.setFocusedToken(
        widget.asset.symbol.toUpperCase(),
        name: widget.asset.name,
        price: t.lastPrice,
        change24h: t.priceChangePercent24h,
        volume24h: t.quoteVolume24h,
        high24h: t.highPrice24h,
        low24h: t.lowPrice24h,
        marketCap: widget.asset.marketCap,
        chartRange: _chartRange,
      );
    }
  }

  @override
  void dispose() {
    // Remove engine listener via stored reference — no notifierFor() call.
    _engineNotifier?.removeListener(_onEngineNotify);
    _engineNotifier = null;
    _priceTimer?.cancel();
    _liveTicker.dispose();
    _tickNonce.dispose();
    _chartCandles.dispose();
    _chartStyle.dispose();
    ScreenContextService.instance.clearFocusedToken(
      symbol: widget.asset.symbol.toUpperCase(),
    );
    super.dispose();
  }

  Future<void> _loadDetail() async {
    // Skip CoinGecko fetch for exchange-only assets (no valid CG id).
    // These assets have sourceId=binance/mexc but id is either empty or
    // a synthetic placeholder that will 404 on CoinGecko.
    if (asset.id.isEmpty) return;
    if (_isLive &&
        !asset.id.contains('-') &&
        asset.id == asset.symbol.toLowerCase()) {
      // id == symbol means it was auto-generated, not a real CoinGecko id.
      _log.d('Skipping CoinGecko detail for exchange-only asset: ${asset.id}');
      return;
    }
    try {
      final detail = await MarketDataService.instance.fetchDetail(asset.id);
      if (mounted) {
        setState(() {
          _detail = detail;
        });
        // Sync enriched data to AI context.
        // IMPORTANT: if live exchange data is flowing, do NOT overwrite
        // price/change/volume/high/low with stale widget.asset values.
        // Detail only supplements: description, venues, marketCap fallback.
        final lt = _liveTicker.value;
        final hasLive = lt != null;
        ScreenContextService.instance.setFocusedToken(
          widget.asset.symbol.toUpperCase(),
          name: widget.asset.name,
          price: hasLive ? lt.lastPrice : asset.price,
          change24h: hasLive ? lt.priceChangePercent24h : asset.change24h,
          volume24h: hasLive
              ? lt.quoteVolume24h
              : (widget.asset.volume > 0
                  ? widget.asset.volume
                  : detail.totalVolume),
          high24h: hasLive
              ? lt.highPrice24h
              : (widget.asset.high24h > 0
                  ? widget.asset.high24h
                  : detail.high24h),
          low24h: hasLive
              ? lt.lowPrice24h
              : (widget.asset.low24h > 0 ? widget.asset.low24h : detail.low24h),
          marketCap: widget.asset.marketCap > 0
              ? widget.asset.marketCap
              : detail.marketCap,
          chartRange: _chartRange,
        );
      }
    } catch (e) {
      _log.w('Detail load failed for ${asset.id}', e);
    }
  }

  Future<void> _loadChart() async {
    // Don't show loading spinner if we already have sparkline data
    if (_chartCandles.value.isEmpty && mounted) {
      setState(() => _loadingChart = true);
    }

    final nonce = ++_chartRequestNonce;

    // ── Strategy 1: Exchange klines (Binance/MEXC/Gate/OKX) — fast, no rate limits ──
    try {
      _log.i(
          '[Chart] source=$_liveSourceId pair=$_liveSourcePair');
      final exchangeCandles = await ExchangeChartService.instance.fetchCandles(
          asset.symbol,
          rangeKey: _chartRange,
          sourceId: _liveSourceId,
          sourcePair: _liveSourcePair);
      if (nonce != _chartRequestNonce) return; // Request race protection
      if (mounted && exchangeCandles.length >= 2) {
        _chartCandles.value = exchangeCandles;
        setState(() {
          _loadingChart = false;
        });
        return; // Done — exchange data is best
      }
    } catch (e) {
      _log.w('Exchange chart failed for ${asset.symbol}', e);
    }

    if (_isLive) {
      if (nonce == _chartRequestNonce && mounted) {
        _chartCandles.value = [];
        setState(() {
          _loadingChart = false;
        });
      }
      return;
    }

    // ── Strategy 2: CoinGecko chart API (fallback) ────────────────────────
    if (asset.id.isNotEmpty) {
      try {
        final cgPrices = await MarketDataService.instance.fetchChart(
          asset.id,
          rangeKey: _chartRange,
        );
        if (nonce != _chartRequestNonce) return; // Request race protection
        if (mounted && cgPrices.length >= 2) {
          _chartCandles.value = _pricesToCandles(cgPrices);
          setState(() {
            _loadingChart = false;
          });
          return;
        }
      } catch (e) {
        _log.w('CoinGecko chart failed for ${asset.id}', e);
      }
    }

    // ── Strategy 3: Use sparkline from MarketAsset cache ──────────────────
    if (nonce == _chartRequestNonce && mounted) {
      setState(() {
        if (_chartRange == '7d' || _chartRange == '7D') {
          _chartCandles.value = _pricesToCandles(widget.asset.sparkline);
        } else {
          _chartCandles.value = [];
        }
        _loadingChart = false;
      });
    }
  }

  void _onRangeChanged(String range) {
    setState(() {
      _chartRange = range;
      _loadingChart = true;
    });
    _chartCandles.value = [];
    ScreenContextService.instance.setFocusedChartRange(range);
    _loadChart();
  }

  List<Candle> _pricesToCandles(List<double> prices) {
    if (prices.isEmpty) return [];
    final now = DateTime.now().toUtc();
    return List.generate(prices.length, (i) {
      final p = prices[i];
      return Candle(
        time: now.subtract(Duration(hours: prices.length - i)),
        open: p,
        high: p,
        low: p,
        close: p,
        volume: 0.0,
      );
    });
  }

  void _updateLiveCandle(LiveTicker t) {
    final list = List<Candle>.from(_chartCandles.value);
    if (list.isEmpty) return;

    final last = list.last;
    final now = DateTime.now().toUtc();
    final duration = _getCandleIntervalDuration(_chartRange);
    final bucketTime = _roundToBucket(now, duration);

    if (bucketTime.isAfter(last.time)) {
      final newCandle = Candle(
        time: bucketTime,
        open: t.lastPrice,
        high: t.lastPrice,
        low: t.lastPrice,
        close: t.lastPrice,
        volume: 0.0,
      );
      list.add(newCandle);
      _log.d('[LiveChart] Opened new candle at $bucketTime');
    } else {
      list[list.length - 1] = Candle(
        time: last.time,
        open: last.open,
        high: max(last.high, t.lastPrice),
        low: min(last.low, t.lastPrice),
        close: t.lastPrice,
        volume: last.volume,
      );
    }
    _chartCandles.value = list;
  }

  DateTime _roundToBucket(DateTime time, Duration duration) {
    final ms = time.millisecondsSinceEpoch;
    final durMs = duration.inMilliseconds;
    if (durMs <= 0) return time;
    final roundedMs = (ms ~/ durMs) * durMs;
    return DateTime.fromMillisecondsSinceEpoch(roundedMs, isUtc: true);
  }

  Duration _getCandleIntervalDuration(String rangeKey) {
    switch (rangeKey) {
      case '1m':
        return const Duration(minutes: 1);
      case '5m':
        return const Duration(minutes: 5);
      case '15m':
        return const Duration(minutes: 15);
      case '30m':
        return const Duration(minutes: 30);
      case '1h':
        return const Duration(hours: 1);
      case '24h':
      case '24H':
        return const Duration(minutes: 15);
      case '7d':
      case '7D':
        return const Duration(hours: 1);
      case '1mth':
      case '1M':
        return const Duration(hours: 4);
      case '3mth':
      case '3M':
        return const Duration(days: 1);
      default:
        return const Duration(hours: 1);
    }
  }

  void _showPriceAlertSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PriceAlertSheet(asset: asset),
    );
  }

  void _showTpSlSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TpSlSheet(asset: asset),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = LocalizationService.instance;
    final watchlist = WatchlistService.instance;

    return Scaffold(
      backgroundColor: const Color(0xFF05070B),
      body: ListenableBuilder(
        listenable:
            Listenable.merge([watchlist, MarketPriceAlertService.instance]),
        builder: (context, _) {
          final isFavNow = watchlist.isFavoriteAny(asset.id, asset.symbol);
          final hasAlert =
              MarketPriceAlertService.instance.hasAlerts(asset.symbol);
          final isUp = asset.change24h >= 0;
          return CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              // ── App Bar ──────────────────────────────────────────────────
              SliverAppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                pinned: true,
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new_rounded,
                      color: Colors.white, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (asset.imageUrl.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ClipOval(
                          child: Image.network(
                            asset.imageUrl,
                            width: 24,
                            height: 24,
                            errorBuilder: (_, __, ___) =>
                                _SymbolIcon(symbol: asset.symbol, size: 24),
                          ),
                        ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _SymbolIcon(symbol: asset.symbol, size: 24),
                      ),
                    Text(
                      asset.symbol,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                centerTitle: true,
                actions: [
                  // ── Bell: border = trend color, yellow when alert active ──
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: GestureDetector(
                      onTap: () => _showPriceAlertSheet(context),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: hasAlert
                                ? const Color(0xFFFFD700) // yellow when active
                                : isUp
                                    ? const Color(
                                        0xFF00C853) // green when rising
                                    : const Color(
                                        0xFFFF1744), // red when falling
                            width: 1.5,
                          ),
                          color: (hasAlert
                                  ? const Color(0xFFFFD700)
                                  : isUp
                                      ? const Color(0xFF00C853)
                                      : const Color(0xFFFF1744))
                              .withValues(alpha: 0.08),
                        ),
                        child: Icon(
                          hasAlert
                              ? Icons.notifications_active_rounded
                              : Icons.notifications_none_rounded,
                          color: hasAlert
                              ? const Color(0xFFFFD700)
                              : isUp
                                  ? const Color(0xFF00C853)
                                  : const Color(0xFFFF1744),
                          size: 18,
                        ),
                      ),
                    ),
                  ),

                  // ── Star: border = trend color, gold when watchlisted ──
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () =>
                          watchlist.toggleSmart(asset.id, asset.symbol),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isFavNow
                                ? const Color(0xFFFFD700) // gold when saved
                                : isUp
                                    ? const Color(
                                        0xFF00C853) // green when rising
                                    : const Color(
                                        0xFFFF1744), // red when falling
                            width: 1.5,
                          ),
                          color: (isFavNow
                                  ? const Color(0xFFFFD700)
                                  : isUp
                                      ? const Color(0xFF00C853)
                                      : const Color(0xFFFF1744))
                              .withValues(alpha: 0.08),
                        ),
                        child: Icon(
                          isFavNow
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          color: isFavNow
                              ? const Color(0xFFFFD700)
                              : isUp
                                  ? const Color(0xFF00C853)
                                  : const Color(0xFFFF1744),
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              // ── Price header (rebuilds ONLY on tick, not the page) ────────
              SliverToBoxAdapter(
                child: _LivePriceHeader(
                  baseAsset: widget.asset,
                  liveTicker: _liveTicker,
                  tickNonce: _tickNonce,
                  isLive: _isLive,
                  buildSourceBadge: _buildSourceBadge,
                ),
              ),

              // ── Chart ────────────────────────────────────────────────────
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      // Chart area
                      _loadingChart
                          ? SizedBox(
                              height: 180,
                              child: Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: GuardianColors.accent
                                      .withValues(alpha: 0.5),
                                ),
                              ),
                            )
                          : ValueListenableBuilder<List<Candle>>(
                              valueListenable: _chartCandles,
                              builder: (context, candles, _) {
                                return ValueListenableBuilder<ChartStyle>(
                                  valueListenable: _chartStyle,
                                  builder: (context, style, _) {
                                    return CandleChart(
                                      candles: candles,
                                      height: 180,
                                      style: style,
                                      showMinMax: true,
                                      enableTouch: true,
                                    );
                                  },
                                );
                              },
                            ),
                      const SizedBox(height: 12),

                      // Range selector and Style Toggle
                      Row(
                        children: [
                          Expanded(
                            child: _ChartRangeSelector(
                              selected: _chartRange,
                              onChanged: _onRangeChanged,
                            ),
                          ),
                          const SizedBox(width: 8),
                          ValueListenableBuilder<ChartStyle>(
                            valueListenable: _chartStyle,
                            builder: (context, style, _) {
                              final isCandle = style == ChartStyle.candle;
                              return GestureDetector(
                                onTap: () {
                                  _chartStyle.value = isCandle
                                      ? ChartStyle.line
                                      : ChartStyle.candle;
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  margin: const EdgeInsets.only(right: 12),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.04),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: Colors.white.withValues(alpha: 0.08),
                                    ),
                                  ),
                                  child: Icon(
                                    isCandle
                                        ? Icons.candlestick_chart_rounded
                                        : Icons.show_chart_rounded,
                                    color: GuardianColors.accent,
                                    size: 18,
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),

              // ── Action buttons ───────────────────────────────────────────
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      Expanded(
                        child: _ActionButton(
                          label: l.t('marketBtnBuy', {'default': 'Buy'}),
                          icon: Icons.arrow_downward_rounded,
                          color: const Color(0xFF00C853),
                          onTap: () => _openTrade(context, isBuy: true),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _ActionButton(
                          label: l.t('marketBtnSell', {'default': 'Sell'}),
                          icon: Icons.arrow_upward_rounded,
                          color: const Color(0xFFFF1744),
                          onTap: () => _openTrade(context, isBuy: false),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ── TP / SL automation triggers ───────────────────────────────
              SliverToBoxAdapter(
                child: ListenableBuilder(
                  listenable: AutomationEngine.instance,
                  builder: (context, _) {
                    final sym = asset.symbol.toUpperCase();
                    final triggers = AutomationEngine.instance.triggers
                        .where((t) =>
                            t.assetSymbol.toUpperCase() == sym &&
                            (t.type == TriggerType.takeProfit ||
                             t.type == TriggerType.stopLoss))
                        .toList();

                    return Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.shield_outlined,
                                  size: 16, color: Color(0xFFFF9100)),
                              const SizedBox(width: 6),
                              const Text(
                                'TP / SL',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const Spacer(),
                              GestureDetector(
                                onTap: () => _showTpSlSheet(context),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFF9100)
                                        .withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: const Color(0xFFFF9100)
                                          .withValues(alpha: 0.3),
                                    ),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.add_rounded,
                                          size: 14, color: Color(0xFFFF9100)),
                                      SizedBox(width: 4),
                                      Text(
                                        'Add',
                                        style: TextStyle(
                                          color: Color(0xFFFF9100),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (triggers.isEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Text(
                                'No TP/SL set. Tap + to add.',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.3),
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          if (triggers.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            ...triggers.map((t) => Dismissible(
                                  key: ValueKey(t.id),
                                  direction: DismissDirection.endToStart,
                                  onDismissed: (_) => AutomationEngine
                                      .instance
                                      .removeTrigger(t.id),
                                  background: Container(
                                    alignment: Alignment.centerRight,
                                    padding: const EdgeInsets.only(right: 16),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFF1744)
                                          .withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: const Icon(Icons.delete_rounded,
                                        color: Color(0xFFFF1744), size: 20),
                                  ),
                                  child: Container(
                                    margin: const EdgeInsets.only(bottom: 6),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 14, vertical: 10),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.04),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          t.type == TriggerType.takeProfit
                                              ? Icons.trending_up_rounded
                                              : Icons.trending_down_rounded,
                                          color: t.type == TriggerType.takeProfit
                                              ? const Color(0xFF00C853)
                                              : const Color(0xFFFF1744),
                                          size: 18,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            t.conditionDescription,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          '← swipe',
                                          style: TextStyle(
                                            color: Colors.white
                                                .withValues(alpha: 0.25),
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                )),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),

              // ── Market metrics ───────────────────────────────────────────
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.t('marketMetrics', {'default': 'Market Stats'}),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Metrics rebuild only on tick, not on page setState
                      ValueListenableBuilder<LiveTicker?>(
                        valueListenable: _liveTicker,
                        builder: (context, ticker, _) {
                          return _MetricsGrid(asset: asset, detail: _detail);
                        },
                      ),
                    ],
                  ),
                ),
              ),

              // ── Exchanges / Venues ───────────────────────────────────────
              if (_detail != null && _detail!.venues.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.t('marketVenues', {'default': 'Available on'}),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _detail!.venues
                              .map((v) => _VenueChip(name: v))
                              .toList(),
                        ),
                      ],
                    ),
                  ),
                ),

              // ── Description ──────────────────────────────────────────────
              if (_detail != null && _detail!.description.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.t('marketAbout', {'default': 'About'}),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _detail!.description.length > 500
                              ? '${_detail!.description.substring(0, 500)}...'
                              : _detail!.description,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 13,
                            height: 1.6,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // ── Bottom padding ───────────────────────────────────────────
              const SliverToBoxAdapter(child: SizedBox(height: 48)),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openTrade(BuildContext context, {required bool isBuy}) async {
    var src = _liveSourceId.isNotEmpty ? _liveSourceId.toLowerCase() : asset.sourceId.toLowerCase();
    if (src == 'gate.io') src = 'gateio';
    if (['mexc', 'binance', 'gateio', 'okx'].contains(src)) {
      final isConnected = await ExchangeAccountStore.instance.isConnected(src);

      if (!isConnected) {
        if (mounted) {
          ConnectExchangeModal.show(
            context,
            exchangeId: src,
            onConnected: () => _openTrade(context, isBuy: isBuy),
          );
        }
      } else {
        final settings = AiControlService.instance.settings;
        final displayName = src == 'gateio' ? 'Gate.io' : (src == 'mexc' ? 'MEXC' : (src == 'binance' ? 'Binance' : 'OKX'));
        
        if (!settings.activeSources.contains(src)) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('$displayName Spot выключен в Policy. Включите $displayName Spot как источник торговли.'),
              backgroundColor: Colors.redAccent,
            ));
          }
          return;
        }

        String quoteAsset = 'USDT';
        if (src == 'okx') {
          final base = asset.symbol.replaceAll('USDT', '').replaceAll('USDC', '').replaceAll('EUR', '').replaceAll('-', '').replaceAll('/', '').toUpperCase();
          final region = await ExchangeAccountStore.instance.getOkxRegion() ?? 'global';
          final bestPair = await OkxExchangeService.instance.findBestPair(base, region);
          if (bestPair == null) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('Пара ${asset.symbol.toUpperCase()} недоступна для торговли на вашем аккаунте OKX (ограничение региона).'),
                backgroundColor: Colors.redAccent,
              ));
            }
            return;
          }
          quoteAsset = bestPair.split('-')[1];
        }

        if (mounted) {
          CexSpotTradeModal.show(
            context,
            asset: asset,
            isBuy: isBuy,
          );
        }
      }
      return;
    }

    final chainKey = WalletAdapter.instance.chainKey;
    final portfolio = VaultPortfolioListener.instance.summary;
    final match = portfolio?.allAssets
        .where((a) => a.symbol.toLowerCase() == asset.symbol.toLowerCase() && a.chainKey == chainKey)
        .firstOrNull;

    int fallbackChainId;
    try {
      fallbackChainId = WalletAdapter.instance.chainId;
    } on StateError {
      fallbackChainId = 56; // BSC default for swap context
    }

    final targetAsset = match ??
        WalletAsset(
          name: asset.name,
          symbol: asset.symbol,
          address: '',
          balance: 0,
          priceUsd: asset.price,
          valueUsd: 0,
          decimals: 18,
          chainId: fallbackChainId,
        );

    WalletTradeModal.show(context, marketAsset: targetAsset, isBuy: isBuy);
  }

  static String _formatPrice(double p) => PriceFormatter.price(p);

  /// Whether the LIVE pulsing dot should be visible.
  bool get _isLiveDotVisible => _isLive && _liveTicker.value != null;

  /// Builds a small source badge: "LIVE" (green) or "CoinGecko" (dim).
  Widget _buildSourceBadge() {
    if (_isLive && _liveTicker.value != null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFF00C853).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: const Color(0xFF00C853).withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: const BoxDecoration(
                color: Color(0xFF00C853),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              'LIVE · ${_liveSourceId.toUpperCase()}',
              style: const TextStyle(
                color: Color(0xFF00C853),
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      );
    }
    // Non-live: CoinGecko badge
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        widget.asset.sourceId.isNotEmpty
            ? widget.asset.sourceId.toUpperCase()
            : 'COINGECKO',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.35),
          fontSize: 9,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ─── Live Price Header ────────────────────────────────────────────────────────
//
// Only THIS widget rebuilds on each tick (via ValueListenableBuilder).
// The parent page's build() is NOT called for live ticks.
// ──────────────────────────────────────────────────────────────────────────────

class _LivePriceHeader extends StatelessWidget {
  final MarketAsset baseAsset;
  final ValueNotifier<LiveTicker?> liveTicker;
  final ValueNotifier<int> tickNonce;
  final bool isLive;
  final Widget Function() buildSourceBadge;

  const _LivePriceHeader({
    required this.baseAsset,
    required this.liveTicker,
    required this.tickNonce,
    required this.isLive,
    required this.buildSourceBadge,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Token name + source badge (static, rarely changes)
          Row(
            children: [
              Expanded(
                child: Text(
                  baseAsset.name,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              // Source badge also listens for first tick to switch from CoinGecko→LIVE
              ValueListenableBuilder<int>(
                valueListenable: tickNonce,
                builder: (_, __, ___) => buildSourceBadge(),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Price + change — rebuilds only here, not the page
          ValueListenableBuilder<LiveTicker?>(
            valueListenable: liveTicker,
            builder: (context, ticker, _) {
              final price = ticker?.lastPrice ?? baseAsset.price;
              final change =
                  ticker?.priceChangePercent24h ?? baseAsset.change24h;
              final isUp = change >= 0;
              final changeColor =
                  isUp ? const Color(0xFF00C853) : const Color(0xFFFF1744);

              return RepaintBoundary(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // LIVE pulsing dot
                    if (isLive && ticker != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 6, bottom: 8),
                        child: _LiveDot(color: changeColor),
                      ),
                    // Price — always white
                    Flexible(
                      child: Text(
                        '\$${PriceFormatter.price(price)}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 36,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Change — clean text (like Binance)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        PriceFormatter.percentLive(change),
                        style: TextStyle(
                          color: changeColor,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ─── Live Pulsing Dot ──────────────────────────────────────────────────────────

class _LiveDot extends StatefulWidget {
  final Color color;
  const _LiveDot({required this.color});

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _opacity = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: 0.5),
              blurRadius: 6,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Chart Range Selector ──────────────────────────────────────────────────────

class _ChartRangeSelector extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onChanged;

  const _ChartRangeSelector({
    required this.selected,
    required this.onChanged,
  });

  static const _ranges = [
    '1m',
    '5m',
    '15m',
    '30m',
    '1h',
    '24h',
    '7d',
    '1mth',
    '3mth',
  ];

  String _rangeLabel(BuildContext context, String range) {
    final locale = context
        .dependOnInheritedWidgetOfExactType<LocalizationProvider>()
        ?.locale
        .languageCode;
    final isCyrillic = locale == 'ru' || locale == 'uk';
    if (isCyrillic) {
      return switch (range) {
        '1m' => '1м',
        '5m' => '5м',
        '15m' => '15м',
        '30m' => '30м',
        '1h' => '1ч',
        '24h' => '24ч',
        '7d' => '7д',
        '1mth' => '1мес',
        '3mth' => '3мес',
        _ => range,
      };
    } else {
      return switch (range) {
        '1m' => '1m',
        '5m' => '5m',
        '15m' => '15m',
        '30m' => '30m',
        '1h' => '1h',
        '24h' => '24h',
        '7d' => '7d',
        '1mth' => '1mth',
        '3mth' => '3mth',
        _ => range,
      };
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: _ranges.map((r) {
            final active = selected == r;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: GestureDetector(
                onTap: () => onChanged(r),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: active
                        ? GuardianColors.accent.withValues(alpha: 0.15)
                        : Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: active
                          ? GuardianColors.accent
                          : Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Text(
                    _rangeLabel(context, r),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      color: active
                          ? GuardianColors.accent
                          : Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

// ─── Metrics Grid ──────────────────────────────────────────────────────────────

class _MetricsGrid extends StatelessWidget {
  final MarketAsset asset;
  final MarketAssetDetail? detail;

  const _MetricsGrid({required this.asset, this.detail});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        children: [
          _MetricRow(
            label: 'Market Cap',
            value: _fmtLarge(asset.marketCap > 0
                ? asset.marketCap
                : (detail?.marketCap ?? 0)),
          ),
          _divider,
          _MetricRow(
            label: '24h Volume',
            value: _fmtLarge(
                asset.volume > 0 ? asset.volume : (detail?.totalVolume ?? 0)),
          ),
          _divider,
          _MetricRow(
            label: '24h High',
            value:
                '\$${_fmtPrice(asset.high24h > 0 ? asset.high24h : (detail?.high24h ?? 0))}',
          ),
          _divider,
          _MetricRow(
            label: '24h Low',
            value:
                '\$${_fmtPrice(asset.low24h > 0 ? asset.low24h : (detail?.low24h ?? 0))}',
          ),
          if (detail != null && detail!.ath > 0) ...[
            _divider,
            _MetricRow(
              label: 'All-Time High',
              value: '\$${_fmtPrice(detail!.ath)}',
            ),
          ],
          if (detail != null && detail!.circulatingSupply > 0) ...[
            _divider,
            _MetricRow(
              label: 'Circulating Supply',
              value: _fmtLarge(detail!.circulatingSupply),
            ),
          ],
          if (asset.change7d != 0) ...[
            _divider,
            _MetricRow(
              label: '7d Change',
              value:
                  '${asset.change7d >= 0 ? '+' : ''}${asset.change7d.toStringAsFixed(2)}%',
              valueColor: asset.change7d >= 0
                  ? const Color(0xFF00C853)
                  : const Color(0xFFFF1744),
            ),
          ],
          if (asset.change30d != 0) ...[
            _divider,
            _MetricRow(
              label: '30d Change',
              value:
                  '${asset.change30d >= 0 ? '+' : ''}${asset.change30d.toStringAsFixed(2)}%',
              valueColor: asset.change30d >= 0
                  ? const Color(0xFF00C853)
                  : const Color(0xFFFF1744),
            ),
          ],
          if (asset.rank > 0) ...[
            _divider,
            _MetricRow(label: 'Rank', value: '#${asset.rank}'),
          ],
        ],
      ),
    );
  }

  static Widget get _divider => Divider(
        color: Colors.white.withValues(alpha: 0.05),
        height: 20,
      );

  static String _fmtPrice(double p) => PriceFormatter.price(p);

  static String _fmtLarge(double v) => PriceFormatter.large(v);
}

// ─── Metric Row ────────────────────────────────────────────────────────────────

class _MetricRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _MetricRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.45),
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const Spacer(),
        Flexible(
          child: Text(
            value,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: valueColor ?? Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Action Button ─────────────────────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Symbol Icon fallback ──────────────────────────────────────────────────────

class _SymbolIcon extends StatelessWidget {
  final String symbol;
  final double size;
  const _SymbolIcon({required this.symbol, this.size = 24});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: GuardianColors.accent.withValues(alpha: 0.15),
      ),
      child: Center(
        child: Text(
          symbol.isNotEmpty ? symbol[0] : '?',
          style: TextStyle(
            color: GuardianColors.accent,
            fontSize: size * 0.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

// ─── Venue Chip ────────────────────────────────────────────────────────────────

class _VenueChip extends StatelessWidget {
  final String name;
  const _VenueChip({required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Text(
        name,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.6),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ─── Price Alert Bottom Sheet ──────────────────────────────────────────────────

// ─── TP / SL Bottom Sheet ──────────────────────────────────────────────────────

class _TpSlSheet extends StatefulWidget {
  final MarketAsset asset;
  const _TpSlSheet({required this.asset});

  @override
  State<_TpSlSheet> createState() => _TpSlSheetState();
}

class _TpSlSheetState extends State<_TpSlSheet> {
  final _pctController = TextEditingController(text: '10');
  bool _isTakeProfit = true;

  MarketAsset get asset => widget.asset;

  double? get _pct => double.tryParse(_pctController.text);

  double? get _targetPrice {
    final p = _pct;
    if (p == null || p <= 0) return null;
    return _isTakeProfit
        ? asset.price * (1 + p / 100)
        : asset.price * (1 - p / 100);
  }

  @override
  void dispose() {
    _pctController.dispose();
    super.dispose();
  }

  void _addTrigger() {
    final pct = _pct;
    if (pct == null || pct <= 0) return;

    AutomationEngine.instance.addTrigger(
      assetSymbol: asset.symbol.toUpperCase(),
      type: _isTakeProfit ? TriggerType.takeProfit : TriggerType.stopLoss,
      requestedAction: TriggerAction.notifyOnly,
      thresholdPct: pct,
      entryPriceUsd: asset.price,
      label: _isTakeProfit
          ? '${asset.symbol.toUpperCase()} TP +${pct.toStringAsFixed(1)}%'
          : '${asset.symbol.toUpperCase()} SL -${pct.toStringAsFixed(1)}%',
    );

    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = LocalizationService.instance;
    final bottomPad = MediaQuery.of(context).viewInsets.bottom +
        MediaQuery.of(context).padding.bottom;

    return SingleChildScrollView(
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0D1117),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.fromLTRB(20, 0, 20, bottomPad + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Icon(Icons.shield_outlined,
                    size: 20, color: Color(0xFFFF9100)),
                const SizedBox(width: 8),
                Text(
                  l.t('tpSlTitle'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l.t('tpSlEntry', {'price': '\$${PriceFormatter.price(asset.price)}'}),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(height: 16),
            // ── TP / SL toggle ──
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _isTakeProfit = true),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: _isTakeProfit
                            ? const Color(0xFF00C853)
                                .withValues(alpha: 0.15)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: _isTakeProfit
                                ? const Color(0xFF00C853)
                                : Colors.white.withValues(alpha: 0.1)),
                      ),
                      child: Center(
                          child: Text(l.t('tpSlTakeProfit'),
                              style: TextStyle(
                                color: _isTakeProfit
                                    ? const Color(0xFF00C853)
                                    : Colors.white.withValues(alpha: 0.4),
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ))),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _isTakeProfit = false),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: !_isTakeProfit
                            ? const Color(0xFFFF1744)
                                .withValues(alpha: 0.15)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: !_isTakeProfit
                                ? const Color(0xFFFF1744)
                                : Colors.white.withValues(alpha: 0.1)),
                      ),
                      child: Center(
                          child: Text(l.t('tpSlStopLoss'),
                              style: TextStyle(
                                color: !_isTakeProfit
                                    ? const Color(0xFFFF1744)
                                    : Colors.white.withValues(alpha: 0.4),
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ))),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // ── Quick % buttons ──
            Row(
              children: [5, 10, 20, 50].map((v) {
                final isSelected = _pct != null && _pct!.round() == v;
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: v == 50 ? 0 : 8),
                    child: GestureDetector(
                      onTap: () => setState(() {
                        _pctController.text = v.toString();
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? const Color(0xFFFF9100).withValues(alpha: 0.15)
                              : Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isSelected
                                ? const Color(0xFFFF9100).withValues(alpha: 0.4)
                                : Colors.white.withValues(alpha: 0.08),
                          ),
                        ),
                        child: Center(
                          child: Text(
                            '$v%',
                            style: TextStyle(
                              color: isSelected
                                  ? const Color(0xFFFF9100)
                                  : Colors.white.withValues(alpha: 0.5),
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 14),
            // ── Custom % input ──
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
                border:
                    Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Text('%',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 18,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _pctController,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600),
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: '10',
                          hintStyle: TextStyle(color: Color(0x40FFFFFF))),
                    ),
                  ),
                  if (_targetPrice != null)
                    Text(
                      '→ \$${PriceFormatter.price(_targetPrice!)}',
                      style: TextStyle(
                        color: _isTakeProfit
                            ? const Color(0xFF00C853)
                            : const Color(0xFFFF1744),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: (_pct != null && _pct! > 0) ? _addTrigger : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isTakeProfit
                      ? const Color(0xFF00C853)
                      : const Color(0xFFFF1744),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.white.withValues(alpha: 0.1),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(
                  _isTakeProfit ? l.t('tpSlSetTakeProfit') : l.t('tpSlSetStopLoss'),
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _PriceAlertSheet extends StatefulWidget {
  final MarketAsset asset;
  const _PriceAlertSheet({required this.asset});

  @override
  State<_PriceAlertSheet> createState() => _PriceAlertSheetState();
}

class _PriceAlertSheetState extends State<_PriceAlertSheet> {
  final _priceController = TextEditingController();
  bool _isAbove = true;

  MarketAsset get asset => widget.asset;

  @override
  void initState() {
    super.initState();
    _priceController.text = asset.price.toStringAsFixed(
      asset.price < 1 ? 6 : 2,
    );
  }

  @override
  void dispose() {
    _priceController.dispose();
    super.dispose();
  }

  void _setAlert() {
    final price = double.tryParse(_priceController.text);
    if (price == null || price <= 0) return;

    MarketPriceAlertService.instance.upsertAlert(
      MarketPriceAlert(
        symbol: asset.symbol,
        assetId: asset.id,
        targetPrice: price,
        isAbove: _isAbove,
        createdAt: DateTime.now(),
      ),
    );

    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = LocalizationService.instance;
    return ListenableBuilder(
      listenable: MarketPriceAlertService.instance,
      builder: (context, _) {
        final alerts = MarketPriceAlertService.instance.alertsFor(asset.symbol);
        final bottomPad = MediaQuery.of(context).viewInsets.bottom +
            MediaQuery.of(context).padding.bottom;

        return SingleChildScrollView(
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xFF0D1117),
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            padding: EdgeInsets.fromLTRB(20, 0, 20, bottomPad + 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Icon(Icons.notifications_active_rounded,
                        size: 20, color: Color(0xFFFFD700)),
                    const SizedBox(width: 8),
                    Text(
                      l.t('priceAlertTitle'),
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l.t('priceAlertCurrent', {'price': '\$${_formatPrice(asset.price)}'}),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _isAbove = true),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: _isAbove
                                ? const Color(0xFF00C853)
                                    .withValues(alpha: 0.15)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: _isAbove
                                    ? const Color(0xFF00C853)
                                    : Colors.white.withValues(alpha: 0.1)),
                          ),
                          child: Center(
                              child: Text(l.t('priceAlertAbove'),
                                  style: TextStyle(
                                    color: _isAbove
                                        ? const Color(0xFF00C853)
                                        : Colors.white.withValues(alpha: 0.4),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ))),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _isAbove = false),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: !_isAbove
                                ? const Color(0xFFFF1744)
                                    .withValues(alpha: 0.15)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: !_isAbove
                                    ? const Color(0xFFFF1744)
                                    : Colors.white.withValues(alpha: 0.1)),
                          ),
                          child: Center(
                              child: Text(l.t('priceAlertBelow'),
                                  style: TextStyle(
                                    color: !_isAbove
                                        ? const Color(0xFFFF1744)
                                        : Colors.white.withValues(alpha: 0.4),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ))),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.1)),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      Text('\$',
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.4),
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _priceController,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600),
                          decoration: const InputDecoration(
                              border: InputBorder.none,
                              hintText: '0.00',
                              hintStyle: TextStyle(color: Color(0x40FFFFFF))),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _setAlert,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF9100),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(l.t('priceAlertSetAlert'),
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 16)),
                  ),
                ),
                if (alerts.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(l.t('priceAlertActiveAlerts'),
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(height: 8),
                  ...alerts.map((alert) => Dismissible(
                        key: ValueKey(alert.key),
                        direction: DismissDirection.endToStart,
                        onDismissed: (_) => MarketPriceAlertService.instance
                            .removeAlert(alert.symbol, alert.isAbove),
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 16),
                          decoration: BoxDecoration(
                              color: const Color(0xFFFF1744)
                                  .withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(10)),
                          child: const Icon(Icons.delete_rounded,
                              color: Color(0xFFFF1744), size: 20),
                        ),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(10)),
                          child: Row(
                            children: [
                              Icon(
                                  alert.isAbove
                                      ? Icons.trending_up_rounded
                                      : Icons.trending_down_rounded,
                                  color: alert.isAbove
                                      ? const Color(0xFF00C853)
                                      : const Color(0xFFFF1744),
                                  size: 18),
                              const SizedBox(width: 10),
                              Text(
                                  '${alert.isAbove ? l.t('priceAlertAbovePrice', {'price': '\$${_formatPrice(alert.targetPrice)}'}) : l.t('priceAlertBelowPrice', {'price': '\$${_formatPrice(alert.targetPrice)}'})}',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600)),
                              const Spacer(),
                              Text(l.t('priceAlertSwipeHint'),
                                  style: TextStyle(
                                      color:
                                          Colors.white.withValues(alpha: 0.25),
                                      fontSize: 11)),
                            ],
                          ),
                        ),
                      )),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _formatPrice(double p) => PriceFormatter.price(p);
}
