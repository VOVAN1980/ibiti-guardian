import 'package:ibiti_guardian/services/token_metadata_cache.dart';
import 'package:ibiti_guardian/config/chains.dart';

class WalletAsset {
  final String name;
  final String symbol;
  final String address;
  final double balance;
  final String? logoUrl;
  final double priceUsd;
  final double valueUsd;
  final int decimals;
  final bool isNative;
  final int chainId;

  /// Network key for cross-chain identity (e.g. 'bsc', 'eth', 'solana', 'tron').
  /// Used to build unique asset IDs and display the correct chain name.
  final String chainKey;

  /// 24h price change percentage (e.g. +0.11, -3.5). Null if unknown.
  final double? priceChange24hPct;

  /// 24h value change in USD (balance * price delta). Null if unknown.
  final double? valueChange24hUsd;

  /// Whether a reliable price source exists for this asset.
  /// When false, UI should show "—" instead of "$0.00".
  final bool priceAvailable;

  WalletAsset({
    required this.name,
    required this.symbol,
    required this.address,
    required this.balance,
    this.logoUrl,
    required this.priceUsd,
    required this.valueUsd,
    required this.decimals,
    this.isNative = false,
    required this.chainId,
    this.chainKey = '',
    this.priceChange24hPct,
    this.valueChange24hUsd,
    this.priceAvailable = true,
  });

  /// Creates a copy with enriched price performance data.
  WalletAsset copyWith({
    double? priceUsd,
    double? valueUsd,
    double? priceChange24hPct,
    double? valueChange24hUsd,
    bool? priceAvailable,
  }) {
    return WalletAsset(
      name: name,
      symbol: symbol,
      address: address,
      balance: balance,
      logoUrl: logoUrl,
      priceUsd: priceUsd ?? this.priceUsd,
      valueUsd: valueUsd ?? this.valueUsd,
      decimals: decimals,
      isNative: isNative,
      chainId: chainId,
      chainKey: chainKey,
      priceChange24hPct: priceChange24hPct ?? this.priceChange24hPct,
      valueChange24hUsd: valueChange24hUsd ?? this.valueChange24hUsd,
      priceAvailable: priceAvailable ?? this.priceAvailable,
    );
  }

  factory WalletAsset.fromMoralis(Map<String, dynamic> json, {String? chain}) {
    final address = json['token_address']?.toString() ??
        '0x0000000000000000000000000000000000000000';

    String name = json['name']?.toString() ?? 'Unknown';
    String symbol = json['symbol']?.toString() ?? '???';
    int decimals = int.tryParse(json['decimals']?.toString() ?? '18') ?? 18;
    String? logoUrl = json['thumbnail']?.toString() ?? json['logo']?.toString();

    if (chain != null && address.toLowerCase() != 'native') {
      final cache = TokenMetadataCache();
      final cached = cache.get(chain, address);
      if (cached != null) {
        name = cached.name;
        symbol = cached.symbol;
        decimals = cached.decimals;
        logoUrl = cached.logoUrl;
      } else {
        cache.set(
          chain,
          address,
          TokenMetadata(
            tokenAddress: address,
            name: name,
            symbol: symbol,
            decimals: decimals,
            logoUrl: logoUrl,
          ),
        );
      }
    }

    final balanceRaw =
        double.tryParse(json['balance']?.toString() ?? '0') ?? 0.0;

    // Moralis tokens endpoint usually returns human-readable balance or we calculate it
    // If 'balance_formatted' is available, we can use it, otherwise divide by 10^decimals
    double balance = balanceRaw;
    if (json.containsKey('balance_formatted')) {
      balance = double.tryParse(json['balance_formatted'].toString()) ?? 0.0;
    } else {
      // Manual calculation if needed, but Moralis v2.2 usually provides formatted
      // balance = balanceRaw / pow(10, decimals);
    }

    final price = double.tryParse(json['usd_price']?.toString() ?? '0') ?? 0.0;
    final value = double.tryParse(json['usd_value']?.toString() ?? '0') ?? 0.0;

    return WalletAsset(
      name: name,
      symbol: symbol,
      address: address,
      balance: balance,
      logoUrl: logoUrl,
      priceUsd: price,
      valueUsd: value,
      decimals: decimals,
      isNative: false,
      chainId: chain != null ? ChainConfig.getChainId(chain) : 1,
      chainKey: chain ?? '',
      // Mark as price-unavailable if Moralis returned zero price
      priceAvailable: price > 0,
    );
  }

  factory WalletAsset.native({
    required String name,
    required String symbol,
    required double balance,
    String? logoUrl,
    required double priceUsd,
    required int decimals,
    required int chainId,
    String chainKey = '',
  }) {
    return WalletAsset(
      name: name,
      symbol: symbol,
      address: 'native',
      balance: balance,
      logoUrl: logoUrl,
      priceUsd: priceUsd,
      valueUsd: balance * priceUsd,
      decimals: decimals,
      isNative: true,
      chainId: chainId,
      chainKey: chainKey,
      priceAvailable: priceUsd > 0,
    );
  }
}
