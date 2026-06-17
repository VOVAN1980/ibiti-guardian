/// Maps voice/STT transcriptions (Cyrillic, aliases, typos) to canonical
/// token symbols. Used by wallet_send_modal and wallet_swap_modal to
/// resolve voice-dispatched selectToken commands.
class TokenSymbolNormalizer {
  TokenSymbolNormalizer._();

  // ── Alias map ─────────────────────────────────────────────────────────────
  // Keys are lowercase, values are canonical uppercase symbols.
  static const _aliases = <String, String>{
    // IBITI
    'ибити': 'IBITI',
    'и бити': 'IBITI',
    'ибитикоин': 'IBITI',
    'ibiti': 'IBITI',
    'ibiticoin': 'IBITI',
    'ибитиcoin': 'IBITI',
    'iбити': 'IBITI',
    'ибіті': 'IBITI',
    // USDT
    'юсдт': 'USDT',
    'усдт': 'USDT',
    'ю эс ди ти': 'USDT',
    'ю эс дэ тэ': 'USDT',
    'yusdt': 'USDT',
    'тезер': 'USDT',
    'тетер': 'USDT',
    'тизер': 'USDT',
    'usdt': 'USDT',
    'tether': 'USDT',
    // USDC
    'юсдс': 'USDC',
    'усдс': 'USDC',
    'ю эс ди си': 'USDC',
    'usdc': 'USDC',
    // ETH
    'эфир': 'ETH',
    'эфириум': 'ETH',
    'эфиреум': 'ETH',
    'eth': 'ETH',
    'ethereum': 'ETH',
    'ether': 'ETH',
    // BNB
    'бнб': 'BNB',
    'бинанс': 'BNB',
    'бинанскоин': 'BNB',
    'bnb': 'BNB',
    // SOL
    'сол': 'SOL',
    'солана': 'SOL',
    'sol': 'SOL',
    'solana': 'SOL',
    // BTC
    'биткоин': 'BTC',
    'биткойн': 'BTC',
    'битка': 'BTC',
    'bitcoin': 'BTC',
    'btc': 'BTC',
    // TRX
    'трон': 'TRX',
    'тронкоин': 'TRX',
    'трикс': 'TRX',
    'tron': 'TRX',
    'trx': 'TRX',
    // MATIC / POL
    'матик': 'POL',
    'полигон': 'POL',
    'matic': 'POL',
    'polygon': 'POL',
    'pol': 'POL',
    // DOGE
    'дож': 'DOGE',
    'дожкоин': 'DOGE',
    'доги': 'DOGE',
    'doge': 'DOGE',
    'dogecoin': 'DOGE',
    // PEPE
    'пепе': 'PEPE',
    'pepe': 'PEPE',
  };

  /// Normalize a raw voice/STT symbol string to its canonical form.
  ///
  /// 1. Strips whitespace, dashes, underscores
  /// 2. Checks alias map
  /// 3. Falls back to uppercase input
  static String normalize(String raw) {
    final cleaned =
        raw.trim().toLowerCase().replaceAll(RegExp(r'[-_\s]+'), ' ').trim();

    if (cleaned.isEmpty) return raw.toUpperCase();

    // Exact alias match
    final exact = _aliases[cleaned];
    if (exact != null) return exact;

    // Try without spaces (e.g. "и бити" → "ибити")
    final noSpaces = cleaned.replaceAll(' ', '');
    final compact = _aliases[noSpaces];
    if (compact != null) return compact;

    // Try as-is uppercase (already a valid symbol like "BTC")
    return raw.trim().toUpperCase();
  }
}
