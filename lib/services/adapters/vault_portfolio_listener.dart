import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/services/adapters/portfolio_adapter.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/models/portfolio_summary.dart';
import 'package:ibiti_guardian/models/unified_portfolio.dart';
import 'package:ibiti_guardian/services/wallet/wallet_portfolio_history_service.dart';
import 'package:ibiti_guardian/services/wallet/wallet_price_enricher.dart';
import 'package:ibiti_guardian/services/wallet/wallet_topup_detector.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';

/// Listens to vault changes and fetches portfolio for the **active** address.
/// Also provides [summaryForAddress] for per-card balance in AllWalletsScreen.
class VaultPortfolioListener extends ChangeNotifier {
  static final VaultPortfolioListener instance =
      VaultPortfolioListener._internal();

  // Active wallet state
  PortfolioSummary? _cachedSummary;
  bool _isLoading = false;
  String _lastAddress = '';
  String _lastChainKey = '';
  DateTime? _lastUpdatedAt;
  String? _lastError;

  // Per-address cache for AllWalletsScreen (P1-1)
  final Map<String, PortfolioSummary> _perAddressCache = {};
  final Map<String, bool> _perAddressLoading = {};
  DateTime _lastValuationUpdateAt = DateTime(2000);

  PortfolioSummary? get summary => _cachedSummary;
  bool get isLoading => _isLoading;
  DateTime? get lastUpdatedAt => _lastUpdatedAt;
  String? get lastError => _lastError;
  bool get hasCachedData => _cachedSummary != null;

  void setSummaryForTest(PortfolioSummary summary) {
    _cachedSummary = summary;
    notifyListeners();
  }

  /// Unified multi-chain portfolio (all EVM chains).
  UnifiedPortfolioSummary? _unifiedSummary;
  UnifiedPortfolioSummary? get unifiedSummary => _unifiedSummary;
  bool get hasUnifiedData => _unifiedSummary != null;

  bool get isStale {
    if (_cachedSummary == null) return false;
    if (_lastError != null) return true;
    if (_lastUpdatedAt == null) return false;
    return DateTime.now().difference(_lastUpdatedAt!) >
        const Duration(minutes: 3);
  }

  VaultPortfolioListener._internal() {
    IBITIVaultService.instance.addListener(_onVaultChanged);
    MarketDataService.instance.addListener(_onMarketPricesChanged);
    _onVaultChanged();
  }

  void _onVaultChanged() {
    final vault = IBITIVaultService.instance;
    final address = vault.activeAddress;
    final chainKey = vault.chainKey;

    if (!vault.isVaultCreated || address.isEmpty) {
      if (_cachedSummary != null) {
        _cachedSummary = null;
        _lastAddress = '';
        _lastChainKey = '';
        _lastUpdatedAt = null;
        _lastError = null;
        notifyListeners();
      }
      return;
    }

    if (address != _lastAddress || chainKey != _lastChainKey) {
      _lastAddress = address;
      _lastChainKey = chainKey;
      refresh();
    }
  }

  Future<void> refresh() async {
    if (_lastAddress.isEmpty) return;

    _isLoading = true;
    _lastError = null;
    notifyListeners();

    try {
      _cachedSummary = await PortfolioAdapter.instance
          .fetchSummary(_lastAddress, _lastChainKey);

      // Enrich assets with 24h price change from CoinGecko.
      // Non-blocking: if CoinGecko fails, we still show balances.
      try {
        final enriched = await WalletPriceEnricher.instance
            .enrich(_cachedSummary!.allAssets);
        _cachedSummary = PortfolioSummary(
          totalBalanceUsd: _cachedSummary!.totalBalanceUsd,
          assetsCount: _cachedSummary!.assetsCount,
          allAssets: enriched,
          address: _cachedSummary!.address,
          networkName: _cachedSummary!.networkName,
          chainKey: _cachedSummary!.chainKey,
          isSupported: _cachedSummary!.isSupported,
        ).withPerformance();
        
        final sumAssetsUsd = _cachedSummary!.allAssets.fold<double>(0.0, (s, a) => s + a.valueUsd);
        const log = GuardianLogger('VaultPortfolio');
        log.d('manual_refresh: $_lastChainKey totalBalanceUsd=${_cachedSummary!.totalBalanceUsd}, sumAssetsUsd=$sumAssetsUsd');
      } catch (e) {
        const log = GuardianLogger('VaultPortfolio');
        log.w('Price enrichment skipped', e);
      }

      // Also update per-address cache for the active address
      _perAddressCache['${_lastAddress.toLowerCase()}_$_lastChainKey'] =
          _cachedSummary!;
      await WalletPortfolioHistoryService.instance
          .recordSummary(_cachedSummary!);
      _lastUpdatedAt = DateTime.now();
      _lastError = null;

      // Detect wallet top-ups (balance increases) and play coin sound
      WalletTopUpDetector.instance.onPortfolioRefresh(_cachedSummary!);
    } catch (e) {
      _lastError = e.toString();
      const log = GuardianLogger('VaultPortfolio');
      log.e('Failed to refresh portfolio', e);
    } finally {
      _isLoading = false;
      notifyListeners();
    }

    // DISABLED: auto-unified refresh was burning Moralis daily limits.
    // Unified portfolio now loads ONLY when user taps "All" network chip.
    // _refreshUnified();
  }

  /// Refreshes unified portfolio across ALL supported chains in background.
  Future<void> _refreshUnified() async {
    final vault = IBITIVaultService.instance;
    final evmAddress = vault.evmAddress;
    if (evmAddress == null || evmAddress.isEmpty) return;

    try {
      // 1. Fetch unified EVM summary
      final evmUnified = await PortfolioAdapter.instance.fetchUnifiedEvmSummary(
        evmAddress,
        onChainReady: (chainKey, summary) {
          _perAddressCache['${evmAddress.toLowerCase()}_$chainKey'] = summary;
          notifyListeners();
        },
      );

      // 2. Fetch Solana if address exists
      final solAddress = vault.solanaAddress;
      PortfolioSummary? solanaSummary;
      if (solAddress != null && solAddress.isNotEmpty) {
        try {
          solanaSummary = await PortfolioAdapter.instance
              .fetchSummary(solAddress, 'solana');
          _perAddressCache['${solAddress.toLowerCase()}_solana'] =
              solanaSummary;
        } catch (e) {
          evmUnified.failedChains['solana'] = e.toString();
        }
      }

      // 3. Fetch Tron if address exists
      final tronAddress = vault.tronAddress;
      PortfolioSummary? tronSummary;
      if (tronAddress != null && tronAddress.isNotEmpty) {
        try {
          tronSummary =
              await PortfolioAdapter.instance.fetchSummary(tronAddress, 'tron');
          _perAddressCache['${tronAddress.toLowerCase()}_tron'] = tronSummary;
        } catch (e) {
          evmUnified.failedChains['tron'] = e.toString();
        }
      }

      // 4. Merge Solana + Tron into unified
      final allAssets = [...evmUnified.allAssets];
      var totalUsd = evmUnified.totalUsd;
      final perChain = Map<String, PortfolioSummary>.from(evmUnified.perChain);

      if (solanaSummary != null) {
        allAssets.addAll(solanaSummary.allAssets);
        totalUsd += solanaSummary.totalBalanceUsd;
        perChain['solana'] = solanaSummary;
      }

      if (tronSummary != null) {
        allAssets.addAll(tronSummary.allAssets);
        totalUsd += tronSummary.totalBalanceUsd;
        perChain['tron'] = tronSummary;
      }

      allAssets.sort((a, b) => b.valueUsd.compareTo(a.valueUsd));

      _unifiedSummary = UnifiedPortfolioSummary(
        totalUsd: totalUsd,
        perChain: perChain,
        allAssets: allAssets,
        failedChains: evmUnified.failedChains,
        fetchedAt: DateTime.now(),
      );
      notifyListeners();
    } catch (e) {
      const log = GuardianLogger('VaultPortfolio');
      log.e('Unified portfolio refresh failed', e);
    }
  }

  /// Forces a unified portfolio refresh (e.g. after chain switch).
  Future<void> refreshUnified() => _refreshUnified();

  /// Returns the cached summary for a specific address on a specific chain.
  /// Triggers a background fetch + price enrichment if not yet cached.
  PortfolioSummary? summaryForAddress(String address, String chainKey) {
    final key = '${address.toLowerCase()}_$chainKey';
    if (_perAddressCache.containsKey(key)) {
      return _perAddressCache[key];
    }
    // Kick off background fetch if not already loading
    if (_perAddressLoading[key] != true) {
      _perAddressLoading[key] = true;
      PortfolioAdapter.instance.fetchSummary(address, chainKey).then((s) async {
        // Enrich with prices — same as refresh() does
        try {
          final enriched =
              await WalletPriceEnricher.instance.enrich(s.allAssets);
          final enrichedSummary = PortfolioSummary(
            totalBalanceUsd: s.totalBalanceUsd,
            assetsCount: s.assetsCount,
            allAssets: enriched,
            address: s.address,
            networkName: s.networkName,
            chainKey: s.chainKey,
            isSupported: s.isSupported,
          ).withPerformance();
          _perAddressCache[key] = enrichedSummary;
        } catch (_) {
          _perAddressCache[key] = s;
        }
        _perAddressLoading[key] = false;
        notifyListeners();
      }).catchError((e) {
        _perAddressLoading[key] = false;
        const log = GuardianLogger('VaultPortfolio');
        log.e('Per-card fetch failed for $key', e);
      });
    }
    return null; // null = loading (caller shows shimmer)
  }

  bool isLoadingAddress(String address, [String? chainKey]) {
    if (chainKey != null) {
      return _perAddressLoading['${address.toLowerCase()}_$chainKey'] == true;
    }
    // Legacy fallback: check if any chain is loading for this address
    final prefix = address.toLowerCase();
    return _perAddressLoading.entries
        .any((e) => e.key.startsWith(prefix) && e.value);
  }

  /// Returns wallet assets for a specific chain.
  /// Independent of what chain the wallet screen is on.
  /// If data is not yet cached, triggers a background fetch and returns
  /// whatever is available (may be empty on first call — UI rebuilds via
  /// notifyListeners when fetch completes).
  List<WalletAsset> assetsForChain(String chainKey) {
    // 1. Active chain — use _cachedSummary (always fresh)
    if (chainKey == _lastChainKey && _cachedSummary != null) {
      return _cachedSummary!.allAssets;
    }

    // 2. Resolve address for the requested chain
    final vault = IBITIVaultService.instance;
    String? address;
    if (chainKey == 'solana') {
      address = vault.solanaAddress;
    } else if (chainKey == 'tron') {
      address = vault.tronAddress;
    } else {
      address = vault.evmAddress;
    }

    if (address == null || address.isEmpty) return [];

    // 3. Per-address cache — returns data if available,
    //    triggers background fetch if not (notifyListeners on completion).
    final summary = summaryForAddress(address, chainKey);
    return summary?.allAssets ?? [];
  }

  /// Updates cached portfolio summaries and active portfolio state (if matching)
  /// when fetched in the background.
  void updateSummaryCache(String address, String chainKey, PortfolioSummary summary) {
    final sumAssetsUsd = summary.allAssets.fold<double>(0.0, (s, a) => s + a.valueUsd);
    PortfolioSummary finalSummary = summary;

    if ((summary.totalBalanceUsd - sumAssetsUsd).abs() > 0.001) {
      const log = GuardianLogger('VaultPortfolio');
      log.w('updateSummaryCache: totalBalanceUsd mismatch for $chainKey ($address). '
            'Repairing totalBalanceUsd from ${summary.totalBalanceUsd} to $sumAssetsUsd');
      
      finalSummary = PortfolioSummary(
        totalBalanceUsd: sumAssetsUsd,
        assetsCount: summary.assetsCount,
        allAssets: summary.allAssets,
        address: summary.address,
        networkName: summary.networkName,
        chainKey: summary.chainKey,
        isSupported: summary.isSupported,
        totalChangeUsd: summary.totalChangeUsd,
        totalChangePct: summary.totalChangePct,
        hasPerformanceData: summary.hasPerformanceData,
        hasUnpricedAssets: summary.hasUnpricedAssets,
      );
    }

    final key = '${address.toLowerCase()}_$chainKey';
    _perAddressCache[key] = finalSummary;
    if (address == _lastAddress && chainKey == _lastChainKey) {
      _cachedSummary = finalSummary;
      _lastUpdatedAt = DateTime.now();
    }
    notifyListeners();
  }

  void _onMarketPricesChanged() {
    if (_cachedSummary == null) return;

    final now = DateTime.now();
    if (now.difference(_lastValuationUpdateAt) < const Duration(seconds: 3)) {
      return; // Throttle wallet valuation UI updates to once every 3s
    }

    final markets = MarketDataService.instance.cachedMarkets;
    if (markets.isEmpty) return;

    // Index markets by symbol for O(1) lookup
    final marketMap = {for (final m in markets) m.symbol.toUpperCase(): m};

    bool priceChanged = false;
    final oldTotal = _cachedSummary!.totalBalanceUsd;

    final updatedAssets = _cachedSummary!.allAssets.map((a) {
      final sym = a.symbol.toUpperCase();

      // Stablecoins: always 1.0
      if (sym == 'USDT' || sym == 'USDC' || sym == 'DAI' || sym == 'BUSD' || sym == 'FDUSD') {
        if (a.priceUsd != 1.0) {
          priceChanged = true;
          return a.copyWith(
            priceUsd: 1.0,
            valueUsd: a.balance * 1.0,
            priceChange24hPct: 0.0,
            valueChange24hUsd: 0.0,
            priceAvailable: true,
          );
        }
        return a;
      }

      final match = marketMap[sym];
      if (match != null && match.price > 0) {
        if ((a.priceUsd - match.price).abs() > 0.0001) {
          priceChanged = true;

          final currentPrice = match.price;
          final changePct = match.change24h;
          final currentValue = a.balance * currentPrice;
          final valueChange = changePct.abs() > 0.001
              ? currentValue - (currentValue / (1 + changePct / 100))
              : 0.0;

          const log = GuardianLogger('VaultPortfolio');
          log.d('wallet_valuation_refresh (asset): '
                'chainKey=${_cachedSummary!.chainKey}, '
                'symbol=$sym, '
                'balance=${a.balance}, '
                'oldPrice=${a.priceUsd}, '
                'newPrice=$currentPrice');

          return a.copyWith(
            priceUsd: currentPrice,
            valueUsd: currentValue,
            priceChange24hPct: changePct,
            valueChange24hUsd: valueChange,
            priceAvailable: true,
          );
        }
      }
      return a;
    }).toList();

    if (priceChanged) {
      final newSummary = PortfolioSummary(
        totalBalanceUsd: _cachedSummary!.totalBalanceUsd,
        assetsCount: _cachedSummary!.assetsCount,
        allAssets: updatedAssets,
        address: _cachedSummary!.address,
        networkName: _cachedSummary!.networkName,
        chainKey: _cachedSummary!.chainKey,
        isSupported: _cachedSummary!.isSupported,
      ).withPerformance();

      const log = GuardianLogger('VaultPortfolio');
      log.d('wallet_valuation_refresh (summary): '
            'chainKey=${_cachedSummary!.chainKey}, '
            'oldTotal=$oldTotal, '
            'newTotal=${newSummary.totalBalanceUsd}');

      _cachedSummary = newSummary;
      _perAddressCache['${_lastAddress.toLowerCase()}_$_lastChainKey'] = _cachedSummary!;
      _lastValuationUpdateAt = now;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    IBITIVaultService.instance.removeListener(_onVaultChanged);
    MarketDataService.instance.removeListener(_onMarketPricesChanged);
    super.dispose();
  }
}
