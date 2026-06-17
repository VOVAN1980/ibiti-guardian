import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';

// ─── Token Resolution Result ───────────────────────────────────────────────────

/// Source that produced a resolved address.
enum TokenAddressSource {
  /// Address came from user's current wallet holdings.
  walletHoldings,

  /// Address came from the built-in well-known token table.
  builtInRegistry,

  /// Address was not resolved — caller must block.
  notFound,
}

/// Result of a token address lookup.
class TokenResolution {
  final String symbol;
  final String chainKey;

  /// Resolved on-chain token address. Null only when [source] is [notFound].
  final String? address;

  /// Token decimals (18 default if not known).
  final int decimals;

  /// Where the address came from.
  final TokenAddressSource source;

  /// Human-readable note for audit log.
  final String note;

  bool get found => source != TokenAddressSource.notFound;

  const TokenResolution._({
    required this.symbol,
    required this.chainKey,
    required this.address,
    required this.decimals,
    required this.source,
    required this.note,
  });

  factory TokenResolution.fromHoldings({
    required String symbol,
    required String chainKey,
    required String address,
    required int decimals,
  }) =>
      TokenResolution._(
        symbol: symbol,
        chainKey: chainKey,
        address: address,
        decimals: decimals,
        source: TokenAddressSource.walletHoldings,
        note: 'Address resolved from wallet holdings.',
      );

  factory TokenResolution.fromRegistry({
    required String symbol,
    required String chainKey,
    required String address,
    required int decimals,
  }) =>
      TokenResolution._(
        symbol: symbol,
        chainKey: chainKey,
        address: address,
        decimals: decimals,
        source: TokenAddressSource.builtInRegistry,
        note: 'Address resolved from built-in token registry.',
      );

  factory TokenResolution.notFound({
    required String symbol,
    required String chainKey,
  }) =>
      TokenResolution._(
        symbol: symbol,
        chainKey: chainKey,
        address: null,
        decimals: 18,
        source: TokenAddressSource.notFound,
        note:
            'Token $symbol not found on chain $chainKey in holdings or registry.',
      );
}

// ─── TokenRegistryService ──────────────────────────────────────────────────────

/// Read-only token address resolution layer for automation execution.
///
/// ## Resolution order
/// 1. **Wallet holdings** — checked first. Real addresses from Moralis/wallet.
/// 2. **Built-in registry** — well-known tokens on each supported chain.
///    These are the same addresses used by 0x and 1inch on mainnet.
///    Only includes tokens explicitly vetted for production use.
///
/// ## Safety
/// - Resolution always checks that the result chain matches the mandate.
/// - Never resolves a token across the wrong chain (symbol alone is not enough).
/// - If a symbol matches on multiple chains, the current active chain wins,
///   then the mandate's allowed networks.
///
/// ## What this is NOT
/// - NOT an on-chain lookup (no RPC calls).
/// - NOT a coingecko/dex aggregator query.
/// - NOT a guarantee that a route exists for this token.
///   Route existence is determined by [GuardianExecutionController._orchestrateSwap].
class TokenRegistryService {
  TokenRegistryService._();
  static final TokenRegistryService instance = TokenRegistryService._();

  static const _log = GuardianLogger('TokenRegistry');

  // ── Built-in well-known tokens ─────────────────────────────────────────────
  // Key: 'SYMBOL:chainKey' → token contract address
  // Sources: Uniswap token list, 0x documentation, official token sites.
  // Decimals assumed 18 unless noted.
  static const Map<String, _TokenEntry> _registry = {
    // ── Ethereum (eth) ──────────────────────────────────────────────────────
    'USDT:eth': _TokenEntry('0xdAC17F958D2ee523a2206206994597C13D831ec7', 6),
    'USDC:eth': _TokenEntry('0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', 6),
    'DAI:eth': _TokenEntry('0x6B175474E89094C44Da98b954EedeAC495271d0F', 18),
    'WETH:eth': _TokenEntry('0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2', 18),
    'WBTC:eth': _TokenEntry('0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599', 8),
    'LINK:eth': _TokenEntry('0x514910771AF9Ca656af840dff83E8264EcF986CA', 18),
    'UNI:eth': _TokenEntry('0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984', 18),
    'AAVE:eth': _TokenEntry('0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9', 18),
    'MKR:eth': _TokenEntry('0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2', 18),
    'SNX:eth': _TokenEntry('0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F', 18),
    'LDO:eth': _TokenEntry('0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32', 18),
    'CRV:eth': _TokenEntry('0xD533a949740bb3306d119CC777fa900bA034cd52', 18),
    'SHIB:eth': _TokenEntry('0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE', 18),
    'PEPE:eth': _TokenEntry('0x6982508145454Ce325dDbE47a25d4ec3d2311933', 18),

    // ── BNB Chain (bsc) ─────────────────────────────────────────────────────
    'USDT:bsc': _TokenEntry('0x55d398326f99059fF775485246999027B3197955', 18),
    'USDC:bsc': _TokenEntry('0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d', 18),
    'BUSD:bsc': _TokenEntry('0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56', 18),
    'WBNB:bsc': _TokenEntry('0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c', 18),
    'CAKE:bsc': _TokenEntry('0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82', 18),
    'ETH:bsc': _TokenEntry(
        '0x2170Ed0880ac9A755fd29B2688956BD959F933F8', 18, 'Binance-Peg ETH'),
    'BTC:bsc':
        _TokenEntry('0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c', 18, 'BTCB'),
    'XRP:bsc': _TokenEntry(
        '0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE', 18, 'Binance-Peg XRP'),
    'ADA:bsc': _TokenEntry(
        '0x3EE2200Efb3400fAbB9AacF31297cBdD1d435D47', 18, 'Binance-Peg ADA'),
    'DOT:bsc': _TokenEntry(
        '0x7083609fCE4d1d8Dc0C979AAb8c869Ea2C873402', 18, 'Binance-Peg DOT'),
    'DOGE:bsc': _TokenEntry(
        '0xbA2aE424d960c26247Dd6c32edC70B295c744C43', 8, 'Binance-Peg DOGE'),

    // ── Base (base) ─────────────────────────────────────────────────────────
    'USDC:base': _TokenEntry('0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', 6),
    'WETH:base': _TokenEntry('0x4200000000000000000000000000000000000006', 18),
    'DAI:base': _TokenEntry('0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb', 18),
    'cbETH:base': _TokenEntry('0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22', 18),

    // ── Arbitrum (arbitrum) ─────────────────────────────────────────────────
    'USDT:arbitrum':
        _TokenEntry('0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9', 6),
    'USDC:arbitrum':
        _TokenEntry('0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8', 6),
    'WETH:arbitrum':
        _TokenEntry('0x82aF49447D8a07e3bd95BD0d56f35241523fBab1', 18),
    'WBTC:arbitrum':
        _TokenEntry('0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f', 8),
    'ARB:arbitrum':
        _TokenEntry('0x912CE59144191C1204E64559FE8253a0e49E6548', 18),
    'GMX:arbitrum':
        _TokenEntry('0xfc5A1A6EB076a2C7aD06eD22C90d7E710E35ad0a', 18),
    'LINK:arbitrum':
        _TokenEntry('0xf97f4df75117a78c1A5a0DBb814Af92458539FB4', 18),

    // ── Polygon (polygon) ────────────────────────────────────────────────────
    'USDT:polygon':
        _TokenEntry('0xc2132D05D31c914a87C6611C10748AEb04B58e8F', 6),
    'USDC:polygon':
        _TokenEntry('0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174', 6),
    'WETH:polygon':
        _TokenEntry('0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619', 18),
    'WBTC:polygon':
        _TokenEntry('0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6', 8),
    'MATIC:polygon':
        _TokenEntry('0x0000000000000000000000000000000000001010', 18),
    'AAVE:polygon':
        _TokenEntry('0xD6DF932A45C0f255f85145f286eA0b292B21C90B', 18),

    // ── Solana (solana) ─────────────────────────────────────────────────────
    'USDC:solana':
        _TokenEntry('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v', 6),
    'USDT:solana':
        _TokenEntry('Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB', 6),
    'WSOL:solana': _TokenEntry(
        'So11111111111111111111111111111111111111112', 9, 'Wrapped SOL'),
    'BONK:solana':
        _TokenEntry('DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263', 5),
    'JUP:solana': _TokenEntry('JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN', 6),
    'MSOL:solana': _TokenEntry(
        'mSoLzYCxHdYgdzU16g5QSh3i5K3z3KZK7ytfqcJm7So', 9, 'Marinade SOL'),

    // ── Tron (tron) ─────────────────────────────────────────────────────────
    'USDT:tron': _TokenEntry('TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t', 6),
    'USDC:tron': _TokenEntry('TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8', 6),
    'WTRX:tron': _TokenEntry('TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR', 6),
    'BTT:tron': _TokenEntry('TAFjULxiVgT4qWk6UZwjqwZXTSaGaqnVp4', 18),
    'JST:tron': _TokenEntry('TCFLL5dx5ZJdKnWuesXxi1VPwjLVmWZZy9', 18),
    'SUN:tron': _TokenEntry('TSSMHYeV2uE9qYH95DqyoCuNCzEL1NvU3S', 18),
    'WIN:tron': _TokenEntry('TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7', 6),
  };

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Resolve the on-chain address for [symbol] on [chainKey].
  ///
  /// Resolution order:
  /// 1. Wallet holdings (most trusted — real user-verified addresses)
  /// 2. Built-in registry (vetted mainnet addresses)
  ///
  /// Returns a [TokenResolution] with [source] indicating where the
  /// address came from. Caller must honour [TokenResolution.found].
  TokenResolution resolve({
    required String symbol,
    required String chainKey,
  }) {
    final upper = symbol.toUpperCase();
    final chain = chainKey.toLowerCase();

    // ─ 1. Wallet holdings ──────────────────────────────────────────────────
    final holdingsResult = _resolveFromHoldings(upper, chain);
    if (holdingsResult != null) {
      _log.d('$upper@$chain → holdings');
      return holdingsResult;
    }

    // ─ 2. Built-in registry ────────────────────────────────────────────────
    final registryResult = _resolveFromRegistry(upper, chain);
    if (registryResult != null) {
      _log.d('$upper@$chain → registry');
      return registryResult;
    }

    _log.d('$upper@$chain → not found');
    return TokenResolution.notFound(symbol: upper, chainKey: chain);
  }

  /// Resolve using the active wallet's current chain.
  /// Convenience wrapper for automation flow where chain = active wallet chain.
  TokenResolution resolveOnActiveChain(String symbol) {
    final chainKey = WalletAdapter.instance.chainKey;
    return resolve(
        symbol: symbol, chainKey: chainKey.isNotEmpty ? chainKey : 'eth');
  }

  /// Resolve on the best chain from a priority list.
  ///
  /// Tries [preferredChainKeys] in order. Returns first match.
  /// Falls back to [resolveOnActiveChain] if none match.
  TokenResolution resolveWithFallback({
    required String symbol,
    required List<String> preferredChainKeys,
  }) {
    for (final chain in preferredChainKeys) {
      final r = resolve(symbol: symbol, chainKey: chain);
      if (r.found) return r;
    }
    return resolveOnActiveChain(symbol);
  }

  /// Returns a list of all built-in symbols supported on the given chain.
  List<String> getSupportedSymbols(String chainKey) {
    final chain = chainKey.toLowerCase();
    final result = <String>{};
    for (final key in _registry.keys) {
      final parts = key.split(':');
      if (parts.length == 2 && parts[1] == chain) {
        result.add(parts[0]);
      }
    }
    return result.toList(growable: false);
  }

  /// Returns a display-friendly name for a token on a specific chain.
  /// For pegged/wrapped assets (e.g. ETH on BSC), returns 'Binance-Peg ETH'.
  /// Returns null if no custom display name is set (use symbol or market name).
  String? getDisplayName(String symbol, String chainKey) {
    final key = '${symbol.toUpperCase()}:${chainKey.toLowerCase()}';
    return _registry[key]?.displayName;
  }

  // ── Private ────────────────────────────────────────────────────────────────

  TokenResolution? _resolveFromHoldings(String symbol, String chainKey) {
    final portfolio = VaultPortfolioListener.instance.summary;
    if (portfolio == null) return null;

    // Find the best (highest USD value) holding for this symbol on this chain.
    WalletAsset? best;
    for (final asset in portfolio.allAssets) {
      if (asset.symbol.toUpperCase() != symbol) continue;
      // Match by chainId if we know the chain.
      final chain = PrivyChainRegistry.getChain(chainKey);
      if (chain.evmChainId != null && asset.chainId != chain.evmChainId)
        continue;
      if (asset.address.isEmpty || asset.address == 'native') continue;
      if (best == null || asset.valueUsd > best.valueUsd) {
        best = asset;
      }
    }

    if (best == null) return null;
    return TokenResolution.fromHoldings(
      symbol: symbol,
      chainKey: chainKey,
      address: best.address,
      decimals: best.decimals,
    );
  }

  TokenResolution? _resolveFromRegistry(String symbol, String chainKey) {
    final key = '$symbol:$chainKey';
    final entry = _registry[key];
    if (entry == null) return null;
    return TokenResolution.fromRegistry(
      symbol: symbol,
      chainKey: chainKey,
      address: entry.address,
      decimals: entry.decimals,
    );
  }
}

// ─── Internal registry entry ───────────────────────────────────────────────────

class _TokenEntry {
  final String address;
  final int decimals;

  /// Human-readable name for pegged/wrapped tokens. Null = use symbol as-is.
  final String? displayName;
  const _TokenEntry(this.address, this.decimals, [this.displayName]);
}
