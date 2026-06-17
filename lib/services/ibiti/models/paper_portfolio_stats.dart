// ─── Paper Portfolio Stats ──────────────────────────────────────────────────────
//
// Aggregate statistics from all paper trades.
// Used by Brain to self-calibrate: if win rate is low, be more conservative.
// Used by UI to show IBITI's track record before unlocking real trading.
// ─────────────────────────────────────────────────────────────────────────────────

/// Aggregated statistics for IBITI's paper trading portfolio.
class PaperPortfolioStats {
  /// Total closed trades.
  final int totalTrades;

  /// Trades that ended with positive net PnL.
  final int wins;

  /// Trades that ended with zero or negative net PnL.
  final int losses;

  /// Win rate (0.0–1.0). 0 if no trades.
  double get winRate => totalTrades > 0 ? wins / totalTrades : 0;

  /// Cumulative net PnL in USD across all closed trades.
  final double totalPnlUsd;

  /// Average net PnL per trade in USD.
  double get avgPnlUsd => totalTrades > 0 ? totalPnlUsd / totalTrades : 0;

  /// Average net PnL per trade as percentage of entry size.
  final double avgPnlPercent;

  /// Best single trade net PnL in USD.
  final double bestTradeUsd;

  /// Worst single trade net PnL in USD.
  final double worstTradeUsd;

  /// Number of currently open trades.
  final int openCount;

  /// Total USD currently deployed in open trades.
  final double currentExposureUsd;

  /// Profit factor: gross wins / gross losses. > 1.0 = profitable.
  /// Infinity if no losses, 0 if no wins.
  final double profitFactor;

  /// Number of consecutive wins (current streak).
  final int winStreak;

  /// Number of consecutive losses (current streak).
  final int lossStreak;

  /// Maximum drawdown observed (peak-to-trough of equity curve).
  final double maxDrawdownUsd;

  const PaperPortfolioStats({
    this.totalTrades = 0,
    this.wins = 0,
    this.losses = 0,
    this.totalPnlUsd = 0,
    this.avgPnlPercent = 0,
    this.bestTradeUsd = 0,
    this.worstTradeUsd = 0,
    this.openCount = 0,
    this.currentExposureUsd = 0,
    this.profitFactor = 0,
    this.winStreak = 0,
    this.lossStreak = 0,
    this.maxDrawdownUsd = 0,
  });

  /// Empty stats — no trades yet.
  static const empty = PaperPortfolioStats();

  /// Whether IBITI has enough data to be confident in its stats.
  /// Minimum 20 closed trades to be statistically meaningful.
  bool get isStatisticallyMeaningful => totalTrades >= 20;

  /// Confidence tier for unlocking real trading.
  /// Returns a label and threshold for UI display.
  String get performanceTier {
    if (totalTrades < 10) return 'TRAINING';
    if (totalTrades < 20) return 'CALIBRATING';
    if (winRate >= 0.6 && profitFactor > 1.5) return 'PROVEN';
    if (winRate >= 0.5 && profitFactor > 1.0) return 'PROMISING';
    if (winRate >= 0.4) return 'LEARNING';
    return 'NEEDS_WORK';
  }

  /// Whether paper stats suggest IBITI is ready for real trading.
  bool get readyForReal =>
      isStatisticallyMeaningful &&
      winRate >= 0.55 &&
      profitFactor >= 1.3 &&
      maxDrawdownUsd.abs() < totalPnlUsd.abs();

  @override
  String toString() => 'PaperStats(trades=$totalTrades W=$wins L=$losses '
      'WR=${(winRate * 100).toStringAsFixed(1)}% '
      'PnL=\$${totalPnlUsd.toStringAsFixed(2)} '
      'PF=${profitFactor.toStringAsFixed(2)} '
      'tier=$performanceTier)';

  Map<String, dynamic> toJson() => {
        'totalTrades': totalTrades,
        'wins': wins,
        'losses': losses,
        'winRate': winRate,
        'totalPnlUsd': totalPnlUsd,
        'avgPnlPercent': avgPnlPercent,
        'bestTradeUsd': bestTradeUsd,
        'worstTradeUsd': worstTradeUsd,
        'openCount': openCount,
        'currentExposureUsd': currentExposureUsd,
        'profitFactor': profitFactor,
        'winStreak': winStreak,
        'lossStreak': lossStreak,
        'maxDrawdownUsd': maxDrawdownUsd,
        'performanceTier': performanceTier,
        'readyForReal': readyForReal,
      };
}
