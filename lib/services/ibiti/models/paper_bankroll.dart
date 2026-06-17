// ─── Paper Bankroll ─────────────────────────────────────────────────────────────
//
// Phase 19 → v2 Phase 5: Paper Bankroll = STATS & ACCOUNTING ONLY.
//
// PaperBankroll does NOT decide position sizing. It is a ledger.
//
// What it tracks:
//   - currentBalance (starting + realized PnL)
//   - peakBalance, drawdown (peak vs current)
//   - totalTrades, realizedPnl
//   - available capital (for exposure reporting)
//
// What decides position size:
//   PAPER mode → DailyBudget (temporary training sandbox)
//   REAL mode  → PolicySnapshot / EPK (the law)
//
// Old EQ-based sizing (0.5%/1.5%/3%/5%/8%) has been removed.
// Old strategy-based sizing (riskPercent) has been removed.
// PaperBankroll is NOT the source of truth for trade limits.
//
// After drawdown, balance shrinks → exposure % changes automatically.
// After recovery, balance grows → available capital grows.
// This is passive money management, not active position sizing.
// ─────────────────────────────────────────────────────────────────────────────────

class PaperBankroll {
  /// Default starting virtual capital (used when user hasn't set a limit).
  static const double defaultBudget = 1000.0;

  /// The user-configured trading budget.
  /// This is the MAX capital JARVIS can work with.
  final double maxBudget;

  /// Current virtual balance (starting + realized PnL).
  double currentBalance;

  /// Total realized PnL (sum of all closed trades' netPnl).
  double realizedPnl;

  /// Highest balance ever reached (for drawdown calculation).
  double peakBalance;

  /// Maximum drawdown in USD (peak - lowest point).
  double maxDrawdownUsd;

  /// Maximum drawdown as percent of peak.
  double maxDrawdownPercent;

  /// Total trades executed from this bankroll.
  int totalTrades;

  /// When this bankroll was created.
  final DateTime startedAt;

  /// Last update time.
  DateTime updatedAt;

  PaperBankroll({
    double? maxBudget,
    double? currentBalance,
    this.realizedPnl = 0,
    double? peakBalance,
    this.maxDrawdownUsd = 0,
    this.maxDrawdownPercent = 0,
    this.totalTrades = 0,
    DateTime? startedAt,
    DateTime? updatedAt,
  })  : maxBudget = maxBudget ?? defaultBudget,
        currentBalance = currentBalance ?? (maxBudget ?? defaultBudget),
        peakBalance = peakBalance ?? (maxBudget ?? defaultBudget),
        startedAt = startedAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  // ── Exposure limits (safety rails for reporting) ──────────────────────────

  /// Max total exposure as fraction of balance (for status logging).
  static const double maxTotalExposurePct = 0.80; // 80% max deployed
  static const int maxOpenPositionsSoftCap = 30; // anti-spam
  static const double minPositionSizeUsd = 0.50; // no dust

  /// How much capital is currently available for new positions.
  /// [currentExposure] = sum of all open positions' remaining size.
  /// Used for exposure reporting and status logging.
  double availableCapital(double currentExposure) {
    final maxExposure = currentBalance * maxTotalExposurePct;
    return (maxExposure - currentExposure).clamp(0, currentBalance);
  }

  // ── Update on trade close ─────────────────────────────────────────────────

  /// Record a closed trade's PnL into the bankroll.
  /// This is pure accounting — no sizing decisions.
  void recordTradeResult(double netPnl) {
    realizedPnl += netPnl;
    currentBalance = maxBudget + realizedPnl;
    totalTrades++;
    updatedAt = DateTime.now();

    // Update peak.
    if (currentBalance > peakBalance) {
      peakBalance = currentBalance;
    }

    // Update drawdown.
    final currentDrawdown = peakBalance - currentBalance;
    if (currentDrawdown > maxDrawdownUsd) {
      maxDrawdownUsd = currentDrawdown;
      maxDrawdownPercent =
          peakBalance > 0 ? (currentDrawdown / peakBalance * 100) : 0;
    }
  }

  // ── Queries ───────────────────────────────────────────────────────────────

  /// Current drawdown from peak in USD.
  double get currentDrawdownUsd => peakBalance - currentBalance;

  /// Current drawdown from peak in percent.
  double get currentDrawdownPercent =>
      peakBalance > 0 ? (currentDrawdownUsd / peakBalance * 100) : 0;

  /// ROI since start.
  double get roiPercent => (realizedPnl / maxBudget * 100);

  /// Whether the bankroll is in significant drawdown (>10%).
  bool get isInDrawdown => currentDrawdownPercent > 10;

  /// Whether the bankroll is critically low (<50% of initial).
  bool get isCritical => currentBalance < maxBudget * 0.5;

  /// Compact log string.
  String toLogLine() =>
      '[PAPER_BANKROLL] virtual=\$1000 goal=positive_net_pnl | Bankroll: '
      '\$${currentBalance.toStringAsFixed(2)}/'
      '\$${maxBudget.toStringAsFixed(0)} '
      '(${roiPercent >= 0 ? "+" : ""}${roiPercent.toStringAsFixed(1)}%) '
      'peak=\$${peakBalance.toStringAsFixed(2)} '
      'DD=${currentDrawdownPercent.toStringAsFixed(1)}% '
      'maxDD=${maxDrawdownPercent.toStringAsFixed(1)}% '
      'trades=$totalTrades';

  // ── Serialization ─────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'maxBudget': maxBudget,
        'currentBalance': currentBalance,
        'realizedPnl': realizedPnl,
        'peakBalance': peakBalance,
        'maxDrawdownUsd': maxDrawdownUsd,
        'maxDrawdownPercent': maxDrawdownPercent,
        'totalTrades': totalTrades,
        'startedAt': startedAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory PaperBankroll.fromJson(Map<String, dynamic> json) => PaperBankroll(
        maxBudget: (json['maxBudget'] as num?)?.toDouble(),
        currentBalance: (json['currentBalance'] as num?)?.toDouble(),
        realizedPnl: (json['realizedPnl'] as num?)?.toDouble() ?? 0,
        peakBalance: (json['peakBalance'] as num?)?.toDouble(),
        maxDrawdownUsd: (json['maxDrawdownUsd'] as num?)?.toDouble() ?? 0,
        maxDrawdownPercent:
            (json['maxDrawdownPercent'] as num?)?.toDouble() ?? 0,
        totalTrades: json['totalTrades'] as int? ?? 0,
        startedAt: DateTime.tryParse(json['startedAt'] as String? ?? ''),
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
      );

  @override
  String toString() => toLogLine();
}
