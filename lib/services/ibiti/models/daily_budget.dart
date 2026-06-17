// ─── Daily Budget ────────────────────────────────────────────────────────────
//
// IBITI v2: Daily capital management.
//
// The USER sets a daily trading limit (e.g. $1000/day).
// JARVIS manages this budget autonomously:
//   - 75% working capital for trades
//   - 25% reserve for high-conviction entries (requires multi-factor proof)
//   - Paper trading day: 00:01 → 23:55 (local time)
//   - Settlement: 23:55 → close paper positions/report
//     Real trading settlement is enforced by App Policy / EPK
//
// DEFAULTS:
//   Real trading: $0 (OFF) — user MUST explicitly set a limit.
//   Paper trading: $1000 — virtual paper bankroll.
//
// NO SLOTS. NO ROLES. NO DISPLACEMENT.
// Just: daily limit → analyze → enter small → scale if confirmed → exit smart.
//
// Budget resets at 00:01 each day, NOT at app start.
// If user sets limit at 09:00, it works until 23:59 today.
// Tomorrow a fresh budget starts at 00:01.
// ─────────────────────────────────────────────────────────────────────────────

/// Justification required to tap the 25% reserve.
/// EQ alone is not enough — it has proven it can lie.
/// Multiple factors must align.
class ReserveJustification {
  final double entryQuality;
  final String flowClass;
  final bool costsPositive;
  final bool trajectoryConfirmed;
  final bool noWhaleExitSigns;
  final bool strategyAllowed;

  const ReserveJustification({
    required this.entryQuality,
    required this.flowClass,
    required this.costsPositive,
    required this.trajectoryConfirmed,
    required this.noWhaleExitSigns,
    required this.strategyAllowed,
  });

  /// ALL conditions must pass to unlock reserve.
  bool get approved =>
      entryQuality >= 0.90 &&
      (flowClass == 'seriousInflow' || flowClass == 'whaleInflow') &&
      costsPositive &&
      trajectoryConfirmed &&
      noWhaleExitSigns &&
      strategyAllowed;

  String get reason {
    final fails = <String>[];
    if (entryQuality < 0.90) fails.add('EQ<0.90');
    if (flowClass != 'seriousInflow' && flowClass != 'whaleInflow') {
      fails.add('flow=$flowClass');
    }
    if (!costsPositive) fails.add('costs_negative');
    if (!trajectoryConfirmed) fails.add('no_trajectory');
    if (!noWhaleExitSigns) fails.add('whale_exit_detected');
    if (!strategyAllowed) fails.add('strategy_blocked');
    return fails.isEmpty ? 'all_passed' : fails.join('+');
  }
}

/// Daily trading budget for JARVIS capital management.
class DailyBudget {
  /// Default limits.
  /// Real trading = $0 (OFF). User MUST explicitly enable.
  /// Paper trading = $1000 (virtual paper bankroll).
  static const double defaultRealLimit = 0.0;
  static const double defaultPaperLimit = 1000.0;

  /// User-configured daily trading limit in USD.
  final double dailyLimitUsd;

  /// Calendar date this budget covers (local time, date-only).
  final DateTime tradingDate;

  // ── Explicit exposure tracking ──────────────────────────────────────────
  // These track EXACTLY where money is right now. No ambiguity.

  /// USD currently locked in open positions (sum of all open trades' sizes).
  /// Updated on entry (+), scale-in (+), and close (-).
  double openExposureUsd;

  /// How much of the 75% working capital has been allocated (including closed).
  double workingSpentUsd;

  /// How much of the 25% reserve has been allocated (including closed).
  double reserveSpentUsd;

  // ── Daily stats ─────────────────────────────────────────────────────────

  /// Realized PnL for today (sum of all closed trades' netPnl).
  double realizedPnlToday;

  /// Number of trades opened today.
  int tradesOpenedToday;

  /// Number of trades closed today.
  int tradesClosedToday;

  /// Number of winning trades today.
  int winsToday;

  /// Best single trade PnL today.
  double bestTradePnl;

  /// Worst single trade PnL today.
  double worstTradePnl;

  /// When this budget was created.
  final DateTime createdAt;

  DailyBudget({
    required this.dailyLimitUsd,
    DateTime? tradingDate,
    this.openExposureUsd = 0,
    this.workingSpentUsd = 0,
    this.reserveSpentUsd = 0,
    this.realizedPnlToday = 0,
    this.tradesOpenedToday = 0,
    this.tradesClosedToday = 0,
    this.winsToday = 0,
    this.bestTradePnl = 0,
    this.worstTradePnl = 0,
    DateTime? createdAt,
  })  : tradingDate = tradingDate ?? _todayDate(),
        createdAt = createdAt ?? DateTime.now();

  // ── Capital Allocation ───────────────────────────────────────────────────

  /// 75% of daily limit = working capital for normal trades.
  double get workingCapitalUsd => dailyLimitUsd * 0.75;

  /// 25% of daily limit = reserve for high-conviction entries only.
  double get reserveCapitalUsd => dailyLimitUsd * 0.25;

  /// How much working capital is still available.
  /// Simple: allocation - what's been spent from working pool.
  double get availableWorkingUsd =>
      (workingCapitalUsd - workingSpentUsd).clamp(0, workingCapitalUsd);

  /// How much reserve capital is still available.
  double get availableReserveUsd =>
      (reserveCapitalUsd - reserveSpentUsd).clamp(0, reserveCapitalUsd);

  /// Total available capital (working + reserve).
  double get totalAvailableUsd => availableWorkingUsd + availableReserveUsd;

  /// Can we open a new trade with working capital?
  bool get canTradeFromWorking => availableWorkingUsd >= 0.50;

  /// Can we tap reserve? Requires multi-factor proof.
  /// EQ alone is not enough — it has proven it can lie (180 scouts, 0 wins).
  /// ALL conditions in [justification] must pass.
  bool canUseReserve(ReserveJustification justification) =>
      justification.approved && availableReserveUsd >= 0.50;

  /// Check if a specific size can be allocated from working capital.
  bool canAllocateWorking(double sizeUsd) =>
      sizeUsd > 0 && sizeUsd <= availableWorkingUsd;

  /// Check if a specific size can be allocated from reserve.
  bool canAllocateReserve(double sizeUsd, ReserveJustification justification) =>
      sizeUsd > 0 &&
      sizeUsd <= availableReserveUsd &&
      canUseReserve(justification);

  /// Exposure as % of daily limit.
  double get exposurePct =>
      dailyLimitUsd > 0 ? openExposureUsd / dailyLimitUsd : 0;

  // ── Entry/Exit Accounting ──────────────────────────────────────────────

  /// Record a new trade entry from working capital.
  void recordEntry(double sizeUsd) {
    assert(sizeUsd > 0, 'Entry size must be positive');
    openExposureUsd += sizeUsd;
    workingSpentUsd += sizeUsd;
    tradesOpenedToday++;
  }

  /// Record a new trade entry from reserve capital.
  void recordReserveEntry(double sizeUsd) {
    assert(sizeUsd > 0, 'Entry size must be positive');
    openExposureUsd += sizeUsd;
    reserveSpentUsd += sizeUsd;
    tradesOpenedToday++;
  }

  /// Record a trade close. Returns freed capital to the pool it came from.
  /// [entrySizeUsd] = total invested (initial + scale-ins).
  /// [netPnl] = final PnL after fees.
  /// [fromReserve] = how much of entrySizeUsd came from reserve.
  void recordClose(
    double entrySizeUsd,
    double netPnl, {
    double fromReserve = 0,
  }) {
    openExposureUsd =
        (openExposureUsd - entrySizeUsd).clamp(0, double.infinity);
    // Return capital: working gets back what it spent, reserve gets back what it spent.
    final fromWorking = entrySizeUsd - fromReserve;
    workingSpentUsd = (workingSpentUsd - fromWorking).clamp(0, double.infinity);
    reserveSpentUsd = (reserveSpentUsd - fromReserve).clamp(0, double.infinity);
    realizedPnlToday += netPnl;
    tradesClosedToday++;
    if (netPnl > 0) winsToday++;
    if (netPnl > bestTradePnl) bestTradePnl = netPnl;
    if (netPnl < worstTradePnl) worstTradePnl = netPnl;
  }

  /// Record a scale-in (additional entry into existing position).
  void recordScaleIn(double sizeUsd, {bool fromReserve = false}) {
    openExposureUsd += sizeUsd;
    if (fromReserve) {
      reserveSpentUsd += sizeUsd;
    } else {
      workingSpentUsd += sizeUsd;
    }
  }

  // ── Day Boundary ─────────────────────────────────────────────────────────

  /// Is this budget for the current calendar day (local time)?
  bool get isToday {
    final now = DateTime.now();
    return tradingDate.year == now.year &&
        tradingDate.month == now.month &&
        tradingDate.day == now.day;
  }

  /// Minutes until end of trading day (23:59 local).
  int get minutesUntilClose {
    final now = DateTime.now();
    final endOfDay = DateTime(now.year, now.month, now.day, 23, 59);
    return endOfDay.difference(now).inMinutes.clamp(0, 1440);
  }

  /// Is it time for end-of-day settlement?
  /// Strictly 23:55–23:59 local time. Not 23:54.
  bool get isSettlementTime {
    final now = DateTime.now();
    return now.hour == 23 && now.minute >= 55;
  }

  /// Is the trading day over? (past 23:59)
  bool get isDayOver => minutesUntilClose <= 0;

  /// Is it too early to trade? (00:00–00:00:59 local)
  bool get isTooEarly {
    final now = DateTime.now();
    return now.hour == 0 && now.minute < 1;
  }

  // ── Stats ────────────────────────────────────────────────────────────────

  /// Win rate for today (0.0–1.0).
  double get winRate =>
      tradesClosedToday > 0 ? winsToday / tradesClosedToday : 0;

  /// Current utilization: how much of the daily limit is currently in open positions.
  /// NOTE: This is current exposure, NOT daily turnover. Decreases when trades close.
  double get currentUtilizationPct => dailyLimitUsd > 0
      ? (workingSpentUsd + reserveSpentUsd) / dailyLimitUsd
      : 0;

  /// ROI for today.
  double get roiPct =>
      dailyLimitUsd > 0 ? realizedPnlToday / dailyLimitUsd * 100 : 0;

  /// Compact log string.
  String toLogLine() => '[BUDGET] '
      'work=\$${availableWorkingUsd.toStringAsFixed(2)}/'
      '\$${workingCapitalUsd.toStringAsFixed(2)} '
      'rsv=\$${availableReserveUsd.toStringAsFixed(2)}/'
      '\$${reserveCapitalUsd.toStringAsFixed(2)} '
      'open=\$${openExposureUsd.toStringAsFixed(2)}'
      '(${(exposurePct * 100).toStringAsFixed(0)}%) '
      'trades=$tradesOpenedToday '
      'PnL=${realizedPnlToday >= 0 ? "+" : ""}'
      '\$${realizedPnlToday.toStringAsFixed(4)} '
      'WR=${(winRate * 100).toStringAsFixed(0)}% '
      'until=${minutesUntilClose}m';

  /// End-of-day report.
  String toDayReport() => '[DAY_END] '
      '${tradingDate.toIso8601String().substring(0, 10)} | '
      'Trades: $tradesClosedToday | '
      'WR: ${(winRate * 100).toStringAsFixed(1)}% | '
      'PnL: ${realizedPnlToday >= 0 ? "+" : ""}'
      '\$${realizedPnlToday.toStringAsFixed(4)} | '
      'Best: +\$${bestTradePnl.toStringAsFixed(4)} | '
      'Worst: \$${worstTradePnl.toStringAsFixed(4)} | '
      'ROI: ${roiPct.toStringAsFixed(1)}% | '
      'Used: ${(currentUtilizationPct * 100).toStringAsFixed(0)}%';

  // ── Factory ──────────────────────────────────────────────────────────────

  /// Create a fresh budget for today.
  factory DailyBudget.forToday(double dailyLimitUsd) => DailyBudget(
        dailyLimitUsd: dailyLimitUsd,
        tradingDate: _todayDate(),
      );

  /// Create with a new daily limit (preserves today's stats if same day).
  DailyBudget withNewLimit(double newLimit) => DailyBudget(
        dailyLimitUsd: newLimit,
        tradingDate: tradingDate,
        openExposureUsd: openExposureUsd,
        workingSpentUsd: workingSpentUsd,
        reserveSpentUsd: reserveSpentUsd,
        realizedPnlToday: realizedPnlToday,
        tradesOpenedToday: tradesOpenedToday,
        tradesClosedToday: tradesClosedToday,
        winsToday: winsToday,
        bestTradePnl: bestTradePnl,
        worstTradePnl: worstTradePnl,
        createdAt: createdAt,
      );

  // ── Serialization ────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'dailyLimitUsd': dailyLimitUsd,
        'tradingDate': tradingDate.toIso8601String(),
        'openExposureUsd': openExposureUsd,
        'workingSpentUsd': workingSpentUsd,
        'reserveSpentUsd': reserveSpentUsd,
        'realizedPnlToday': realizedPnlToday,
        'tradesOpenedToday': tradesOpenedToday,
        'tradesClosedToday': tradesClosedToday,
        'winsToday': winsToday,
        'bestTradePnl': bestTradePnl,
        'worstTradePnl': worstTradePnl,
        'createdAt': createdAt.toIso8601String(),
      };

  /// Deserialize. [isPaper] controls the default limit fallback:
  ///   isPaper=true  → defaults to $10 (learning mode).
  ///   isPaper=false → defaults to $0 (OFF, user must set explicitly).
  factory DailyBudget.fromJson(
    Map<String, dynamic> json, {
    required bool isPaper,
  }) =>
      DailyBudget(
        dailyLimitUsd: (json['dailyLimitUsd'] as num?)?.toDouble() ??
            (isPaper ? defaultPaperLimit : defaultRealLimit),
        tradingDate: DateTime.tryParse(json['tradingDate'] as String? ?? ''),
        openExposureUsd: (json['openExposureUsd'] as num?)?.toDouble() ?? 0,
        workingSpentUsd: (json['workingSpentUsd'] as num?)?.toDouble() ?? 0,
        reserveSpentUsd: (json['reserveSpentUsd'] as num?)?.toDouble() ?? 0,
        realizedPnlToday: (json['realizedPnlToday'] as num?)?.toDouble() ?? 0,
        tradesOpenedToday: json['tradesOpenedToday'] as int? ?? 0,
        tradesClosedToday: json['tradesClosedToday'] as int? ?? 0,
        winsToday: json['winsToday'] as int? ?? 0,
        bestTradePnl: (json['bestTradePnl'] as num?)?.toDouble() ?? 0,
        worstTradePnl: (json['worstTradePnl'] as num?)?.toDouble() ?? 0,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      );

  /// Helper: today as date-only DateTime (midnight local).
  static DateTime _todayDate() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  String toString() => toLogLine();
}
