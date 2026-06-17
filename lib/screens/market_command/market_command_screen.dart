import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/models/trading_plan.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/screens/market_command/widgets/active_plan_card.dart';
import 'package:ibiti_guardian/screens/market_command/widgets/ai_status_header.dart';
import 'package:ibiti_guardian/screens/market_command/widgets/automation_overview.dart';
import 'package:ibiti_guardian/screens/market_command/widgets/exposure_summary.dart';
import 'package:ibiti_guardian/screens/market_command/widgets/rocket_alert_settings_card.dart';
import 'package:ibiti_guardian/screens/market_command/widgets/secondary_market_list.dart';
import 'package:ibiti_guardian/screens/market_command/exchange_terminal_screen.dart';
import 'package:ibiti_guardian/screens/market_command/market_token_detail_screen.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/market/exchange_market_bridge.dart';
import 'package:ibiti_guardian/services/market/automation_dispatch_service.dart';
import 'package:ibiti_guardian/services/market/automation_engine.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/market/price_alert_monitor.dart';
import 'package:ibiti_guardian/services/market/rocket_alert_service.dart';
import 'package:ibiti_guardian/services/market/rocket_alert_settings.dart';
import 'package:ibiti_guardian/services/market/token_search_service.dart';
import 'package:ibiti_guardian/services/market/watchlist_service.dart';

import 'package:ibiti_guardian/services/exchanges/exchange_interface.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_registry.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/ibiti/ibiti_loop.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/utils/price_formatter.dart';

const _log = GuardianLogger('MarketScreen');

// в”Ђв”Ђв”Ђ Market Command Center в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

/// AI Trading Command Center вЂ” answers 5 questions in 2 seconds:
///  1. What does the AI see right now?
///  2. What does the AI recommend right now?
///  3. What do I already have?
///  4. What can the AI do in this mode?
///  5. What is blocked and why?
///
/// Uses MEXC API for Hot Movers (real moonshot data: +100%, +500%).
/// Uses CoinGecko for Blue Chips and general market data.
class MarketCommandScreen extends StatefulWidget {
  const MarketCommandScreen({super.key});

  @override
  State<MarketCommandScreen> createState() => MarketCommandScreenState();
}

class MarketCommandScreenState extends State<MarketCommandScreen> {
  TradingPlan? _activePlan;
  Timer? _autoRefresh;

  // в”Ђв”Ђ Search state в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
  final _searchController = TextEditingController();
  List<SearchResult>? _searchResults;
  Timer? _searchDebounce;
  bool _isSearching = false;

  /// Called from outside (e.g. voice pipeline) to show a built plan.
  void showPlan(TradingPlan plan) {
    if (mounted) setState(() => _activePlan = plan);
  }

  @override
  void initState() {
    super.initState();
    _log.i('initState START');
    try {
      _fetchAll();
      _log.i('fetchAll dispatched');
    } catch (e) {
      _log.e('fetchAll CRASH', e);
    }
    // Load watchlist from disk.
    unawaited(WatchlistService.instance.load());
    // Start exchange connections in background.
    _log.i('connectAll START (parallel, non-blocking)');
    unawaited(ExchangeRegistry.instance.connectAll().then((_) {
      _log.i('connectAll DONE вЂ” all exchanges attempted');
      // в”Ђв”Ђ IBITI: start cognitive loop in observeOnly mode в”Ђв”Ђ
      if (!IbitiLoop.instance.isRunning) {
        unawaited(IbitiLoop.instance.start());
      }
    }).catchError((e) {
      _log.e('connectAll CRASH', e);
    }));
    // Start the exchangeв†’scout data bridge.
    ExchangeMarketBridge.instance.start();
    // Start price alert monitor (watches tickers for alert triggers).
    PriceAlertMonitor.instance.start();
    // Start rocket alert monitor (watches for rapid price spikes).
    unawaited(RocketAlertSettings.instance.load().then((_) {
      RocketAlertService.instance.start();
    }));
    // Live refresh every 90s (CoinGecko free tier = ~10 calls/min max).
    // Exchange WS data updates independently via ExchangeMarketBridge.
    _autoRefresh = Timer.periodic(
      const Duration(seconds: 90),
      (_) => _fetchAll(silent: true),
    );
    _log.i('initState DONE');
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    _searchController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = null;
        _isSearching = false;
      });
      return;
    }
    setState(() => _isSearching = true);
    _searchDebounce = Timer(const Duration(milliseconds: 300), () async {
      final results = await TokenSearchService.instance.search(query);
      if (mounted)
        setState(() {
          _searchResults = results;
          _isSearching = false;
        });
    });
  }

  void _openTokenDetail(MarketAsset asset) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MarketTokenDetailScreen(asset: asset),
      ),
    );
  }

  void _openSearchResultDetail(SearchResult r) {
    // Try to get enriched data from CoinGecko cache
    MarketAsset asset;
    if (r.id.isNotEmpty) {
      final cgMatch = MarketDataService.instance.cachedMarkets
          .where((a) => a.id == r.id)
          .firstOrNull;
      if (cgMatch != null) {
        asset = cgMatch;
      } else {
        asset = MarketAsset(
          id: r.id,
          symbol: r.symbol,
          name: r.name,
          imageUrl: r.imageUrl ?? '',
          price: r.price ?? 0,
          change24h: r.change24h ?? 0,
          marketCap: r.marketCap ?? 0,
          volume: 0,
          rank: 0,
          sparkline: const [],
          high24h: 0,
          low24h: 0,
          change7d: 0,
          change30d: 0,
          networkGroup: '',
        );
      }
    } else {
      // Exchange-only вЂ” try resolver
      asset = MarketDataService.instance.resolveAssetFromTicker(
        symbol: r.symbol,
        price: r.price ?? 0,
        change24h: r.change24h ?? 0,
        volume: 0,
        high24h: 0,
        low24h: 0,
      );
    }
    _searchController.clear();
    setState(() {
      _searchResults = null;
    });
    _openTokenDetail(asset);
  }

  Future<void> _fetchAll({bool silent = false}) async {
    if (!mounted) return;
    try {
      await MarketDataService.instance.fetchMarkets(forceRefresh: true);
    } catch (e) {
      const log = GuardianLogger('MarketCmd');
      log.e('fetchAll error', e);
    }
    // No setState needed — ListenableBuilder already listens to
    // MarketDataService.notifyListeners() which fires after fetchMarkets.
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        AiControlService.instance,
        VaultPortfolioListener.instance,
        AutomationDispatchService.instance,
        AutomationEngine.instance,
        WatchlistService.instance,
        MarketDataService.instance,
      ]),
      builder: (context, _) {
        final settings = AiControlService.instance.settings;
        final portfolio = VaultPortfolioListener.instance.summary;
        final dispatch = AutomationDispatchService.instance;
        final markets = MarketDataService.instance.liveExchangeMovers;
        final watchlistAssets = WatchlistService.instance.watchlistAssets;

        final topPositions = portfolio?.topAssets
                .where((a) => !const {
                      'USDT',
                      'USDC',
                      'DAI',
                      'BUSD',
                      'FDUSD',
                      'USDE',
                      'PYUSD'
                    }.contains(a.symbol.toUpperCase()))
                .take(4)
                .toList() ??
            <WalletAsset>[];

        return Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: SafeArea(
            child: RefreshIndicator(
              onRefresh: _fetchAll,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  // в”Ђв”Ђ Search Bar в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
                  SliverToBoxAdapter(
                    child: _MarketSearchBar(
                      controller: _searchController,
                      onChanged: _onSearchChanged,
                      isSearching: _isSearching,
                    ),
                  ),

                  // в”Ђв”Ђ Search Results (overlay mode) в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
                  if (_searchResults != null)
                    SliverToBoxAdapter(
                      child: _SearchResultsList(
                        results: _searchResults!,
                        onTap: _openSearchResultDetail,
                      ),
                    )
                  else ...[
                    // в”Ђв”Ђ Block 1: What the AI sees / can do в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
                    SliverToBoxAdapter(
                      child: AiStatusHeader(
                        settings: settings,
                        pendingQueueCount: dispatch.pendingCount,
                        onScanRequested: _fetchAll,
                      ),
                    ),

                    // в”Ђв”Ђ Block 1.5: Exchange shortcuts в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 4),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: ExchangeRegistry
                                .instance.availableExchanges
                                .map((id) => Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: _ExchangeEntryButton(
                                        label: '${id.emoji} ${id.displayName}',
                                        onTap: () => Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                ExchangeTerminalScreen(
                                              exchangeId: id,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ))
                                .toList(),
                          ),
                        ),
                      ),
                    ),

                    // в”Ђв”Ђ Watchlist в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
                    if (watchlistAssets.isNotEmpty)
                      SliverToBoxAdapter(
                        child: _WatchlistSection(
                          assets: watchlistAssets,
                          onTap: _openTokenDetail,
                        ),
                      ),

                    // в”Ђв”Ђ Block 2.5: Active trading plan (if any) в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
                    if (_activePlan != null)
                      SliverToBoxAdapter(
                        child: ActivePlanCard(
                          plan: _activePlan!,
                          onDismiss: () => setState(() => _activePlan = null),
                        ),
                      ),

                    // Block 3 (My positions) removed вЂ” AI has portfolio context.

                    // ── Rocket Alert Settings ────────────────────────────────
                    const SliverToBoxAdapter(
                      child: RocketAlertSettingsCard(),
                    ),

                    // ── Block 4: Automation / queue ──────────────────────────в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
                    SliverToBoxAdapter(
                      child: AutomationOverview(
                        dispatch: dispatch,
                        triggers: AutomationEngine.instance.triggers,
                      ),
                    ),

                    // в”Ђв”Ђ Block 5: All markets (secondary) в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
                    SliverToBoxAdapter(
                      child: SecondaryMarketList(
                        markets: markets,
                        settings: settings,
                      ),
                    ),

                    const SliverToBoxAdapter(child: SizedBox(height: 80)),
                  ], // end of else (non-search mode)
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// в”Ђв”Ђв”Ђ Exchange Entry Button в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

class _ExchangeEntryButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _ExchangeEntryButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
        decoration: BoxDecoration(
          color: GuardianColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: GuardianColors.accent.withValues(alpha: 0.4),
          ),
          boxShadow: [
            BoxShadow(
              color: GuardianColors.accent.withValues(alpha: 0.08),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: GuardianColors.accent,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.arrow_forward_ios,
              size: 10,
              color: GuardianColors.accent,
            ),
          ],
        ),
      ),
    );
  }
}

// в”Ђв”Ђв”Ђ Market Search Bar в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

class _MarketSearchBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final bool isSearching;

  const _MarketSearchBar({
    required this.controller,
    required this.onChanged,
    required this.isSearching,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: GuardianColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: controller.text.isNotEmpty
                ? GuardianColors.accent.withValues(alpha: 0.4)
                : GuardianColors.border,
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 14),
            Icon(
              Icons.search_rounded,
              size: 20,
              color: controller.text.isNotEmpty
                  ? GuardianColors.accent
                  : GuardianColors.textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                style: const TextStyle(
                  color: GuardianColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                decoration: InputDecoration(
                  hintText: LocalizationService.instance.t(
                    'marketSearchHint',
                    {'default': 'Search token by name or symbol...'},
                  ),
                  hintStyle: TextStyle(
                    color: GuardianColors.textSecondary.withValues(alpha: 0.5),
                    fontSize: 14,
                  ),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            if (isSearching)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: GuardianColors.accent.withValues(alpha: 0.6),
                  ),
                ),
              )
            else if (controller.text.isNotEmpty)
              GestureDetector(
                onTap: () {
                  controller.clear();
                  onChanged('');
                },
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: GuardianColors.textSecondary.withValues(alpha: 0.6),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// в”Ђв”Ђв”Ђ Search Results List в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

class _SearchResultsList extends StatelessWidget {
  final List<SearchResult> results;
  final ValueChanged<SearchResult> onTap;

  const _SearchResultsList({required this.results, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Column(
            children: [
              Icon(Icons.search_off_rounded,
                  size: 40, color: Colors.white.withValues(alpha: 0.15)),
              const SizedBox(height: 12),
              Text(
                LocalizationService.instance.t(
                  'marketSearchEmpty',
                  {'default': 'No tokens found'},
                ),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: GuardianColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: GuardianColors.border),
        ),
        child: Column(
          children: results.asMap().entries.map((entry) {
            final r = entry.value;
            final isLast = entry.key == results.length - 1;
            final change = r.change24h ?? 0;
            final changeColor =
                change >= 0 ? const Color(0xFF00C853) : const Color(0xFFFF1744);

            return Column(
              children: [
                InkWell(
                  borderRadius: isLast
                      ? const BorderRadius.vertical(bottom: Radius.circular(14))
                      : null,
                  onTap: () => onTap(r),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    child: Row(
                      children: [
                        // Icon
                        if (r.imageUrl != null && r.imageUrl!.isNotEmpty)
                          ClipOval(
                            child: Image.network(
                              r.imageUrl!,
                              width: 32,
                              height: 32,
                              errorBuilder: (_, __, ___) =>
                                  _FallbackSearchIcon(symbol: r.symbol),
                            ),
                          )
                        else
                          _FallbackSearchIcon(symbol: r.symbol),
                        const SizedBox(width: 12),

                        // Name + Symbol
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                r.symbol,
                                style: const TextStyle(
                                  color: GuardianColors.textPrimary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                r.name,
                                style: TextStyle(
                                  color: GuardianColors.textSecondary
                                      .withValues(alpha: 0.6),
                                  fontSize: 12,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),

                        // Price + Change
                        if (r.price != null && r.price! > 0) ...[
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '\$${_fmtPrice(r.price!)}',
                                style: const TextStyle(
                                  color: GuardianColors.textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (r.change24h != null)
                                Text(
                                  PriceFormatter.percent(change),
                                  style: TextStyle(
                                    color: changeColor,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                            ],
                          ),
                        ],

                        const SizedBox(width: 6),
                        Icon(Icons.chevron_right_rounded,
                            size: 18,
                            color: GuardianColors.textSecondary
                                .withValues(alpha: 0.3)),
                      ],
                    ),
                  ),
                ),
                if (!isLast)
                  Divider(
                    height: 1,
                    indent: 58,
                    color: Colors.white.withValues(alpha: 0.05),
                  ),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }

  static String _fmtPrice(double p) => PriceFormatter.price(p);
}

class _FallbackSearchIcon extends StatelessWidget {
  final String symbol;
  const _FallbackSearchIcon({required this.symbol});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: GuardianColors.accent.withValues(alpha: 0.12),
      ),
      child: Center(
        child: Text(
          symbol.isNotEmpty ? symbol[0] : '?',
          style: const TextStyle(
            color: GuardianColors.accent,
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

// в”Ђв”Ђв”Ђ Watchlist Section в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

class _WatchlistSection extends StatelessWidget {
  final List<MarketAsset> assets;
  final ValueChanged<MarketAsset> onTap;

  const _WatchlistSection({required this.assets, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.star_rounded,
                  size: 18, color: Color(0xFFFFD700)),
              const SizedBox(width: 8),
              Text(
                LocalizationService.instance.t(
                  'marketWatchlist',
                  {'default': 'Watchlist'},
                ),
                style: const TextStyle(
                  color: GuardianColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                '${assets.length}',
                style: TextStyle(
                  color: GuardianColors.textSecondary.withValues(alpha: 0.5),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 88,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: assets.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final a = assets[i];
                final change = a.change24h;
                final isUp = change >= 0;
                final changeColor =
                    isUp ? const Color(0xFF00C853) : const Color(0xFFFF1744);

                return GestureDetector(
                  onTap: () => onTap(a),
                  child: Container(
                    width: 120,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: GuardianColors.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: changeColor.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (a.imageUrl.isNotEmpty)
                              ClipOval(
                                child: Image.network(
                                  a.imageUrl,
                                  width: 20,
                                  height: 20,
                                  errorBuilder: (_, __, ___) =>
                                      const SizedBox(width: 20),
                                ),
                              )
                            else
                              const SizedBox(width: 20),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                a.symbol,
                                style: const TextStyle(
                                  color: GuardianColors.textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const Spacer(),
                        Text(
                          '\$${_fmtPrice(a.price)}',
                          style: const TextStyle(
                            color: GuardianColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${PriceFormatter.percent(change)}',
                          style: TextStyle(
                            color: changeColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static String _fmtPrice(double p) => PriceFormatter.price(p);
}
