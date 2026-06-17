// ─── IBITI Market Phase ─────────────────────────────────────────────────────────
//
// Market phase context. Every lesson IBITI learns is tagged with the phase
// it was learned in, so rules from a bull market don't poison bear market
// decisions. This is the fix for Sonnet's concern about "toxic experience".
// ─────────────────────────────────────────────────────────────────────────────────

/// Macro market regime.
enum MarketPhase {
  /// BTC/ETH trending up, altcoins generally rising.
  bull,

  /// BTC/ETH trending down, altcoins generally falling.
  bear,

  /// No clear direction, range-bound.
  sideways,

  /// High volatility, rapid reversals, uncertain.
  volatile,

  /// Market after strong move, pullback likely. Not safe for entries.
  exhaustion,
}

extension MarketPhaseExt on MarketPhase {
  String get label => switch (this) {
        MarketPhase.bull => '🟢 Bull',
        MarketPhase.bear => '🔴 Bear',
        MarketPhase.sideways => '🟡 Sideways',
        MarketPhase.volatile => '🟠 Volatile',
        MarketPhase.exhaustion => '🟣 Exhaustion',
      };

  /// Whether this phase generally favours new entries.
  bool get favoursEntry =>
      this == MarketPhase.bull || this == MarketPhase.sideways;

  /// Whether this phase suggests extra caution.
  bool get suggestsCaution =>
      this == MarketPhase.bear ||
      this == MarketPhase.volatile ||
      this == MarketPhase.exhaustion;
}

/// Snapshot of overall market context at a point in time.
class MarketPhaseSnapshot {
  final MarketPhase phase;

  /// BTC 24h change % at time of snapshot.
  final double btcChange24h;

  /// ETH 24h change % at time of snapshot.
  final double ethChange24h;

  /// How many top-50 coins are green vs red (0.0–1.0).
  final double marketBreadth;

  final DateTime timestamp;

  const MarketPhaseSnapshot({
    required this.phase,
    this.btcChange24h = 0,
    this.ethChange24h = 0,
    this.marketBreadth = 0.5,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'phase': phase.name,
        'btcChange24h': btcChange24h,
        'ethChange24h': ethChange24h,
        'marketBreadth': marketBreadth,
        'timestamp': timestamp.toIso8601String(),
      };

  factory MarketPhaseSnapshot.fromJson(Map<String, dynamic> json) =>
      MarketPhaseSnapshot(
        phase: MarketPhase.values.firstWhere(
          (e) => e.name == json['phase'],
          orElse: () => MarketPhase.sideways,
        ),
        btcChange24h: (json['btcChange24h'] as num?)?.toDouble() ?? 0,
        ethChange24h: (json['ethChange24h'] as num?)?.toDouble() ?? 0,
        marketBreadth: (json['marketBreadth'] as num?)?.toDouble() ?? 0.5,
        timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
            DateTime.now(),
      );
}

// ── Phase 17G-C: Market Heartbeat & Cardiogram ──

enum MarketHeartbeat {
  accumulation,
  earlyInflow,
  acceleration,
  distribution,
  panicDump,
  deadChop,
  rotation,
  listingMania,
  unknown,
}

extension MarketHeartbeatExt on MarketHeartbeat {
  String get label => switch (this) {
        MarketHeartbeat.accumulation => 'Accumulation',
        MarketHeartbeat.earlyInflow => 'Early Inflow',
        MarketHeartbeat.acceleration => 'Acceleration',
        MarketHeartbeat.distribution => 'Distribution',
        MarketHeartbeat.panicDump => 'Panic Dump',
        MarketHeartbeat.deadChop => 'Dead Chop',
        MarketHeartbeat.rotation => 'Rotation',
        MarketHeartbeat.listingMania => 'Listing Mania',
        MarketHeartbeat.unknown => 'Unknown',
      };

  bool get favoursEntry =>
      this == MarketHeartbeat.earlyInflow ||
      this == MarketHeartbeat.acceleration ||
      this == MarketHeartbeat.accumulation ||
      this == MarketHeartbeat.rotation;

  bool get suggestsCaution =>
      this == MarketHeartbeat.distribution ||
      this == MarketHeartbeat.deadChop ||
      this == MarketHeartbeat.listingMania;

  bool get isRiskOff => this == MarketHeartbeat.panicDump;

  bool get isOpportunity =>
      this == MarketHeartbeat.earlyInflow ||
      this == MarketHeartbeat.listingMania;
}

class MarketCardiogramSnapshot {
  final MarketHeartbeat heartbeat;
  final MarketPhase mappedPhase;

  final double flow1mUsd;
  final double flow5mUsd;
  final double flow15mUsd;
  final double flow60mUsd;

  final double flowAcceleration5m;
  final double marketBreadth;
  final double btcChange24h;
  final double ethChange24h;
  final double topCoinFlowShare;
  final double altFlowShare;
  final double memeFlowShare;
  final double newListingFlowShare;

  final String leadingSector;
  final double rotationScore;
  final double dumpPressure;
  final double liquidityExpansion;
  final int activeTickers;
  final DateTime timestamp;

  const MarketCardiogramSnapshot({
    required this.heartbeat,
    required this.mappedPhase,
    required this.flow1mUsd,
    required this.flow5mUsd,
    required this.flow15mUsd,
    required this.flow60mUsd,
    required this.flowAcceleration5m,
    required this.marketBreadth,
    required this.btcChange24h,
    required this.ethChange24h,
    required this.topCoinFlowShare,
    required this.altFlowShare,
    required this.memeFlowShare,
    required this.newListingFlowShare,
    required this.leadingSector,
    required this.rotationScore,
    required this.dumpPressure,
    required this.liquidityExpansion,
    required this.activeTickers,
    required this.timestamp,
  });

  static MarketCardiogramSnapshot get empty => MarketCardiogramSnapshot(
        heartbeat: MarketHeartbeat.unknown,
        mappedPhase: MarketPhase.sideways,
        flow1mUsd: 0,
        flow5mUsd: 0,
        flow15mUsd: 0,
        flow60mUsd: 0,
        flowAcceleration5m: 0,
        marketBreadth: 0.5,
        btcChange24h: 0,
        ethChange24h: 0,
        topCoinFlowShare: 0,
        altFlowShare: 0,
        memeFlowShare: 0,
        newListingFlowShare: 0,
        leadingSector: 'unknown',
        rotationScore: 0,
        dumpPressure: 0,
        liquidityExpansion: 0,
        activeTickers: 0,
        timestamp: DateTime.now(),
      );

  String toLogLine() {
    return 'heartbeat=${heartbeat.name} phase=${mappedPhase.name} '
        'flow1m=\$${(flow1mUsd / 1000).toStringAsFixed(0)}K '
        'flow5m=\$${(flow5mUsd / 1000).toStringAsFixed(0)}K '
        'flow15m=\$${(flow15mUsd / 1000).toStringAsFixed(0)}K '
        'flow60m=\$${(flow60mUsd / 1000).toStringAsFixed(0)}K '
        'accel=${flowAcceleration5m.toStringAsFixed(2)} '
        'breadth=${marketBreadth.toStringAsFixed(2)} '
        'sector=$leadingSector '
        'rotation=${rotationScore.toStringAsFixed(2)} '
        'dump=${dumpPressure.toStringAsFixed(2)}';
  }
}
