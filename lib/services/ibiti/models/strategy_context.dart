// ─── Strategy Context Models ────────────────────────────────────────────────────
//
// Phase 10A: Context Intelligence Layer.
//
// These models give JARVIS the ability to classify WHAT it's looking at
// before deciding WHAT TO DO. A +30% move means completely different things
// depending on context:
//   - BTC +30%     → rare, probably market-wide event
//   - New MEXC +30% → could be early rocket
//   - Zombie +30%  → noise trap
//
// The classifier fills StrategyContext before Brain scores anything.
// ─────────────────────────────────────────────────────────────────────────────────

/// How mature/established is this token as a tradeable asset?
enum TokenMaturity {
  /// Brand new listing, appeared within ~7 days. High vol, unknown behavior.
  newborn,

  /// Trading for days/weeks, starting to form patterns. Still risky.
  emerging,

  /// Well-known asset with deep liquidity and history (BTC, ETH, SOL, etc).
  established,

  /// Low volume, repeated noisy events, poor history. Likely dead/scam.
  zombie,

  /// Not enough data to classify.
  unknown,
}

extension TokenMaturityExt on TokenMaturity {
  String get label => switch (this) {
        TokenMaturity.newborn => 'Новый',
        TokenMaturity.emerging => 'Формируется',
        TokenMaturity.established => 'Зрелый',
        TokenMaturity.zombie => 'Мёртвый',
        TokenMaturity.unknown => 'Неизвестный',
      };
}

/// Which trading strategy should JARVIS apply to this context?
enum StrategyType {
  /// Liquid asset with confirmed trend. Standard momentum entry.
  normalMomentum,

  /// Asset already pumping hard. Analyze if it's a rocket or a trap.
  rocketContinuation,

  /// Recently listed token. High volatility, short time window.
  newListing,

  /// Quick in-and-out. Small TP, small SL, fast exit.
  scalp,

  /// Not enough context to trade. Observe, collect data, learn.
  researchOnly,

  /// Market is dirty, token is toxic, or conditions are unsafe. Do nothing.
  noTrade,
}

extension StrategyTypeExt on StrategyType {
  String get label => switch (this) {
        StrategyType.normalMomentum => 'Momentum',
        StrategyType.rocketContinuation => 'Rocket',
        StrategyType.newListing => 'NewListing',
        StrategyType.scalp => 'Scalp',
        StrategyType.researchOnly => 'Research',
        StrategyType.noTrade => 'NoTrade',
      };

  /// Whether this strategy allows opening a paper trade.
  bool get allowsTrade => switch (this) {
        StrategyType.normalMomentum => true,
        StrategyType.rocketContinuation => true,
        StrategyType.newListing => true,
        StrategyType.scalp =>
          false, // scalp is observation-only until a dedicated scalp engine exists.
        StrategyType.researchOnly => false,
        StrategyType.noTrade => false,
      };
}

/// What stage of a pump/rocket is this asset in?
enum RocketStage {
  /// +10–30%, volume growing, trend forming. Best entry window.
  earlyRocket,

  /// +30–100%, strong momentum. Entry possible but riskier.
  midRocket,

  /// +100–300%, dangerous. Only tiny positions or scalp.
  lateRocket,

  /// +300%+ or RSI>80 + wick rejection. Trap for late buyers.
  exhaustionTrap,

  /// Not in a rocket pattern.
  unknown,
}

extension RocketStageExt on RocketStage {
  String get label => switch (this) {
        RocketStage.earlyRocket => 'EarlyRocket',
        RocketStage.midRocket => 'MidRocket',
        RocketStage.lateRocket => 'LateRocket',
        RocketStage.exhaustionTrap => 'ExhaustionTrap',
        RocketStage.unknown => 'N/A',
      };
}

/// Phase 15A: Coin Passport — what kind of asset is this at its core?
///
/// This classification happens BEFORE any strategy decision.
/// Stablecoins, commodity-backed, and dead tokens are flagged for rejection.
enum AssetCategory {
  /// USDT, USDC, DAI, FDUSD, TUSD — never trade under normal conditions.
  stablecoin,

  /// BTC, ETH, SOL, BNB — slow confirmation, longer horizon.
  major,

  /// Top alts by volume (>$10M daily).
  largeAlt,

  /// Mid-tier alts ($1M–$10M daily).
  altcoin,

  /// Small alts ($100K–$1M daily).
  smallAlt,

  /// <$100K daily volume — risky.
  microcap,

  /// DOGE, PEPE, WIF, SHIB — meme dynamics, high volatility.
  meme,

  /// First seen <7 days ago — special regime.
  newListing,

  /// Gold/commodity-backed tokens (XAUT, PAXG) — not crypto.
  commodityBacked,

  /// Low volume, noisy, bad WR — auto-reject.
  dead,
}

extension AssetCategoryExt on AssetCategory {
  String get label => switch (this) {
        AssetCategory.stablecoin => 'Stablecoin',
        AssetCategory.major => 'Major',
        AssetCategory.largeAlt => 'LargeAlt',
        AssetCategory.altcoin => 'Altcoin',
        AssetCategory.smallAlt => 'SmallAlt',
        AssetCategory.microcap => 'Microcap',
        AssetCategory.meme => 'Meme',
        AssetCategory.newListing => 'NewListing',
        AssetCategory.commodityBacked => 'Commodity',
        AssetCategory.dead => 'Dead',
      };

  /// Whether this category should NEVER be traded (hard block candidates).
  bool get isNoTrade => switch (this) {
        AssetCategory.stablecoin => true,
        AssetCategory.commodityBacked => true,
        AssetCategory.dead => true,
        _ => false,
      };
}

/// Full context classification for one market event.
/// Produced by ContextClassifier, consumed by Brain.
class StrategyContext {
  /// Recommended strategy for this event.
  final StrategyType strategyType;

  /// If this is a rocket, what stage?
  final RocketStage rocketStage;

  /// How mature is this token?
  final TokenMaturity tokenMaturity;

  /// Asset class hint (e.g. "major", "altcoin", "memecoin", "unknown").
  /// Kept for backward compatibility with existing code.
  final String assetClass;

  /// Phase 15A: Coin Passport category (enum-based, replaces assetClass).
  final AssetCategory assetCategory;

  // ── Flags ──

  /// Token shows rocket continuation pattern (volume + candles + momentum).
  final bool isRocketCandidate;

  /// Token is a new listing with early action.
  final bool isNewListingCandidate;

  /// Token has confirmed trend continuation (EMA stack + volume).
  final bool isContinuationCandidate;

  /// High risk of exhaustion/reversal (RSI + wick + extreme pump).
  final bool isExhaustionRisk;

  /// Enough liquidity to enter and exit without >1% slippage.
  final bool isLiquiditySafe;

  /// Context lacks critical info — would benefit from external research.
  final bool needsExternalResearch;

  /// How confident is the classifier in this assessment (0.0–1.0).
  final double confidence;

  /// Human-readable reasons for this classification.
  final List<String> reasons;

  /// What data is missing that would improve the classification.
  final List<String> missingData;

  const StrategyContext({
    required this.strategyType,
    this.rocketStage = RocketStage.unknown,
    this.tokenMaturity = TokenMaturity.unknown,
    this.assetClass = 'unknown',
    this.assetCategory = AssetCategory.altcoin,
    this.isRocketCandidate = false,
    this.isNewListingCandidate = false,
    this.isContinuationCandidate = false,
    this.isExhaustionRisk = false,
    this.isLiquiditySafe = true,
    this.needsExternalResearch = false,
    this.confidence = 0.5,
    this.reasons = const [],
    this.missingData = const [],
  });

  /// Default: unknown context, research only.
  static const empty = StrategyContext(
    strategyType: StrategyType.researchOnly,
    confidence: 0.0,
    missingData: ['no classification performed'],
  );

  /// Compact log string.
  String toLogLine() => 'strategy=${strategyType.label} '
      'stage=${rocketStage.label} '
      'maturity=${tokenMaturity.label} '
      'asset=${assetCategory.label} '
      'conf=${confidence.toStringAsFixed(2)} '
      '${reasons.isNotEmpty ? "reason=${reasons.first}" : ""}';

  Map<String, dynamic> toJson() => {
        'strategyType': strategyType.name,
        'rocketStage': rocketStage.name,
        'tokenMaturity': tokenMaturity.name,
        'assetClass': assetClass,
        'assetCategory': assetCategory.name,
        'isRocketCandidate': isRocketCandidate,
        'isNewListingCandidate': isNewListingCandidate,
        'isContinuationCandidate': isContinuationCandidate,
        'isExhaustionRisk': isExhaustionRisk,
        'isLiquiditySafe': isLiquiditySafe,
        'needsExternalResearch': needsExternalResearch,
        'confidence': confidence,
        'reasons': reasons,
        'missingData': missingData,
      };

  @override
  String toString() => 'StrategyContext(${toLogLine()})';
}
