// ─── IBITI Token Profile ────────────────────────────────────────────────────────
//
// Long-term memory for a specific token ON A SPECIFIC EXCHANGE.
// Key = "exchange:symbol" (e.g. "mexc:AIUSDT").
//
// AIUSDT on MEXC and AIUSDT on Binance are different markets with different
// liquidity, spreads, and behavior. Mixing their profiles would poison memory.
// ─────────────────────────────────────────────────────────────────────────────────

import 'package:ibiti_guardian/services/ibiti/models/market_event.dart';

/// Persistent profile for one token on one exchange.
class TokenProfile {
  /// Composite key: "exchange:SYMBOL" (e.g. "mexc:AIUSDT").
  final String key;

  /// Exchange name (e.g. "mexc").
  final String exchange;

  /// Trading pair symbol (e.g. "AIUSDT").
  final String symbol;

  /// How many times IBITI detected a significant event for this token.
  int timesSeen;

  /// How many times IBITI decided to watch (not trade).
  int timesWatched;

  /// How many times IBITI decided to reject (not even watch).
  int timesRejected;

  /// How many times IBITI entered a trade (paper or real).
  int timesActed;

  /// How many times IBITI would have bought (observeOnly virtual intent).
  int timesWouldBuy;

  /// How many trades ended in profit.
  int timesWon;

  /// How many trades ended in loss.
  int timesLost;

  /// Average % pump before a dump was detected.
  double avgPumpBeforeDump;

  /// How often this token produces fake breakouts (0.0–1.0).
  double fakeBreakoutRate;

  /// Which event type historically worked best for this token.
  MarketEventType? bestSignalType;

  /// Why the last trade/decision failed.
  String? lastFailReason;

  /// Most recent price seen.
  double lastSeenPrice;

  /// When IBITI last observed this token.
  DateTime lastSeenAt;

  /// Last 10 decision reasons (ring buffer for context).
  List<String> recentReasons;

  /// Noise score (0.0–1.0). Rolling average of how often this token
  /// spams events. > 0.8 = auto-block candidate.
  double noiseScore;

  /// How many events this token generated in the current hour.
  /// Reset by hourly hygiene.
  int hourlyEventCount;

  /// Last hour reset timestamp.
  DateTime _lastHourReset;

  TokenProfile({
    required this.exchange,
    required this.symbol,
    String? key,
    this.timesSeen = 0,
    this.timesWatched = 0,
    this.timesRejected = 0,
    this.timesActed = 0,
    this.timesWouldBuy = 0,
    this.timesWon = 0,
    this.timesLost = 0,
    this.avgPumpBeforeDump = 0,
    this.fakeBreakoutRate = 0,
    this.bestSignalType,
    this.lastFailReason,
    this.lastSeenPrice = 0,
    DateTime? lastSeenAt,
    List<String>? recentReasons,
    this.noiseScore = 0.0,
    this.hourlyEventCount = 0,
    DateTime? lastHourReset,
  })  : key = key ?? '${exchange.toLowerCase()}:${symbol.toUpperCase()}',
        lastSeenAt = lastSeenAt ?? DateTime.now(),
        recentReasons = recentReasons ?? [],
        _lastHourReset = lastHourReset ?? DateTime.now();

  /// Build canonical key from exchange + symbol.
  static String buildKey(String exchange, String symbol) =>
      '${exchange.toLowerCase()}:${symbol.toUpperCase()}';

  /// Win rate (0.0–1.0). Returns 0 if no trades.
  double get winRate {
    final total = timesWon + timesLost;
    return total > 0 ? timesWon / total : 0;
  }

  /// How "familiar" IBITI is with this token (0.0–1.0, capped at 50 observations).
  double get familiarity => (timesSeen / 50).clamp(0.0, 1.0);

  /// How stale this profile is (0.0 = just seen, 1.0 = 30+ days unseen).
  double get staleness {
    final daysSinceLastSeen =
        DateTime.now().difference(lastSeenAt).inDays.toDouble();
    return (daysSinceLastSeen / 30.0).clamp(0.0, 1.0);
  }

  /// Whether this profile has enough data AND is fresh enough to influence scoring.
  bool get isTrustworthy => timesSeen >= 5 && staleness < 0.7;

  /// Whether this token is considered noisy (generates too many events).
  bool get isNoisy => noiseScore > 0.8;

  /// Record an event for noise tracking. Call on every event detection.
  void recordHourlyEvent() {
    final now = DateTime.now();
    // Reset counter if an hour has passed.
    if (now.difference(_lastHourReset).inMinutes >= 60) {
      // Update rolling noise score before resetting.
      // Blend: 70% old score + 30% new observation.
      final hourlyNoise = (hourlyEventCount / 100).clamp(0.0, 1.0);
      noiseScore = (noiseScore * 0.7 + hourlyNoise * 0.3).clamp(0.0, 1.0);
      hourlyEventCount = 0;
      _lastHourReset = now;
    }
    hourlyEventCount++;
  }

  /// Reset noise counters (called during hourly hygiene).
  void resetHourlyNoise() {
    final hourlyNoise = (hourlyEventCount / 100).clamp(0.0, 1.0);
    noiseScore = (noiseScore * 0.7 + hourlyNoise * 0.3).clamp(0.0, 1.0);
    hourlyEventCount = 0;
    _lastHourReset = DateTime.now();
  }

  /// Record a new observation.
  void recordSeen({
    required double price,
    String? reason,
  }) {
    timesSeen++;
    lastSeenPrice = price;
    lastSeenAt = DateTime.now();
    if (reason != null) {
      recentReasons.add(reason);
      if (recentReasons.length > 10) recentReasons.removeAt(0);
    }
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'exchange': exchange,
        'symbol': symbol,
        'timesSeen': timesSeen,
        'timesWatched': timesWatched,
        'timesRejected': timesRejected,
        'timesActed': timesActed,
        'timesWouldBuy': timesWouldBuy,
        'timesWon': timesWon,
        'timesLost': timesLost,
        'avgPumpBeforeDump': avgPumpBeforeDump,
        'fakeBreakoutRate': fakeBreakoutRate,
        'bestSignalType': bestSignalType?.name,
        'lastFailReason': lastFailReason,
        'lastSeenPrice': lastSeenPrice,
        'lastSeenAt': lastSeenAt.toIso8601String(),
        'recentReasons': recentReasons,
        'noiseScore': noiseScore,
        'hourlyEventCount': hourlyEventCount,
      };

  factory TokenProfile.fromJson(Map<String, dynamic> json) {
    final exchange = json['exchange'] as String? ?? '';
    final symbol = json['symbol'] as String? ?? '';
    return TokenProfile(
      key: json['key'] as String? ?? buildKey(exchange, symbol),
      exchange: exchange,
      symbol: symbol,
      timesSeen: json['timesSeen'] as int? ?? 0,
      timesWatched: json['timesWatched'] as int? ?? 0,
      timesRejected: json['timesRejected'] as int? ?? 0,
      timesActed: json['timesActed'] as int? ?? 0,
      timesWouldBuy: json['timesWouldBuy'] as int? ?? 0,
      timesWon: json['timesWon'] as int? ?? 0,
      timesLost: json['timesLost'] as int? ?? 0,
      avgPumpBeforeDump: (json['avgPumpBeforeDump'] as num?)?.toDouble() ?? 0,
      fakeBreakoutRate: (json['fakeBreakoutRate'] as num?)?.toDouble() ?? 0,
      bestSignalType: json['bestSignalType'] != null
          ? MarketEventType.values.firstWhere(
              (e) => e.name == json['bestSignalType'],
              orElse: () => MarketEventType.volumeSpike,
            )
          : null,
      lastFailReason: json['lastFailReason'] as String?,
      lastSeenPrice: (json['lastSeenPrice'] as num?)?.toDouble() ?? 0,
      lastSeenAt: DateTime.tryParse(json['lastSeenAt'] as String? ?? ''),
      recentReasons: (json['recentReasons'] as List?)?.cast<String>().toList(),
      noiseScore: (json['noiseScore'] as num?)?.toDouble() ?? 0.0,
      hourlyEventCount: json['hourlyEventCount'] as int? ?? 0,
    );
  }
}
