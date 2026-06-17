// ─── IBITI Exchange Profile ──────────────────────────────────────────────────────
//
// Exchange-level memory. IBITI learns which exchanges produce reliable
// signals vs fake breakouts.
// ─────────────────────────────────────────────────────────────────────────────────

/// Persistent profile for one exchange.
class ExchangeProfile {
  final String exchange;
  int totalEvents;
  int fakeBreakouts;
  int successfulSignals;
  double avgSlippagePercent;
  double avgSpreadPercent;
  double reliability;
  DateTime lastUpdated;

  // ── Per-signal-type tracking (Phase 3) ──────────────────────────────────
  int volumeSpikeSignals;
  int volumeSpikeWins;
  int breakoutSignals;
  int breakoutWins;
  int listingSignals;
  int listingWins;
  int exhaustionSignals;
  int exhaustionWins;

  ExchangeProfile({
    required this.exchange,
    this.totalEvents = 0,
    this.fakeBreakouts = 0,
    this.successfulSignals = 0,
    this.avgSlippagePercent = 0,
    this.avgSpreadPercent = 0,
    this.reliability = 0.5,
    this.volumeSpikeSignals = 0,
    this.volumeSpikeWins = 0,
    this.breakoutSignals = 0,
    this.breakoutWins = 0,
    this.listingSignals = 0,
    this.listingWins = 0,
    this.exhaustionSignals = 0,
    this.exhaustionWins = 0,
    DateTime? lastUpdated,
  }) : lastUpdated = lastUpdated ?? DateTime.now();

  double get fakeBreakoutRate =>
      totalEvents > 0 ? fakeBreakouts / totalEvents : 0;

  double get successRate =>
      totalEvents > 0 ? successfulSignals / totalEvents : 0;

  /// Signal quality for a specific event type on this exchange (0.0–1.0).
  /// Returns 0.5 (neutral) if not enough data.
  double signalQuality(String eventTypeName) {
    int signals, wins;
    switch (eventTypeName) {
      case 'volumeSpike':
        signals = volumeSpikeSignals;
        wins = volumeSpikeWins;
      case 'priceBreakout':
        signals = breakoutSignals;
        wins = breakoutWins;
      case 'newListingMove':
        signals = listingSignals;
        wins = listingWins;
      case 'exhaustionCandle':
        signals = exhaustionSignals;
        wins = exhaustionWins;
      default:
        return 0.5; // Not enough data for this type.
    }
    if (signals < 3) return 0.5; // Need at least 3 data points.
    return (wins / signals).clamp(0.0, 1.0);
  }

  /// Overall trust score for this exchange (0.0–1.0).
  /// Combines success rate, fake breakout rate, and signal volume.
  double get trustScore {
    if (totalEvents < 5) return 0.5; // Not enough data.
    final sr = successRate;
    final fbPenalty = fakeBreakoutRate * 0.3;
    return (sr - fbPenalty + 0.2).clamp(0.0, 1.0); // Bias slightly positive.
  }

  /// Record a signal for a specific event type.
  void recordSignal(String eventTypeName, {required bool won}) {
    switch (eventTypeName) {
      case 'volumeSpike':
        volumeSpikeSignals++;
        if (won) volumeSpikeWins++;
      case 'priceBreakout':
        breakoutSignals++;
        if (won) breakoutWins++;
      case 'newListingMove':
        listingSignals++;
        if (won) listingWins++;
      case 'exhaustionCandle':
        exhaustionSignals++;
        if (won) exhaustionWins++;
    }
    totalEvents++;
    if (won) successfulSignals++;
    lastUpdated = DateTime.now();
  }

  Map<String, dynamic> toJson() => {
        'exchange': exchange,
        'totalEvents': totalEvents,
        'fakeBreakouts': fakeBreakouts,
        'successfulSignals': successfulSignals,
        'avgSlippagePercent': avgSlippagePercent,
        'avgSpreadPercent': avgSpreadPercent,
        'reliability': reliability,
        'lastUpdated': lastUpdated.toIso8601String(),
        'volumeSpikeSignals': volumeSpikeSignals,
        'volumeSpikeWins': volumeSpikeWins,
        'breakoutSignals': breakoutSignals,
        'breakoutWins': breakoutWins,
        'listingSignals': listingSignals,
        'listingWins': listingWins,
        'exhaustionSignals': exhaustionSignals,
        'exhaustionWins': exhaustionWins,
      };

  factory ExchangeProfile.fromJson(Map<String, dynamic> json) =>
      ExchangeProfile(
        exchange: json['exchange'] as String? ?? '',
        totalEvents: json['totalEvents'] as int? ?? 0,
        fakeBreakouts: json['fakeBreakouts'] as int? ?? 0,
        successfulSignals: json['successfulSignals'] as int? ?? 0,
        avgSlippagePercent:
            (json['avgSlippagePercent'] as num?)?.toDouble() ?? 0,
        avgSpreadPercent: (json['avgSpreadPercent'] as num?)?.toDouble() ?? 0,
        reliability: (json['reliability'] as num?)?.toDouble() ?? 0.5,
        volumeSpikeSignals: json['volumeSpikeSignals'] as int? ?? 0,
        volumeSpikeWins: json['volumeSpikeWins'] as int? ?? 0,
        breakoutSignals: json['breakoutSignals'] as int? ?? 0,
        breakoutWins: json['breakoutWins'] as int? ?? 0,
        listingSignals: json['listingSignals'] as int? ?? 0,
        listingWins: json['listingWins'] as int? ?? 0,
        exhaustionSignals: json['exhaustionSignals'] as int? ?? 0,
        exhaustionWins: json['exhaustionWins'] as int? ?? 0,
        lastUpdated: DateTime.tryParse(json['lastUpdated'] as String? ?? ''),
      );
}
