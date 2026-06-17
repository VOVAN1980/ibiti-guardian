import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_interface.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_registry.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/market/watchlist_service.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';
import 'package:ibiti_guardian/screens/market_command/market_token_detail_screen.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/utils/price_formatter.dart';

// ─── Exchange Terminal Screen ──────────────────────────────────────────────────
//
// Pro-grade live terminal. Performance rules:
//   1. Throttle UI rebuilds to max 4/sec (250ms) — not per-WS-tick
//   2. ListView.builder + itemExtent for instant scroll math
//   3. RepaintBoundary around price/change cells
//   4. Inline search filters from exchange's live tickers
// ─────────────────────────────────────────────────────────────────────────────────

class ExchangeTerminalScreen extends StatefulWidget {
  final ExchangeId exchangeId;

  const ExchangeTerminalScreen({super.key, required this.exchangeId});

  @override
  State<ExchangeTerminalScreen> createState() => _ExchangeTerminalScreenState();
}

class _ExchangeTerminalScreenState extends State<ExchangeTerminalScreen> {
  final _registry = ExchangeRegistry.instance;

  late ExchangeService _svc;

  // Active view tab
  TerminalView _view = TerminalView.fastGrowth;

  // Ticker list snapshot
  List<LiveTicker> _displayed = const [];
  StreamSubscription? _streamSub;
  Timer? _throttleTimer;
  bool _connecting = true;
  bool _dirty = false; // marks pending UI update

  // ── Search ──
  final _searchController = TextEditingController();
  bool _searchActive = false;
  List<LiveTicker> _searchResults = const [];

  @override
  void initState() {
    super.initState();
    _activateExchange();
    final exName = widget.exchangeId.name; // mexc, binance, gateio, okx
    ScreenContextService.instance.setExchange(exName);
    ScreenContextService.instance.setTerminalView(_view.name);
  }

  Future<void> _activateExchange() async {
    _svc = _registry.serviceFor(widget.exchangeId);

    if (!_svc.isConnected) {
      unawaited(_svc.connect());
    }

    setState(() => _connecting = false);
    _rebuildList(); // immediate first paint

    // ── Throttled stream listener ──
    // WS fires 10-50x/sec. We mark dirty and flush at 250ms intervals.
    _streamSub = _svc.tickerStream.listen((_) {
      _dirty = true;
    });

    _throttleTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      if (_dirty) {
        _dirty = false;
        _rebuildList();
      }
    });
  }

  void _rebuildList() {
    final list = switch (_view) {
      TerminalView.newListings => _svc.viewNewListings.take(30).toList(),
      TerminalView.fastGrowth => _svc.viewFastGrowth.take(30).toList(),
      TerminalView.memeTrend => _svc.viewMemeTrend.take(30).toList(),
      TerminalView.majors => _svc.viewMajors.toList(),
    };
    setState(() => _displayed = list);
  }

  // ── Search logic ──
  void _onSearchChanged(String query) {
    final q = query.trim().toUpperCase();
    if (q.isEmpty) {
      setState(() => _searchResults = const []);
      return;
    }
    // Filter from ALL exchange tickers (not just current view)
    final results = _svc.currentTickers
        .where((t) => t.baseAsset.contains(q) || t.symbol.contains(q))
        .toList()
      ..sort((a, b) {
        // Exact match first, then by volume
        final aExact = a.baseAsset == q ? 0 : 1;
        final bExact = b.baseAsset == q ? 0 : 1;
        if (aExact != bExact) return aExact.compareTo(bExact);
        return b.quoteVolume24h.compareTo(a.quoteVolume24h);
      });
    setState(() => _searchResults = results.take(20).toList());
  }

  void _openDetail(LiveTicker t) {
    final asset = MarketDataService.instance.resolveAssetFromTicker(
      symbol: t.baseAsset,
      price: t.lastPrice,
      change24h: t.priceChangePercent24h,
      volume: t.quoteVolume24h,
      high24h: t.highPrice24h,
      low24h: t.lowPrice24h,
      sourceId: widget.exchangeId.name,
      sourcePair: t.symbol,
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MarketTokenDetailScreen(asset: asset),
      ),
    );
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    _throttleTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _registry,
      builder: (context, _) {
        final showSearch = _searchActive;
        final hasSearchResults = _searchResults.isNotEmpty;

        return Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded,
                  color: Colors.white, size: 20),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Text(
              LocalizationService.instance
                  .t('terminalTitle', {'default': 'Exchange Terminal'}),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            centerTitle: true,
          ),
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Exchange selector tabs ──────────────────────────────
                _ExchangeTabBar(
                  selected: widget.exchangeId,
                  exchanges: _registry.availableExchanges,
                  onSelect: (id) {
                    Navigator.pushReplacement(
                      context,
                      PageRouteBuilder(
                        pageBuilder: (_, __, ___) =>
                            ExchangeTerminalScreen(exchangeId: id),
                        transitionDuration: const Duration(milliseconds: 200),
                        transitionsBuilder: (_, anim, __, child) =>
                            FadeTransition(opacity: anim, child: child),
                      ),
                    );
                  },
                ),

                // ── Status bar + search toggle ─────────────────────────
                _StatusBar(
                  svc: _svc,
                  onSearchTap: () {
                    setState(() {
                      _searchActive = !_searchActive;
                      if (!_searchActive) {
                        _searchController.clear();
                        _searchResults = const [];
                      }
                    });
                  },
                  searchActive: _searchActive,
                ),

                // ── Search bar ─────────────────────────────────────────
                if (showSearch)
                  _SearchBar(
                    controller: _searchController,
                    onChanged: _onSearchChanged,
                    onClose: () {
                      setState(() {
                        _searchActive = false;
                        _searchController.clear();
                        _searchResults = const [];
                      });
                    },
                  ),

                // ── Search results overlay ─────────────────────────────
                if (showSearch && hasSearchResults)
                  Expanded(
                    child: _SearchResultsList(
                      results: _searchResults,
                      exchangeId: widget.exchangeId,
                      onTap: _openDetail,
                    ),
                  )
                else ...[
                  // ── New listing banner ────────────────────────────────
                  if (_registry.recentNewListings.isNotEmpty)
                    _NewListingBanner(
                      events: _registry.recentNewListings
                          .where((e) =>
                              e.exchange == widget.exchangeId.displayName)
                          .take(3)
                          .toList(),
                    ),

                  // ── View toggle ──────────────────────────────────────
                  _ViewToggle(
                    selected: _view,
                    onChanged: (v) {
                      setState(() => _view = v);
                      ScreenContextService.instance.setTerminalView(v.name);
                      _rebuildList();
                    },
                  ),

                  // ── Live ticker list ─────────────────────────────────
                  Expanded(
                    child: _LiveTickerList(
                      tickers: _displayed,
                      exchangeId: widget.exchangeId,
                      isConnected: _svc.isConnected,
                      isConnecting: _connecting,
                      activeView: _view,
                      onTap: _openDetail,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─── Exchange Tab Bar ─────────────────────────────────────────────────────────

class _ExchangeTabBar extends StatelessWidget {
  final ExchangeId selected;
  final List<ExchangeId> exchanges;
  final ValueChanged<ExchangeId> onSelect;

  const _ExchangeTabBar({
    required this.selected,
    required this.exchanges,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...exchanges.map((id) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => onSelect(id),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: selected == id
                            ? GuardianColors.accent.withValues(alpha: 0.15)
                            : GuardianColors.surface,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: selected == id
                              ? GuardianColors.accent
                              : GuardianColors.border,
                          width: selected == id ? 1.5 : 1,
                        ),
                      ),
                      child: Text(
                        '${id.emoji} ${id.displayName}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: selected == id
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: selected == id
                              ? GuardianColors.accent
                              : GuardianColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                )),
          ],
        ),
      ),
    );
  }
}

// ─── Status Bar ───────────────────────────────────────────────────────────────

class _StatusBar extends StatelessWidget {
  final ExchangeService svc;
  final VoidCallback onSearchTap;
  final bool searchActive;

  const _StatusBar({
    required this.svc,
    required this.onSearchTap,
    this.searchActive = false,
  });

  @override
  Widget build(BuildContext context) {
    final connected = svc.isConnected;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          // Status dot
          AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color:
                  connected ? const Color(0xFF00C853) : const Color(0xFFFF9800),
              boxShadow: connected
                  ? [
                      BoxShadow(
                        color: const Color(0xFF00C853).withValues(alpha: 0.6),
                        blurRadius: 6,
                        spreadRadius: 2,
                      )
                    ]
                  : null,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            connected
                ? LocalizationService.instance.t('terminalLive')
                : LocalizationService.instance.t('terminalConnecting'),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color:
                  connected ? const Color(0xFF00C853) : const Color(0xFFFF9800),
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            LocalizationService.instance
                .t('terminalPairs', {'count': svc.totalPairs}),
            style: const TextStyle(
              fontSize: 12,
              color: GuardianColors.textSecondary,
            ),
          ),
          const Spacer(),
          // Search toggle
          GestureDetector(
            onTap: onSearchTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: searchActive
                    ? GuardianColors.accent.withValues(alpha: 0.15)
                    : Colors.transparent,
                border: Border.all(
                  color: searchActive
                      ? GuardianColors.accent
                      : GuardianColors.border,
                ),
              ),
              child: Icon(
                searchActive ? Icons.close_rounded : Icons.search_rounded,
                size: 16,
                color: searchActive
                    ? GuardianColors.accent
                    : GuardianColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // WebSocket indicator
          if (connected)
            _PulseWidget(
              child: Text(
                LocalizationService.instance.t('terminalWebSocket'),
                style: TextStyle(
                  fontSize: 11,
                  color: const Color(0xFF00C853).withValues(alpha: 0.8),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Search Bar ───────────────────────────────────────────────────────────────

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  const _SearchBar({
    required this.controller,
    required this.onChanged,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: GuardianColors.surface,
          borderRadius: BorderRadius.circular(10),
          border:
              Border.all(color: GuardianColors.accent.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(Icons.search_rounded,
                size: 18, color: GuardianColors.accent.withValues(alpha: 0.6)),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                autofocus: true,
                style: const TextStyle(
                  color: GuardianColors.textPrimary,
                  fontSize: 14,
                ),
                decoration: InputDecoration(
                  hintText: LocalizationService.instance
                      .t('terminalSearch', {'default': 'Search symbol...'}),
                  hintStyle: TextStyle(
                    color: GuardianColors.textSecondary.withValues(alpha: 0.5),
                    fontSize: 14,
                  ),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            if (controller.text.isNotEmpty)
              GestureDetector(
                onTap: () {
                  controller.clear();
                  onChanged('');
                },
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.clear_rounded,
                      size: 16, color: GuardianColors.textSecondary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Search Results List ──────────────────────────────────────────────────────

class _SearchResultsList extends StatelessWidget {
  final List<LiveTicker> results;
  final ExchangeId exchangeId;
  final void Function(LiveTicker) onTap;

  const _SearchResultsList({
    required this.results,
    required this.exchangeId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: results.length,
      itemExtent: 56,
      itemBuilder: (context, i) {
        final t = results[i];
        final change = t.priceChangePercent24h;
        final changeColor =
            change >= 0 ? const Color(0xFF00C853) : const Color(0xFFFF1744);
        final watchlist = WatchlistService.instance;
        final isFav = watchlist.isFavoriteAny('', t.baseAsset);

        return GestureDetector(
          onTap: () => onTap(t),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: GuardianColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: GuardianColors.border.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              children: [
                // Symbol
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        t.baseAsset,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: GuardianColors.textPrimary,
                        ),
                      ),
                      const Text(
                        '/USDT',
                        style: const TextStyle(
                          fontSize: 10,
                          color: GuardianColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                // Price
                Expanded(
                  flex: 3,
                  child: RepaintBoundary(
                    child: Text(
                      '\$${PriceFormatter.price(t.lastPrice)}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: GuardianColors.textPrimary,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Change badge
                RepaintBoundary(
                  child: Container(
                    width: 76,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    decoration: BoxDecoration(
                      color: changeColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      PriceFormatter.percent(change),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: changeColor,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Watchlist star
                GestureDetector(
                  onTap: () => watchlist.toggleSmart('', t.baseAsset),
                  child: Icon(
                    isFav ? Icons.star_rounded : Icons.star_border_rounded,
                    size: 22,
                    color: isFav
                        ? const Color(0xFFFFD700)
                        : GuardianColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─── New Listing Banner ────────────────────────────────────────────────────────

class _NewListingBanner extends StatelessWidget {
  final List<NewListingEvent> events;
  const _NewListingBanner({required this.events});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFF9800).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFFFF9800).withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        children: [
          const Text('🆕', style: TextStyle(fontSize: 14)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: events.map((e) {
                final change = e.ticker.priceChangePercent24h;
                final changeStr = change >= 0
                    ? PriceFormatter.percent(change)
                    : '${change.toStringAsFixed(2)}%';
                return Text(
                  '${e.exchange}: ${e.ticker.baseAsset}/USDT  $changeStr',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFFF9800),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── View Toggle (4 tabs) ─────────────────────────────────────────────────────

class _ViewToggle extends StatelessWidget {
  final TerminalView selected;
  final ValueChanged<TerminalView> onChanged;

  const _ViewToggle({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: TerminalView.values.map((view) {
          final active = selected == view;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => onChanged(view),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: active
                      ? GuardianColors.accent.withValues(alpha: 0.15)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color:
                        active ? GuardianColors.accent : GuardianColors.border,
                  ),
                ),
                child: Text(
                  LocalizationService.instance.t(view.labelKey),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                    color: active
                        ? GuardianColors.accent
                        : GuardianColors.textSecondary,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ─── Live Ticker List ──────────────────────────────────────────────────────────

class _LiveTickerList extends StatelessWidget {
  final List<LiveTicker> tickers;
  final ExchangeId exchangeId;
  final bool isConnected;
  final bool isConnecting;
  final TerminalView activeView;
  final void Function(LiveTicker) onTap;

  const _LiveTickerList({
    required this.tickers,
    required this.exchangeId,
    required this.isConnected,
    required this.activeView,
    required this.onTap,
    this.isConnecting = false,
  });

  @override
  Widget build(BuildContext context) {
    if (isConnecting || (!isConnected && tickers.isEmpty)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(strokeWidth: 2),
            const SizedBox(height: 12),
            Text(LocalizationService.instance.t('terminalConnectingExchange')),
          ],
        ),
      );
    }

    if (tickers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(strokeWidth: 2),
            const SizedBox(height: 12),
            Text(
              LocalizationService.instance.t('terminalLoadingData'),
              style: const TextStyle(color: GuardianColors.textSecondary),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: tickers.length,
      itemExtent: 56, // Fixed height → instant scroll math, no measure pass
      itemBuilder: (context, i) {
        return _TickerRow(
          key: ValueKey(tickers[i].symbol),
          rank: i + 1,
          ticker: tickers[i],
          exchangeId: exchangeId,
          useGrowthSinceListing: activeView == TerminalView.newListings,
          onTap: () => onTap(tickers[i]),
        );
      },
    );
  }
}

// ─── Ticker Row ────────────────────────────────────────────────────────────────

class _TickerRow extends StatefulWidget {
  final int rank;
  final LiveTicker ticker;
  final ExchangeId exchangeId;
  final bool useGrowthSinceListing;
  final VoidCallback? onTap;

  const _TickerRow(
      {super.key,
      required this.rank,
      required this.ticker,
      required this.exchangeId,
      this.useGrowthSinceListing = false,
      this.onTap});

  @override
  State<_TickerRow> createState() => _TickerRowState();
}

class _TickerRowState extends State<_TickerRow>
    with SingleTickerProviderStateMixin {
  late AnimationController _flashController;
  late Animation<Color?> _flashAnimation;
  @override
  void initState() {
    super.initState();
    _flashController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _flashAnimation = ColorTween(
      begin: Colors.transparent,
      end: Colors.transparent,
    ).animate(_flashController);
  }

  @override
  void didUpdateWidget(_TickerRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ticker.lastPrice != widget.ticker.lastPrice) {
      final up = widget.ticker.lastPrice > (oldWidget.ticker.lastPrice);
      _flashAnimation = ColorTween(
        begin: up
            ? const Color(0xFF00C853).withValues(alpha: 0.25)
            : const Color(0xFFFF1744).withValues(alpha: 0.25),
        end: Colors.transparent,
      ).animate(CurvedAnimation(
        parent: _flashController,
        curve: Curves.easeOut,
      ));
      _flashController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _flashController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.ticker;
    // Show growth since listing only on 'Новые' tab; 24h change otherwise.
    final growth = widget.useGrowthSinceListing
        ? (t.growthSinceListing ?? t.priceChangePercent24h)
        : t.priceChangePercent24h;
    final changeColor =
        growth >= 0 ? const Color(0xFF00C853) : const Color(0xFFFF1744);

    final changeStr = PriceFormatter.percent(growth);

    final priceStr = PriceFormatter.price(t.lastPrice);
    final volStr = PriceFormatter.volume(t.quoteVolume24h);
    final l = LocalizationService.instance;
    final ageStr = t.daysListed != null
        ? (t.daysListed == 0
            ? l.t('terminalAgeToday')
            : t.daysListed == 1
                ? l.t('terminalAge1d')
                : l.t('terminalAgeDays', {'d': t.daysListed}))
        : '';

    return AnimatedBuilder(
      animation: _flashAnimation,
      builder: (context, child) => Container(
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: _flashAnimation.value ?? Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: child,
      ),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: t.isNewlyListed
                ? const Color(0xFFFF9800).withValues(alpha: 0.08)
                : GuardianColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: t.isNewlyListed
                  ? const Color(0xFFFF9800).withValues(alpha: 0.4)
                  : growth > 50
                      ? const Color(0xFF00C853).withValues(alpha: 0.25)
                      : GuardianColors.border.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              // Rank
              SizedBox(
                width: 24,
                child: Text(
                  '${widget.rank}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: widget.rank <= 3
                        ? const Color(0xFFFFD700)
                        : GuardianColors.textSecondary,
                  ),
                ),
              ),

              // Symbol + age
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.baseAsset,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: GuardianColors.textPrimary,
                      ),
                    ),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            ageStr.isEmpty ? '/USDT' : '/USDT · $ageStr',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 9,
                              color: GuardianColors.textSecondary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 3),
                        _RiskBadge(risk: t.risk),
                      ],
                    ),
                  ],
                ),
              ),

              // Price — RepaintBoundary isolates repaint to this cell only
              Expanded(
                flex: 3,
                child: RepaintBoundary(
                  child: Text(
                    '\$$priceStr',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: GuardianColors.textPrimary,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 6),

              // Change badge — RepaintBoundary isolates repaint
              RepaintBoundary(
                child: Container(
                  width: 76,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  decoration: BoxDecoration(
                    color: changeColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    changeStr,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: changeColor,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 6),

              // Volume
              SizedBox(
                width: 44,
                child: Text(
                  volStr,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 10,
                    color: GuardianColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Pulse widget ──────────────────────────────────────────────────────────────

class _PulseWidget extends StatefulWidget {
  final Widget child;
  const _PulseWidget({required this.child});

  @override
  State<_PulseWidget> createState() => _PulseWidgetState();
}

class _PulseWidgetState extends State<_PulseWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _ctrl, child: widget.child);
  }
}

// ─── Risk Badge ────────────────────────────────────────────────────────────────

class _RiskBadge extends StatelessWidget {
  final TickerRisk risk;
  const _RiskBadge({required this.risk});

  @override
  Widget build(BuildContext context) {
    final Color color;
    switch (risk) {
      case TickerRisk.newListing:
        color = const Color(0xFFFF9800); // orange
        break;
      case TickerRisk.hot:
        color = const Color(0xFFFF5252); // red-ish
        break;
      case TickerRisk.thinLiquidity:
        color = const Color(0xFFFFD600); // yellow
        break;
      case TickerRisk.safe:
        color = const Color(0xFF00C853); // green
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 0.5),
      ),
      child: Text(
        LocalizationService.instance.t(risk.labelKey),
        style: TextStyle(
          fontSize: 8,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
