// ─── Shared exchange types ─────────────────────────────────────────────────────

/// Risk/entry label shown next to each coin.
enum TickerRisk {
  newListing, // just listed, high risk / early opportunity
  hot, // strong momentum + volume right now
  thinLiquidity, // volume too low to enter safely with $100
  safe, // good liquidity, established pair
}

extension TickerRiskExt on TickerRisk {
  /// Localization key for badge label.
  String get labelKey {
    switch (this) {
      case TickerRisk.newListing:
        return 'terminalRiskNew';
      case TickerRisk.hot:
        return 'terminalRiskHot';
      case TickerRisk.thinLiquidity:
        return 'terminalRiskThin';
      case TickerRisk.safe:
        return 'terminalRiskSafe';
    }
  }

  /// Fallback English label (for logs, non-UI usage).
  String get label {
    switch (this) {
      case TickerRisk.newListing:
        return '🆕 New';
      case TickerRisk.hot:
        return '🔥 Hot';
      case TickerRisk.thinLiquidity:
        return '⚠️ Thin';
      case TickerRisk.safe:
        return '✅ Safe';
    }
  }

  /// Localization key for entry note.
  String get entryNoteKey {
    switch (this) {
      case TickerRisk.newListing:
        return 'terminalRiskNewDesc';
      case TickerRisk.hot:
        return 'terminalRiskHotDesc';
      case TickerRisk.thinLiquidity:
        return 'terminalRiskThinDesc';
      case TickerRisk.safe:
        return 'terminalRiskSafeDesc';
    }
  }

  String get entryNote {
    switch (this) {
      case TickerRisk.newListing:
        return 'Early · High risk';
      case TickerRisk.hot:
        return 'Good for small entry';
      case TickerRisk.thinLiquidity:
        return 'Risky liquidity';
      case TickerRisk.safe:
        return 'Safer entry';
    }
  }
}

// ─── 4 Terminal View Tabs ──────────────────────────────────────────────────────

enum TerminalView {
  newListings, // brand new coins ≤7 days
  fastGrowth, // momentum score: freshness × volume × price × liquidity
  memeTrend, // community/meme coins with upward momentum
  majors, // BTC ETH SOL BNB + large-cap going up
}

extension TerminalViewExt on TerminalView {
  /// Localization key for tab label.
  String get labelKey {
    switch (this) {
      case TerminalView.newListings:
        return 'terminalViewNew';
      case TerminalView.fastGrowth:
        return 'terminalViewFastGrowth';
      case TerminalView.memeTrend:
        return 'terminalViewMeme';
      case TerminalView.majors:
        return 'terminalViewMajors';
    }
  }

  /// Fallback English label.
  String get label {
    switch (this) {
      case TerminalView.newListings:
        return '🆕 New';
      case TerminalView.fastGrowth:
        return '🚀 Fast Growth';
      case TerminalView.memeTrend:
        return '🐸 Meme';
      case TerminalView.majors:
        return '💎 Majors';
    }
  }
}

// ─── LiveTicker ────────────────────────────────────────────────────────────────

/// One live ticker — real-time price + enriched metadata.
class LiveTicker {
  final String symbol;
  final String baseAsset;
  final String quoteAsset;
  final double lastPrice;
  final double priceChangePercent24h;
  final double volume24h;
  final double quoteVolume24h;
  final double highPrice24h;
  final double lowPrice24h;

  // ── Phase 11A: Exact Exchange Flow Data ──
  final double? baseVolume;
  final double? quoteVolume;
  final double? takerBuyBaseVolume;
  final double? takerBuyQuoteVolume;
  final double? takerSellBaseVolume;
  final double? takerSellQuoteVolume;
  final double? buyPressure;

  /// Momentum score (0–1): freshness × volumeSpike × priceMomentum × liquidity.
  /// Higher = better opportunity right now.
  final double momentumScore;

  /// Growth from listing open price. null = unknown.
  final double? growthSinceListing;

  /// Days since the coin was listed. null = unknown.
  final int? daysListed;

  /// Flag: this appeared in the last poll cycle (new listing detection).
  final bool isNewlyListed;

  /// Entry risk label based on volume and listing age.
  final TickerRisk risk;

  const LiveTicker({
    required this.symbol,
    required this.baseAsset,
    this.quoteAsset = 'USDT',
    required this.lastPrice,
    required this.priceChangePercent24h,
    required this.volume24h,
    required this.quoteVolume24h,
    this.highPrice24h = 0,
    this.lowPrice24h = 0,
    this.momentumScore = 0,
    this.growthSinceListing,
    this.daysListed,
    this.isNewlyListed = false,
    this.risk = TickerRisk.safe,
    this.baseVolume,
    this.quoteVolume,
    this.takerBuyBaseVolume,
    this.takerBuyQuoteVolume,
    this.takerSellBaseVolume,
    this.takerSellQuoteVolume,
    this.buyPressure,
  });

  LiveTicker copyWith({
    double? lastPrice,
    double? priceChangePercent24h,
    double? volume24h,
    double? quoteVolume24h,
    bool? isNewlyListed,
    double? momentumScore,
    TickerRisk? risk,
    double? baseVolume,
    double? quoteVolume,
    double? takerBuyBaseVolume,
    double? takerBuyQuoteVolume,
    double? takerSellBaseVolume,
    double? takerSellQuoteVolume,
    double? buyPressure,
  }) {
    return LiveTicker(
      symbol: symbol,
      baseAsset: baseAsset,
      quoteAsset: quoteAsset,
      lastPrice: lastPrice ?? this.lastPrice,
      priceChangePercent24h:
          priceChangePercent24h ?? this.priceChangePercent24h,
      volume24h: volume24h ?? this.volume24h,
      quoteVolume24h: quoteVolume24h ?? this.quoteVolume24h,
      highPrice24h: highPrice24h,
      lowPrice24h: lowPrice24h,
      momentumScore: momentumScore ?? this.momentumScore,
      growthSinceListing: growthSinceListing,
      daysListed: daysListed,
      isNewlyListed: isNewlyListed ?? this.isNewlyListed,
      risk: risk ?? this.risk,
      baseVolume: baseVolume ?? this.baseVolume,
      quoteVolume: quoteVolume ?? this.quoteVolume,
      takerBuyBaseVolume: takerBuyBaseVolume ?? this.takerBuyBaseVolume,
      takerBuyQuoteVolume: takerBuyQuoteVolume ?? this.takerBuyQuoteVolume,
      takerSellBaseVolume: takerSellBaseVolume ?? this.takerSellBaseVolume,
      takerSellQuoteVolume: takerSellQuoteVolume ?? this.takerSellQuoteVolume,
      buyPressure: buyPressure ?? this.buyPressure,
    );
  }
}

/// A new listing event — emitted when a brand-new coin appears.
class NewListingEvent {
  final String exchange;
  final LiveTicker ticker;
  final DateTime detectedAt;

  const NewListingEvent({
    required this.exchange,
    required this.ticker,
    required this.detectedAt,
  });
}

/// Supported exchange IDs.
enum ExchangeId { mexc, binance, okx, gateio }

extension ExchangeIdExt on ExchangeId {
  String get displayName {
    switch (this) {
      case ExchangeId.mexc:
        return 'MEXC';
      case ExchangeId.binance:
        return 'Binance';
      case ExchangeId.okx:
        return 'OKX';
      case ExchangeId.gateio:
        return 'Gate.io';
    }
  }

  String get emoji {
    switch (this) {
      case ExchangeId.mexc:
        return '🔵';
      case ExchangeId.binance:
        return '🟡';
      case ExchangeId.okx:
        return '⚫';
      case ExchangeId.gateio:
        return '🟢';
    }
  }

  /// MEXC is an early/high-risk exchange for micro-cap listings.
  bool get isEarlyStage => this == ExchangeId.mexc;
}

// ─── Exchange interface ────────────────────────────────────────────────────────

/// Every exchange adapter must implement this.
/// Provides live ticker stream + 4-category views.
abstract class ExchangeService {
  ExchangeId get id;

  /// Whether the WebSocket is currently connected.
  bool get isConnected;

  /// Total number of USDT pairs on this exchange.
  int get totalPairs;

  /// Stream of ALL live tickers — updates from WebSocket every ~1s.
  Stream<List<LiveTicker>> get tickerStream;

  /// All tickers from the most recent update.
  List<LiveTicker> get currentTickers;

  // ── 4 category views ────────────────────────────────────────────────────────

  /// 🆕 New Listings — coins listed in the last 7 days.
  /// Sorted by listing date (newest first).
  List<LiveTicker> get viewNewListings;

  /// 🚀 Fast Growth — momentum-scored coins.
  /// Score = freshness×0.30 + volumeSpike×0.30 + priceMomentum×0.25 + liquidity×0.15
  /// Only positive momentum. Sorted by score desc.
  List<LiveTicker> get viewFastGrowth;

  /// 🐸 Meme/Trend — community coins with upward momentum.
  List<LiveTicker> get viewMemeTrend;

  /// 💎 Majors — BTC, ETH, SOL, BNB, XRP + large-cap going up.
  List<LiveTicker> get viewMajors;

  /// Top gainers by 24h % (all categories, fallback).
  List<LiveTicker> get topGainers24h;

  // ── Legacy compatibility ─────────────────────────────────────────────────────
  List<LiveTicker> get topGainersSinceListing => viewFastGrowth;
  List<LiveTicker> get newListings;

  // ── Lifecycle ────────────────────────────────────────────────────────────────
  Future<void> connect();
  Future<void> disconnect();
  Future<void> refreshMetadata();
}

// ─── Shared scoring helper ─────────────────────────────────────────────────────

/// Calculates momentum score for a ticker.
/// Used by all exchange adapters to ensure consistent scoring.
double calcMomentumScore({
  required double priceChangePercent24h,
  required double quoteVolume24h,
  required double avgVolume24h, // typical volume for this exchange tier
  required int? daysListed,
  required double? growthSinceListing,
}) {
  // Freshness: newer listings score higher (0–1).
  // Listed today = 1.0, listed 30 days ago = 0.0
  final days = daysListed ?? 30;
  final freshness = (1 - (days.clamp(0, 30) / 30)).clamp(0.0, 1.0);

  // Volume spike: how much above the exchange average (0–1).
  final normalVol = avgVolume24h > 0 ? quoteVolume24h / avgVolume24h : 0.0;
  final volumeSpike = (normalVol / 5.0).clamp(0.0, 1.0); // 5× avg = max

  // Price momentum: 24h change, only positive, capped at 200%.
  final momentum = (priceChangePercent24h.clamp(0, 200) / 200).clamp(0.0, 1.0);

  // Liquidity: log scale ≥ $10K = 0, ≥ $1M = 0.5, ≥ $10M = 1.0
  double liquidity = 0;
  if (quoteVolume24h >= 10000) {
    liquidity = (quoteVolume24h / 10000000).clamp(0.0, 1.0);
  }

  return freshness * 0.30 +
      volumeSpike * 0.30 +
      momentum * 0.25 +
      liquidity * 0.15;
}

/// Determine entry risk for a ticker.
TickerRisk calcRisk({
  required double quoteVolume24h,
  required int? daysListed,
  required double priceChangePercent24h,
}) {
  final days = daysListed ?? 999;

  // New listing ≤ 3 days → always New (highest risk/opportunity).
  if (days <= 3) return TickerRisk.newListing;

  // Very low volume → thin liquidity.
  if (quoteVolume24h < 10000) return TickerRisk.thinLiquidity;

  // Strong momentum + decent volume → Hot.
  if (priceChangePercent24h > 5 && quoteVolume24h > 100000) {
    return TickerRisk.hot;
  }

  return TickerRisk.safe;
}
