import 'dart:convert';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ibiti_guardian/models/approval.dart';

class SpenderIntelligenceService {
  static final SpenderIntelligenceService instance =
      SpenderIntelligenceService._internal();
  SpenderIntelligenceService._internal();

  static const _log = GuardianLogger('SpenderIntel');

  static const String _manifestUrl =
      "https://raw.githubusercontent.com/VOVAN1980/IBITI Guardian-intel/main/spenders.json";
  static const String _cacheKey = "spender_manifest_cache";

  final Map<int, Map<String, SpenderReputation>> _remoteMap = {};
  final Map<String, String> _remoteLabels = {};

  /// Local reputation map categories (Hardcoded Fallbacks)
  static final Map<int, Map<String, SpenderReputation>> _reputationMap = {
    // BNB Smart Chain (56)
    56: {
      "0x10ED43C718714eb63d5aA57B78B54704E256024E":
          SpenderReputation.dex, // PancakeSwap V2: Router
      "0x13fQDD19701a4702e06917Da301948747Aa02B07":
          SpenderReputation.dex, // PancakeSwap V3: Router
      "0x1111111254EEB25477B68fb85Ed929f73A960582":
          SpenderReputation.dex, // 1inch v5: Aggregator
      "0x5DC88D67e9d8dF61846f48348CCf0f08918A0194":
          SpenderReputation.trusted, // MetaMask: Swap Router
      "0x3a6d448421162297941677d5fefda5F08e6c1C0E":
          SpenderReputation.trusted, // PancakeSwap: Staking
      "0xCe710653629DE3484f4E630324707198dD9e7B81":
          SpenderReputation.bridge, // MultiChain Bridge
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
      "0x88ad09518695c6c3712ba10a218bb27091903735":
          SpenderReputation.bridge, // L1-L2 Bridge
    },
    // Polygon (137)
    137: {
      "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff":
          SpenderReputation.dex, // QuickSwap
      "0x1111111254EEB25477B68fb85Ed929f73A960582":
          SpenderReputation.dex, // 1inch
    },
    // Arbitrum (42161)
    42161: {
      "0xabbcad3f43456d773cd522024395513cd45ab0bc":
          SpenderReputation.dex, // GMX: Router
      "0x1111111254EEB25477B68fb85Ed929f73A960582":
          SpenderReputation.dex, // 1inch
    },
  };

  /// Explicit labels for known names
  static final Map<String, String> _knownLabels = {
    "0x10ED43C718714eb63d5aA57B78B54704E256024E": "PancakeSwap V2",
    "0x1111111254EEB25477B68fb85Ed929f73A960582": "1inch Aggregator",
    "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D": "Uniswap V2",
    "0xE592427A0AEce92De3Edee1F18E0157C05861564": "Uniswap V3",
    "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff": "QuickSwap",
    "0xabbcad3f43456d773cd522024395513cd45ab0bc": "GMX",
    "0xCe710653629DE3484f4E630324707198dD9e7B81": "MultiChain Bridge",
  };

  static final Map<String, SpenderReputation> _flaggedSpenders = {
    "0x000000000000000000000000000000000000dEaD": SpenderReputation.suspicious,
    "0x6666666666666666666666666666666666666666": SpenderReputation.flagged,
  };

  /// Restricted list of known safety/security tools
  static final Map<String, SpenderReputation> _safetyTools = {
    "0x000000000022d473030f116ddee9f6b43ac78ba3":
        SpenderReputation.safety, // Revoke.cash (Permit2)
    "0xfec0000000000b21fc106f368940801825fa777c":
        SpenderReputation.safety, // Revoke.cash (L2/Alt)
    "0xDc6513d408AdE4B57de6143a44576f763ec94194":
        SpenderReputation.safety, // Rabby: Swap Router
    "0x1c0029ea974f0090886cfa733dfcc81665a587ed":
        SpenderReputation.safety, // Gnosis Safe: Proxy Factory
    "0x2c00000000000000000000000000000000000000":
        SpenderReputation.safety, // OpenZeppelin Defender
  };

  /// Trusted protocols map for careful expansion (Base, Avalanche, Optimism)
  static final Map<int, Map<String, SpenderReputation>> _trustedProtocols = {
    // Base (8453)
    8453: {
      "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24":
          SpenderReputation.dex, // Base: Swap Router
      "0xAB799359679268688439EcbBa76A192A6B296816":
          SpenderReputation.dex, // Base: Aerodrome
    },
    // Avalanche (43114)
    43114: {
      "0x60ae61ccc09c05ca41c13bc20e9876ccf312891d":
          SpenderReputation.dex, // Trader Joe
      "0xE592427A0AEce92De3Edee1F18E0157C05861564":
          SpenderReputation.dex, // Uniswap V3
    },
    // Optimism (10)
    10: {
      "0xe592427a0aece92de3edee1f18e0157c05861564":
          SpenderReputation.dex, // Uniswap V3
      "0x1111111254EEB25477B68fb85Ed929f73A960582":
          SpenderReputation.dex, // 1inch
    },
  };

  Future<void> init() async {
    await _loadFromCache();
    // Non-blocking sync
    syncRemoteData().catchError((_) {});
  }

  Future<void> _loadFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_cacheKey);
      if (cached != null) {
        _parseManifest(cached);
      }
    } catch (e) {
      _log.e('Caught', e);
    }
  }

  Future<void> syncRemoteData() async {
    try {
      final res = await http.get(Uri.parse(_manifestUrl)).timeout(
            const Duration(seconds: 5),
          );
      if (res.statusCode == 200) {
        final body = res.body;
        _parseManifest(body);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_cacheKey, body);
      }
    } catch (_) {
      // Handle error silently as per requirements (graceful degradation)
    }
  }

  void _parseManifest(String jsonStr) {
    try {
      final data = jsonDecode(jsonStr);
      if (data["spenders"] is List) {
        for (final item in data["spenders"]) {
          final chainId = item["chainId"] as int?;
          final address = (item["address"] as String?)?.toLowerCase();
          final repStr = item["reputation"] as String?;
          final label = item["label"] as String?;

          if (chainId != null && address != null && repStr != null) {
            final rep = _parseReputation(repStr);
            _remoteMap.putIfAbsent(chainId, () => {})[address] = rep;
            if (label != null) _remoteLabels[address] = label;
          }
        }
      }
    } catch (e) {
      _log.e('Caught', e);
    }
  }

  SpenderReputation _parseReputation(String rep) {
    switch (rep.toLowerCase()) {
      case 'trusted':
        return SpenderReputation.trusted;
      case 'dex':
        return SpenderReputation.dex;
      case 'bridge':
        return SpenderReputation.bridge;
      case 'safety':
        return SpenderReputation.safety;
      case 'suspicious':
        return SpenderReputation.suspicious;
      case 'flagged':
        return SpenderReputation.flagged;
      default:
        return SpenderReputation.unknown;
    }
  }

  /// Returns the reputation of a spender for a specific chain.
  SpenderReputation getReputation(int chainId, String address) {
    final addr = address.toLowerCase();

    // 1. Check Remote/Dynamic Data first
    final remoteChainMap = _remoteMap[chainId];
    if (remoteChainMap != null && remoteChainMap.containsKey(addr)) {
      return remoteChainMap[addr]!;
    }

    // 2. Check flagged/suspicious first
    for (final entry in _flaggedSpenders.entries) {
      if (entry.key.toLowerCase() == addr) return entry.value;
    }

    // 2. Check restricted safety tools
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

    // 1. Check Remote Labels
    if (_remoteLabels.containsKey(addr)) return _remoteLabels[addr];

    // 2. Check fixed labels
    for (final entry in _knownLabels.entries) {
      if (entry.key.toLowerCase() == addr) return entry.value;
    }

    // Check Safety tool labels
    if (addr == "0x000000000022d473030f116ddee9f6b43ac78ba3" ||
        addr == "0xfec0000000000b21fc106f368940801825fa777c") {
      return "Revoke.cash";
    }
    if (addr == "0xdc6513d408ade4b57de6143a44576f763ec94194") return "Rabby";
    if (addr == "0x1c0029ea974f0090886cfa733dfcc81665a587ed") {
      return "Gnosis Safe";
    }
    if (addr == "0x2c00000000000000000000000000000000000000") {
      return "OZ Defender";
    }

    return null;
  }
}
