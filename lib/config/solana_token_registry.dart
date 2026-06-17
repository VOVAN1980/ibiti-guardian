/// Known SPL token metadata for common Solana tokens.
///
/// When `getTokenAccountsByOwner` returns a mint address, we look it up here
/// to get a human-readable name, symbol, and logo. If not found, we display
/// the mint address truncated.
class SolanaTokenMeta {
  final String mint;
  final String symbol;
  final String name;
  final int decimals;
  final double? fallbackPrice;
  final String? logoUrl;

  const SolanaTokenMeta({
    required this.mint,
    required this.symbol,
    required this.name,
    required this.decimals,
    this.fallbackPrice,
    this.logoUrl,
  });
}

class SolanaTokenRegistry {
  SolanaTokenRegistry._();

  // ── Well-known SPL tokens ──────────────────────────────────────────────────
  static const List<SolanaTokenMeta> _known = [
    SolanaTokenMeta(
      mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
      symbol: 'USDC',
      name: 'USD Coin',
      decimals: 6,
      fallbackPrice: 1.0,
      logoUrl: 'https://cryptologos.cc/logos/usd-coin-usdc-logo.png',
    ),
    SolanaTokenMeta(
      mint: 'Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB',
      symbol: 'USDT',
      name: 'Tether USD',
      decimals: 6,
      fallbackPrice: 1.0,
      logoUrl: 'https://cryptologos.cc/logos/tether-usdt-logo.png',
    ),
    SolanaTokenMeta(
      mint: 'So11111111111111111111111111111111111111112',
      symbol: 'wSOL',
      name: 'Wrapped SOL',
      decimals: 9,
      logoUrl: 'https://cryptologos.cc/logos/solana-sol-logo.png',
    ),
    SolanaTokenMeta(
      mint: 'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263',
      symbol: 'BONK',
      name: 'Bonk',
      decimals: 5,
      logoUrl:
          'https://arweave.net/hQiPZOsRZXGXBJd_82PhVdlM_hACsT_q6wqwf5cSY7I',
    ),
    SolanaTokenMeta(
      mint: 'JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN',
      symbol: 'JUP',
      name: 'Jupiter',
      decimals: 6,
      logoUrl: 'https://static.jup.ag/jup/icon.png',
    ),
    SolanaTokenMeta(
      mint: 'RLBxxFkseAZ4RgJH3Sqn8jXxhmGoz9jWxDNJMh8pL7a',
      symbol: 'RLBB',
      name: 'Rollbit Coin',
      decimals: 2,
    ),
    SolanaTokenMeta(
      mint: 'mSoLzYCxHdYgdzU16g5QSh3i5K3z3KZK7ytfqcJm7So',
      symbol: 'mSOL',
      name: 'Marinade Staked SOL',
      decimals: 9,
    ),
  ];

  static final Map<String, SolanaTokenMeta> _cache = {
    for (final t in _known) t.mint: t,
  };

  /// Lookup token metadata by mint address.
  /// Returns null for unknown tokens.
  static SolanaTokenMeta? lookup(String mint) => _cache[mint];

  /// Returns a display symbol for an SPL mint.
  /// Falls back to truncated mint address if unknown.
  static String symbolFor(String mint) {
    final meta = _cache[mint];
    if (meta != null) return meta.symbol;
    // Unknown token: show first 4 + last 4 of mint
    if (mint.length > 8) {
      return '${mint.substring(0, 4)}…${mint.substring(mint.length - 4)}';
    }
    return mint;
  }
}
