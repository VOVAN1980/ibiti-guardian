import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/market/trading_size_calculator.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_registry.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';

// ─── Market Opportunity ────────────────────────────────────────────────────────

/// Liquidity tier for risk display.
enum LiquidityTier { low, medium, high }

class MarketOpportunity {
  final MarketAsset asset;
  final String action;
  final String thesis;
  final double score;

  /// Trust/reliability metric (0.0–1.0).
  /// High = well-known, liquid, CoinGecko-tracked asset.
  /// Low = exchange-only, thin liquidity, unknown coin.
  final double confidence;

  /// Liquidity classification for risk display.
  final LiquidityTier liquidityTier;

  /// Whether the AI is actually permitted to trade this asset in the current mode/mandate.
  /// «Советник» (AiMode.manual) → always false (advice only).
  /// «Ручной» / «Автономный» → true only if asset passes mandate and limit checks.
  final bool executableByAi;

  /// Reason execution is blocked, or null if executableByAi is true.
  final String? blockReason;

  const MarketOpportunity({
    required this.asset,
    required this.action,
    required this.thesis,
    required this.score,
    required this.confidence,
    required this.liquidityTier,
    this.executableByAi = false,
    this.blockReason,
  });
}

/// Market category for filtered signal views.
enum MarketCategory {
  /// Hot movers: biggest 24h gainers, explosive growth, meme coins.
  /// This is what traders with $100 actually need.
  hotMovers,

  /// Mid-cap volatile: SHIB, PEPE, DOGE, FLOKI, etc.
  /// Active community, high volatility, swing trade potential.
  memeAndTrending,

  /// Blue chips: BTC, ETH, SOL, BNB, etc.
  /// Lower risk, bigger capital, steady movement.
  blueChip,
}

// ─── Stablecoin blacklist — NEVER show in signals ──────────────────────────────

const _stablecoins = <String>{
  'USDT',
  'USDC',
  'DAI',
  'BUSD',
  'FDUSD',
  'USDE',
  'PYUSD',
  'TUSD',
  'FRAX',
  'LUSD',
  'GUSD',
  'USDP',
  'CRVUSD',
  'GHO',
  'SUSD',
  'MIM',
  'DOLA',
  'EURC',
  'EURS',
};

/// Minimum 24h volume (USD) to be considered a real signal.
/// CoinGecko assets: $500K (well-known coins).
/// Exchange-only assets (no CoinGecko metadata): $50K (allow moonshots).
const double _minSignalVolumeUsd = 500000.0;
const double _minExchangeOnlyVolumeUsd = 50000.0;

/// Wrapped / pegged assets that track stables — also excluded.
const _boringAssets = <String>{
  'STETH',
  'WSTETH',
  'CBETH',
  'RETH',
  'WETH',
  'WBTC',
  'TBTC',
  'WBNB',
  'WMATIC',
  'WAVAX',
  'WSOL',
};

/// Blue-chip tier symbols.
const _blueChips = <String>{
  'BTC',
  'ETH',
  'SOL',
  'BNB',
  'XRP',
  'ADA',
  'AVAX',
  'DOT',
  'MATIC',
  'LINK',
  'UNI',
  'AAVE',
  'LTC',
  'ATOM',
  'NEAR',
  'APT',
  'SUI',
  'TON',
  'FIL',
  'ICP',
  'ARB',
  'OP',
  'INJ',
  'TIA',
  'SEI',
  'RENDER',
  'FET',
  'GRT',
};

/// Meme / trending community coins.
const _memeCoins = <String>{
  'DOGE',
  'SHIB',
  'PEPE',
  'FLOKI',
  'WIF',
  'BONK',
  'MEME',
  'BOME',
  'BRETT',
  'TURBO',
  'BABYDOGE',
  'ELON',
  'NEIRO',
  'MOG',
  'POPCAT',
  'MYRO',
  'PONKE',
  'MEW',
  'GIGA',
};

// ─── Market Scout Service ──────────────────────────────────────────────────────

/// Analyses live market assets and surfaces the top trading opportunities
/// that are compatible with the user's current AI mode, mandate, and limits.
///
/// Stablecoins and wrapped/pegged assets are ALWAYS excluded from signals.
/// The scout prioritizes momentum and volatility over liquidity.
class MarketScoutService {
  MarketScoutService._();

  static final MarketScoutService instance = MarketScoutService._();

  /// Why no signal is executable in «Советник» (AiMode.manual). Kept in
  /// English and containing "Manual mode": the signal lists classify block
  /// reasons by that text (priority_signals_list.dart _classifyBlockReason,
  /// secondary_market_list.dart dot colour).
  static const String advisorBlockReason =
      'Advisor mode — advice only. The AI prepares trades in Manual mode and '
      'carries them out in Autonomous mode.';

  /// Returns top [topN] opportunities filtered by [category].
  ///
  /// If [category] is null, returns the best across all non-stable assets
  /// (default behavior — hot movers first).
  List<MarketOpportunity> findTopOpportunities(
    List<MarketAsset> assets, {
    AiControlSettings? settings,
    int topN = 3,
    MarketCategory? category,
  }) {
    final ai = settings ?? AiControlService.instance.settings;
    final mandate = ai.mandate;
    final mode = ai.mode;

    // ── Pre-filter: remove stables, wrapped, and zero-data assets ──────────
    final registry = ExchangeRegistry.instance;
    final filtered = assets.where((a) {
      if (a.price <= 0 || a.volume <= 0) return false;
      final sym = a.symbol.toUpperCase();
      if (_stablecoins.contains(sym)) return false;
      if (_boringAssets.contains(sym)) return false;

      final isExchangeOnly = a.id.isEmpty || a.rank == 0;

      // Tiered volume filter:
      // - Exchange-only: $50K minimum (MEXC/Binance moonshots)
      // - CoinGecko: $500K minimum (well-known coins)
      final minVol =
          isExchangeOnly ? _minExchangeOnlyVolumeUsd : _minSignalVolumeUsd;
      if (a.volume < minVol) return false;

      // HARD GATE: Exchange-only assets must show real movement (≥10% 24h).
      // Below 10% in the $50K–$500K volume range = noise/bots/scam pumps.
      if (isExchangeOnly && a.change24h < 10.0) return false;

      // TRADABILITY CHECK: only show assets the user can actually buy.
      // Must exist on at least one connected exchange.
      if (!registry.isTradable(sym)) return false;

      return true;
    });

    // ── Category filter ──────────────────────────────────────────────────────
    final categoryFiltered = category == null
        ? filtered
        : filtered.where((a) => _matchesCategory(a, category));

    final ranked = categoryFiltered.map((asset) {
      // ── Mandate: allowed assets whitelist ────────────────────────────
      final mandateAssets =
          mandate.allowedAssets.map((s) => s.toUpperCase()).toList();
      final assetWhitelisted = mandateAssets.isEmpty ||
          mandateAssets.contains(asset.symbol.toUpperCase());

      // ── Mandate: allowed networks whitelist ──────────────────────────
      final mandateNetworks =
          mandate.allowedNetworks.map((n) => n.toLowerCase()).toList();
      final networkAllowed = mandateNetworks.isEmpty ||
          mandateNetworks
              .any((n) => asset.networkGroup.toLowerCase().contains(n));

      // ── Trade size check ──────────────────────────────────────────────
      final sizeResult = TradingSizeCalculator.calculate(asset, ai);

      // ── Score: MOMENTUM-FIRST with directional weighting ──────────────
      // P1 Fix: Signed momentum — crashes are penalized, not rewarded.
      final momentum = asset.change24h.clamp(-30.0, 30.0) / 30.0;
      final weekly = asset.change7d.clamp(-50.0, 50.0) / 50.0;
      // Volume relative to market cap — indicates unusual activity.
      // For exchange-only assets (marketCap == 0), estimate a synthetic ratio
      // based on raw volume: >$1M → 1.0, >$5M → 1.5, scaled linearly.
      // This prevents exchange-only moonshots from being scored as dead.
      final double volumeRatio;
      if (asset.marketCap > 0) {
        volumeRatio = (asset.volume / asset.marketCap).clamp(0.0, 2.0);
      } else {
        // Synthetic ratio: $50K→0.2, $500K→0.5, $2M→1.0, $5M+→1.5
        volumeRatio = (asset.volume / 2000000.0).clamp(0.1, 1.5);
      }
      // Volatility score: distance between high and low
      final range24h = asset.high24h > 0
          ? ((asset.high24h - asset.low24h) / asset.high24h * 100)
                  .clamp(0.0, 30.0) /
              30.0
          : 0.0;

      // Use SIGNED momentum: positive = good, negative = bad.
      // Crashes should score lower, not equal to rallies.
      final signedMomentum = momentum > 0 ? momentum : momentum * 0.3;
      final signedWeekly = weekly > 0 ? weekly : weekly * 0.3;

      double score = (signedMomentum * 0.40) + // 40% — directional 24h
          (signedWeekly * 0.15) + // 15% — directional weekly
          (volumeRatio * 0.25) + // 25% — unusual volume
          (range24h * 0.20); // 20% — intraday volatility

      // Bonus for strong positive momentum (gainers > losers)
      if (momentum > 0.15) score += 0.10;
      // Bonus for breakout (high 24h movement + high volume)
      if (momentum > 0.25 && volumeRatio > 0.3) score += 0.15;

      // Exchange rocket bonus: exchange-only assets with extreme growth
      // get a boost since they represent real moonshots from live exchanges.
      final isExchangeOnly = asset.id.isEmpty || asset.rank == 0;
      if (isExchangeOnly && asset.change24h > 20) score += 0.20;
      if (isExchangeOnly && asset.change24h > 50) score += 0.15;

      // ── Action classification ─────────────────────────────────────────
      String action;
      String thesis;

      if (asset.change24h >= 10) {
        // Only label as "Breakout" if data is from a live exchange
        // and updated recently. Stale CoinGecko data ≠ real breakout.
        final isFresh = asset.sourceUpdatedAt != null &&
            DateTime.now().difference(asset.sourceUpdatedAt!).inMinutes < 5;
        final isLiveExchange =
            asset.sourceId == 'binance' || asset.sourceId == 'mexc';
        if (isFresh && isLiveExchange) {
          action = LocalizationService.instance.t('marketScoutActionBreakout');
          thesis = LocalizationService.instance.t('marketScoutThesisBreakout');
          score += 0.15;
        } else {
          action = LocalizationService.instance.t('marketScoutActionMomentum');
          thesis = LocalizationService.instance.t('marketScoutThesisMomentum');
          score += 0.05;
        }
      } else if (asset.change24h >= 5 && asset.volume > 100000000) {
        action = LocalizationService.instance.t('marketScoutActionMomentum');
        thesis = LocalizationService.instance.t('marketScoutThesisMomentum');
        score += 0.10;
      } else if (asset.change24h <= -6 && asset.change7d > -15) {
        action = LocalizationService.instance.t('marketScoutActionPullback');
        thesis = LocalizationService.instance.t('marketScoutThesisPullback');
        score += 0.08;
      } else if (asset.change24h >= 3) {
        action = LocalizationService.instance.t('marketScoutActionMomentum');
        thesis = LocalizationService.instance.t('marketScoutThesisMomentum');
      } else {
        action = LocalizationService.instance.t('marketScoutActionRotate');
        thesis = LocalizationService.instance.t('marketScoutThesisRotate');
      }

      // ── Execution eligibility ─────────────────────────────────────────
      bool executableByAi = false;
      String? blockReason;

      if (mode == AiMode.manual) {
        blockReason = advisorBlockReason;
      } else if (!assetWhitelisted) {
        blockReason = '${asset.symbol} is not in your allowed-assets mandate.';
      } else if (!networkAllowed) {
        blockReason =
            '${asset.networkGroup} is not in your allowed-networks mandate.';
      } else if (!sizeResult.viable) {
        blockReason = sizeResult.blockReason ??
            'Trade size not viable given current limits.';
      } else {
        executableByAi = true;
      }

      // ── Confidence / Trust Layer ───────────────────────────────────────
      // Measures how much the user should TRUST this signal.
      // High score + low confidence = “high risk / high reward”.
      // High score + high confidence = “solid opportunity”.
      double confidence = 0.5;
      if (!isExchangeOnly)
        confidence += 0.30; // CoinGecko-tracked = more reliable
      if (asset.volume > 1000000) confidence += 0.10; // $1M+ daily volume
      if (asset.marketCap > 50000000) confidence += 0.10; // $50M+ market cap
      confidence = confidence.clamp(0.0, 1.0);

      // ── Liquidity Tier ───────────────────────────────────────────────
      final LiquidityTier liqTier;
      if (asset.volume >= 10000000) {
        liqTier = LiquidityTier.high; // $10M+ = deep liquidity
      } else if (asset.volume >= 500000) {
        liqTier = LiquidityTier.medium; // $500K–$10M = tradable
      } else {
        liqTier = LiquidityTier.low; // <$500K = thin, risky
      }

      return MarketOpportunity(
        asset: asset,
        action: action,
        thesis: thesis,
        score: score,
        confidence: confidence,
        liquidityTier: liqTier,
        executableByAi: executableByAi,
        blockReason: blockReason,
      );
    }).toList()
      // P1 Fix: Sort by SCORE — not raw change24h.
      // Previously the score was computed but discarded, and ranking
      // was pure change24h, making low-liquidity scam pumps rank #1.
      ..sort((a, b) => b.score.compareTo(a.score));

    return ranked.take(topN).toList(growable: false);
  }

  /// Category filter — ALL categories show only POSITIVE movers.
  /// Negative coins are hidden. Biggest gainers always appear first.
  static bool _matchesCategory(MarketAsset asset, MarketCategory category) {
    final sym = asset.symbol.toUpperCase();
    switch (category) {
      case MarketCategory.hotMovers:
        // Hot movers = explosive positive growth, NOT blue chips.
        // Low rank (newer/smaller coins) + high 24h gain = rockets.
        // Only coins going UP. Minimum +5% to appear.
        if (asset.change24h < 5.0) return false;
        if (_blueChips.contains(sym)) return false;
        if (_memeCoins.contains(sym)) return false;
        return true;
      case MarketCategory.memeAndTrending:
        // Meme coins going UP only.
        if (asset.change24h <= 0) return false;
        return _memeCoins.contains(sym) ||
            (asset.rank > 80 && asset.change24h >= 5.0);
      case MarketCategory.blueChip:
        // Blue chips going UP only.
        if (asset.change24h <= 0) return false;
        return _blueChips.contains(sym);
    }
  }

  /// Returns a short human-readable summary of what the AI can do right now
  /// on the market, given its current mode, mandate and (in «Автономный»)
  /// the «Подтверждать действия ИИ ПИН-кодом» setting.
  ///
  /// Mode names as the user sees them: «Советник» (AiMode.manual) only
  /// advises, «Ручной» (AiMode.guarded) prepares, «Автономный»
  /// (AiMode.fullAutonomy) carries out — never over a limit.
  String buildModeCapabilityNote(AiControlSettings settings) {
    final t = LocalizationService.instance;
    final mode = settings.mode;
    final mandate = settings.mandate;
    final actions = settings.allowedActions.map((a) => a.name).join(', ');
    final assets = mandate.allowedAssets.isEmpty
        ? t.t('marketScoutAnyAsset', {'default': 'any asset'})
        : mandate.allowedAssets.join(', ');
    final networks = mandate.allowedNetworks.isEmpty
        ? t.t('marketScoutAnyNetwork', {'default': 'any network'})
        : mandate.allowedNetworks.join(', ');
    final daily = '\$${settings.dailyLimit.toStringAsFixed(0)}';
    // «AI Мандат» max position: it caps buys only (sends and sells are
    // bounded by the daily limit, the policy and EPK).
    final capUsd = mandate.maxPositionUsd;
    final cap = capUsd == capUsd.roundToDouble()
        ? '\$${capUsd.toStringAsFixed(0)}'
        : '\$${capUsd.toStringAsFixed(2)}';
    final args = <String, dynamic>{
      'assets': assets,
      'networks': networks,
      'actions': actions,
      'daily': daily,
      'cap': cap,
    };

    // A missing key returns the default as is, so the defaults carry the
    // values already.
    switch (mode) {
      case AiMode.manual:
        return t.t('marketScoutNoteAdvisor', {
          'default': '«Advisor» mode: I only advise — I analyse, compare and '
              'explain the market. I open, prepare and execute nothing (no '
              'windows, orders, watchlist or alerts). To let me act, switch '
              'to «Manual» or «Autonomous» in AI Center.',
        });
      case AiMode.guarded:
        return t.t('marketScoutNoteManual', {
          ...args,
          'default': '«Manual» mode: I build buy/sell plans and prepare the '
              'order or swap window for $assets on $networks. Allowed '
              'actions: $actions. You check it and confirm with your PIN — '
              'nothing runs without you.',
        });
      case AiMode.fullAutonomy:
        if (settings.aiPinConfirm) {
          return t.t('marketScoutNoteAutoPin', {
            ...args,
            'default': '«Autonomous» mode: I carry out the trades you ask '
                'for, within your mandate: $assets on $networks. Allowed '
                'actions: $actions. Daily limit: $daily. PIN confirmation is '
                'on: each trade first shows a card and asks your PIN. Limits, '
                'policy and EPK hold on every trade; I never trade on my own '
                'without your request.',
          });
        }
        // D6, exactly: no card only when ALL hold; a new address / unknown
        // price / locked wallet → the user confirms with the PIN (the card;
        // a wallet trade of a coin without a price: its filled-in window,
        // D17);
        // over a limit or outside the mandate → refused with the «Политика»
        // hint (never a card or a window that lets the user go over).
        return t.t('marketScoutNoteAutoNoPin', {
          ...args,
          'default': '«Autonomous» mode: I carry out the trades you ask for, '
              'within your mandate: $assets on $networks. Allowed actions: '
              '$actions. Daily limit: $daily; one buy at most $cap. PIN '
              'confirmation is off: I act without the card only when all of '
              'this holds: within the daily limit and the «AI Mandate», EPK '
              'protection on, a trusted recipient (a trusted address or '
              'contract, or your own wallet), a known USD price, and the app '
              'open with the wallet unlocked. A new address, an unknown price '
              'or a locked wallet: I ask you first — the card and your PIN '
              '(a wallet trade of a coin without a price opens in the '
              'filled-in window instead). Over a limit or outside the mandate '
              'I refuse; '
              'to allow more, raise the limit in «Policy» (needs your PIN). '
              'After each trade you get the notification «AI did: …». I never '
              'go over a limit and never trade on my own without your '
              'request.',
        });
    }
  }
}
