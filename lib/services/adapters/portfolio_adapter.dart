import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/services/portfolio_service.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/models/portfolio_summary.dart';
import 'package:ibiti_guardian/models/unified_portfolio.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/config/solana_token_registry.dart';
import 'package:ibiti_guardian/services/execution/clients/solana_rpc_client.dart';
import 'package:ibiti_guardian/services/execution/clients/tron_rpc_client.dart';

/// IBITI token contract on BNB Smart Chain (BEP-20).
const String _ibitiContract = '0x47F2FFCb164b2EeCCfb7eC436Dfb3637a457B9bb';
const int _ibitiDecimals = 8;

// ── Multi-chain known token contracts ────────────────────────────────────────
// Key = chainKey, value = list of (contract, symbol, name, decimals, price).
// These are injected when Moralis doesn't index them.
class _KnownToken {
  final String contract;
  final String symbol;
  final String name;
  final int decimals;
  final double fallbackPrice;
  final String? logoUrl;
  const _KnownToken(
      this.contract, this.symbol, this.name, this.decimals, this.fallbackPrice,
      {this.logoUrl});
}

const _ibitiLogo =
    'https://raw.githubusercontent.com/nicksigma/ibiti-assets/main/ibiti_logo.png';
const _usdtLogo =
    'https://assets.coingecko.com/coins/images/325/small/Tether.png';
const _usdcLogo =
    'https://assets.coingecko.com/coins/images/6319/small/usdc.png';

const Map<String, List<_KnownToken>> _knownTokens = {
  'bsc': [
    _KnownToken('0x47F2FFCb164b2EeCCfb7eC436Dfb3637a457B9bb', 'IBITI',
        'IBITIcoin', 8, 0,
        logoUrl: _ibitiLogo),
    _KnownToken('0x55d398326f99059fF775485246999027B3197955', 'USDT',
        'Tether USD', 18, 1.0,
        logoUrl: _usdtLogo),
  ],
  'eth': [
    _KnownToken('0xdAC17F958D2ee523a2206206994597C13D831ec7', 'USDT',
        'Tether USD', 6, 1.0,
        logoUrl: _usdtLogo),
    _KnownToken('0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', 'USDC',
        'USD Coin', 6, 1.0,
        logoUrl: _usdcLogo),
  ],
  'polygon': [
    _KnownToken('0xc2132D05D31c914a87C6611C10748AEb04B58e8F', 'USDT',
        'Tether USD', 6, 1.0,
        logoUrl: _usdtLogo),
    _KnownToken('0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359', 'USDC',
        'USD Coin', 6, 1.0,
        logoUrl: _usdcLogo),
  ],
  'arbitrum': [
    _KnownToken('0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9', 'USDT',
        'Tether USD', 6, 1.0,
        logoUrl: _usdtLogo),
    _KnownToken('0xaf88d065e77c8cC2239327C5EDb3A432268e5831', 'USDC',
        'USD Coin', 6, 1.0,
        logoUrl: _usdcLogo),
  ],
  'base': [
    _KnownToken('0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', 'USDC',
        'USD Coin', 6, 1.0,
        logoUrl: _usdcLogo),
  ],
};

class PortfolioAdapter extends ChangeNotifier {
  static final PortfolioAdapter instance = PortfolioAdapter._internal();
  factory PortfolioAdapter() => instance;
  PortfolioAdapter._internal();

  static const _log = GuardianLogger('PortfolioAdapter');

  final PortfolioService _portfolioService = PortfolioService();

  Future<List<WalletAsset>> fetchAssets(
    String address,
    String chainKey, {
    bool includeDiscovery = false,
  }) async {
    final chain = PrivyChainRegistry.getChain(chainKey);

    // ── Tron: TRX native + TRC20 USDT ───────────────────────────────────────
    if (chainKey == 'tron') {
      return _fetchTronPortfolio(address, chain);
    }

    // ── Solana: SOL native + SPL tokens via RPC ─────────────────────────────
    if (chainKey == 'solana') {
      return _fetchSolanaPortfolio(address, chain);
    }

    final chainSlug = chain.moralisSlug;

    // ═══════════════════════════════════════════════════════════════════════
    // RPC-FIRST PORTFOLIO: all core balances via free, unlimited RPC calls.
    // Moralis is only used as optional enrichment for token discovery.
    // ═══════════════════════════════════════════════════════════════════════

    List<WalletAsset> assets = [];
    final rpcUrl = chain.rpcUrl;

    if (rpcUrl == null || rpcUrl.isEmpty) {
      _log.w('No RPC URL for chain $chainKey — skipping');
      return [];
    }

    // ── 1. Native balance via RPC (free, unlimited) ──────────────────────
    // Price is set to 0 here — WalletPriceEnricher sets real price later.
    try {
      final nativeBal = await _fetchNativeBalanceViaRpc(address, rpcUrl);
      final nativeLogo = _nativeLogos[chain.nativeSymbol ?? 'ETH'];

      assets.add(WalletAsset.native(
        name: chain.displayName,
        symbol: chain.nativeSymbol ?? 'ETH',
        balance: nativeBal,
        logoUrl: nativeLogo,
        priceUsd: 0,
        decimals: 18,
        chainId: chain.evmChainId ?? 0,
        chainKey: chainKey,
      ));
      _log.d('[RPC] $chainKey native: ${chain.nativeSymbol} = $nativeBal');
    } catch (e) {
      _log.e('[RPC] native balance failed on $chainKey', e);
    }

    // ── 2. Known tokens via RPC balanceOf (free, unlimited) ──────────────
    final knownForChain = _knownTokens[chainKey];
    if (knownForChain != null) {
      for (final known in knownForChain) {
        try {
          final bal = await _fetchErc20Balance(
              address, known.contract, rpcUrl, known.decimals);
          if (bal > 0) {
            assets.add(WalletAsset(
              name: known.name,
              symbol: known.symbol,
              address: known.contract,
              balance: bal,
              logoUrl: known.logoUrl,
              priceUsd: known.fallbackPrice,
              valueUsd: bal * known.fallbackPrice,
              decimals: known.decimals,
              chainId: chain.evmChainId ?? 0,
              chainKey: chainKey,
            ));
            _log.d('[RPC] $chainKey ${known.symbol}: $bal');
          }
        } catch (e) {
          _log.w('[RPC] ${known.symbol} balanceOf failed on $chainKey', e);
        }
      }
    }

    // ── 3. Moralis enrichment — ONLY when explicitly requested ────────────
    // Default wallet refresh = 0 Moralis calls.
    // Discovery mode = finds unknown tokens (airdrops, new receives).
    if (includeDiscovery && chainSlug != null) {
      try {
        final moralisAssets = await _portfolioService.getPortfolio(address,
            chainOverride: chainSlug);

        // Identity by contract address ONLY (never symbol — prevents fakes)
        final knownAddresses = assets
            .where((a) => !a.isNative)
            .map((a) => a.address.toLowerCase())
            .toSet();

        for (final ma in moralisAssets) {
          if (ma.isNative) {
            // Moralis native may have better price — update ours
            final idx = assets.indexWhere((a) => a.isNative);
            if (idx >= 0 && ma.priceUsd > 0) {
              assets[idx] = WalletAsset.native(
                name: assets[idx].name,
                symbol: assets[idx].symbol,
                balance: assets[idx].balance,
                logoUrl: ma.logoUrl ?? assets[idx].logoUrl,
                priceUsd: ma.priceUsd,
                decimals: assets[idx].decimals,
                chainId: assets[idx].chainId,
                chainKey: chainKey,
              );
            }
            continue;
          }

          final addr = ma.address.toLowerCase();

          if (knownAddresses.contains(addr)) {
            // Already have — update price/logo if Moralis has better
            final idx = assets.indexWhere(
                (a) => !a.isNative && a.address.toLowerCase() == addr);
            if (idx >= 0) {
              final existing = assets[idx];
              assets[idx] = WalletAsset(
                name: existing.name,
                symbol: existing.symbol,
                address: existing.address,
                balance: existing.balance,
                logoUrl: ma.logoUrl ?? existing.logoUrl,
                priceUsd: ma.priceUsd > 0 ? ma.priceUsd : existing.priceUsd,
                valueUsd: ma.priceUsd > 0
                    ? existing.balance * ma.priceUsd
                    : existing.valueUsd,
                decimals: existing.decimals,
                isNative: existing.isNative,
                chainId: existing.chainId,
                chainKey: chainKey,
              );
            }
            continue;
          }

          // NEW token discovered by Moralis — add it
          if (ma.balance > 0) {
            assets.add(WalletAsset(
              name: ma.name,
              symbol: ma.symbol,
              address: ma.address,
              balance: ma.balance,
              logoUrl: ma.logoUrl,
              priceUsd: ma.priceUsd,
              valueUsd: ma.valueUsd,
              decimals: ma.decimals,
              chainId: ma.chainId,
              chainKey: chainKey,
            ));
            knownAddresses.add(addr);
            _log.d('[Moralis] discovered: ${ma.symbol} on $chainKey');
          }
        }
        _log.d('[Moralis] discovery OK for $chainKey');
      } catch (e) {
        _log.w('[Moralis] discovery failed for $chainKey — RPC data only', e);
      }
    } else {
      _log.d(
          '[Portfolio] RPC core only chain=$chainKey (discovery=${includeDiscovery ? 'on' : 'off'})');
    }

    // Sort: native first, then by value
    assets.sort((a, b) {
      if (a.isNative && !b.isNative) return -1;
      if (!a.isNative && b.isNative) return 1;
      return b.valueUsd.compareTo(a.valueUsd);
    });

    return assets;
  }

  // ── Unified Multi-Chain Portfolio ─────────────────────────────────────────

  /// Fetches portfolio from ALL EVM chains in parallel.
  ///
  /// Returns results incrementally — caller gets data as soon as each chain
  /// responds. Failed chains are recorded but don't block others.
  ///
  /// Uses [onChainReady] callback for incremental UI updates.
  Future<UnifiedPortfolioSummary> fetchUnifiedEvmSummary(
    String evmAddress, {
    void Function(String chainKey, PortfolioSummary summary)? onChainReady,
  }) async {
    final evmChains =
        PrivyChainRegistry.fullSupportChains.where((c) => c.isEvm).toList();

    final perChain = <String, PortfolioSummary>{};
    final failedChains = <String, String>{};

    // Fire all chain fetches in parallel
    final futures = evmChains.map((chain) async {
      try {
        final summary = await fetchSummary(evmAddress, chain.chainKey);
        perChain[chain.chainKey] = summary;
        onChainReady?.call(chain.chainKey, summary);
      } catch (e) {
        failedChains[chain.chainKey] = e.toString();
        _log.w('Unified portfolio: ${chain.chainKey} failed: $e');
      }
    });

    await Future.wait(futures);

    // Merge all assets, sorted by USD value descending
    final allAssets = <WalletAsset>[];
    for (final summary in perChain.values) {
      allAssets.addAll(summary.allAssets);
    }
    allAssets.sort((a, b) => b.valueUsd.compareTo(a.valueUsd));

    final totalUsd =
        perChain.values.fold<double>(0, (sum, s) => sum + s.totalBalanceUsd);

    return UnifiedPortfolioSummary(
      totalUsd: totalUsd,
      perChain: perChain,
      allAssets: allAssets,
      failedChains: failedChains,
      fetchedAt: DateTime.now(),
    );
  }

  Future<PortfolioSummary> fetchSummary(
    String address,
    String chainKey, {
    bool includeDiscovery = false,
  }) async {
    if (address.isEmpty) return PortfolioSummary.empty();

    final chain = PrivyChainRegistry.getChain(chainKey);
    final assets = await fetchAssets(address, chainKey,
        includeDiscovery: includeDiscovery);
    final totalBalance =
        assets.fold<double>(0, (sum, asset) => sum + asset.valueUsd);

    return PortfolioSummary(
      totalBalanceUsd: totalBalance,
      assetsCount: assets.length,
      allAssets: assets, // full list — no cap
      address: address,
      networkName: chain.displayName,
      chainKey: chainKey,
      isSupported: chain.moralisSlug != null ||
          chainKey == 'tron' ||
          chainKey == 'solana',
    );
  }

  // ── Solana portfolio: SOL native + SPL tokens ───────────────────────────────

  Future<List<WalletAsset>> _fetchSolanaPortfolio(
      String address, PrivyChain chain) async {
    final rpcUrl = chain.rpcUrl ?? 'https://api.mainnet-beta.solana.com';
    final client = SolanaHttpRpcClient(rpcUrl: rpcUrl);
    final assets = <WalletAsset>[];

    // Price is set to 0 here — WalletPriceEnricher sets real price later.

    // 1. SOL native balance
    try {
      final lamports = await client.getBalanceLamports(address);
      final solBalance = lamports.toDouble() / 1e9;
      assets.add(WalletAsset.native(
        name: 'Solana',
        symbol: 'SOL',
        balance: solBalance,
        logoUrl: 'https://cryptologos.cc/logos/solana-sol-logo.png',
        priceUsd: 0,
        decimals: 9,
        chainId: 0,
        chainKey: 'solana',
      ));
    } catch (e) {
      _log.e('Solana native balance fetch failed', e);
    }

    // 2. SPL token accounts
    try {
      final splAccounts = await client.getTokenAccountsByOwner(address);
      for (final spl in splAccounts) {
        final meta = SolanaTokenRegistry.lookup(spl.mint);
        final symbol = meta?.symbol ?? SolanaTokenRegistry.symbolFor(spl.mint);
        final name = meta?.name ?? 'SPL Token';
        final price = meta?.fallbackPrice ?? 0.0;

        assets.add(WalletAsset(
          name: name,
          symbol: symbol,
          address: spl.mint,
          balance: spl.balance,
          logoUrl: meta?.logoUrl,
          priceUsd: price,
          valueUsd: spl.balance * price,
          decimals: spl.decimals,
          chainId: 0,
          chainKey: 'solana',
        ));
      }
    } catch (e) {
      _log.e('SPL token fetch failed', e);
    }

    // Sort by value descending
    assets.sort((a, b) => b.valueUsd.compareTo(a.valueUsd));
    return assets;
  }

  // ── Native token logos (hardcoded, no API needed) ─────────────────────────
  static const _nativeLogos = <String, String>{
    'BNB': 'https://cryptologos.cc/logos/bnb-bnb-logo.png',
    'ETH': 'https://cryptologos.cc/logos/ethereum-eth-logo.png',
    'MATIC': 'https://cryptologos.cc/logos/polygon-matic-logo.png',
    'POL': 'https://cryptologos.cc/logos/polygon-matic-logo.png',
    'AVAX': 'https://cryptologos.cc/logos/avalanche-avax-logo.png',
  };

  // All CoinGecko price calls removed — WalletPriceEnricher is the single
  // price source. See lib/services/wallet/wallet_price_enricher.dart.

  // ── Tron portfolio: TRX native + TRC20 USDT ─────────────────────────────────

  Future<List<WalletAsset>> _fetchTronPortfolio(
      String address, PrivyChain chain) async {
    final rpcUrl = chain.rpcUrl ?? 'https://api.trongrid.io';
    final client = TronHttpRpcClient(baseUrl: rpcUrl);
    final assets = <WalletAsset>[];

    // Price is set to 0 here — WalletPriceEnricher sets real price later.

    // 1. TRX native balance
    try {
      final balanceSun = await client.getBalanceSun(address);
      final trxBalance = balanceSun.toDouble() / 1e6;
      assets.add(WalletAsset.native(
        name: 'Tron',
        symbol: 'TRX',
        balance: trxBalance,
        logoUrl: 'https://cryptologos.cc/logos/tron-trx-logo.png',
        priceUsd: 0,
        decimals: 6,
        chainId: 0,
        chainKey: 'tron',
      ));
    } catch (e) {
      _log.e('Tron native balance fetch failed', e);
    }

    // 2. TRC20 USDT balance
    try {
      final usdtRaw = await client.getTrc20Balance(
        address,
        TronHttpRpcClient.usdtContract,
      );
      if (usdtRaw > BigInt.zero) {
        final usdtBalance = usdtRaw.toDouble() / 1e6;
        assets.add(WalletAsset(
          name: 'Tether USD',
          symbol: 'USDT',
          address: TronHttpRpcClient.usdtContract,
          balance: usdtBalance,
          logoUrl: 'https://cryptologos.cc/logos/tether-usdt-logo.png',
          priceUsd: 1.0,
          valueUsd: usdtBalance * 1.0,
          decimals: TronHttpRpcClient.usdtDecimals,
          chainId: 0,
          chainKey: 'tron',
        ));
      }
    } catch (e) {
      _log.e('TRC20 USDT balance fetch failed', e);
    }

    // Sort by value descending
    assets.sort((a, b) => b.valueUsd.compareTo(a.valueUsd));
    return assets;
  }

  // _fetchTrxPrice removed — WalletPriceEnricher handles TRX pricing.

  /// Fetches an ERC-20 token balance via direct JSON-RPC `eth_call`.
  /// Returns human-readable balance (divided by 10^[decimals]).
  Future<double> _fetchErc20Balance(
      String wallet, String tokenContract, String rpcUrl, int decimals) async {
    // balanceOf(address) selector = 0x70a08231
    final paddedAddress = wallet.replaceFirst('0x', '').padLeft(64, '0');
    final data = '0x70a08231$paddedAddress';

    final response = await http
        .post(
          Uri.parse(rpcUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'jsonrpc': '2.0',
            'method': 'eth_call',
            'params': [
              {'to': tokenContract, 'data': data},
              'latest',
            ],
            'id': 1,
          }),
        )
        .timeout(const Duration(seconds: 8));

    if (response.statusCode != 200) return 0;

    final json = jsonDecode(response.body);
    final result = json['result'] as String?;
    if (result == null || result == '0x' || result == '0x0') return 0;

    final rawBigInt = BigInt.parse(result.replaceFirst('0x', ''), radix: 16);
    final divisor = BigInt.from(10).pow(decimals);
    // Use integer division + modulo to avoid double precision loss on large balances
    final wholePart = rawBigInt ~/ divisor;
    final fracPart = (rawBigInt % divisor).toString().padLeft(decimals, '0');
    final fracDigits = decimals >= 8 ? 8 : decimals;
    return double.parse('$wholePart.${fracPart.substring(0, fracDigits)}');
  }

  /// Fetches native token balance (ETH/BNB/MATIC) via JSON-RPC eth_getBalance.
  /// Returns human-readable balance (divided by 10^18).
  Future<double> _fetchNativeBalanceViaRpc(String wallet, String rpcUrl) async {
    final response = await http
        .post(
          Uri.parse(rpcUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'jsonrpc': '2.0',
            'method': 'eth_getBalance',
            'params': [wallet, 'latest'],
            'id': 1,
          }),
        )
        .timeout(const Duration(seconds: 8));

    if (response.statusCode != 200) return 0;

    final json = jsonDecode(response.body);
    final result = json['result'] as String?;
    if (result == null || result == '0x' || result == '0x0') return 0;

    final rawBigInt = BigInt.parse(result.replaceFirst('0x', ''), radix: 16);
    const decimals = 18;
    final divisor = BigInt.from(10).pow(decimals);
    final wholePart = rawBigInt ~/ divisor;
    final fracPart = (rawBigInt % divisor).toString().padLeft(decimals, '0');
    return double.parse('$wholePart.${fracPart.substring(0, 8)}');
  }
}
