class TokenMetadata {
  final String tokenAddress;
  final String name;
  final String symbol;
  final int decimals;
  final String? logoUrl;

  TokenMetadata({
    required this.tokenAddress,
    required this.name,
    required this.symbol,
    required this.decimals,
    this.logoUrl,
  });
}

class TokenMetadataCache {
  static final TokenMetadataCache _instance = TokenMetadataCache._internal();
  factory TokenMetadataCache() => _instance;
  TokenMetadataCache._internal();

  // Cache structure: Map<"chain_tokenAddress", TokenMetadata>
  final Map<String, TokenMetadata> _cache = {};

  String _generateKey(String chain, String tokenAddress) {
    return "${chain.toLowerCase()}_${tokenAddress.toLowerCase()}";
  }

  /// Retrieves cached metadata, or null if not found.
  TokenMetadata? get(String chain, String tokenAddress) {
    final key = _generateKey(chain, tokenAddress);
    return _cache[key];
  }

  /// Saves or updates metadata in the cache.
  void set(String chain, String tokenAddress, TokenMetadata data) {
    if (tokenAddress.isEmpty) return;
    final key = _generateKey(chain, tokenAddress);
    _cache[key] = data;
  }

  /// Clears the entire cache.
  void clear() {
    _cache.clear();
  }
}
