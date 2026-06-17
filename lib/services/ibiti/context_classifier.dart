// ─── Context Classifier ─────────────────────────────────────────────────────────
//
// Phase 10A: Context Intelligence Layer.
//
// Before JARVIS decides whether to trade, it must understand WHAT it's
// looking at. This classifier answers:
//   - What kind of asset is this? (major, altcoin, meme, unknown)
//   - How mature is it? (newborn, emerging, established, zombie)
//   - What stage of movement? (early/mid/late rocket, exhaustion)
//   - What strategy fits? (momentum, rocket, newListing, scalp, research, noTrade)
//
// The classifier does NOT decide to buy — it provides context to the Brain.
//
// Key principle: +30% on BTC ≠ +30% on a new MEXC microcap.
// ─────────────────────────────────────────────────────────────────────────────────

import 'package:ibiti_guardian/services/ibiti/models/market_event.dart';
import 'package:ibiti_guardian/services/ibiti/models/market_phase.dart';
import 'package:ibiti_guardian/services/ibiti/models/technical_snapshot.dart';
import 'package:ibiti_guardian/services/ibiti/models/token_profile.dart';
import 'package:ibiti_guardian/services/ibiti/models/exchange_profile.dart';
import 'package:ibiti_guardian/services/ibiti/models/strategy_context.dart';
import 'package:ibiti_guardian/services/ibiti/known_asset_registry.dart';
import 'package:ibiti_guardian/services/ibiti/stablecoin_registry_service.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

const _log = GuardianLogger('ContextClassifier');

class ContextClassifier {
  ContextClassifier._();
  static final ContextClassifier instance = ContextClassifier._();

  /// Known major assets that should never be treated as microcap rockets.
  static const _majors = {
    'BTCUSDT',
    'ETHUSDT',
    'BNBUSDT',
    'SOLUSDT',
    'XRPUSDT',
    'ADAUSDT',
    'DOGEUSDT',
    'DOTUSDT',
    'AVAXUSDT',
    'MATICUSDT',
    'LINKUSDT',
    'UNIUSDT',
    'ATOMUSDT',
    'LTCUSDT',
    'TRXUSDT',
    'NEARUSDT',
    'APTUSDT',
    'OPUSDT',
    'ARBUSDT',
    'SUIUSDT',
  };

  // ── Phase 15A: Coin Passport lists ─────────────────────────────────────────

  /// Stablecoin detection is now delegated to StablecoinRegistryService.
  /// This static set is kept ONLY as a fast fallback for the old code path.
  /// The registry has 3 layers: hardcoded pairs, base detector, CoinGecko.

  /// Meme coins — high volatility, meme dynamics.
  static const _memecoins = {
    'DOGEUSDT',
    'PEPEUSDT',
    'WIFUSDT',
    'SHIBUSDT',
    'BONKUSDT',
    'FLOKIUSDT',
    'MOGUUSDT',
    'BRETTUSDT',
    'TRUMPUSDT',
    '1000CHEEMSUSDT',
    'HMSTRUSDT',
    'BABYDOGEUSDT',
    '1000PEPEUSDT',
    'MEMECOINUSDT',
  };

  /// Commodity-backed — not crypto, never trade.
  static const _commodityBacked = {
    'XAUTUSDT',
    'PAXGUSDT',
  };

  /// Classify a market event into full strategy context.
  StrategyContext classify({
    required MarketEvent event,
    TechnicalSnapshot? ta,
    TokenProfile? tokenProfile,
    ExchangeProfile? exchangeProfile,
    MarketPhase phase = MarketPhase.sideways,
  }) {
    final reasons = <String>[];
    final missingData = <String>[];

    // ── 1. Asset class (legacy string, kept for compatibility) ──
    final assetClass = _classifyAssetClass(event.symbol, event.volume24h);

    // ── 1b. Coin Passport (Phase 15A) ──
    final assetCategory = _classifyAssetCategory(
      event.symbol,
      event.volume24h,
      tokenProfile,
    );
    // Determine action, reason, and source for this category.
    final String passportAction;
    final String passportReason;
    String passportSource = '';
    if (assetCategory.isNoTrade) {
      passportAction = 'REJECT';
      passportReason = switch (assetCategory) {
        AssetCategory.stablecoin => 'stablecoin_hard_block',
        AssetCategory.commodityBacked => 'commodity_not_crypto',
        AssetCategory.dead => 'dead_token_noisy',
        _ => 'unknown_block',
      };
      if (assetCategory == AssetCategory.stablecoin) {
        passportSource =
            ' source=${StablecoinRegistryService.instance.detectionSource(event.symbol)}';
      }
    } else if (assetCategory == AssetCategory.microcap ||
        assetCategory == AssetCategory.newListing) {
      passportAction = 'SCOUT_ONLY';
      passportReason = assetCategory == AssetCategory.newListing
          ? 'new_listing_unproven'
          : 'microcap_low_liquidity';
    } else {
      passportAction = 'ALLOW';
      passportReason = '${assetCategory.label}_normal';
    }
    // Tiered logging: REJECT/SCOUT_ONLY = info, ALLOW = debug.
    if (passportAction == 'REJECT' || passportAction == 'SCOUT_ONLY') {
      _log.i('[CoinPassport] ${event.symbol}@${event.exchange} '
          'category=${assetCategory.label} '
          'action=$passportAction '
          'reason=$passportReason$passportSource');
    } else {
      _log.d('[CoinPassport] ${event.symbol}@${event.exchange} '
          'category=${assetCategory.label} '
          'action=$passportAction '
          'reason=$passportReason');
    }

    // ── 2. Token maturity ──
    final maturity = _classifyMaturity(
      event,
      tokenProfile,
      assetClass,
      reasons,
      missingData,
    );

    // ── 3. Rocket stage ──
    final rocketStage = _classifyRocketStage(event, ta, reasons);

    // ── 4. Liquidity safety ──
    final isLiquiditySafe = event.volume24h > 50000;
    if (!isLiquiditySafe) {
      reasons.add('Low liquidity (\$${event.volume24h.toStringAsFixed(0)})');
    }

    // ── 5. Exhaustion risk ──
    final isExhaustionRisk = _isExhaustionRisk(event, ta, rocketStage);
    if (isExhaustionRisk) {
      reasons.add('Exhaustion risk detected');
    }

    // ── 6. Candidate flags ──
    final isRocketCandidate = rocketStage != RocketStage.unknown &&
        rocketStage != RocketStage.exhaustionTrap &&
        isLiquiditySafe;

    final isNewListingCandidate =
        event.type == MarketEventType.newListingMove ||
            maturity == TokenMaturity.newborn;

    final isContinuationCandidate =
        event.type == MarketEventType.trendContinuation &&
            maturity == TokenMaturity.established &&
            isLiquiditySafe;

    // ── 7. Needs research flag ──
    final needsResearch = maturity == TokenMaturity.unknown ||
        (tokenProfile == null && assetClass != 'major') ||
        missingData.isNotEmpty;

    // ── 8. Strategy selection ──
    final strategy = _selectStrategy(
      event: event,
      ta: ta,
      phase: phase,
      maturity: maturity,
      rocketStage: rocketStage,
      assetClass: assetClass,
      assetCategory: assetCategory,
      isLiquiditySafe: isLiquiditySafe,
      isExhaustionRisk: isExhaustionRisk,
      isRocketCandidate: isRocketCandidate,
      isNewListingCandidate: isNewListingCandidate,
      isContinuationCandidate: isContinuationCandidate,
      tokenProfile: tokenProfile,
      exchangeProfile: exchangeProfile,
      reasons: reasons,
    );

    // ── 9. Confidence ──
    final confidence = _calculateConfidence(
      ta: ta,
      tokenProfile: tokenProfile,
      maturity: maturity,
      missingData: missingData,
    );

    final context = StrategyContext(
      strategyType: strategy,
      rocketStage: rocketStage,
      tokenMaturity: maturity,
      assetClass: assetClass,
      assetCategory: assetCategory,
      isRocketCandidate: isRocketCandidate,
      isNewListingCandidate: isNewListingCandidate,
      isContinuationCandidate: isContinuationCandidate,
      isExhaustionRisk: isExhaustionRisk,
      isLiquiditySafe: isLiquiditySafe,
      needsExternalResearch: needsResearch,
      confidence: confidence,
      reasons: reasons,
      missingData: missingData,
    );

    _log.d('${event.symbol}@${event.exchange}: ${context.toLogLine()}');
    return context;
  }

  // ── Asset Class (legacy) ────────────────────────────────────────────────────

  String _classifyAssetClass(String symbol, double volume24h) {
    if (_majors.contains(symbol.toUpperCase())) return 'major';
    if (volume24h > 10000000) return 'large_alt'; // >$10M daily
    if (volume24h > 1000000) return 'altcoin'; // >$1M daily
    if (volume24h > 100000) return 'small_alt'; // >$100K daily
    return 'microcap';
  }

  // ── Coin Passport (Phase 15A) ──────────────────────────────────────────────

  AssetCategory _classifyAssetCategory(
    String symbol,
    double volume24h,
    TokenProfile? profile,
  ) {
    final sym = symbol.toUpperCase();

    // ── Hard classifications (no exceptions) ──
    // Phase 15A.2: Use StablecoinRegistryService (3-layer detection).
    if (StablecoinRegistryService.instance.isStablecoin(sym)) {
      return AssetCategory.stablecoin;
    }
    if (_commodityBacked.contains(sym)) return AssetCategory.commodityBacked;

    // ── Phase 18A: KnownAssetRegistry — check global identity FIRST ──
    // Known assets (RNDR, APT, WBTC, PEPE, etc.) must NOT depend on
    // seenCount. A fresh DB should not make BTC look like a "new listing".
    final knownIdentity = KnownAssetRegistry.lookup(sym);
    if (knownIdentity != null) {
      _log.d('[KNOWN_ASSET] $sym '
          'tier=${knownIdentity.tier.name} '
          'sector=${knownIdentity.sector} '
          'category=${knownIdentity.toCategory().label}');
      return knownIdentity.toCategory();
    }

    // ── Meme detection (legacy, for tokens not yet in registry) ──
    if (_memecoins.contains(sym)) return AssetCategory.meme;

    // ── New listing detection (only for truly unknown tokens) ──
    if (profile != null &&
        profile.timesSeen <= 3 &&
        DateTime.now().difference(profile.lastSeenAt).inDays < 7) {
      return AssetCategory.newListing;
    }

    // ── Dead token detection ──
    if (profile != null &&
        profile.timesSeen >= 10 &&
        profile.isNoisy &&
        profile.winRate < 0.15 &&
        volume24h < 100000) {
      return AssetCategory.dead;
    }

    // ── Volume-based classification (fallback for unknown tokens) ──
    if (_majors.contains(sym)) return AssetCategory.major;
    if (volume24h > 10000000) return AssetCategory.largeAlt;
    if (volume24h > 1000000) return AssetCategory.altcoin;
    if (volume24h > 100000) return AssetCategory.smallAlt;
    return AssetCategory.microcap;
  }

  // ── Token Maturity ──────────────────────────────────────────────────────────

  TokenMaturity _classifyMaturity(
    MarketEvent event,
    TokenProfile? profile,
    String assetClass,
    List<String> reasons,
    List<String> missingData,
  ) {
    // ── Phase 18A: KnownAssetRegistry overrides seenCount maturity ──
    // Known assets are ALWAYS established (or meme-established).
    // This prevents fresh DB from treating RNDR/APT/CAKE as "unknown".
    final knownIdentity = KnownAssetRegistry.lookup(event.symbol);
    if (knownIdentity != null) {
      if (knownIdentity.isMeme) {
        reasons
            .add('Known meme (${knownIdentity.sector}) — established-volatile');
      } else {
        reasons.add(
            'Known ${knownIdentity.tier.name} (${knownIdentity.sector}) — established');
      }
      return TokenMaturity.established;
    }

    // Major assets are always established.
    if (assetClass == 'major') {
      reasons.add('Major asset — established');
      return TokenMaturity.established;
    }

    // Large alts with significant history are established.
    if (assetClass == 'large_alt') {
      reasons.add('High volume alt — established');
      return TokenMaturity.established;
    }

    // New listing event type → newborn.
    if (event.type == MarketEventType.newListingMove) {
      reasons.add('New listing event → newborn');
      return TokenMaturity.newborn;
    }

    // No profile → unknown, needs research.
    if (profile == null) {
      missingData.add('No token history — first encounter');
      return TokenMaturity.unknown;
    }

    // Zombie detection: seen many times, poor results, noisy.
    if (profile.timesSeen >= 10 &&
        profile.isNoisy &&
        profile.winRate < 0.2 &&
        event.volume24h < 200000) {
      reasons.add('Noisy token, bad WR, low volume → zombie');
      return TokenMaturity.zombie;
    }

    // Low familiarity with low volume → likely newborn or unknown.
    if (profile.timesSeen <= 3) {
      if (event.volume24h < 500000) {
        reasons.add('Rarely seen + low volume → newborn');
        return TokenMaturity.newborn;
      }
      missingData.add('Seen ${profile.timesSeen}× — still learning');
      return TokenMaturity.unknown;
    }

    // Moderate familiarity → emerging.
    if (profile.timesSeen <= 20) {
      reasons.add('Seen ${profile.timesSeen}× — emerging');
      return TokenMaturity.emerging;
    }

    // Well-known on this exchange.
    reasons
        .add('Seen ${profile.timesSeen}× — established on ${event.exchange}');
    return TokenMaturity.established;
  }

  // ── Rocket Stage ────────────────────────────────────────────────────────────

  RocketStage _classifyRocketStage(
    MarketEvent event,
    TechnicalSnapshot? ta,
    List<String> reasons,
  ) {
    final change = event.changePercent;
    final rsi = ta?.rsi14;
    final volRatio = ta?.volumeRatio;
    final bodyRatio = ta?.candleBodyRatio;

    // Not really pumping.
    if (change < 10) return RocketStage.unknown;

    // Exhaustion trap: extreme pump + RSI overbought + wick rejection.
    if (change > 300 ||
        (change > 100 && rsi != null && rsi > 80) ||
        (change > 50 &&
            bodyRatio != null &&
            bodyRatio < 0.25 &&
            rsi != null &&
            rsi > 75)) {
      reasons.add('Exhaustion: chg=${change.toStringAsFixed(0)}% '
          'RSI=${rsi?.toStringAsFixed(0) ?? "?"} '
          'body=${bodyRatio?.toStringAsFixed(2) ?? "?"}');
      return RocketStage.exhaustionTrap;
    }

    // Late rocket: +100–300%, still has body but dangerous.
    if (change > 100) {
      reasons.add('Late rocket: +${change.toStringAsFixed(0)}%');
      return RocketStage.lateRocket;
    }

    // Mid rocket: +30–100% with volume confirmation.
    if (change > 30) {
      final hasVolume = volRatio != null && volRatio > 2.0;
      final hasBody = bodyRatio == null || bodyRatio > 0.4;
      if (hasVolume && hasBody) {
        reasons.add(
            'Mid rocket: +${change.toStringAsFixed(0)}% vol=${volRatio.toStringAsFixed(1)}x');
        return RocketStage.midRocket;
      }
      reasons.add('Mid rocket range but weak signals');
      return RocketStage.midRocket;
    }

    // Early rocket: +10–30%, volume growing.
    if (change >= 10) {
      final hasVolume = volRatio != null && volRatio > 1.5;
      if (hasVolume) {
        reasons.add(
            'Early rocket: +${change.toStringAsFixed(0)}% vol=${volRatio.toStringAsFixed(1)}x');
        return RocketStage.earlyRocket;
      }
    }

    return RocketStage.unknown;
  }

  // ── Exhaustion Risk ─────────────────────────────────────────────────────────

  bool _isExhaustionRisk(
    MarketEvent event,
    TechnicalSnapshot? ta,
    RocketStage rocketStage,
  ) {
    if (rocketStage == RocketStage.exhaustionTrap) return true;
    if (ta == null) return false;

    final rsi = ta.rsi14;
    final bodyRatio = ta.candleBodyRatio;

    // RSI > 80 = likely exhausted.
    if (rsi != null && rsi > 80) return true;

    // Long wick (body < 25%) + RSI > 70 = distribution.
    if (bodyRatio != null && bodyRatio < 0.25 && rsi != null && rsi > 70) {
      return true;
    }

    // Extreme pump without volume = likely fake.
    if (event.changePercent > 50 &&
        ta.volumeRatio != null &&
        ta.volumeRatio! < 1.5) {
      return true;
    }

    return false;
  }

  // ── Strategy Selection ──────────────────────────────────────────────────────

  StrategyType _selectStrategy({
    required MarketEvent event,
    required TechnicalSnapshot? ta,
    required MarketPhase phase,
    required TokenMaturity maturity,
    required RocketStage rocketStage,
    required String assetClass,
    required AssetCategory assetCategory,
    required bool isLiquiditySafe,
    required bool isExhaustionRisk,
    required bool isRocketCandidate,
    required bool isNewListingCandidate,
    required bool isContinuationCandidate,
    required TokenProfile? tokenProfile,
    required ExchangeProfile? exchangeProfile,
    required List<String> reasons,
  }) {
    // ── Phase 15A.2: Coin Passport HARD BLOCK ──
    // Stablecoin, commodity-backed, dead tokens → instant noTrade.
    if (assetCategory.isNoTrade) {
      reasons.add('CoinPassport REJECT: ${assetCategory.label}');
      return StrategyType.noTrade;
    }

    // ── Hard blocks ──

    // Exhaustion trap → noTrade.
    if (isExhaustionRisk && rocketStage == RocketStage.exhaustionTrap) {
      reasons.add('Exhaustion trap → noTrade');
      return StrategyType.noTrade;
    }

    // Zombie token → noTrade.
    if (maturity == TokenMaturity.zombie) {
      reasons.add('Zombie token → noTrade');
      return StrategyType.noTrade;
    }

    // No liquidity → researchOnly (can't trade safely).
    if (!isLiquiditySafe) {
      reasons.add('Insufficient liquidity → researchOnly');
      return StrategyType.researchOnly;
    }

    // Fake breakout event → noTrade.
    if (event.type == MarketEventType.fakeBreakout) {
      reasons.add('Fake breakout detected → noTrade');
      return StrategyType.noTrade;
    }

    // Liquidity drain → noTrade.
    if (event.type == MarketEventType.liquidityDrain) {
      reasons.add('Liquidity draining → noTrade');
      return StrategyType.noTrade;
    }

    // ── Context-driven selection ──

    // Unknown token → researchOnly (learn first, trade later).
    if (maturity == TokenMaturity.unknown) {
      reasons.add('Unknown token → researchOnly');
      return StrategyType.researchOnly;
    }

    // New listing with early action.
    if (isNewListingCandidate && maturity == TokenMaturity.newborn) {
      reasons.add('New listing + newborn → newListing strategy');
      return StrategyType.newListing;
    }

    // Rocket continuation for non-majors.
    if (isRocketCandidate && assetClass != 'major') {
      if (rocketStage == RocketStage.lateRocket) {
        reasons.add('Late rocket → scalp only');
        return StrategyType.scalp;
      }
      reasons.add('Rocket candidate → rocketContinuation');
      return StrategyType.rocketContinuation;
    }

    // Major + exhaustion risk → researchOnly.
    if (assetClass == 'major' && isExhaustionRisk) {
      reasons.add('Major + exhaustion → researchOnly');
      return StrategyType.researchOnly;
    }

    // Trend continuation on established asset.
    if (isContinuationCandidate) {
      reasons.add('Confirmed trend on established asset → normalMomentum');
      return StrategyType.normalMomentum;
    }

    // Established asset with moderate move.
    if (maturity == TokenMaturity.established &&
        event.changePercent >= 3 &&
        event.changePercent <= 30) {
      reasons.add('Established + moderate move → normalMomentum');
      return StrategyType.normalMomentum;
    }

    // Emerging asset with strong signals.
    if (maturity == TokenMaturity.emerging) {
      final hasTA = ta != null && ta.hasData;
      if (hasTA && event.volume24h > 200000) {
        reasons.add('Emerging + TA + volume → normalMomentum');
        return StrategyType.normalMomentum;
      }
      reasons.add('Emerging but insufficient confirmation → researchOnly');
      return StrategyType.researchOnly;
    }

    // Newborn not matching newListing criteria.
    if (maturity == TokenMaturity.newborn) {
      reasons.add('Newborn without clear pattern → researchOnly');
      return StrategyType.researchOnly;
    }

    // Default: researchOnly.
    reasons.add('No clear strategy match → researchOnly');
    return StrategyType.researchOnly;
  }

  // ── Confidence ──────────────────────────────────────────────────────────────

  double _calculateConfidence({
    required TechnicalSnapshot? ta,
    required TokenProfile? tokenProfile,
    required TokenMaturity maturity,
    required List<String> missingData,
  }) {
    double conf = 0.5;

    // TA available → confidence boost.
    if (ta != null && ta.hasData) conf += 0.2;

    // Token profile with history → confidence boost.
    if (tokenProfile != null && tokenProfile.isTrustworthy) conf += 0.15;

    // Known maturity → small boost.
    if (maturity != TokenMaturity.unknown) conf += 0.1;

    // Missing data → penalty.
    conf -= missingData.length * 0.1;

    return conf.clamp(0.1, 0.95);
  }
}
