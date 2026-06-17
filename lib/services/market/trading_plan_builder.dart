import 'dart:math' as math;

import 'package:ibiti_guardian/models/trading_plan.dart';
import 'package:ibiti_guardian/services/assistant/user_memory_service.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/market/trading_size_calculator.dart';
import 'package:ibiti_guardian/services/market/venue_analyser.dart';
import 'package:ibiti_guardian/services/market/wallet_exposure_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';

/// Assembles a [TradingPlan] from market data and current AI settings.
///
/// This is a pure factory — no network calls, no side effects.
/// All inputs must already be loaded. Chart data is optional; the plan
/// degrades gracefully when chart data is unavailable.
class TradingPlanBuilder {
  TradingPlanBuilder._();

  static TradingPlan build({
    required MarketAsset asset,
    required TradingDirection direction,
    required AiControlSettings settings,
    MarketAssetDetail? detail,

    /// Already-loaded line chart prices (may be empty).
    List<double> chart = const [],
  }) {
    final mandate = settings.mandate;
    final mode = settings.mode;

    // ── Size calculation ─────────────────────────────────────────────────────
    final sizeResult = TradingSizeCalculator.calculate(asset, settings);

    // ── Venue analysis ────────────────────────────────────────────────────────
    final userPrefs = UserMemoryService.instance.preferences;
    final venues = VenueAnalyser.analyse(
      asset,
      detail,
      mandate,
      userPreferredVenue: userPrefs.preferredVenue,
    );

    // ── AI-derived planning levels ────────────────────────────────────────────
    // These are HEURISTICS derived from the chart shape — not live quotes.
    final levels = _deriveLevels(asset, chart, direction);

    // ── Risk classification ───────────────────────────────────────────────────
    final (risk, riskNote) = _classifyRisk(asset, sizeResult);

    // ── Slippage estimate ─────────────────────────────────────────────────────
    // Heuristic: (24h high - 24h low) / current price as % ÷ 2.
    final slippagePct = asset.high24h > 0 && asset.low24h > 0
        ? ((asset.high24h - asset.low24h) / asset.price * 50).clamp(0.1, 5.0)
        : 0.5;

    // ── Exposure check ───────────────────────────────────────────────────────────────
    // Must run BEFORE execution eligibility so we can adjust size + block.
    final exposure = WalletExposureService.instance.snapshotFor(
      asset.symbol,
      mandate,
    );

    // Cap suggestedSize to remaining capacity when position is building.
    // If blocked by exposure, setBlockReason below in the eligibility section.
    double effectiveSuggestedUsd = sizeResult.suggestedUsd;
    if (direction == TradingDirection.buy ||
        direction == TradingDirection.swing) {
      effectiveSuggestedUsd = WalletExposureService.instance
          .cappedAddition(exposure, effectiveSuggestedUsd);
    }

    // ── Execution eligibility ────────────────────────────────────────────────────────────
    bool executableByAi = false;
    String? blockReason;

    if (mode == AiMode.manual) {
      blockReason = 'Manual mode — analysis only. No execution.';
    } else if (exposure.action == ExposureAction.blockedByExposure &&
        (direction == TradingDirection.buy ||
            direction == TradingDirection.swing)) {
      blockReason = exposure.concentrationNote;
    } else if (!mandate.allowsAsset(asset.symbol)) {
      blockReason = '${asset.symbol} is not in your mandate allowed-assets.';
    } else if (!mandate.allowsNetwork(asset.networkGroup)) {
      blockReason =
          '${asset.networkGroup} is not in your mandate allowed-networks.';
    } else if (venues.allowedVenues.isEmpty &&
        mandate.allowedVenues.isNotEmpty) {
      blockReason = 'No allowed venues for ${asset.symbol}. '
          'Blocked: ${venues.blockedVenues.take(2).join(", ")}.';
    } else if (!sizeResult.viable) {
      blockReason =
          sizeResult.blockReason ?? 'Trade size not viable vs gas cost.';
    } else if (risk == TradingRisk.excessive) {
      blockReason = 'Risk level is excessive (volatility too high). '
          'Manual review recommended.';
    } else {
      executableByAi = true;
    }

    // ── Thesis ────────────────────────────────────────────────────────────────
    final thesis =
        _buildThesis(asset, direction, sizeResult, effectiveSuggestedUsd);

    // ── Zone ──────────────────────────────────────────────────────────────────
    final zone = _deriveZone(chart, asset);

    return TradingPlan(
      asset: asset,
      direction: direction,
      suggestedSizeUsd: effectiveSuggestedUsd,
      maxSizeUsd: sizeResult.maxUsd,
      minViableSizeUsd: sizeResult.minViableUsd,
      sizeViable: sizeResult.viable,
      entryPrice: asset.price,
      targetPrice: levels.$1,
      stopLossPrice: levels.$2,
      preferredBuyVenue: venues.preferredBuyVenue,
      preferredSellVenue: venues.preferredSellVenue,
      routeNote: venues.routeNote,
      riskLevel: risk,
      riskNote: riskNote,
      estimatedSlippagePct: slippagePct,
      executableByAi: executableByAi,
      blockReason: blockReason,
      exposureSnapshot: exposure,
      thesis: thesis,
      zone: zone,
      mode: mode,
    );
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  /// Derives a (target, stop) pair from chart structure.
  /// Returns (null, null) if chart has fewer than 5 data points.
  static (double?, double?) _deriveLevels(
    MarketAsset asset,
    List<double> chart,
    TradingDirection direction,
  ) {
    if (chart.length < 5) return (null, null);

    final high = chart.reduce(math.max);
    final low = chart.reduce(math.min);
    final range = high - low;
    final current = asset.price;

    if (range < 0.000001) return (null, null);

    switch (direction) {
      case TradingDirection.buy:
        // Enter long: aim for 35% of recent range as target, stop below 20%.
        final target = current + range * 0.35;
        final stop = current - range * 0.20;
        return (target, math.max(stop, current * 0.90));

      case TradingDirection.sell:
        // Exit plan: target 25% below current, invalidation above 15%.
        final target = current - range * 0.25;
        final stop = current + range * 0.15;
        return (math.max(target, 0.0), stop);

      case TradingDirection.swing:
        // Short-term: tight target (15% of range), shallow stop (10%).
        // Faster in/out than a full buy — better R:R for range-bound markets.
        final target = current + range * 0.15;
        final stop = current - range * 0.10;
        return (target, math.max(stop, current * 0.96));

      case TradingDirection.swap:
        // Swap is a route problem, not a directional trade — no levels.
        return (null, null);
    }
  }

  static (TradingRisk, String) _classifyRisk(
    MarketAsset asset,
    TradeSizeResult size,
  ) {
    final volatility = asset.change24h.abs();

    if (volatility >= 15) {
      return (
        TradingRisk.excessive,
        'Extreme 24h volatility (${volatility.toStringAsFixed(1)}%). '
            'High risk of adverse execution.',
      );
    }
    if (volatility >= 8) {
      return (
        TradingRisk.high,
        'High 24h volatility (${volatility.toStringAsFixed(1)}%). '
            'Size down, use limit entries.',
      );
    }
    if (volatility >= 3) {
      return (
        TradingRisk.medium,
        'Moderate volatility (${volatility.toStringAsFixed(1)}%). '
            'Normal risk — review entry zone.',
      );
    }
    return (
      TradingRisk.low,
      'Low volatility (${volatility.toStringAsFixed(1)}%). '
          'Stable conditions for planned entry.',
    );
  }

  static String _buildThesis(
    MarketAsset asset,
    TradingDirection direction,
    TradeSizeResult size,
    double effectiveSizeUsd,
  ) {
    final dirPhrase = switch (direction) {
      TradingDirection.buy => 'enter a long position in',
      TradingDirection.sell => 'exit or reduce',
      TradingDirection.swap => 'rotate into',
      TradingDirection.swing => 'open a short-term swing trade on',
    };
    final statusNote = switch (asset.status) {
      'Breakout' =>
        'Price is breaking out with strong momentum (${_pct(asset.change24h)}).',
      'Bullish' => 'Positive trend with manageable momentum.',
      'Pullback' => 'Short-term pullback (${_pct(asset.change24h)}). '
          'Weekly structure ${asset.change7d >= -10 ? 'intact' : 'weakening'}.',
      'Flush' => 'Heavy sell-off (${_pct(asset.change24h)}). High-risk zone.',
      _ => 'Price is in a ranging structure.',
    };
    // Use effectiveSizeUsd (post-exposure cap) so thesis matches the plan.
    return 'Plan to $dirPhrase ${asset.symbol} — $statusNote '
        'Suggested size: \$${effectiveSizeUsd.toStringAsFixed(0)}.';
  }

  static String _deriveZone(List<double> chart, MarketAsset asset) {
    if (chart.length < 2) return 'Unknown';
    final low = chart.reduce(math.min);
    final high = chart.reduce(math.max);
    final span = (high - low).abs();
    if (span < 0.000001) return 'Flat';
    final pos = (asset.price - low) / span;
    if (pos >= 0.8) return 'Near local highs';
    if (pos <= 0.2) return 'Near local lows';
    return 'Mid-range';
  }

  static String _pct(double v) {
    final sign = v > 0 ? '+' : '';
    return '$sign${v.toStringAsFixed(2)}%';
  }
}
