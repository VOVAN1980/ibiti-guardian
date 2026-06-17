// ─── Known Asset Registry ───────────────────────────────────────────────────────
//
// Phase 18A: Global Asset Identity
//
// JARVIS must know WHAT an asset is BEFORE seeing it on any exchange.
// BTC is always a major. PEPE is always a meme. RNDR is always an AI token.
// This knowledge does NOT depend on seenCount or exchange history.
//
// seenCount = exchange-local maturity (how familiar on THIS exchange)
// KnownAssetRegistry = global identity (what IS this token)
//
// CoinPassport checks registry FIRST → then seenCount for local maturity.
// ─────────────────────────────────────────────────────────────────────────────────

import 'package:ibiti_guardian/services/ibiti/models/strategy_context.dart';

/// Global identity tier — what kind of asset this is at its core.
enum AssetTier {
  /// BTC, ETH, BNB, SOL, XRP — top market cap, deep liquidity
  major,

  /// Well-known alts with significant market cap and history
  knownAlt,

  /// DeFi protocols (UNI, AAVE, MKR, etc.)
  defi,

  /// AI/GPU sector (RNDR, TAO, FET, etc.)
  ai,

  /// Layer 2 tokens (ARB, OP, MATIC, etc.)
  l2,

  /// Gaming/Metaverse (AXS, SAND, MANA, etc.)
  gaming,

  /// Meme tokens (DOGE, PEPE, SHIB, etc.)
  meme,

  /// Wrapped assets (WBTC, WBETH, stETH)
  wrapped,

  /// Infrastructure / Oracle / Cross-chain
  infra,

  /// Exchange tokens (BNB already major, but CRO, GT, MX, etc.)
  exchangeToken,

  /// Privacy coins
  privacy,

  /// Not in registry — truly unknown
  unknown,
}

/// Known asset identity — immutable global knowledge.
class AssetIdentity {
  final AssetTier tier;
  final String sector; // e.g. 'L1', 'AI/GPU', 'meme', 'DeFi/DEX'
  final String mcapTier; // 'mega', 'large', 'mid', 'small'

  const AssetIdentity({
    required this.tier,
    required this.sector,
    this.mcapTier = 'mid',
  });

  /// Map tier to existing AssetCategory for backward compatibility.
  AssetCategory toCategory() => switch (tier) {
        AssetTier.major => AssetCategory.major,
        AssetTier.knownAlt => AssetCategory.largeAlt,
        AssetTier.defi => AssetCategory.altcoin,
        AssetTier.ai => AssetCategory.altcoin,
        AssetTier.l2 => AssetCategory.altcoin,
        AssetTier.gaming => AssetCategory.altcoin,
        AssetTier.meme => AssetCategory.meme,
        AssetTier.wrapped => AssetCategory.largeAlt,
        AssetTier.infra => AssetCategory.altcoin,
        AssetTier.exchangeToken => AssetCategory.altcoin,
        AssetTier.privacy => AssetCategory.smallAlt,
        AssetTier.unknown => AssetCategory.altcoin,
      };

  /// Known assets are always at least "established" maturity.
  bool get isEstablished => tier != AssetTier.unknown && tier != AssetTier.meme;

  /// Memes have special volatility rules — "established" but wild.
  bool get isMeme => tier == AssetTier.meme;
}

// ═════════════════════════════════════════════════════════════════════════════
// KNOWN ASSET REGISTRY
// ═════════════════════════════════════════════════════════════════════════════

class KnownAssetRegistry {
  KnownAssetRegistry._();

  /// Lookup a symbol in the global registry.
  /// Returns null if the asset is not known (truly new/unknown).
  static AssetIdentity? lookup(String symbol) {
    return _registry[symbol.toUpperCase()];
  }

  /// Check if a symbol is a known asset.
  static bool isKnown(String symbol) =>
      _registry.containsKey(symbol.toUpperCase());

  /// Get the tier for a symbol, or [AssetTier.unknown] if not found.
  static AssetTier tierOf(String symbol) =>
      _registry[symbol.toUpperCase()]?.tier ?? AssetTier.unknown;

  // ── Registry: ~200 tokens ──────────────────────────────────────────────

  static const Map<String, AssetIdentity> _registry = {
    // ═══════════════════════════════════════════════════════════════════════
    // MAJORS — Top market cap, deep liquidity, market-defining assets
    // ═══════════════════════════════════════════════════════════════════════
    'BTCUSDT':
        AssetIdentity(tier: AssetTier.major, sector: 'L1', mcapTier: 'mega'),
    'ETHUSDT':
        AssetIdentity(tier: AssetTier.major, sector: 'L1', mcapTier: 'mega'),
    'BNBUSDT': AssetIdentity(
        tier: AssetTier.major, sector: 'CEX/L1', mcapTier: 'mega'),
    'SOLUSDT':
        AssetIdentity(tier: AssetTier.major, sector: 'L1', mcapTier: 'large'),
    'XRPUSDT': AssetIdentity(
        tier: AssetTier.major, sector: 'payments', mcapTier: 'large'),
    'ADAUSDT':
        AssetIdentity(tier: AssetTier.major, sector: 'L1', mcapTier: 'large'),
    'TRXUSDT':
        AssetIdentity(tier: AssetTier.major, sector: 'L1', mcapTier: 'large'),
    'AVAXUSDT':
        AssetIdentity(tier: AssetTier.major, sector: 'L1', mcapTier: 'large'),
    'DOTUSDT':
        AssetIdentity(tier: AssetTier.major, sector: 'L0', mcapTier: 'large'),
    'LINKUSDT': AssetIdentity(
        tier: AssetTier.major, sector: 'oracle', mcapTier: 'large'),
    'LTCUSDT':
        AssetIdentity(tier: AssetTier.major, sector: 'L1', mcapTier: 'large'),
    'TONUSDT':
        AssetIdentity(tier: AssetTier.major, sector: 'L1', mcapTier: 'large'),
    'SUIUSDT':
        AssetIdentity(tier: AssetTier.major, sector: 'L1', mcapTier: 'large'),

    // ═══════════════════════════════════════════════════════════════════════
    // KNOWN ALTS — Well-established, significant market cap
    // ═══════════════════════════════════════════════════════════════════════
    'NEARUSDT':
        AssetIdentity(tier: AssetTier.knownAlt, sector: 'L1', mcapTier: 'mid'),
    'APTUSDT':
        AssetIdentity(tier: AssetTier.knownAlt, sector: 'L1', mcapTier: 'mid'),
    'ICPUSDT':
        AssetIdentity(tier: AssetTier.knownAlt, sector: 'L1', mcapTier: 'mid'),
    'ATOMUSDT':
        AssetIdentity(tier: AssetTier.knownAlt, sector: 'L0', mcapTier: 'mid'),
    'XLMUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'payments', mcapTier: 'mid'),
    'FILUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'storage', mcapTier: 'mid'),
    'VETUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'supply-chain', mcapTier: 'mid'),
    'HBARUSDT':
        AssetIdentity(tier: AssetTier.knownAlt, sector: 'L1', mcapTier: 'mid'),
    'ALGOUSDT':
        AssetIdentity(tier: AssetTier.knownAlt, sector: 'L1', mcapTier: 'mid'),
    'SEIUSDT':
        AssetIdentity(tier: AssetTier.knownAlt, sector: 'L1', mcapTier: 'mid'),
    'INJUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'L1/DeFi', mcapTier: 'mid'),
    'TIAUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'modular', mcapTier: 'mid'),
    'JUPUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'DEX/SOL', mcapTier: 'mid'),
    'STXUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'BTC-L2', mcapTier: 'mid'),
    'ETCUSDT':
        AssetIdentity(tier: AssetTier.knownAlt, sector: 'L1', mcapTier: 'mid'),
    'EOSUSDT':
        AssetIdentity(tier: AssetTier.knownAlt, sector: 'L1', mcapTier: 'mid'),
    'XTZUSDT':
        AssetIdentity(tier: AssetTier.knownAlt, sector: 'L1', mcapTier: 'mid'),
    'EGLDUSDT':
        AssetIdentity(tier: AssetTier.knownAlt, sector: 'L1', mcapTier: 'mid'),
    'FLOWUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'L1/NFT', mcapTier: 'small'),
    'RUNEUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'cross-chain', mcapTier: 'mid'),
    'KASUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'L1/PoW', mcapTier: 'mid'),
    'FTMUSDT':
        AssetIdentity(tier: AssetTier.knownAlt, sector: 'L1', mcapTier: 'mid'),
    'ARUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'storage', mcapTier: 'mid'),
    'MINAUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'L1/zk', mcapTier: 'small'),
    'NEOUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'L1', mcapTier: 'small'),
    'QNTUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'interop', mcapTier: 'mid'),
    'IOTAUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'IoT', mcapTier: 'small'),
    'ZILUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'L1', mcapTier: 'small'),

    // ═══════════════════════════════════════════════════════════════════════
    // AI / GPU / COMPUTE — Hot sector
    // ═══════════════════════════════════════════════════════════════════════
    'RNDRUSDT':
        AssetIdentity(tier: AssetTier.ai, sector: 'AI/GPU', mcapTier: 'mid'),
    'TAOUSDT':
        AssetIdentity(tier: AssetTier.ai, sector: 'AI/ML', mcapTier: 'mid'),
    'FETUSDT':
        AssetIdentity(tier: AssetTier.ai, sector: 'AI/agents', mcapTier: 'mid'),
    'WLDUSDT':
        AssetIdentity(tier: AssetTier.ai, sector: 'AI/ID', mcapTier: 'mid'),
    'OCEANUSDT':
        AssetIdentity(tier: AssetTier.ai, sector: 'AI/data', mcapTier: 'small'),
    'AGIXUSDT':
        AssetIdentity(tier: AssetTier.ai, sector: 'AI', mcapTier: 'small'),
    'ARKMUSDT': AssetIdentity(
        tier: AssetTier.ai, sector: 'AI/compute', mcapTier: 'small'),
    'AITUSDT':
        AssetIdentity(tier: AssetTier.ai, sector: 'AI', mcapTier: 'small'),
    'AIUSDT':
        AssetIdentity(tier: AssetTier.ai, sector: 'AI', mcapTier: 'small'),
    'VIRTUSDT': AssetIdentity(
        tier: AssetTier.ai, sector: 'AI/agents', mcapTier: 'small'),

    // ═══════════════════════════════════════════════════════════════════════
    // L2 — Layer 2 scaling solutions
    // ═══════════════════════════════════════════════════════════════════════
    'ARBUSDT':
        AssetIdentity(tier: AssetTier.l2, sector: 'L2/ETH', mcapTier: 'mid'),
    'OPUSDT':
        AssetIdentity(tier: AssetTier.l2, sector: 'L2/ETH', mcapTier: 'mid'),
    'MATICUSDT':
        AssetIdentity(tier: AssetTier.l2, sector: 'L2/ETH', mcapTier: 'large'),
    'POLUSDT':
        AssetIdentity(tier: AssetTier.l2, sector: 'L2/ETH', mcapTier: 'large'),
    'MANTAUSDT':
        AssetIdentity(tier: AssetTier.l2, sector: 'L2/ETH', mcapTier: 'small'),
    'METISUSDT':
        AssetIdentity(tier: AssetTier.l2, sector: 'L2/ETH', mcapTier: 'small'),
    'STRKUSDT':
        AssetIdentity(tier: AssetTier.l2, sector: 'L2/zk', mcapTier: 'mid'),
    'ZKUSDT':
        AssetIdentity(tier: AssetTier.l2, sector: 'L2/zk', mcapTier: 'mid'),
    'SCROLLUSDT':
        AssetIdentity(tier: AssetTier.l2, sector: 'L2/zk', mcapTier: 'small'),
    'BLASTUSDT':
        AssetIdentity(tier: AssetTier.l2, sector: 'L2/ETH', mcapTier: 'small'),

    // ═══════════════════════════════════════════════════════════════════════
    // DeFi — Decentralized Finance protocols
    // ═══════════════════════════════════════════════════════════════════════
    'UNIUSDT': AssetIdentity(
        tier: AssetTier.defi, sector: 'DeFi/DEX', mcapTier: 'mid'),
    'AAVEUSDT': AssetIdentity(
        tier: AssetTier.defi, sector: 'DeFi/lending', mcapTier: 'mid'),
    'MKRUSDT': AssetIdentity(
        tier: AssetTier.defi, sector: 'DeFi/stable', mcapTier: 'mid'),
    'CRVUSDT': AssetIdentity(
        tier: AssetTier.defi, sector: 'DeFi/AMM', mcapTier: 'mid'),
    'LDOUSDT': AssetIdentity(
        tier: AssetTier.defi, sector: 'DeFi/staking', mcapTier: 'mid'),
    'SNXUSDT': AssetIdentity(
        tier: AssetTier.defi, sector: 'DeFi/synth', mcapTier: 'small'),
    'COMPUSDT': AssetIdentity(
        tier: AssetTier.defi, sector: 'DeFi/lending', mcapTier: 'small'),
    'SUSHIUSDT': AssetIdentity(
        tier: AssetTier.defi, sector: 'DeFi/DEX', mcapTier: 'small'),
    '1INCHUSDT': AssetIdentity(
        tier: AssetTier.defi, sector: 'DeFi/aggregator', mcapTier: 'small'),
    'PENDLEUSDT': AssetIdentity(
        tier: AssetTier.defi, sector: 'DeFi/yield', mcapTier: 'small'),
    'GMXUSDT': AssetIdentity(
        tier: AssetTier.defi, sector: 'DeFi/perps', mcapTier: 'small'),
    'DYDXUSDT': AssetIdentity(
        tier: AssetTier.defi, sector: 'DeFi/perps', mcapTier: 'small'),
    'CAKEUSDT': AssetIdentity(
        tier: AssetTier.defi, sector: 'DeFi/DEX', mcapTier: 'small'),
    'JOEUSDT': AssetIdentity(
        tier: AssetTier.defi, sector: 'DeFi/DEX', mcapTier: 'small'),
    'RAYUSDT': AssetIdentity(
        tier: AssetTier.defi, sector: 'DeFi/SOL', mcapTier: 'small'),
    'ORCAUSDT': AssetIdentity(
        tier: AssetTier.defi, sector: 'DeFi/SOL', mcapTier: 'small'),
    'ENSUSDT': AssetIdentity(
        tier: AssetTier.defi, sector: 'DeFi/naming', mcapTier: 'small'),

    // ═══════════════════════════════════════════════════════════════════════
    // MEMES — High volatility, meme dynamics, can 10x or dump 90%
    // ═══════════════════════════════════════════════════════════════════════
    'DOGEUSDT':
        AssetIdentity(tier: AssetTier.meme, sector: 'meme', mcapTier: 'large'),
    'SHIBUSDT':
        AssetIdentity(tier: AssetTier.meme, sector: 'meme', mcapTier: 'mid'),
    'PEPEUSDT':
        AssetIdentity(tier: AssetTier.meme, sector: 'meme', mcapTier: 'mid'),
    'WIFUSDT': AssetIdentity(
        tier: AssetTier.meme, sector: 'meme/SOL', mcapTier: 'mid'),
    'BONKUSDT': AssetIdentity(
        tier: AssetTier.meme, sector: 'meme/SOL', mcapTier: 'small'),
    'FLOKIUSDT':
        AssetIdentity(tier: AssetTier.meme, sector: 'meme', mcapTier: 'small'),
    'TRUMPUSDT': AssetIdentity(
        tier: AssetTier.meme, sector: 'meme/political', mcapTier: 'mid'),
    'BRETTUSDT': AssetIdentity(
        tier: AssetTier.meme, sector: 'meme/BASE', mcapTier: 'small'),
    'MOGUUSDT':
        AssetIdentity(tier: AssetTier.meme, sector: 'meme', mcapTier: 'small'),
    'MEMECOINUSDT':
        AssetIdentity(tier: AssetTier.meme, sector: 'meme', mcapTier: 'small'),
    '1000PEPEUSDT':
        AssetIdentity(tier: AssetTier.meme, sector: 'meme', mcapTier: 'mid'),
    '1000CHEEMSUSDT':
        AssetIdentity(tier: AssetTier.meme, sector: 'meme', mcapTier: 'small'),
    'HMSTRUSDT': AssetIdentity(
        tier: AssetTier.meme, sector: 'meme/game', mcapTier: 'small'),
    'BABYDOGEUSDT':
        AssetIdentity(tier: AssetTier.meme, sector: 'meme', mcapTier: 'small'),
    'NEIROUSDT': AssetIdentity(
        tier: AssetTier.meme, sector: 'meme/AI', mcapTier: 'small'),
    'POPCATUSDT': AssetIdentity(
        tier: AssetTier.meme, sector: 'meme/SOL', mcapTier: 'small'),
    'MEWUSDT': AssetIdentity(
        tier: AssetTier.meme, sector: 'meme/SOL', mcapTier: 'small'),
    'PENGUUSDT': AssetIdentity(
        tier: AssetTier.meme, sector: 'meme/NFT', mcapTier: 'small'),
    'ACTUSDT': AssetIdentity(
        tier: AssetTier.meme, sector: 'meme/AI', mcapTier: 'small'),
    'PNUTUSDT':
        AssetIdentity(tier: AssetTier.meme, sector: 'meme', mcapTier: 'small'),
    'SUNDOGUSDT': AssetIdentity(
        tier: AssetTier.meme, sector: 'meme/TRON', mcapTier: 'small'),
    'PONKEUSDT': AssetIdentity(
        tier: AssetTier.meme, sector: 'meme/SOL', mcapTier: 'small'),

    // ═══════════════════════════════════════════════════════════════════════
    // WRAPPED / STAKED — Never treat as "new listing"
    // ═══════════════════════════════════════════════════════════════════════
    'WBTCUSDT': AssetIdentity(
        tier: AssetTier.wrapped, sector: 'wrappedBTC', mcapTier: 'large'),
    'WBETHUSDT': AssetIdentity(
        tier: AssetTier.wrapped, sector: 'stakedETH', mcapTier: 'large'),
    'BETHUSDT': AssetIdentity(
        tier: AssetTier.wrapped, sector: 'stakedETH', mcapTier: 'large'),
    'STETHUSDT': AssetIdentity(
        tier: AssetTier.wrapped, sector: 'stakedETH', mcapTier: 'large'),
    'RETHUSDT': AssetIdentity(
        tier: AssetTier.wrapped, sector: 'stakedETH', mcapTier: 'mid'),
    'CBETHUSDT': AssetIdentity(
        tier: AssetTier.wrapped, sector: 'stakedETH', mcapTier: 'mid'),

    // ═══════════════════════════════════════════════════════════════════════
    // GAMING / METAVERSE
    // ═══════════════════════════════════════════════════════════════════════
    'AXSUSDT': AssetIdentity(
        tier: AssetTier.gaming, sector: 'gaming', mcapTier: 'mid'),
    'SANDUSDT': AssetIdentity(
        tier: AssetTier.gaming, sector: 'metaverse', mcapTier: 'mid'),
    'MANAUSDT': AssetIdentity(
        tier: AssetTier.gaming, sector: 'metaverse', mcapTier: 'mid'),
    'GALAUSDT': AssetIdentity(
        tier: AssetTier.gaming, sector: 'gaming', mcapTier: 'small'),
    'ILVUSDT': AssetIdentity(
        tier: AssetTier.gaming, sector: 'gaming', mcapTier: 'small'),
    'IMXUSDT': AssetIdentity(
        tier: AssetTier.gaming, sector: 'gaming/L2', mcapTier: 'mid'),
    'APEUSDT': AssetIdentity(
        tier: AssetTier.gaming, sector: 'NFT/gaming', mcapTier: 'small'),
    'PIXELUSDT': AssetIdentity(
        tier: AssetTier.gaming, sector: 'gaming', mcapTier: 'small'),
    'NOTUSDT': AssetIdentity(
        tier: AssetTier.gaming, sector: 'gaming/TON', mcapTier: 'small'),
    'RONINUSDT': AssetIdentity(
        tier: AssetTier.gaming, sector: 'gaming/L1', mcapTier: 'small'),

    // ═══════════════════════════════════════════════════════════════════════
    // INFRA / ORACLE / CROSS-CHAIN
    // ═══════════════════════════════════════════════════════════════════════
    'GRTUSDT': AssetIdentity(
        tier: AssetTier.infra, sector: 'indexing', mcapTier: 'mid'),
    'PYTHUSDT': AssetIdentity(
        tier: AssetTier.infra, sector: 'oracle/SOL', mcapTier: 'small'),
    'WUSDT': AssetIdentity(
        tier: AssetTier.infra, sector: 'cross-chain', mcapTier: 'mid'),
    'AXLUSDT': AssetIdentity(
        tier: AssetTier.infra, sector: 'cross-chain', mcapTier: 'small'),
    'ZETAUSDT': AssetIdentity(
        tier: AssetTier.infra, sector: 'cross-chain', mcapTier: 'small'),
    'CELOUSDT': AssetIdentity(
        tier: AssetTier.infra, sector: 'mobile', mcapTier: 'small'),
    'IOTXUSDT':
        AssetIdentity(tier: AssetTier.infra, sector: 'IoT', mcapTier: 'small'),
    'THETAUSDT': AssetIdentity(
        tier: AssetTier.infra, sector: 'streaming', mcapTier: 'mid'),
    'CHZUSDT': AssetIdentity(
        tier: AssetTier.infra, sector: 'sports/fan', mcapTier: 'small'),

    // ═══════════════════════════════════════════════════════════════════════
    // EXCHANGE TOKENS
    // ═══════════════════════════════════════════════════════════════════════
    'CROUSDT': AssetIdentity(
        tier: AssetTier.exchangeToken, sector: 'CEX', mcapTier: 'mid'),
    'GTUSDT': AssetIdentity(
        tier: AssetTier.exchangeToken, sector: 'CEX/Gate', mcapTier: 'small'),
    'MXUSDT': AssetIdentity(
        tier: AssetTier.exchangeToken, sector: 'CEX/MEXC', mcapTier: 'small'),
    'OKBUSDT': AssetIdentity(
        tier: AssetTier.exchangeToken, sector: 'CEX/OKX', mcapTier: 'mid'),
    'FTTUSDT': AssetIdentity(
        tier: AssetTier.exchangeToken, sector: 'CEX/dead', mcapTier: 'small'),
    'HTUSDT': AssetIdentity(
        tier: AssetTier.exchangeToken, sector: 'CEX/HTX', mcapTier: 'small'),

    // ═══════════════════════════════════════════════════════════════════════
    // PRIVACY
    // ═══════════════════════════════════════════════════════════════════════
    'XMRUSDT': AssetIdentity(
        tier: AssetTier.privacy, sector: 'privacy', mcapTier: 'mid'),
    'ZECUSDT': AssetIdentity(
        tier: AssetTier.privacy, sector: 'privacy', mcapTier: 'small'),

    // ═══════════════════════════════════════════════════════════════════════
    // OTHER KNOWN — miscellaneous well-known tokens
    // ═══════════════════════════════════════════════════════════════════════
    'MASKUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'social', mcapTier: 'small'),
    'CKBUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'L1', mcapTier: 'small'),
    'CFXUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'L1', mcapTier: 'small'),
    'JASMYUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'IoT/Japan', mcapTier: 'small'),
    'ONDOUSDT':
        AssetIdentity(tier: AssetTier.defi, sector: 'RWA', mcapTier: 'mid'),
    'ORDIUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'BTC/ordinals', mcapTier: 'small'),
    'SATSUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'BTC/BRC20', mcapTier: 'small'),
    'ACMUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'fan-token', mcapTier: 'small'),
    'POLSUSDT': AssetIdentity(
        tier: AssetTier.knownAlt, sector: 'launchpad', mcapTier: 'small'),
  };

  /// Total count of known assets in the registry.
  static int get count => _registry.length;
}
