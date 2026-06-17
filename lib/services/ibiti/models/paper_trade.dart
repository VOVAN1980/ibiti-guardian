// ─── IBITI Paper Trade ──────────────────────────────────────────────────────────
//
// A virtual trade that IBITI "would have made" in observeOnly mode.
// Tracks entry, exit, fees, and net PnL to build real performance statistics
// before any real money is risked.
//
// Status lifecycle: open → closed (by price check) or expired (by timeout).
// v2 default expiry: 4 hours. Clamped [5m, 480m].
//
// v2 scaling: positions can be scaled into (max 3 times).
// PnL is calculated from averageEntryPrice (VWAP of all entries).
// ─────────────────────────────────────────────────────────────────────────────────

/// Status of a paper trade.
enum PaperTradeStatus {
  /// Still open — waiting for exit price.
  open,

  /// Closed by postmortem price check — has real PnL data.
  closed,

  /// Expired — was never closed within the expiry window.
  expired,
}

/// Why a paper trade was closed.
enum PaperCloseReason {
  /// Price reached take-profit target.
  takeProfit,

  /// Price hit stop-loss floor.
  stopLoss,

  /// Price dropped from peak after trailing stop activation (default +1.5%).
  trailingStop,

  /// Expiry window elapsed without exit trigger.
  expired,

  // ── Phase 21: Thesis-Based Exit Reasons ──

  /// The original entry thesis is no longer valid (buyers disappeared, distribution).
  thesisBroken,

  /// Catastrophic fallback triggered (drawdown > 25%).
  disasterStop,

  /// Thesis weakened and position was partially/fully closed.
  flowExit,

  /// Liquidity completely vanished, making the position unsafe to hold.
  liquidityCollapse,

  // ── v2: New exit reasons ──────────────────────────────────────────────

  /// Flow degraded to retailNoise for 3+ ticks AND price < entry.
  flowDied,

  /// Detected mass whale/large holder exit (volume spike + price drop).
  whaleExit,

  /// End-of-day settlement (23:55 local). All positions closed.
  endOfDay,

  // ── Legacy (kept for DB parsing of old records) ──────────────────────
  // These are NEVER created by v2 logic. Only used to parse old DB rows.

  /// @deprecated v1 only. Displaced by a higher-quality signal.
  displaced,

  /// @deprecated v1 only. Scout failed confirmation.
  scoutRejected,

  /// @deprecated v1 only. Scout succeeded and was promoted to MAIN.
  promoted,
}

/// Phase 15B: Position role.
/// @deprecated v2 does NOT use roles for gating or logic.
/// Kept ONLY for safe parsing of old DB records.
/// New trades always use [PositionRole.active].
enum PositionRole {
  /// v2: The only role. All trades are active.
  active,

  /// @deprecated v1 only. Learning slot.
  scout,

  /// @deprecated v1 only. Working slot.
  main,

  /// @deprecated v1 only. High-conviction slot.
  reserve,
}

extension PositionRoleExt on PositionRole {
  String get label => switch (this) {
        PositionRole.active => 'ACTIVE',
        PositionRole.scout => 'SCOUT',
        PositionRole.main => 'MAIN',
        PositionRole.reserve => 'RESERVE',
      };

  /// Whether this is a legacy v1 role.
  bool get isLegacy => this != PositionRole.active;
}

/// A virtual trade for PnL tracking without real capital.
class PaperTrade {
  /// DB row id (null before INSERT).
  final int? id;

  /// Foreign key to the decision that triggered this trade.
  final int? decisionId;

  /// Exchange where the signal originated.
  final String exchange;

  /// Trading pair symbol, e.g. "AIUSDT".
  final String symbol;

  /// Price at entry (when WOULD_BUY was decided).
  final double entryPrice;

  /// Price at exit (when trade was closed or expired).
  double? exitPrice;

  /// Initial position size in USD.
  final double initialSizeUsd;

  /// Active remaining size in USD (shrinks upon partial exit).
  double remainingSizeUsd;

  /// Gross PnL before fees (from final close only, or legacy).
  double? grossPnl;

  /// Estimated trading fees (from final close only, or legacy).
  double? feesEstimate;

  /// Estimated slippage cost (from final close only, or legacy).
  double? slippageEstimate;

  /// Net PnL after fees and slippage.
  double? netPnl;

  /// Why this trade was entered.
  final String reason;

  /// Current status.
  PaperTradeStatus status;

  /// Why this trade was closed. Null while open.
  PaperCloseReason? closeReason;

  /// High-water mark for trailing stop. Initialized to entryPrice.
  double peakPrice;

  /// Entry quality score at time of trade open (0.0–1.0).
  /// Used for slot competition: weakest trade can be displaced.
  final double entryQuality;

  /// Phase 15B: Position role.
  /// @deprecated v2 always uses [PositionRole.active]. Legacy values parsed safely.
  final PositionRole role;

  /// Target take-profit price (from TA S/R or default +5%).
  /// v2: Mutable — recalculated after scale-in to prevent negative PnL on TP.
  double takeProfitPrice;

  /// Stop-loss price (from TA S/R or default -2%). Now mutable for breakeven trailing.
  double stopLossPrice;

  /// The original SL price set at entry. Required to calculate R distance.
  final double initialStopLossPrice;

  // ── v2: Position Scaling ──

  /// How many times this position was scaled into (max 3).
  int scaleCount;

  /// When this position was last scaled into.
  DateTime? lastScaleAt;

  /// Total USD invested (initial entry + all scale-ins).
  double totalInvestedUsd;

  /// Total quantity held (in coin units). Sum of all entries.
  /// qty = initialSizeUsd/entryPrice + scaleUsd1/scalePrice1 + ...
  double positionQuantity;

  /// Volume-weighted average entry price (VWAP of all entries).
  /// Used for accurate PnL calculation when position has been scaled.
  double averageEntryPrice;

  /// When the trade was opened.
  final DateTime openedAt;

  /// When the trade was closed or expired.
  DateTime? closedAt;

  /// When this trade auto-expires if not closed.
  /// Phase 15C: mutable for Dynamic Hold extensions.
  DateTime expiresAt;

  /// Phase 15C: How many times this trade was extended (max 3).
  int extensions = 0;

  // ── Phase 16C: Scout Confirmation Pipeline (LEGACY — v2 does NOT use) ──
  // Kept for safe parsing of old DB records.

  /// @deprecated v1 only.
  bool isConfirmationPending;

  /// @deprecated v1 only.
  DateTime? confirmationStartedAt;

  /// @deprecated v1 only.
  int confirmationTicks;

  /// @deprecated v1 only.
  double confirmationPeak;

  /// @deprecated v1 only.
  int confirmationHigherLowCount;

  /// The flow class at the moment the trade was opened.
  String initialFlowClass;

  /// @deprecated v1 only.
  bool promotedFromScout;

  /// @deprecated v1 only.
  double? lastConfirmationTickPrice;

  // ── Phase 16D: Partial Exit Tranches ──

  /// Accumulated gross profit from closed tranches.
  double realizedGrossPnl;

  /// Accumulated fees paid on closed tranches.
  double realizedFees;

  /// Accumulated slippage incurred on closed tranches.
  double realizedSlippage;

  /// Flag indicating if the +1R (30%) target was hit.
  bool tranche1Closed;

  /// Flag indicating if the +2R (30%) target was hit.
  bool tranche2Closed;

  // ── Phase 17E: Strategy Knowledge Context ──

  /// Market event type at entry (e.g. 'volumeSpike', 'priceBreakout').
  String eventType;

  /// Candle timing role at entry (from CandleTimingAnalyzer).
  String candleTimingRole;

  // ── Phase 20: Thesis-Based Hold Engine ──

  /// Strategy type at entry (rocket/scalp/momentum/newListing).
  String strategyType;

  // ── Phase 21: Position Thesis Engine ──

  /// JSON serialized thesis of why we entered the trade.
  String? entryThesis;

  /// JSON serialized thesis of why we exited the trade.
  String? exitThesis;

  // ── Phase 10A: Diagnostic Evidence Fields ──
  // Captured at entry and exit to enable JARVIS to explain WHY
  // a trade won or lost with concrete evidence.

  /// Market phase at moment of entry (e.g. 'accumulation', 'markup', 'exhaustion').
  String marketPhaseAtEntry;

  /// Market heartbeat state at entry (e.g. 'active', 'quiet', 'panic').
  String heartbeatAtEntry;

  /// Asset category at entry (e.g. 'meme', 'defi', 'largeAlt', 'microcap').
  String assetCategory;

  /// Risk:Reward ratio at entry (TP distance / SL distance).
  double rrRatioAtEntry;

  /// Volume flow score at entry (numeric, from perception).
  double flowScoreAtEntry;

  /// Flow class at exit (e.g. 'seriousInflow', 'retailNoise', 'noData').
  String flowAtExit;

  /// Market phase at exit.
  String marketPhaseAtExit;

  /// Maximum drawdown from entry (as negative fraction, e.g. -0.03 = -3%).
  double maxDrawdownPct;

  PaperTrade({
    this.id,
    this.decisionId,
    required this.exchange,
    required this.symbol,
    required this.entryPrice,
    this.exitPrice,
    required this.initialSizeUsd,
    double? remainingSizeUsd,
    this.grossPnl,
    this.feesEstimate,
    this.slippageEstimate,
    this.netPnl,
    required this.reason,
    this.status = PaperTradeStatus.open,
    this.closeReason,
    double? peakPrice,
    this.entryQuality = 0,
    this.role = PositionRole.active,
    double? takeProfitPrice,
    double? stopLossPrice,
    double? initialStopLossPrice,
    required this.openedAt,
    this.closedAt,
    DateTime? expiresAt,
    this.extensions = 0,
    this.isConfirmationPending = false,
    this.confirmationStartedAt,
    this.confirmationTicks = 0,
    double? confirmationPeak,
    this.confirmationHigherLowCount = 0,
    this.initialFlowClass = '',
    this.promotedFromScout = false,
    this.realizedGrossPnl = 0.0,
    this.realizedFees = 0.0,
    this.realizedSlippage = 0.0,
    this.tranche1Closed = false,
    this.tranche2Closed = false,
    this.scaleCount = 0,
    this.lastScaleAt,
    this.totalInvestedUsd = 0,
    this.positionQuantity = 0,
    double? averageEntryPrice,
    this.eventType = '',
    this.candleTimingRole = '',
    this.strategyType = 'normalMomentum',
    this.entryThesis,
    this.exitThesis,
    this.marketPhaseAtEntry = '',
    this.heartbeatAtEntry = '',
    this.assetCategory = '',
    this.rrRatioAtEntry = 0,
    this.flowScoreAtEntry = 0,
    this.flowAtExit = '',
    this.marketPhaseAtExit = '',
    this.maxDrawdownPct = 0,
  })  : peakPrice = peakPrice ?? entryPrice,
        confirmationPeak = confirmationPeak ?? entryPrice,
        remainingSizeUsd = remainingSizeUsd ?? initialSizeUsd,
        takeProfitPrice = takeProfitPrice ?? entryPrice * 1.05,
        // Phase 21: Default to Disaster Stop (-25%) instead of scalper stop (-2%)
        stopLossPrice = stopLossPrice ?? entryPrice * 0.75,
        initialStopLossPrice =
            initialStopLossPrice ?? (stopLossPrice ?? entryPrice * 0.75),
        averageEntryPrice = averageEntryPrice ?? entryPrice,
        expiresAt = expiresAt ?? openedAt.add(const Duration(hours: 4)) {
    // If totalInvestedUsd not explicitly set, default to initialSizeUsd.
    if (totalInvestedUsd <= 0) totalInvestedUsd = initialSizeUsd;
    // If positionQuantity not set, calculate from entry.
    if (positionQuantity <= 0 && entryPrice > 0) {
      positionQuantity = initialSizeUsd / entryPrice;
    }
  }

  /// Whether this trade has exceeded its expiry window.
  bool get isExpired =>
      status == PaperTradeStatus.open && DateTime.now().isAfter(expiresAt);

  /// Phase 15C: Current gain from entry, as fraction (0.01 = 1%).
  double gainFromEntry(double currentPrice) =>
      entryPrice > 0 ? (currentPrice - entryPrice) / entryPrice : 0;

  /// Phase 15C: Drawdown from peak, as fraction (-0.01 = -1%).
  double drawdownFromPeak(double currentPrice) =>
      peakPrice > 0 ? (currentPrice - peakPrice) / peakPrice : 0;

  /// Whether trailing stop is active.
  /// [activationThreshold] = fraction gain from entry required (e.g. 0.015 = 1.5%).
  bool isTrailingActive(double activationThreshold) =>
      entryPrice > 0 &&
      (peakPrice - entryPrice) / entryPrice >= activationThreshold;

  /// Calculate final PnL from exit price for the REMAINING size, and aggregate partials.
  /// v2: Uses averageEntryPrice for accurate PnL after scale-ins.
  void close(
    double exit, {
    double fees = 0,
    double slippage = 0,
    required PaperCloseReason reason,
  }) {
    exitPrice = exit;
    final finalGross = (exit - averageEntryPrice) * positionQuantity;

    grossPnl = realizedGrossPnl + finalGross;
    feesEstimate = realizedFees + fees;
    slippageEstimate = realizedSlippage + slippage;

    netPnl = grossPnl! - feesEstimate! - slippageEstimate!;

    status = PaperTradeStatus.closed;
    closeReason = reason;
    closedAt = DateTime.now();
  }

  /// Mark as expired with current price.
  /// v2: Uses averageEntryPrice for accurate PnL.
  void expire(double currentPrice, {double fees = 0, double slippage = 0}) {
    exitPrice = currentPrice;
    final finalGross = (currentPrice - averageEntryPrice) * positionQuantity;

    grossPnl = realizedGrossPnl + finalGross;
    feesEstimate = realizedFees + fees;
    slippageEstimate = realizedSlippage + slippage;

    netPnl = grossPnl! - feesEstimate! - slippageEstimate!;

    status = PaperTradeStatus.expired;
    closeReason = PaperCloseReason.expired;
    closedAt = DateTime.now();
  }

  /// v2: Scale into this position (add more capital at current price).
  /// Updates averageEntryPrice (VWAP), positionQuantity, and totalInvestedUsd.
  void scaleIn(double usd, double price, {DateTime? at}) {
    if (usd <= 0 || price <= 0) return;
    final addQty = usd / price;
    positionQuantity += addQty;
    totalInvestedUsd += usd;
    remainingSizeUsd += usd;
    averageEntryPrice =
        positionQuantity > 0 ? totalInvestedUsd / positionQuantity : price;
    scaleCount++;
    lastScaleAt = at ?? DateTime.now();
  }

  /// v2: Current gain from AVERAGE entry, not original entry.
  double gainFromAvgEntry(double currentPrice) => averageEntryPrice > 0
      ? (currentPrice - averageEntryPrice) / averageEntryPrice
      : 0;

  /// Canonical key for duplicate tracking: "exchange:symbol".
  String get pairKey => '$exchange:$symbol';

  /// How long this trade has been open.
  Duration get holdDuration =>
      (closedAt ?? DateTime.now()).difference(openedAt);

  Map<String, dynamic> toJson() => {
        'id': id,
        'decisionId': decisionId,
        'exchange': exchange,
        'symbol': symbol,
        'entryPrice': entryPrice,
        'exitPrice': exitPrice,
        'initialSizeUsd': initialSizeUsd,
        'remainingSizeUsd': remainingSizeUsd,
        'grossPnl': grossPnl,
        'feesEstimate': feesEstimate,
        'slippageEstimate': slippageEstimate,
        'netPnl': netPnl,
        'reason': reason,
        'status': status.name,
        'closeReason': closeReason?.name,
        'peakPrice': peakPrice,
        'entryQuality': entryQuality,
        'role': role.name,
        'takeProfitPrice': takeProfitPrice,
        'stopLossPrice': stopLossPrice,
        'initialStopLossPrice': initialStopLossPrice,
        'openedAt': openedAt.toIso8601String(),
        'closedAt': closedAt?.toIso8601String(),
        'expiresAt': expiresAt.toIso8601String(),
        'extensions': extensions,
        'isConfirmationPending': isConfirmationPending,
        'confirmationStartedAt': confirmationStartedAt?.toIso8601String(),
        'confirmationTicks': confirmationTicks,
        'confirmationPeak': confirmationPeak,
        'confirmationHigherLowCount': confirmationHigherLowCount,
        'initialFlowClass': initialFlowClass,
        'promotedFromScout': promotedFromScout,
        'realizedGrossPnl': realizedGrossPnl,
        'realizedFees': realizedFees,
        'realizedSlippage': realizedSlippage,
        'tranche1Closed': tranche1Closed,
        'tranche2Closed': tranche2Closed,
        'scaleCount': scaleCount,
        'lastScaleAt': lastScaleAt?.toIso8601String(),
        'totalInvestedUsd': totalInvestedUsd,
        'positionQuantity': positionQuantity,
        'averageEntryPrice': averageEntryPrice,
        'eventType': eventType,
        'candleTimingRole': candleTimingRole,
        'strategyType': strategyType,
        'entryThesis': entryThesis,
        'exitThesis': exitThesis,
        'marketPhaseAtEntry': marketPhaseAtEntry,
        'heartbeatAtEntry': heartbeatAtEntry,
        'assetCategory': assetCategory,
        'rrRatioAtEntry': rrRatioAtEntry,
        'flowScoreAtEntry': flowScoreAtEntry,
        'flowAtExit': flowAtExit,
        'marketPhaseAtExit': marketPhaseAtExit,
        'maxDrawdownPct': maxDrawdownPct,
      };

  factory PaperTrade.fromJson(Map<String, dynamic> json) => PaperTrade(
        id: json['id'] as int?,
        decisionId: json['decisionId'] as int?,
        exchange: json['exchange'] as String? ?? '',
        symbol: json['symbol'] as String? ?? '',
        entryPrice: (json['entryPrice'] as num?)?.toDouble() ?? 0,
        exitPrice: (json['exitPrice'] as num?)?.toDouble(),
        initialSizeUsd: (json['initialSizeUsd'] as num?)?.toDouble() ??
            (json['sizeUsd'] as num?)?.toDouble() ??
            3,
        remainingSizeUsd: (json['remainingSizeUsd'] as num?)?.toDouble(),
        grossPnl: (json['grossPnl'] as num?)?.toDouble(),
        feesEstimate: (json['feesEstimate'] as num?)?.toDouble(),
        slippageEstimate: (json['slippageEstimate'] as num?)?.toDouble(),
        netPnl: (json['netPnl'] as num?)?.toDouble(),
        reason: json['reason'] as String? ?? '',
        status: PaperTradeStatus.values.firstWhere(
          (e) => e.name == json['status'],
          orElse: () => PaperTradeStatus.open,
        ),
        closeReason: json['closeReason'] != null
            ? PaperCloseReason.values.firstWhere(
                (e) => e.name == json['closeReason'],
                orElse: () => PaperCloseReason.expired,
              )
            : null,
        peakPrice: (json['peakPrice'] as num?)?.toDouble(),
        entryQuality: (json['entryQuality'] as num?)?.toDouble() ?? 0,
        role: PositionRole.values.firstWhere(
          (e) => e.name == (json['role'] as String? ?? 'active'),
          orElse: () => PositionRole.active,
        ),
        takeProfitPrice: (json['takeProfitPrice'] as num?)?.toDouble(),
        stopLossPrice: (json['stopLossPrice'] as num?)?.toDouble(),
        initialStopLossPrice:
            (json['initialStopLossPrice'] as num?)?.toDouble(),
        openedAt: DateTime.tryParse(json['openedAt'] as String? ?? '') ??
            DateTime.now(),
        closedAt: json['closedAt'] != null
            ? DateTime.tryParse(json['closedAt'] as String)
            : null,
        expiresAt: json['expiresAt'] != null
            ? DateTime.tryParse(json['expiresAt'] as String)
            : null,
        extensions: json['extensions'] as int? ?? 0,
        isConfirmationPending: json['isConfirmationPending'] as bool? ?? false,
        confirmationStartedAt: json['confirmationStartedAt'] != null
            ? DateTime.tryParse(json['confirmationStartedAt'] as String)
            : null,
        confirmationTicks: json['confirmationTicks'] as int? ?? 0,
        confirmationPeak: (json['confirmationPeak'] as num?)?.toDouble(),
        confirmationHigherLowCount:
            json['confirmationHigherLowCount'] as int? ?? 0,
        initialFlowClass: json['initialFlowClass'] as String? ?? '',
        promotedFromScout: json['promotedFromScout'] as bool? ?? false,
        realizedGrossPnl: (json['realizedGrossPnl'] as num?)?.toDouble() ?? 0.0,
        realizedFees: (json['realizedFees'] as num?)?.toDouble() ?? 0.0,
        realizedSlippage: (json['realizedSlippage'] as num?)?.toDouble() ?? 0.0,
        tranche1Closed: json['tranche1Closed'] as bool? ?? false,
        tranche2Closed: json['tranche2Closed'] as bool? ?? false,
        scaleCount: json['scaleCount'] as int? ?? 0,
        lastScaleAt: json['lastScaleAt'] != null
            ? DateTime.tryParse(json['lastScaleAt'] as String)
            : null,
        totalInvestedUsd: (json['totalInvestedUsd'] as num?)?.toDouble() ?? 0,
        positionQuantity: (json['positionQuantity'] as num?)?.toDouble() ?? 0,
        averageEntryPrice: (json['averageEntryPrice'] as num?)?.toDouble(),
        eventType: json['eventType'] as String? ?? '',
        candleTimingRole: json['candleTimingRole'] as String? ?? '',
        strategyType: json['strategyType'] as String? ?? 'normalMomentum',
        entryThesis: (json['entryThesis'] ?? json['entry_thesis']) as String?,
        exitThesis: (json['exitThesis'] ?? json['exit_thesis']) as String?,
        marketPhaseAtEntry: json['marketPhaseAtEntry'] as String? ?? '',
        heartbeatAtEntry: json['heartbeatAtEntry'] as String? ?? '',
        assetCategory: json['assetCategory'] as String? ?? '',
        rrRatioAtEntry: (json['rrRatioAtEntry'] as num?)?.toDouble() ?? 0,
        flowScoreAtEntry: (json['flowScoreAtEntry'] as num?)?.toDouble() ?? 0,
        flowAtExit: json['flowAtExit'] as String? ?? '',
        marketPhaseAtExit: json['marketPhaseAtExit'] as String? ?? '',
        maxDrawdownPct: (json['maxDrawdownPct'] as num?)?.toDouble() ?? 0,
      );

  PaperTrade copyWith({
    int? id,
    int? decisionId,
    String? exchange,
    String? symbol,
    double? entryPrice,
    double? exitPrice,
    double? initialSizeUsd,
    double? remainingSizeUsd,
    double? grossPnl,
    double? feesEstimate,
    double? slippageEstimate,
    double? netPnl,
    String? reason,
    PaperTradeStatus? status,
    PaperCloseReason? closeReason,
    double? peakPrice,
    double? entryQuality,
    PositionRole? role,
    double? takeProfitPrice,
    double? stopLossPrice,
    double? initialStopLossPrice,
    DateTime? openedAt,
    DateTime? closedAt,
    DateTime? expiresAt,
    int? extensions,
    bool? isConfirmationPending,
    DateTime? confirmationStartedAt,
    int? confirmationTicks,
    double? confirmationPeak,
    int? confirmationHigherLowCount,
    String? initialFlowClass,
    bool? promotedFromScout,
    double? realizedGrossPnl,
    double? realizedFees,
    double? realizedSlippage,
    bool? tranche1Closed,
    bool? tranche2Closed,
    int? scaleCount,
    DateTime? lastScaleAt,
    double? totalInvestedUsd,
    double? positionQuantity,
    double? averageEntryPrice,
    String? eventType,
    String? candleTimingRole,
    String? strategyType,
    String? entryThesis,
    String? exitThesis,
    String? marketPhaseAtEntry,
    String? heartbeatAtEntry,
    String? assetCategory,
    double? rrRatioAtEntry,
    double? flowScoreAtEntry,
    String? flowAtExit,
    String? marketPhaseAtExit,
    double? maxDrawdownPct,
  }) {
    return PaperTrade(
      id: id ?? this.id,
      decisionId: decisionId ?? this.decisionId,
      exchange: exchange ?? this.exchange,
      symbol: symbol ?? this.symbol,
      entryPrice: entryPrice ?? this.entryPrice,
      exitPrice: exitPrice ?? this.exitPrice,
      initialSizeUsd: initialSizeUsd ?? this.initialSizeUsd,
      remainingSizeUsd: remainingSizeUsd ?? this.remainingSizeUsd,
      grossPnl: grossPnl ?? this.grossPnl,
      feesEstimate: feesEstimate ?? this.feesEstimate,
      slippageEstimate: slippageEstimate ?? this.slippageEstimate,
      netPnl: netPnl ?? this.netPnl,
      reason: reason ?? this.reason,
      status: status ?? this.status,
      closeReason: closeReason ?? this.closeReason,
      peakPrice: peakPrice ?? this.peakPrice,
      entryQuality: entryQuality ?? this.entryQuality,
      role: role ?? this.role,
      takeProfitPrice: takeProfitPrice ?? this.takeProfitPrice,
      stopLossPrice: stopLossPrice ?? this.stopLossPrice,
      initialStopLossPrice: initialStopLossPrice ?? this.initialStopLossPrice,
      openedAt: openedAt ?? this.openedAt,
      closedAt: closedAt ?? this.closedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      extensions: extensions ?? this.extensions,
      isConfirmationPending:
          isConfirmationPending ?? this.isConfirmationPending,
      confirmationStartedAt:
          confirmationStartedAt ?? this.confirmationStartedAt,
      confirmationTicks: confirmationTicks ?? this.confirmationTicks,
      confirmationPeak: confirmationPeak ?? this.confirmationPeak,
      confirmationHigherLowCount:
          confirmationHigherLowCount ?? this.confirmationHigherLowCount,
      initialFlowClass: initialFlowClass ?? this.initialFlowClass,
      promotedFromScout: promotedFromScout ?? this.promotedFromScout,
      realizedGrossPnl: realizedGrossPnl ?? this.realizedGrossPnl,
      realizedFees: realizedFees ?? this.realizedFees,
      realizedSlippage: realizedSlippage ?? this.realizedSlippage,
      tranche1Closed: tranche1Closed ?? this.tranche1Closed,
      tranche2Closed: tranche2Closed ?? this.tranche2Closed,
      scaleCount: scaleCount ?? this.scaleCount,
      lastScaleAt: lastScaleAt ?? this.lastScaleAt,
      totalInvestedUsd: totalInvestedUsd ?? this.totalInvestedUsd,
      positionQuantity: positionQuantity ?? this.positionQuantity,
      averageEntryPrice: averageEntryPrice ?? this.averageEntryPrice,
      eventType: eventType ?? this.eventType,
      candleTimingRole: candleTimingRole ?? this.candleTimingRole,
      strategyType: strategyType ?? this.strategyType,
      entryThesis: entryThesis ?? this.entryThesis,
      exitThesis: exitThesis ?? this.exitThesis,
      marketPhaseAtEntry: marketPhaseAtEntry ?? this.marketPhaseAtEntry,
      heartbeatAtEntry: heartbeatAtEntry ?? this.heartbeatAtEntry,
      assetCategory: assetCategory ?? this.assetCategory,
      rrRatioAtEntry: rrRatioAtEntry ?? this.rrRatioAtEntry,
      flowScoreAtEntry: flowScoreAtEntry ?? this.flowScoreAtEntry,
      flowAtExit: flowAtExit ?? this.flowAtExit,
      marketPhaseAtExit: marketPhaseAtExit ?? this.marketPhaseAtExit,
      maxDrawdownPct: maxDrawdownPct ?? this.maxDrawdownPct,
    );
  }
}
