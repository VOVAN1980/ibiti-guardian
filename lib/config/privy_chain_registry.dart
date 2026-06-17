enum PrivySupportLevel {
  fullEvm,
  fullSolana,
  tier2Raw,
}

/// Represents the actual support capabilities driven by Privy Embedded Wallet architecture.
class PrivyChain {
  final String chainKey;
  final String displayName;
  final PrivySupportLevel supportLevel;

  /// EVM Chain ID (valid only if supportLevel == fullEvm). Null for Solana/Tron.
  final int? evmChainId;
  final String? nativeSymbol;
  final String? moralisSlug;
  final String? logoUrl;
  final String? rpcUrl;

  final bool canSend;
  final bool canSign;
  final bool canSwap;
  final bool canBroadcastDirectly;
  final bool requiresRawSignFlow;

  const PrivyChain({
    required this.chainKey,
    required this.displayName,
    required this.supportLevel,
    this.evmChainId,
    this.nativeSymbol,
    this.moralisSlug,
    this.logoUrl,
    this.rpcUrl,
    this.canSend = true,
    this.canSign = true,
    this.canSwap = true,
    this.canBroadcastDirectly = true,
    this.requiresRawSignFlow = false,
  });

  bool get isEvm => supportLevel == PrivySupportLevel.fullEvm;
  bool get isSolana => supportLevel == PrivySupportLevel.fullSolana;
  bool get isTron => supportLevel == PrivySupportLevel.tier2Raw;
}

class PrivyChainRegistry {
  static const PrivyChain bnbChain = PrivyChain(
    chainKey: 'bsc',
    displayName: 'BNB Chain',
    supportLevel: PrivySupportLevel.fullEvm,
    evmChainId: 56,
    nativeSymbol: 'BNB',
    moralisSlug: 'bsc',
    rpcUrl: 'https://bsc-dataseed.binance.org/',
  );

  static const PrivyChain ethereum = PrivyChain(
    chainKey: 'eth',
    displayName: 'Ethereum',
    supportLevel: PrivySupportLevel.fullEvm,
    evmChainId: 1,
    nativeSymbol: 'ETH',
    moralisSlug: 'eth',
    rpcUrl: 'https://eth.llamarpc.com',
  );

  static const PrivyChain polygon = PrivyChain(
    chainKey: 'polygon',
    displayName: 'Polygon',
    supportLevel: PrivySupportLevel.fullEvm,
    evmChainId: 137,
    nativeSymbol: 'POL',
    moralisSlug: 'polygon',
    rpcUrl: 'https://polygon-rpc.com',
  );

  static const PrivyChain arbitrum = PrivyChain(
    chainKey: 'arbitrum',
    displayName: 'Arbitrum',
    supportLevel: PrivySupportLevel.fullEvm,
    evmChainId: 42161,
    nativeSymbol: 'ETH',
    moralisSlug: 'arbitrum',
    rpcUrl: 'https://arb1.arbitrum.io/rpc',
  );

  static const PrivyChain base = PrivyChain(
    chainKey: 'base',
    displayName: 'Base',
    supportLevel: PrivySupportLevel.fullEvm,
    evmChainId: 8453,
    nativeSymbol: 'ETH',
    moralisSlug: 'base',
    rpcUrl: 'https://mainnet.base.org',
  );

  static const PrivyChain solana = PrivyChain(
    chainKey: 'solana',
    displayName: 'Solana',
    supportLevel: PrivySupportLevel.fullSolana,
    nativeSymbol: 'SOL',
    moralisSlug: 'solana',
    rpcUrl: 'https://api.mainnet-beta.solana.com',
    canSwap: true, // Jupiter V2 swap integration active
  );

  static const PrivyChain tron = PrivyChain(
    chainKey: 'tron',
    displayName: 'Tron',
    supportLevel: PrivySupportLevel.tier2Raw,
    nativeSymbol: 'TRX',
    canSwap: true, // SunSwap V2 swap integration active
    canBroadcastDirectly: false,
    requiresRawSignFlow: true,
  );

  /// All actively supported chains mapped directly to Privy wallet capabilities.
  static const List<PrivyChain> supportedChains = [
    ethereum,
    bnbChain,
    base,
    arbitrum,
    polygon,
    solana,
    tron,
  ];

  /// Group A: Full Wallet UI / Execution integration
  static List<PrivyChain> get fullSupportChains => supportedChains
      .where((c) =>
          c.supportLevel == PrivySupportLevel.fullEvm ||
          c.supportLevel == PrivySupportLevel.fullSolana)
      .toList();

  /// Group B: Tier 2 Chains (separate UI flow / raw transactions)
  static List<PrivyChain> get tier2Chains => supportedChains
      .where((c) => c.supportLevel == PrivySupportLevel.tier2Raw)
      .toList();

  /// Fetches the registry object by string key, safely defaulting to bnbChain
  static PrivyChain getChain(String key) {
    return supportedChains.firstWhere(
      (c) => c.chainKey == key,
      orElse: () => bnbChain,
    );
  }

  /// Compatibility fallback for existing EVM logic
  static PrivyChain? getEvmChain(int chainId) {
    try {
      return supportedChains.firstWhere((c) => c.evmChainId == chainId);
    } catch (_) {
      return null;
    }
  }
}
