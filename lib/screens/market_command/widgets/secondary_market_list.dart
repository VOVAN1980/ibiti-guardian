import 'package:flutter/material.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_account_store.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_order_service.dart';
import 'package:ibiti_guardian/screens/market_command/widgets/connect_exchange_modal.dart';
import 'package:ibiti_guardian/screens/market_command/widgets/cex_spot_trade_modal.dart';
import 'package:ibiti_guardian/screens/market_command/market_token_detail_screen.dart';
import 'package:ibiti_guardian/screens/wallet/components/wallet_trade_modal.dart';
import 'package:ibiti_guardian/services/exchanges/okx_exchange_service.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/market/market_scout_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';
import 'package:ibiti_guardian/services/wallet/market_price_alert_service.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/screens/wallet/wallet_token_management_screen.dart';
import 'package:ibiti_guardian/utils/price_formatter.dart';

// ─── Secondary Market List ─────────────────────────────────────────────────────

/// Block 5: All markets — collapsed by default, expandable.
///
/// Shows [_initialCount] rows. User can expand to see all.
/// This prevents the bottom of the screen from becoming the old noise dump.
class SecondaryMarketList extends StatefulWidget {
  final List<MarketAsset> markets;
  final AiControlSettings settings;

  /// Number of rows visible before "Show all" is tapped.
  static const int _initialCount = 3;

  const SecondaryMarketList({
    super.key,
    required this.markets,
    required this.settings,
  });

  @override
  State<SecondaryMarketList> createState() => _SecondaryMarketListState();
}

class _SecondaryMarketListState extends State<SecondaryMarketList> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allMarkets = widget.markets;
    if (allMarkets.isEmpty) return const SizedBox.shrink();

    // ── Stablecoin + wrapped/boring asset blacklist ────────────────────────
    const stables = <String>{
      'USDT',
      'USDC',
      'DAI',
      'BUSD',
      'FDUSD',
      'USDE',
      'PYUSD',
      'TUSD',
      'FRAX',
      'LUSD',
      'GUSD',
      'USDP',
      'CRVUSD',
      'GHO',
      'SUSD',
      'MIM',
      'DOLA',
      'EURC',
      'EURS',
    };
    const boring = <String>{
      'STETH',
      'WSTETH',
      'CBETH',
      'RETH',
      'WETH',
      'WBTC',
      'TBTC',
      'WBNB',
      'WMATIC',
      'WAVAX',
      'WSOL',
    };

    // Filter: volume > 0, not stablecoin, not wrapped/boring.
    final filtered = allMarkets
        .where((a) {
          if (a.volume <= 0) return false;
          final sym = a.symbol.toUpperCase();
          if (stables.contains(sym) || boring.contains(sym)) return false;
          return true;
        })
        .take(50)
        .toList();

    if (filtered.isEmpty) return const SizedBox.shrink();

    // Score via MarketScout for badge/dot display only — NOT for sorting.
    final classified = MarketScoutService.instance.findTopOpportunities(
      filtered,
      settings: widget.settings,
      topN: filtered.length,
    );
    final oppMap = {for (final o in classified) o.asset.symbol: o};

    // Sort strictly by 24h change descending — real top gainers first.
    // MarketScout score is NOT used for ordering.
    filtered.sort((a, b) => b.change24h.compareTo(a.change24h));

    final markets = filtered;

    final visibleCount = _expanded
        ? markets.length
        : markets.length.clamp(0, SecondaryMarketList._initialCount);
    final visible = markets.take(visibleCount).toList();
    final hiddenCount = markets.length - visibleCount;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                LocalizationService.instance.t('marketCmdAllMarkets'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const WalletTokenManagementScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.add_circle_outline_rounded, size: 16),
                label: Text(LocalizationService.instance
                    .t('btnImportToken', {'default': 'Add Token'})),
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  backgroundColor: theme.colorScheme.surface,
                  foregroundColor: theme.colorScheme.primary,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                        color: theme.colorScheme.primary.withOpacity(0.3)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: [
                ...visible.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final asset = entry.value;
                  final opp = oppMap[asset.symbol];
                  final isLast = idx == visible.length - 1 && hiddenCount == 0;
                  return _MarketRow(
                    asset: asset,
                    opportunity: opp,
                    isLast: isLast,
                    settings: widget.settings,
                  );
                }),

                // ── Show all / Show less toggle ──────────────────────────────
                if (markets.length > SecondaryMarketList._initialCount)
                  InkWell(
                    borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(14)),
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(
                            color:
                                theme.colorScheme.onSurface.withOpacity(0.06),
                          ),
                        ),
                        borderRadius: const BorderRadius.vertical(
                            bottom: Radius.circular(14)),
                      ),
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _expanded
                                  ? LocalizationService.instance
                                      .t('marketCmdShowLess')
                                  : LocalizationService.instance.t(
                                      'marketCmdShowAll',
                                      {'count': hiddenCount}),
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              _expanded
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 16,
                              color: theme.colorScheme.primary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Market Row ────────────────────────────────────────────────────────────────

class _MarketRow extends StatelessWidget {
  final MarketAsset asset;
  final MarketOpportunity? opportunity;
  final bool isLast;
  final AiControlSettings settings;

  const _MarketRow({
    required this.asset,
    required this.opportunity,
    required this.isLast,
    required this.settings,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final change = asset.change24h;
    final changeColor =
        change >= 0 ? Colors.greenAccent.shade400 : Colors.redAccent;

    final opp = opportunity;
    final Color dotColor;
    if (opp == null) {
      dotColor = Colors.grey;
    } else if (opp.executableByAi) {
      dotColor = Colors.greenAccent.shade400;
    } else if (opp.blockReason?.contains('Manual') ?? false) {
      dotColor = Colors.grey;
    } else {
      dotColor = Colors.redAccent.withOpacity(0.7);
    }

    return Column(
      children: [
        InkWell(
          borderRadius: isLast
              ? const BorderRadius.vertical(bottom: Radius.circular(14))
              : null,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => MarketTokenDetailScreen(asset: asset),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: dotColor,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(asset.symbol,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                          Text(asset.name,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface
                                      .withOpacity(0.4),
                                  fontSize: 11),
                              overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (MarketPriceAlertService.instance
                              .hasAlerts(asset.symbol))
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(
                                Icons.notifications_active_rounded,
                                size: 13,
                                color: const Color(0xFFFF9100).withOpacity(0.7),
                              ),
                            ),
                          Flexible(
                            child: Text(
                              '\$${_fmt(asset.price)}',
                              textAlign: TextAlign.right,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      PriceFormatter.percent(change),
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: changeColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _openTrade(context, isBuy: true),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.greenAccent.shade400,
                          side: BorderSide(
                              color: Colors.greenAccent.withOpacity(0.3)),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                            LocalizationService.instance.t('marketBtnBuy'),
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _openTrade(context, isBuy: false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          side: BorderSide(
                              color: Colors.redAccent.withOpacity(0.3)),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                            LocalizationService.instance.t('marketBtnSell'),
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (!isLast)
          Divider(
            height: 1,
            indent: 30,
            color: theme.colorScheme.onSurface.withOpacity(0.06),
          ),
      ],
    );
  }

  Future<void> _openTrade(BuildContext context, {required bool isBuy}) async {
    var src = asset.sourceId.toLowerCase();
    if (src == 'gate.io') src = 'gateio';
    if (['mexc', 'binance', 'gateio', 'okx'].contains(src)) {
      final isConnected = await ExchangeAccountStore.instance.isConnected(src);

      if (!isConnected) {
        if (context.mounted) {
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
          if (context.mounted) {
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
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('Пара ${asset.symbol.toUpperCase()} недоступна для торговли на вашем аккаунте OKX (ограничение региона).'),
                backgroundColor: Colors.redAccent,
              ));
            }
            return;
          }
          quoteAsset = bestPair.split('-')[1];
        }

        if (context.mounted) {
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

  static String _fmt(double p) => PriceFormatter.price(p);
}
