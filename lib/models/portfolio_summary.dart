import 'package:ibiti_guardian/models/wallet_asset.dart';

class PortfolioSummary {
  final double totalBalanceUsd;
  final int assetsCount;

  /// Full list of all assets — no cap. Use [topAssets] for dashboard previews.
  final List<WalletAsset> allAssets;
  final String address;
  final String networkName;
  final String chainKey;
  final bool isSupported;

  /// 24h total portfolio value change in USD.
  final double totalChangeUsd;

  /// 24h total portfolio value change as percentage.
  final double totalChangePct;

  /// True when at least one asset has 24h price change data.
  final bool hasPerformanceData;

  /// True when at least one asset has no price source.
  /// UI can use this to show "Some assets have no price data" disclaimer.
  final bool hasUnpricedAssets;

  PortfolioSummary({
    required this.totalBalanceUsd,
    required this.assetsCount,
    required this.allAssets,
    required this.address,
    required this.networkName,
    required this.chainKey,
    this.isSupported = true,
    this.totalChangeUsd = 0.0,
    this.totalChangePct = 0.0,
    this.hasPerformanceData = false,
    this.hasUnpricedAssets = false,
  });

  /// Top 5 assets for compact dashboard display.
  List<WalletAsset> get topAssets => allAssets.take(5).toList();

  /// Rebuild this summary with enriched performance data from assets.
  /// Recalculates totalBalanceUsd from priced assets only.
  PortfolioSummary withPerformance() {
    double recalculatedTotal = 0.0;
    double changeUsd = 0.0;
    bool hasData = false;
    bool hasUnpriced = false;

    for (final a in allAssets) {
      if (a.priceAvailable) {
        recalculatedTotal += a.valueUsd;
      } else {
        hasUnpriced = true;
      }

      if (a.valueChange24hUsd != null) {
        changeUsd += a.valueChange24hUsd!;
        hasData = true;
      }
    }

    final previousTotal = recalculatedTotal - changeUsd;
    final changePct =
        previousTotal > 0 ? (changeUsd / previousTotal) * 100 : 0.0;

    return PortfolioSummary(
      totalBalanceUsd: recalculatedTotal,
      assetsCount: assetsCount,
      allAssets: allAssets,
      address: address,
      networkName: networkName,
      chainKey: chainKey,
      isSupported: isSupported,
      totalChangeUsd: changeUsd,
      totalChangePct: changePct,
      hasPerformanceData: hasData,
      hasUnpricedAssets: hasUnpriced,
    );
  }

  factory PortfolioSummary.empty() {
    return PortfolioSummary(
      totalBalanceUsd: 0.0,
      assetsCount: 0,
      allAssets: [],
      address: '',
      networkName: 'Not Connected',
      chainKey: '',
      isSupported: false,
    );
  }
}
