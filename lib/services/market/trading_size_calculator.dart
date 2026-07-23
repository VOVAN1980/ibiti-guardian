import 'dart:math' as math;

import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';

/// Result of a trade size calculation.
class TradeSizeResult {
  /// Conservative suggested size in USD.
  final double suggestedUsd;

  /// Maximum allowed size (hard ceiling from mandate + AI limits).
  final double maxUsd;

  /// Minimum viable size (must exceed gas cost by a safe ratio).
  final double minViableUsd;

  /// Whether the suggested size is above the minimum viable threshold.
  final bool viable;

  /// Human-readable reason why a trade is not viable, or null if viable.
  final String? blockReason;

  const TradeSizeResult({
    required this.suggestedUsd,
    required this.maxUsd,
    required this.minViableUsd,
    required this.viable,
    this.blockReason,
  });
}

/// Calculates a trade size that respects AI limits, mandate constraints,
/// gas cost ratios, and liquidity tiers.
///
/// Rule priority (lowest wins — strictest constraint):
///   1. min(perTxLimit, mandate.maxPositionUsd)  → hard ceiling
///   2. 5% of dailyLimit                          → conservative start
///   3. clamp by liquidity tier                   → illiquid assets are capped
///   4. clamp by volatility tier                  → high-vol assets sized down
///   5. minViable = maxGasUsd × 15               → gas ratio guard
///
/// This is a planning-layer calculation.
/// Final execution sizing happens in GuardianExecutionController via real quote.
class TradingSizeCalculator {
  TradingSizeCalculator._();

  /// Minimum gas multiplier: trade must be at least N× the expected gas cost.
  static const double _gasRatioFloor = 15.0;

  /// Volume threshold below which an asset is considered illiquid (USD/day).
  static const double _illiquidVolumeThreshold = 100000.0; // $100K

  /// Volume threshold below which we consider medium liquidity.
  static const double _mediumVolumeThreshold = 10000000.0; // $10M

  /// Cap for illiquid assets.
  static const double _illiquidCap = 10.0;

  /// Cap for medium-liquidity assets.
  static const double _mediumLiquidityCap = 100.0;

  /// Volatility threshold: 24h change above this triggers size reduction.
  static const double _highVolatilityThreshold = 8.0; // 8% 24h

  /// Factor applied to size when asset is highly volatile.
  static const double _highVolatilitySizeFactor = 0.5;

  static TradeSizeResult calculate(
    MarketAsset asset,
    AiControlSettings settings,
  ) {
    final mandate = settings.mandate;

    // ── 1. Hard ceiling ──────────────────────────────────────────────────────
    // Per-trade size is bounded by the autonomy mandate position cap.
    final hardCap = mandate.maxPositionUsd;

    // ── 2. Gas ratio floor ───────────────────────────────────────────────────
    // Trade must be ≥ _gasRatioFloor × expected gas cost to be gas-efficient.
    final minViable = mandate.maxGasUsd * _gasRatioFloor;

    // ── 3. Feasibility check: does a valid window [minViable, hardCap] exist?
    // If minViable > hardCap there is no size that satisfies both constraints.
    // We report this immediately — computing suggestion would be meaningless.
    if (hardCap <= 0) {
      return TradeSizeResult(
        suggestedUsd: 0,
        maxUsd: hardCap,
        minViableUsd: minViable,
        viable: false,
        blockReason: 'Per-tx limit or mandate maxPositionUsd is zero.',
      );
    }

    if (minViable > hardCap) {
      return TradeSizeResult(
        suggestedUsd: 0,
        maxUsd: hardCap,
        minViableUsd: minViable,
        viable: false,
        blockReason: 'Gas floor (\$${minViable.toStringAsFixed(0)} = '
            'maxGasUsd × $_gasRatioFloor) exceeds your per-tx cap '
            '(\$${hardCap.toStringAsFixed(0)}). '
            'Lower maxGasUsd in your mandate or raise the per-tx limit.',
      );
    }

    // ── 4. Conservative start: 5% of daily limit ────────────────────────────
    // We now know a valid window exists. Start conservative, then clamp.
    double suggestion = settings.dailyLimit * 0.05;

    // ── 5. Liquidity tier cap ─────────────────────────────────────────────────
    if (asset.volume < _illiquidVolumeThreshold) {
      suggestion = math.min(suggestion, _illiquidCap);
    } else if (asset.volume < _mediumVolumeThreshold) {
      suggestion = math.min(suggestion, _mediumLiquidityCap);
    }

    // ── 6. Volatility reduction ───────────────────────────────────────────────
    final absChange = asset.change24h.abs();
    if (absChange >= _highVolatilityThreshold) {
      suggestion = suggestion * _highVolatilitySizeFactor;
    }

    // ── 7. Clamp to valid window [minViable, hardCap] ─────────────────────────
    // suggestion is always ≥ minViable AND ≤ hardCap after this step.
    // There is no ambiguity: the window is guaranteed to exist (checked above).
    suggestion = suggestion.clamp(minViable, hardCap);

    // ── 8. Determine viability and optional note ──────────────────────────────
    String? blockReason;
    bool viable = true;

    if (asset.volume < _illiquidVolumeThreshold) {
      // Viable (suggestion fits mandate), but caller should display a note.
      blockReason = 'Asset is illiquid (24h volume '
          '\$${asset.volume.toStringAsFixed(0)}). '
          'Capped at \$${suggestion.toStringAsFixed(0)}.';
      // Not a hard block — still viable.
    }

    return TradeSizeResult(
      suggestedUsd: suggestion,
      maxUsd: hardCap,
      minViableUsd: minViable,
      viable: viable,
      blockReason: blockReason,
    );
  }
}
