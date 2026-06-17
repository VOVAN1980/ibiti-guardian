import 'dart:convert';
import 'package:http/http.dart' as http;

import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/market/token_registry_service.dart';
import 'package:ibiti_guardian/services/moralis/moralis_config_service.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';

// ─── Token Discovery Result ─────────────────────────────────────────────────────

class TokenDiscoveryResult {
  final String symbol;
  final String name;
  final String? contractAddress;
  final int decimals;
  final String chainKey;
  final String? logoUrl;
  final double? priceUsd;
  final String
      source; // 'holdings', 'registry', 'moralis', 'onchain', 'search', 'coingecko'
  final bool verified;
  final bool hasContract;
  final String? reason;

  const TokenDiscoveryResult({
    required this.symbol,
    required this.name,
    this.contractAddress,
    this.decimals = 18,
    required this.chainKey,
    this.logoUrl,
    this.priceUsd,
    required this.source,
    required this.verified,
    required this.hasContract,
    this.reason,
  });
}

// ─── Token Discovery Service ─────────────────────────────────────────────────────
///
/// Multi-source token resolution for swap UI and voice orchestration.
///
/// Resolution order:
///   1. Wallet holdings (Moralis/VaultPortfolioListener) — address, balance, price
///   2. Built-in registry (TokenRegistryService) — verified contract addresses
///   3. Moralis token metadata by contract address — symbol/name/decimals/price
///   4. On-chain ERC-20 lookup (raw eth_call) — symbol/name/decimals fallback
///   5. CoinGecko cached markets — price/image, informational only (NO contract)
///   6. CoinGecko /search — name/rank only, informational only
///
/// Sources 1-4 produce [hasContract=true] results → ready for quote.
/// Sources 5-6 produce [hasContract=false] → UI/voice must ask for address.
class TokenDiscoveryService {
  TokenDiscoveryService._();
  static final TokenDiscoveryService instance = TokenDiscoveryService._();

  static const _moralisBaseUrl = 'https://deep-index.moralis.io/api/v2.2';
  static const _cgBaseUrl = 'https://api.coingecko.com/api/v3';

  // Standard ERC-20 function selectors (keccak256 first 4 bytes)
  static const _symbolSelector = '0x95d89b41';
  static const _nameSelector = '0x06fdde03';
  static const _decimalsSelector = '0x313ce567';

  // ── Primary: resolve by symbol/name ──────────────────────────────────────

  /// Resolve a token by symbol or name on the given chain.
  /// Returns multiple candidates if found in several sources.
  Future<List<TokenDiscoveryResult>> resolve(
    String query, {
    String? chainKey,
  }) async {
    final chain = chainKey ?? IBITIVaultService.instance.chainKey;
    final q = query.trim();
    if (q.isEmpty) return const [];

    final qUpper = q.toUpperCase();
    final qLower = q.toLowerCase();
    final results = <String, TokenDiscoveryResult>{}; // keyed by symbol+source

    // 1. Wallet holdings (Moralis-powered via VaultPortfolioListener)
    _searchHoldings(qUpper, qLower, chain, results);

    // 2. Built-in verified registry
    _searchRegistry(qUpper, chain, results);

    // 3. CoinGecko cached markets (informational only)
    _searchCachedMarkets(qUpper, qLower, results, chain);

    // 4. CoinGecko /search API (network) — only if < 2 results
    if (results.length < 2 && q.length >= 2) {
      await _searchCoinGeckoRemote(qLower, results, chain);
    }

    // Sort: hasContract first, then by source priority
    final sorted = results.values.toList()
      ..sort((a, b) {
        if (a.hasContract != b.hasContract) {
          return a.hasContract ? -1 : 1;
        }
        return _sourcePriority(a.source).compareTo(_sourcePriority(b.source));
      });

    return sorted;
  }

  // ── Resolve by on-chain address ──────────────────────────────────────────

  /// Look up an ERC-20 token by contract address.
  /// Tries Moralis metadata first, then raw eth_call as fallback.
  Future<TokenDiscoveryResult?> resolveByAddress(
    String address, {
    String? chainKey,
  }) async {
    final chain = chainKey ?? IBITIVaultService.instance.chainKey;

    // 1. Try Moralis token metadata (has price, logo, verified info)
    final moralisResult = await _resolveViaMoralis(address, chain);
    if (moralisResult != null) return moralisResult;

    // 2. Fallback: raw ERC-20 eth_call
    return _resolveViaEthCall(address, chain);
  }

  // ── Popular tokens for picker tab ────────────────────────────────────────

  /// Returns verified popular tokens for the given chain from the built-in
  /// registry, enriched with cached price data where available.
  List<TokenDiscoveryResult> getPopularTokens(String chainKey) {
    final symbols = TokenRegistryService.instance.getSupportedSymbols(chainKey);
    final cachedMarkets = MarketDataService.instance.cachedMarkets;

    return symbols.map((symbol) {
      final resolution = TokenRegistryService.instance.resolve(
        symbol: symbol,
        chainKey: chainKey,
      );

      // Registry may provide a display name for pegged/wrapped assets
      final registryDisplayName =
          TokenRegistryService.instance.getDisplayName(symbol, chainKey);

      double? price;
      String? logo;
      String? marketName;
      for (final m in cachedMarkets) {
        if (m.symbol.toUpperCase() == symbol) {
          price = m.price;
          logo = m.imageUrl;
          marketName = m.name;
          break;
        }
      }

      // Priority: registry displayName > market name > symbol
      final name = registryDisplayName ?? marketName ?? symbol;

      return TokenDiscoveryResult(
        symbol: symbol,
        name: name,
        contractAddress: resolution.found ? resolution.address : null,
        decimals: resolution.decimals,
        chainKey: chainKey,
        logoUrl: logo,
        priceUsd: price,
        source: 'registry',
        verified: true,
        hasContract: resolution.found,
      );
    }).toList();
  }

  // ── Moralis token metadata ──────────────────────────────────────────────

  /// Fetch token metadata + price from Moralis by contract address.
  /// Returns null if Moralis key is missing or request fails.
  Future<TokenDiscoveryResult?> _resolveViaMoralis(
    String address,
    String chainKey,
  ) async {
    final apiKey = MoralisConfigService.key;
    if (apiKey.isEmpty) return null;

    final chainInfo = PrivyChainRegistry.getChain(chainKey);
    final moralisChain = chainInfo.moralisSlug;
    if (moralisChain == null) return null;

    try {
      // Moralis /erc20/metadata endpoint
      final metaUrl = Uri.parse(
        '$_moralisBaseUrl/erc20/metadata?chain=$moralisChain&addresses=$address',
      );
      final metaResp = await http.get(
        metaUrl,
        headers: {'X-API-Key': apiKey},
      ).timeout(const Duration(seconds: 8));

      if (metaResp.statusCode != 200) return null;

      final metaData = jsonDecode(metaResp.body);
      if (metaData is! List || metaData.isEmpty) return null;
      final token = metaData[0] as Map<String, dynamic>;

      final symbol = token['symbol']?.toString() ?? '';
      final name = token['name']?.toString() ?? symbol;
      final decimals =
          int.tryParse(token['decimals']?.toString() ?? '18') ?? 18;
      final logo = token['logo']?.toString();

      if (symbol.isEmpty) return null;

      // Try to get price via Moralis /erc20/{address}/price
      double? priceUsd;
      try {
        final priceUrl = Uri.parse(
          '$_moralisBaseUrl/erc20/$address/price?chain=$moralisChain',
        );
        final priceResp = await http.get(
          priceUrl,
          headers: {'X-API-Key': apiKey},
        ).timeout(const Duration(seconds: 6));
        if (priceResp.statusCode == 200) {
          final priceData = jsonDecode(priceResp.body);
          priceUsd = double.tryParse(priceData['usdPrice']?.toString() ?? '');
        }
      } catch (_) {
        // Price not critical — proceed without it
      }

      return TokenDiscoveryResult(
        symbol: symbol.toUpperCase(),
        name: name,
        contractAddress: address,
        decimals: decimals,
        chainKey: chainKey,
        logoUrl: logo,
        priceUsd: priceUsd,
        source: 'moralis',
        verified: true,
        hasContract: true,
      );
    } catch (e) {
      // ignore: avoid_print
      return null;
    }
  }

  // ── On-chain ERC-20 fallback ────────────────────────────────────────────

  Future<TokenDiscoveryResult?> _resolveViaEthCall(
    String address,
    String chainKey,
  ) async {
    final chainInfo = PrivyChainRegistry.getChain(chainKey);
    final rpcUrl = chainInfo.rpcUrl;
    if (rpcUrl == null || rpcUrl.isEmpty) return null;

    try {
      final symbol = await _ethCallString(rpcUrl, address, _symbolSelector);
      final name = await _ethCallString(rpcUrl, address, _nameSelector);
      final decimals =
          await _ethCallUint(rpcUrl, address, _decimalsSelector) ?? 18;

      if (symbol == null || symbol.isEmpty) return null;

      return TokenDiscoveryResult(
        symbol: symbol.toUpperCase(),
        name: name ?? symbol,
        contractAddress: address,
        decimals: decimals,
        chainKey: chainKey,
        source: 'onchain',
        verified: false,
        hasContract: true,
      );
    } catch (e) {
      // ignore: avoid_print
      return null;
    }
  }

  // ── Private source helpers ──────────────────────────────────────────────

  void _searchHoldings(
    String qUpper,
    String qLower,
    String chainKey,
    Map<String, TokenDiscoveryResult> results,
  ) {
    final portfolio = VaultPortfolioListener.instance.summary;
    if (portfolio == null) return;
    final chainInfo = PrivyChainRegistry.getChain(chainKey);

    for (final asset in portfolio.allAssets) {
      if (chainInfo.evmChainId != null &&
          asset.chainId != chainInfo.evmChainId) {
        continue;
      }
      if (asset.symbol.toUpperCase() == qUpper ||
          asset.name.toLowerCase().contains(qLower)) {
        final key = '${asset.symbol.toUpperCase()}:holdings';
        results.putIfAbsent(
          key,
          () => TokenDiscoveryResult(
            symbol: asset.symbol.toUpperCase(),
            name: asset.name,
            contractAddress:
                asset.address.isNotEmpty && asset.address != 'native'
                    ? asset.address
                    : null,
            decimals: asset.decimals,
            chainKey: chainKey,
            logoUrl: asset.logoUrl,
            priceUsd: asset.priceUsd,
            source: 'holdings',
            verified: true,
            hasContract: asset.address.isNotEmpty && asset.address != 'native',
          ),
        );
      }
    }
  }

  void _searchRegistry(
    String qUpper,
    String chainKey,
    Map<String, TokenDiscoveryResult> results,
  ) {
    final resolution = TokenRegistryService.instance.resolve(
      symbol: qUpper,
      chainKey: chainKey,
    );
    if (!resolution.found) return;

    final key = '$qUpper:registry';
    results.putIfAbsent(
      key,
      () {
        String name = qUpper;
        double? price;
        String? logo;
        for (final m in MarketDataService.instance.cachedMarkets) {
          if (m.symbol.toUpperCase() == qUpper) {
            name = m.name;
            price = m.price;
            logo = m.imageUrl;
            break;
          }
        }
        return TokenDiscoveryResult(
          symbol: qUpper,
          name: name,
          contractAddress: resolution.address,
          decimals: resolution.decimals,
          chainKey: chainKey,
          logoUrl: logo,
          priceUsd: price,
          source: 'registry',
          verified: true,
          hasContract: true,
        );
      },
    );
  }

  void _searchCachedMarkets(
    String qUpper,
    String qLower,
    Map<String, TokenDiscoveryResult> results,
    String chainKey,
  ) {
    for (final m in MarketDataService.instance.cachedMarkets) {
      if (m.symbol.toUpperCase() == qUpper ||
          m.name.toLowerCase().contains(qLower)) {
        final sym = m.symbol.toUpperCase();
        // Skip if we already have a richer result for this symbol
        if (results.keys.any((k) => k.startsWith('$sym:'))) continue;
        final key = '$sym:search';
        results.putIfAbsent(
          key,
          () => TokenDiscoveryResult(
            symbol: sym,
            name: m.name,
            logoUrl: m.imageUrl,
            priceUsd: m.price,
            chainKey: chainKey,
            source: 'search',
            verified: false,
            hasContract: false,
            reason: 'Found via market data but no contract address known.',
          ),
        );
      }
    }
  }

  Future<void> _searchCoinGeckoRemote(
    String qLower,
    Map<String, TokenDiscoveryResult> results,
    String chainKey,
  ) async {
    try {
      final uri = Uri.parse('$_cgBaseUrl/search').replace(
        queryParameters: {'query': qLower},
      );
      final response = await http.get(uri, headers: const {
        'accept': 'application/json'
      }).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return;

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) return;
      final coins = data['coins'];
      if (coins is! List) return;

      for (final coin in coins.take(10)) {
        if (coin is! Map<String, dynamic>) continue;
        final sym = (coin['symbol']?.toString() ?? '').toUpperCase();
        if (sym.isEmpty) continue;
        if (results.keys.any((k) => k.startsWith('$sym:'))) continue;
        final key = '$sym:coingecko';
        results.putIfAbsent(
          key,
          () => TokenDiscoveryResult(
            symbol: sym,
            name: coin['name']?.toString() ?? sym,
            logoUrl: coin['large']?.toString() ?? coin['thumb']?.toString(),
            chainKey: chainKey,
            source: 'coingecko',
            verified: false,
            hasContract: false,
            reason:
                'Found via CoinGecko search. Contract address not available.',
          ),
        );
      }
    } catch (_) {
      // Network error — return what we have.
    }
  }

  int _sourcePriority(String source) {
    switch (source) {
      case 'holdings':
        return 0;
      case 'registry':
        return 1;
      case 'moralis':
        return 2;
      case 'onchain':
        return 3;
      case 'search':
        return 4;
      case 'coingecko':
        return 5;
      default:
        return 6;
    }
  }

  // ── Raw ERC-20 eth_call helpers (with bytes32 fallback) ────────────────

  /// Decode ABI string return. Handles both dynamic string and bytes32.
  Future<String?> _ethCallString(
    String rpcUrl,
    String contractAddr,
    String selector,
  ) async {
    final raw = await _ethCallRaw(rpcUrl, contractAddr, selector);
    if (raw == null || raw.length < 66) return null;

    final hex = raw.substring(2); // strip 0x

    // ── Try dynamic string first (offset + length + data) ────────
    if (hex.length >= 128) {
      try {
        final lenHex = hex.substring(64, 128);
        final len = int.parse(lenHex, radix: 16);
        if (len > 0 && len <= 256 && hex.length >= 128 + len * 2) {
          final dataHex = hex.substring(128, 128 + len * 2);
          final bytes = <int>[];
          for (var i = 0; i < dataHex.length; i += 2) {
            bytes.add(int.parse(dataHex.substring(i, i + 2), radix: 16));
          }
          final decoded = String.fromCharCodes(bytes).trim();
          if (decoded.isNotEmpty) return decoded;
        }
      } catch (_) {
        // Fall through to bytes32
      }
    }

    // ── Fallback: bytes32 (left-padded, null-terminated) ─────────
    // Some tokens (e.g. MKR, SAI) return symbol/name as bytes32
    if (hex.length >= 64) {
      try {
        final bytes32Hex = hex.substring(0, 64);
        final bytes = <int>[];
        for (var i = 0; i < bytes32Hex.length; i += 2) {
          final byte = int.parse(bytes32Hex.substring(i, i + 2), radix: 16);
          if (byte == 0) break; // null terminator
          bytes.add(byte);
        }
        final decoded = String.fromCharCodes(bytes).trim();
        if (decoded.isNotEmpty) return decoded;
      } catch (_) {
        // Give up
      }
    }

    return null;
  }

  Future<int?> _ethCallUint(
    String rpcUrl,
    String contractAddr,
    String selector,
  ) async {
    final raw = await _ethCallRaw(rpcUrl, contractAddr, selector);
    if (raw == null || raw.length < 66) return null; // 0x + 64 hex digits
    final hex = raw.substring(2);
    return int.tryParse(hex, radix: 16);
  }

  Future<String?> _ethCallRaw(
    String rpcUrl,
    String contractAddr,
    String data,
  ) async {
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'method': 'eth_call',
      'params': [
        {'to': contractAddr, 'data': data},
        'latest',
      ],
      'id': 1,
    });
    final response = await http
        .post(
          Uri.parse(rpcUrl),
          headers: {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return null;
    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) return null;
    final result = json['result']?.toString();
    if (result == null || result == '0x' || result.isEmpty) return null;
    return result;
  }
}
