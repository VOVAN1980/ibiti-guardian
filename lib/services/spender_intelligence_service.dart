import 'package:ibiti_guardian/models/approval.dart';

/// Built-in list of known spender contracts. Safe Scan uses it to name a
/// spender and to rate it (known DEX, or flagged).
/// All addresses except the 0x...dEaD burn address were checked to have
/// contract code on their chain (November 2026).
class SpenderIntelligenceService {
  static final SpenderIntelligenceService instance =
      SpenderIntelligenceService._internal();
  SpenderIntelligenceService._internal();

  /// Local reputation map by chain
  static final Map<int, Map<String, SpenderReputation>> _reputationMap = {
    // BNB Smart Chain (56)
    56: {
      "0x10ED43C718714eb63d5aA57B78B54704E256024E":
          SpenderReputation.dex, // PancakeSwap V2: Router
      "0x1b81D678ffb9C0263b24A97847620C99d213eB14":
          SpenderReputation.dex, // PancakeSwap V3: SwapRouter
      "0x13f4EA83D0bd40E75C8222255bc855a974568Dd4":
          SpenderReputation.dex, // PancakeSwap V3: Smart Router
      "0x1111111254EEB25477B68fb85Ed929f73A960582":
          SpenderReputation.dex, // 1inch v5: Aggregator
    },
    // Ethereum Mainnet (1)
    1: {
      "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D":
          SpenderReputation.dex, // Uniswap V2: Router 2
      "0xE592427A0AEce92De3Edee1F18E0157C05861564":
          SpenderReputation.dex, // Uniswap V3: Router
      "0x1111111254EEB25477B68fb85Ed929f73A960582":
          SpenderReputation.dex, // 1inch v5: Aggregator
      "0xdef1c0ded9bec7f1a1670819833240f027b25eff":
          SpenderReputation.dex, // 0x: Exchange
      "0x1b81D678ffb9C0263b24A97847620C99d213eB14":
          SpenderReputation.dex, // PancakeSwap V3: SwapRouter
      "0x13f4EA83D0bd40E75C8222255bc855a974568Dd4":
          SpenderReputation.dex, // PancakeSwap V3: Smart Router
    },
    // Polygon (137)
    137: {
      "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff":
          SpenderReputation.dex, // QuickSwap
      "0x1111111254EEB25477B68fb85Ed929f73A960582":
          SpenderReputation.dex, // 1inch
      "0xE592427A0AEce92De3Edee1F18E0157C05861564":
          SpenderReputation.dex, // Uniswap V3: Router
    },
    // Arbitrum (42161)
    42161: {
      "0x1111111254EEB25477B68fb85Ed929f73A960582":
          SpenderReputation.dex, // 1inch
      "0xE592427A0AEce92De3Edee1F18E0157C05861564":
          SpenderReputation.dex, // Uniswap V3: Router
      "0x1b81D678ffb9C0263b24A97847620C99d213eB14":
          SpenderReputation.dex, // PancakeSwap V3: SwapRouter
    },
  };

  /// Names of the contracts above. A name is shown only on a chain where the
  /// address is listed (the same address can be another contract elsewhere).
  static final Map<String, String> _knownLabels = {
    "0x10ED43C718714eb63d5aA57B78B54704E256024E": "PancakeSwap V2",
    "0x1b81D678ffb9C0263b24A97847620C99d213eB14": "PancakeSwap V3",
    "0x13f4EA83D0bd40E75C8222255bc855a974568Dd4": "PancakeSwap Smart Router",
    "0x1111111254EEB25477B68fb85Ed929f73A960582": "1inch Aggregator",
    "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D": "Uniswap V2",
    "0xE592427A0AEce92De3Edee1F18E0157C05861564": "Uniswap V3",
    "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff": "QuickSwap",
    "0x000000000022d473030f116ddee9f6b43ac78ba3": "Uniswap Permit2",
  };

  /// Multichain (Anyswap) contracts, by chain. Multichain collapsed in July
  /// 2023 and the January 2022 router exploit was never fixed, so old
  /// approvals to these contracts can still be drained. List from
  /// revoke.cash/exploits/multichain. Per chain on purpose: on other chains
  /// the same addresses are unrelated contracts (e.g. WETH on Arbitrum).
  static const Map<int, List<String>> _multichainByChain = {
    1: [
      "0x6b7a87899490EcE95443e979cA9485CBE7E71522",
      "0x765277EebeCA2e31912C9946eAe1021199B39C61",
      "0xe95fD76CF16008c12FF3b3a937CB16Cd9Cc20284",
    ],
    56: [
      "0xABd380327Fe66724FFDa91A87c772FB8D00bE488",
      "0xae27785B2c91c91c072ba4484D759E0C92D6fae7", // anyBNB token
      "0xd1C5966f9F5Ee6881Ff6b261BBeDa45972B1B5f3",
      "0xf9736ec3926703e85C843FC972BD89A7f8E827C0",
    ],
    137: [
      "0x4f3Aff3A747fCADe12598081e80c6605A8be192F",
      "0xAFAace7138ab3c2BCb2DB4264F8312e1Bbb80653",
    ],
    42161: [
      "0x0caE51e1032e8461f4806e26332c030E34De3aDb",
      "0xC931f61B1534EB21D8c11B24f3f5Ab2471d4aB50",
    ],
  };

  static bool _isMultichain(int chainId, String lowerAddress) =>
      (_multichainByChain[chainId] ?? const [])
          .any((a) => a.toLowerCase() == lowerAddress);

  /// Flagged on every chain.
  static final Map<String, SpenderReputation> _flaggedSpenders = {
    "0x000000000000000000000000000000000000dEaD": SpenderReputation.suspicious,
  };

  /// Known infrastructure contracts: not treated as unknown, no score bonus
  static final Map<String, SpenderReputation> _safetyTools = {
    "0x000000000022d473030f116ddee9f6b43ac78ba3":
        SpenderReputation.safety, // Uniswap Permit2
  };

  /// Trusted protocols map for careful expansion (Base, Optimism)
  static final Map<int, Map<String, SpenderReputation>> _trustedProtocols = {
    // Base (8453)
    8453: {
      "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24":
          SpenderReputation.dex, // Uniswap V2: Router 2
      "0x1b81D678ffb9C0263b24A97847620C99d213eB14":
          SpenderReputation.dex, // PancakeSwap V3: SwapRouter
    },
    // Optimism (10)
    10: {
      "0xe592427a0aece92de3edee1f18e0157c05861564":
          SpenderReputation.dex, // Uniswap V3
      "0x1111111254EEB25477B68fb85Ed929f73A960582":
          SpenderReputation.dex, // 1inch
    },
  };

  /// Returns the reputation of a spender for a specific chain.
  SpenderReputation getReputation(int chainId, String address) {
    final addr = address.toLowerCase();

    // 1. Check flagged/suspicious first
    if (_isMultichain(chainId, addr)) return SpenderReputation.flagged;
    for (final entry in _flaggedSpenders.entries) {
      if (entry.key.toLowerCase() == addr) return entry.value;
    }

    // 2. Check known infrastructure contracts
    for (final entry in _safetyTools.entries) {
      if (entry.key.toLowerCase() == addr) return entry.value;
    }

    // 3. Check trusted protocols map (Expansion chains)
    final trustedMap = _trustedProtocols[chainId];
    if (trustedMap != null) {
      for (final entry in trustedMap.entries) {
        if (entry.key.toLowerCase() == addr) return entry.value;
      }
    }

    // 4. Check main chain-specific mapped reputation
    final chainMap = _reputationMap[chainId];
    if (chainMap != null) {
      for (final entry in chainMap.entries) {
        if (entry.key.toLowerCase() == addr) return entry.value;
      }
    }

    return SpenderReputation.unknown;
  }

  /// Returns a clean label for a known spender, or null if unknown.
  String? getTrustedLabel(int chainId, String address) {
    final addr = address.toLowerCase();

    if (_isMultichain(chainId, addr)) return "Multichain (Anyswap)";

    // Only where the address is a known contract on this chain.
    if (getReputation(chainId, addr) == SpenderReputation.unknown) return null;
    for (final entry in _knownLabels.entries) {
      if (entry.key.toLowerCase() == addr) return entry.value;
    }
    return null;
  }
}
