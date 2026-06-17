// ─── IBITI Market Event ─────────────────────────────────────────────────────────
//
// A market event is what IBITI *sees*. Not a raw tick, but a meaningful
// observation: "volume just spiked 5×", "price broke 24h high", "this looks
// like a fake breakout". Perception converts ticks → events. Brain reasons
// about events. Constitution gates events.
//
// All 10 event types are defined here. Perception activates detectors
// progressively — the enum is the full vocabulary from day one.
// ─────────────────────────────────────────────────────────────────────────────────

/// Severity determines how urgently IBITI should react.
enum MarketEventSeverity {
  /// Background noise — logged, not acted on.
  info,

  /// Worth attention — Brain should evaluate.
  notable,

  /// Immediate evaluation required.
  critical,
}

/// The 10 types of market events IBITI can perceive.
enum MarketEventType {
  /// Volume surged ≥3× vs recent snapshot.
  volumeSpike,

  /// Price broke above 24h high.
  priceBreakout,

  /// Vertical candle: huge % gain with no meaningful pullback (danger signal).
  exhaustionCandle,

  /// Price spiked above resistance then immediately reversed (trap).
  fakeBreakout,

  /// Price compressing into tight range after a move (accumulation/distribution).
  consolidation,

  /// Significant move on one exchange, silence on others (arbitrage or manipulation).
  crossExchangeMove,

  /// Volume collapsing after a pump (exit liquidity drying up).
  liquidityDrain,

  /// BTC/ETH changed direction — affects everything.
  marketMoodShift,

  /// Newly listed token showing first price action.
  newListingMove,

  /// Established trend continuing with healthy volume (momentum trade).
  trendContinuation,
}

/// Human-readable labels for logging.
extension MarketEventTypeExt on MarketEventType {
  String get label => switch (this) {
        MarketEventType.volumeSpike => 'Всплеск объёма',
        MarketEventType.priceBreakout => 'Пробой цены',
        MarketEventType.exhaustionCandle => 'Свеча истощения',
        MarketEventType.fakeBreakout => 'Ложный пробой',
        MarketEventType.consolidation => 'Консолидация',
        MarketEventType.crossExchangeMove => 'Расхождение бирж',
        MarketEventType.liquidityDrain => 'Слив ликвидности',
        MarketEventType.marketMoodShift => 'Смена настроения рынка',
        MarketEventType.newListingMove => 'Новый листинг',
        MarketEventType.trendContinuation => 'Продолжение тренда',
      };

  /// Default severity for this event type.
  MarketEventSeverity get defaultSeverity => switch (this) {
        MarketEventType.volumeSpike => MarketEventSeverity.notable,
        MarketEventType.priceBreakout => MarketEventSeverity.notable,
        MarketEventType.exhaustionCandle => MarketEventSeverity.critical,
        MarketEventType.fakeBreakout => MarketEventSeverity.critical,
        MarketEventType.consolidation => MarketEventSeverity.info,
        MarketEventType.crossExchangeMove => MarketEventSeverity.notable,
        MarketEventType.liquidityDrain => MarketEventSeverity.critical,
        MarketEventType.marketMoodShift => MarketEventSeverity.critical,
        MarketEventType.newListingMove => MarketEventSeverity.notable,
        MarketEventType.trendContinuation => MarketEventSeverity.info,
      };
}

/// A single market event observed by IBITI Perception.
class MarketEvent {
  final MarketEventType type;
  final MarketEventSeverity severity;

  /// Trading pair symbol, e.g. "AIUSDT".
  final String symbol;

  /// Exchange where the event was detected, e.g. "mexc".
  final String exchange;

  /// Current price at detection time.
  final double price;

  /// 24h price change %.
  final double changePercent;

  /// 24h quote volume in USD.
  final double volume24h;

  /// The specific numeric value that triggered this event.
  /// For volumeSpike: the volume multiplier (e.g. 4.2 = 4.2× previous).
  /// For priceBreakout: distance above high24h in %.
  /// For exhaustionCandle: the candle range %.
  final double triggerValue;

  /// When this event was detected.
  final DateTime timestamp;

  /// Human-readable description for logs and UI.
  final String description;

  /// Phase 16B: Volume Flow Score (0.0–1.0).
  /// 0.0–0.3 = noise spike (retail), 0.6–1.0 = sustained flow (whale).
  /// Default 0.5 = neutral (no data or not applicable).
  final double volumeFlowScore;

  /// Phase 16B Full: Dollar flow over 5 minutes (sum of positive deltas).
  final double flow5mUsd;

  /// Phase 16B Full: Dollar flow over 15 minutes.
  final double flow15mUsd;

  /// Phase 16B Full: Dollar flow over 60 minutes.
  final double flow60mUsd;

  /// Phase 16B Full: Flow classification.
  /// Values: 'retailNoise', 'retailInterest', 'seriousInflow', 'whaleInflow'.
  final String flowClass;

  MarketEvent copyWith({
    MarketEventType? type,
    MarketEventSeverity? severity,
    String? symbol,
    String? exchange,
    double? price,
    double? changePercent,
    double? volume24h,
    double? triggerValue,
    DateTime? timestamp,
    String? description,
    double? volumeFlowScore,
    double? flow5mUsd,
    double? flow15mUsd,
    double? flow60mUsd,
    String? flowClass,
  }) {
    return MarketEvent(
      type: type ?? this.type,
      severity: severity ?? this.severity,
      symbol: symbol ?? this.symbol,
      exchange: exchange ?? this.exchange,
      price: price ?? this.price,
      changePercent: changePercent ?? this.changePercent,
      volume24h: volume24h ?? this.volume24h,
      triggerValue: triggerValue ?? this.triggerValue,
      timestamp: timestamp ?? this.timestamp,
      description: description ?? this.description,
      volumeFlowScore: volumeFlowScore ?? this.volumeFlowScore,
      flow5mUsd: flow5mUsd ?? this.flow5mUsd,
      flow15mUsd: flow15mUsd ?? this.flow15mUsd,
      flow60mUsd: flow60mUsd ?? this.flow60mUsd,
      flowClass: flowClass ?? this.flowClass,
    );
  }

  const MarketEvent({
    required this.type,
    required this.symbol,
    required this.exchange,
    required this.price,
    required this.changePercent,
    required this.volume24h,
    required this.triggerValue,
    required this.timestamp,
    required this.description,
    this.volumeFlowScore = 0.5,
    this.flow5mUsd = 0,
    this.flow15mUsd = 0,
    this.flow60mUsd = 0,
    this.flowClass = 'retailNoise',
    MarketEventSeverity? severity,
  }) : severity = severity ?? MarketEventSeverity.notable;

  /// Relative Flow Strength: how anomalous is the current 5m flow
  /// compared to the asset's "normal" 5-minute volume.
  ///
  /// Formula: flow5mUsd / (volume24h / 288)
  /// where 288 = number of 5-minute windows in 24 hours.
  ///
  /// Examples:
  ///   - BTC:  $20K flow / ($1B / 288) = 0.006x → noise (normal BTC activity)
  ///   - MEME: $20K flow / ($200K / 288) = 29x   → massive anomaly (SIGNAL!)
  ///   - ALT:  $20K flow / ($5M / 288)  = 1.15x  → slightly above normal
  ///
  /// Rules of thumb:
  ///   >= 5x: Whale-level anomaly, very strong signal
  ///   >= 3x: Significant anomaly, worth investigating
  ///   >= 1.5x: Above average, mild interest
  ///   < 1x:  Normal or below-normal activity
  double get relativeFlowStrength {
    if (volume24h <= 0 || flow5mUsd <= 0) return 0.0;
    final normal5mVolume = volume24h / 288.0;
    return flow5mUsd / normal5mVolume;
  }

  /// Format USD for compact log (e.g. $42K, $1.2M).
  static String _fmtUsd(double usd) {
    if (usd >= 1000000) return '\$${(usd / 1000000).toStringAsFixed(1)}M';
    if (usd >= 1000) return '\$${(usd / 1000).toStringAsFixed(0)}K';
    return '\$${usd.toStringAsFixed(0)}';
  }

  /// Compact log line.
  String toLogLine() => '[${type.label}] $symbol@$exchange '
      'price=\$${price.toStringAsFixed(6)} '
      'chg=${changePercent.toStringAsFixed(1)}% '
      'vol=\$${volume24h.toStringAsFixed(0)} '
      'trigger=${triggerValue.toStringAsFixed(2)} '
      'vf=${volumeFlowScore.toStringAsFixed(2)} '
      '5m=${_fmtUsd(flow5mUsd)} $flowClass '
      '| $description';

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'severity': severity.name,
        'symbol': symbol,
        'exchange': exchange,
        'price': price,
        'changePercent': changePercent,
        'volume24h': volume24h,
        'triggerValue': triggerValue,
        'volumeFlowScore': volumeFlowScore,
        'flow5mUsd': flow5mUsd,
        'flow15mUsd': flow15mUsd,
        'flow60mUsd': flow60mUsd,
        'flowClass': flowClass,
        'timestamp': timestamp.toIso8601String(),
        'description': description,
      };

  factory MarketEvent.fromJson(Map<String, dynamic> json) => MarketEvent(
        type: MarketEventType.values.firstWhere(
          (e) => e.name == json['type'],
          orElse: () => MarketEventType.volumeSpike,
        ),
        severity: MarketEventSeverity.values.firstWhere(
          (e) => e.name == json['severity'],
          orElse: () => MarketEventSeverity.notable,
        ),
        symbol: json['symbol'] as String? ?? '',
        exchange: json['exchange'] as String? ?? '',
        price: (json['price'] as num?)?.toDouble() ?? 0,
        changePercent: (json['changePercent'] as num?)?.toDouble() ?? 0,
        volume24h: (json['volume24h'] as num?)?.toDouble() ?? 0,
        triggerValue: (json['triggerValue'] as num?)?.toDouble() ?? 0,
        volumeFlowScore: (json['volumeFlowScore'] as num?)?.toDouble() ?? 0.5,
        flow5mUsd: (json['flow5mUsd'] as num?)?.toDouble() ?? 0,
        flow15mUsd: (json['flow15mUsd'] as num?)?.toDouble() ?? 0,
        flow60mUsd: (json['flow60mUsd'] as num?)?.toDouble() ?? 0,
        flowClass: json['flowClass'] as String? ?? 'retailNoise',
        timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
            DateTime.now(),
        description: json['description'] as String? ?? '',
      );
}
