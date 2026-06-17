import 'package:ibiti_guardian/models/portfolio_summary.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';

/// Aggregated portfolio across all supported chains.
///
/// Provides a single `totalUsd` that sums balances from every chain,
/// plus per-chain drill-down via [perChain].
/// Assets are merged into [allAssets] with their source chain preserved
/// in [WalletAsset.chainId].
class UnifiedPortfolioSummary {
  /// Total USD value across ALL chains.
  final double totalUsd;

  /// Per-chain breakdown. Key = chainKey (e.g. 'bsc', 'eth', 'polygon').
  final Map<String, PortfolioSummary> perChain;

  /// All assets from every chain, sorted by valueUsd descending.
  final List<WalletAsset> allAssets;

  /// Chains that failed to load (key = chainKey, value = error message).
  final Map<String, String> failedChains;

  /// Timestamp when this unified summary was last computed.
  final DateTime fetchedAt;

  const UnifiedPortfolioSummary({
    required this.totalUsd,
    required this.perChain,
    required this.allAssets,
    this.failedChains = const {},
    required this.fetchedAt,
  });

  /// Number of chains that returned data.
  int get loadedChainCount => perChain.length;

  /// Total number of unique assets across all chains.
  int get totalAssetsCount => allAssets.length;

  /// Returns per-chain summary for [chainKey], or null if not loaded.
  PortfolioSummary? forChain(String chainKey) => perChain[chainKey];

  /// Top N assets across all chains by USD value.
  List<WalletAsset> topAssets([int n = 5]) => allAssets.take(n).toList();

  /// Whether this summary is stale (older than [duration]).
  bool isStale([Duration duration = const Duration(minutes: 3)]) =>
      DateTime.now().difference(fetchedAt) > duration;

  factory UnifiedPortfolioSummary.empty() => UnifiedPortfolioSummary(
        totalUsd: 0,
        perChain: const {},
        allAssets: const [],
        fetchedAt: DateTime.now(),
      );
}
