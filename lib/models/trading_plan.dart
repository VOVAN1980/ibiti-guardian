import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/market/quote_engine.dart';
import 'package:ibiti_guardian/services/market/wallet_exposure_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';

enum TradingDirection { buy, sell, swap, swing }

enum TradingRisk {
  low,
  medium,
  high,
  excessive,
}

/// A structured trading plan built from market data, AI settings, and mandate.
///
/// This is a **planning layer** object — NOT a trade order.
/// Price levels (entry/target/stop) are AI-derived heuristics based on
/// recent chart data. They are planning references, not live market orders.
/// Always label them as such in the UI.
class TradingPlan {
  final MarketAsset asset;
  final TradingDirection direction;

  // ── Sizing ─────────────────────────────────────────────────────────────────
  /// Conservative suggested size: 5% of daily limit, capped by mandate/limits.
  final double suggestedSizeUsd;

  /// Hard ceiling = min(perTxLimit, mandate.maxPositionUsd).
  final double maxSizeUsd;

  /// Minimum trade size to justify gas cost.
  final double minViableSizeUsd;

  /// Whether the size math produces a viable (minViable > 0, suggested > min) trade.
  final bool sizeViable;

  // ── AI-Derived Planning Levels ─────────────────────────────────────────────
  /// Current price snapshot at plan creation time.
  final double entryPrice;

  /// AI-derived target based on chart structure (planning reference, not a quote).
  /// Null when insufficient chart data.
  final double? targetPrice;

  /// AI-derived stop level — below this the thesis is invalidated.
  /// Null when insufficient chart data.
  final double? stopLossPrice;

  // ── Venue Intelligence ─────────────────────────────────────────────────────
  /// Preferred venue for buying: highest known volume from available venue
  /// metadata. NOT a live order-book quote.
  final String preferredBuyVenue;

  /// Preferred venue for selling: highest known volume from available venue
  /// metadata. NOT a live order-book quote.
  final String preferredSellVenue;

  /// Human-readable routing note. Always explains the data source.
  final String routeNote;

  // ── Risk ───────────────────────────────────────────────────────────────────
  final TradingRisk riskLevel;
  final String riskNote;

  /// Estimated slippage — based on 24h price range / current price.
  /// Planning heuristic, not a live quote.
  final double estimatedSlippagePct;

  // ── Policy gate ────────────────────────────────────────────────────────────
  final bool executableByAi;
  final String? blockReason;

  // ── Live quote (optional — fetched async after plan is built) ───────────────
  /// Live quote from [QuoteEngine]. Null until fetched asynchronously.
  /// When present, replaces heuristic slippage in UI and AI context.
  final MarketQuoteResult? liveQuote;

  // ── Exposure (optional — from WalletExposureService at plan build time) ──────
  /// Snapshot of the user's current position vs mandate cap for this asset.
  /// Null only when portfolio data is not yet loaded.
  final ExposureSnapshot? exposureSnapshot;

  // ── Context ────────────────────────────────────────────────────────────────
  final String thesis;
  final String zone;
  final AiMode mode;

  const TradingPlan({
    required this.asset,
    required this.direction,
    required this.suggestedSizeUsd,
    required this.maxSizeUsd,
    required this.minViableSizeUsd,
    required this.sizeViable,
    required this.entryPrice,
    this.targetPrice,
    this.stopLossPrice,
    required this.preferredBuyVenue,
    required this.preferredSellVenue,
    required this.routeNote,
    required this.riskLevel,
    required this.riskNote,
    required this.estimatedSlippagePct,
    required this.executableByAi,
    this.blockReason,
    this.liveQuote,
    this.exposureSnapshot,
    required this.thesis,
    required this.zone,
    required this.mode,
  });

  /// Builds a compact, structured AI prompt context string.
  /// Keeps it tight — only what the assistant needs to reason about this trade.
  String toPromptContext() {
    final dirLabel = switch (direction) {
      TradingDirection.buy => 'BUY',
      TradingDirection.sell => 'SELL',
      TradingDirection.swap => 'SWAP',
      TradingDirection.swing => 'SWING TRADE',
    };
    final modeLabel = switch (mode) {
      AiMode.manual => 'Manual (analysis only)',
      AiMode.guarded => 'Guarded (prepare, user confirms)',
      AiMode.fullAutonomy => 'Full Autonomy (execute within limits)',
    };

    final sizeLine = sizeViable
        ? 'Suggested size: \$${suggestedSizeUsd.toStringAsFixed(0)} '
            '(max: \$${maxSizeUsd.toStringAsFixed(0)}, '
            'min viable: \$${minViableSizeUsd.toStringAsFixed(0)})'
        : 'Size NOT viable: ${blockReason ?? "too small vs gas cost"}';

    final levelsLine = (targetPrice != null && stopLossPrice != null)
        ? 'AI planning levels (heuristic, not live quotes): '
            'Entry \$${entryPrice.toStringAsFixed(entryPrice >= 1 ? 2 : 4)}, '
            'Target \$${targetPrice!.toStringAsFixed(targetPrice! >= 1 ? 2 : 4)}, '
            'Stop \$${stopLossPrice!.toStringAsFixed(stopLossPrice! >= 1 ? 2 : 4)}'
        : 'Insufficient chart data for level heuristics — use live price only.';

    // Include live quote data if available — replaces heuristic slippage.
    final quoteLine = liveQuote != null && liveQuote!.isLive
        ? 'Live quote (${liveQuote!.providerName}): '
            'out \$${liveQuote!.expectedOutputUsd?.toStringAsFixed(2) ?? "N/A"} '
            '| slippage ${liveQuote!.actualSlippagePct?.toStringAsFixed(2) ?? "?"}% '
            '| gas \$${liveQuote!.gasEstimateUsd?.toStringAsFixed(2) ?? "?"} '
            '| route: ${liveQuote!.routeSummary}'
        : 'Live quote: not yet fetched. Est. slippage: '
            '${estimatedSlippagePct.toStringAsFixed(2)}% (heuristic).';

    // Include exposure data — AI knows whether it can/cannot add to this position.
    final exposureLine = exposureSnapshot != null
        ? exposureSnapshot!.promptLine
        : 'Exposure[${asset.symbol}]: portfolio data not yet loaded.';

    final executionLine = executableByAi
        ? 'AI can proceed with this plan in current mode.'
        : 'AI execution blocked: ${blockReason ?? "see mandate"}';

    return '''
[Trading Plan Context]
Direction: $dirLabel ${asset.symbol} (${asset.networkGroup})
Mode: $modeLabel
Zone: $zone | Risk: ${riskLevel.name}
$sizeLine
$levelsLine
$quoteLine
$exposureLine
Venues (from metadata, not live quotes): buy via $preferredBuyVenue, sell via $preferredSellVenue
Note: $routeNote
Thesis: $thesis
$executionLine
''';
  }

  String get riskColor => switch (riskLevel) {
        TradingRisk.low => '#4CAF50',
        TradingRisk.medium => '#FFC94A',
        TradingRisk.high => '#FF7043',
        TradingRisk.excessive => '#F44336',
      };
}
