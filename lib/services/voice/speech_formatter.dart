/// Normalizes AI text output for natural TTS playback.
///
/// Problems this solves:
/// - "$123.5" read as "dollar sign one two three dot five"
/// - "0.00045 ETH" read character by character
/// - "65000" not abbreviated to "65 тысяч"
/// - Markdown artifacts (**bold**, *italic*, ##) in speech
/// - Emoji cluttering voice output
/// - No natural pauses between logical blocks
class SpeechFormatter {
  SpeechFormatter._();

  /// Main entry point: normalize text for spoken output.
  static String normalize(String text, {String lang = 'ru'}) {
    String result = text;

    // 1. Strip markdown
    result = _stripMarkdown(result);

    // 2. Strip emoji
    result = _stripEmoji(result);

    // 3. Normalize crypto amounts: "0.00045 ETH" → "ноль целых сорок пять стотысячных ETH"
    result = _normalizeCryptoAmounts(result, lang);

    // 4. Normalize dollar amounts: "$123.50" → "123 долларов 50 центов"
    result = _normalizeDollarAmounts(result, lang);

    // 5. Normalize large numbers: "65000" → "65 тысяч"
    result = _normalizeLargeNumbers(result, lang);

    // 6. Normalize percentages: "+12.5%" → "плюс 12 и 5 процента"
    result = _normalizePercentages(result, lang);

    // 7. Insert natural pauses
    result = _insertPauses(result);

    // 8. Clean up whitespace
    result = result.replaceAll(RegExp(r'\s+'), ' ').trim();

    return result;
  }

  // ── Markdown ────────────────────────────────────────────────────────────────

  static String _stripMarkdown(String text) {
    String r = text;
    // Headers
    r = r.replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '');
    // Bold/italic
    r = r.replaceAll(RegExp(r'\*{1,3}'), '');
    r = r.replaceAll(RegExp(r'_{1,3}'), ' ');
    // Code blocks
    r = r.replaceAll(RegExp(r'`{1,3}[^`]*`{1,3}'), '');
    // Bullet points: "- item" or "• item"
    r = r.replaceAll(RegExp(r'^[\-•]\s+', multiLine: true), '');
    // Numbered lists: "1. item"
    r = r.replaceAll(RegExp(r'^\d+\.\s+', multiLine: true), '');
    // Links: [text](url) → text
    r = r.replaceAllMapped(
        RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m.group(1) ?? '');
    return r;
  }

  // ── Emoji ───────────────────────────────────────────────────────────────────

  static String _stripEmoji(String text) {
    // Remove common emoji ranges — keeps letters, digits, punctuation.
    return text.replaceAll(
      RegExp(
        r'[\u{1F300}-\u{1F9FF}]|[\u{2600}-\u{26FF}]|[\u{2700}-\u{27BF}]|'
        r'[\u{FE00}-\u{FE0F}]|[\u{1F000}-\u{1F02F}]|[\u{200D}]|'
        r'[\u{20E3}]|[\u{E0020}-\u{E007F}]|[\u{FE0F}]|'
        r'[✅❌⚠️⛔🔥📌💡📋🧠🚀━]',
        unicode: true,
      ),
      '',
    );
  }

  // ── Crypto Amounts ──────────────────────────────────────────────────────────
  // "0.45 ETH" → "ноль сорок пять ETH"
  // "0.00045 BTC" → "ноль целых сорок пять стотысячных BTC"
  // For voice, simple decimal reading is cleaner than full word form.

  static final _cryptoPattern = RegExp(
    r'(\d+\.?\d*)\s*(BTC|ETH|SOL|BNB|USDT|USDC|IBIT|IBITI|DAI|BUSD|MATIC|'
    r'XRP|DOGE|ADA|DOT|AVAX|LINK|UNI|ATOM|FTM|NEAR|APT|ARB|OP|TRX|'
    r'LTC|BCH|ETC|FIL|HBAR|ICP|VET|ALGO|SAND|MANA|AXS|GALA|APE|'
    r'PEPE|SHIB|WIF|BONK|FLOKI|BRETT|биткоин|эфир|солана)',
    caseSensitive: false,
  );

  static String _normalizeCryptoAmounts(String text, String lang) {
    return text.replaceAllMapped(_cryptoPattern, (m) {
      final numStr = m.group(1)!;
      final symbol = m.group(2)!.toUpperCase();
      final num = double.tryParse(numStr);
      if (num == null) return m.group(0)!;

      if (lang == 'ru') {
        return '${_readNumberRu(num)} $symbol';
      } else {
        return '${_readNumberEn(num)} $symbol';
      }
    });
  }

  // ── Dollar Amounts ──────────────────────────────────────────────────────────
  // "$123.50" → "123 долларов 50 центов"
  // "~$0.0001" → "меньше цента"

  static final _dollarPattern = RegExp(
    r'~?\$\s*(\d+(?:\.\d+)?)',
  );

  static String _normalizeDollarAmounts(String text, String lang) {
    return text.replaceAllMapped(_dollarPattern, (m) {
      final numStr = m.group(1)!;
      final num = double.tryParse(numStr);
      if (num == null) return m.group(0)!;

      if (num < 0.01) {
        return lang == 'ru' ? 'меньше цента' : 'less than a cent';
      }

      final dollars = num.truncate();
      final cents = ((num - dollars) * 100).round();

      if (lang == 'ru') {
        final dollarWord = _pluralRu(dollars, 'доллар', 'доллара', 'долларов');
        if (cents == 0) return '$dollars $dollarWord';
        final centWord = _pluralRu(cents, 'цент', 'цента', 'центов');
        return '$dollars $dollarWord $cents $centWord';
      } else {
        final dollarWord = dollars == 1 ? 'dollar' : 'dollars';
        if (cents == 0) return '$dollars $dollarWord';
        final centWord = cents == 1 ? 'cent' : 'cents';
        return '$dollars $dollarWord $cents $centWord';
      }
    });
  }

  // ── Large Numbers ───────────────────────────────────────────────────────────
  // "65000" → "65 тысяч"
  // "1200000" → "1.2 миллиона"
  // Only standalone numbers, not part of addresses or hashes.

  static final _largeNumberPattern = RegExp(
    r'(?<!\w)(\d{4,})(?!\w|\.)',
  );

  static String _normalizeLargeNumbers(String text, String lang) {
    return text.replaceAllMapped(_largeNumberPattern, (m) {
      final numStr = m.group(1)!;
      // Skip hex addresses (0x...) — they contain only digits sometimes
      if (numStr.length > 10) return numStr; // Probably an address or hash

      final num = int.tryParse(numStr);
      if (num == null) return numStr;

      if (lang == 'ru') {
        return _abbreviateNumberRu(num);
      } else {
        return _abbreviateNumberEn(num);
      }
    });
  }

  // ── Percentages ─────────────────────────────────────────────────────────────
  // "+12.5%" → "плюс 12 и 5 процента"
  // "-3.2%" → "минус 3 и 2 процента"

  static final _percentPattern = RegExp(
    r'([+\-])?\s*(\d+(?:\.\d+)?)\s*%',
  );

  static String _normalizePercentages(String text, String lang) {
    return text.replaceAllMapped(_percentPattern, (m) {
      final sign = m.group(1);
      final numStr = m.group(2)!;
      final num = double.tryParse(numStr);
      if (num == null) return m.group(0)!;

      String prefix = '';
      if (sign == '+') prefix = lang == 'ru' ? 'плюс ' : 'plus ';
      if (sign == '-') prefix = lang == 'ru' ? 'минус ' : 'minus ';

      final whole = num.truncate();
      final frac = ((num - whole) * 10).round();

      if (lang == 'ru') {
        if (frac == 0) {
          return '$prefix$whole ${_pluralRu(whole, 'процент', 'процента', 'процентов')}';
        }
        return '$prefix$whole и $frac ${_pluralRu(frac, 'десятая', 'десятых', 'десятых')} процента';
      } else {
        if (frac == 0) return '$prefix$whole percent';
        return '$prefix$whole point $frac percent';
      }
    });
  }

  // ── Pauses ──────────────────────────────────────────────────────────────────
  // Insert natural micro-pauses for better TTS rhythm.

  static String _insertPauses(String text) {
    String r = text;

    // After colon, add a pause
    r = r.replaceAll(': ', ':... ');

    // Before "но", "однако", "при этом" — slight pause
    r = r.replaceAllMapped(
      RegExp(r'(\S)\s+(но|однако|при этом|however|but)\s',
          caseSensitive: false),
      (m) => '${m.group(1)},... ${m.group(2)} ',
    );

    // After numbers followed by units — slight pause for clarity
    r = r.replaceAllMapped(
      RegExp(r'(\d)\s+(долларов|доллара|доллар|dollars|dollar|процент)',
          caseSensitive: false),
      (m) => '${m.group(1)} ${m.group(2)}',
    );

    return r;
  }

  // ── Number Reading Helpers ──────────────────────────────────────────────────

  /// Read a number for speech in Russian.
  /// 0.45 → "ноль сорок пять"
  /// 123.5 → "сто двадцать три целых пять"
  /// 0.00045 → "ноль целых сорок пять стотысячных" (simplified for voice)
  static String _readNumberRu(double num) {
    if (num == 0) return 'ноль';
    if (num == num.truncate().toDouble() && num >= 1) {
      return _abbreviateNumberRu(num.truncate());
    }

    final whole = num.truncate();
    final fracStr =
        num.toStringAsFixed(8).split('.')[1].replaceAll(RegExp(r'0+$'), '');

    if (fracStr.isEmpty) return _abbreviateNumberRu(whole);

    // For very small fractions (< 0.001), just read digits
    if (num < 0.001 && whole == 0) {
      final digits = fracStr.split('').join(' ');
      return 'ноль точка $digits';
    }

    // For normal decimals: "123 точка 45"
    if (whole > 0) {
      return '${_abbreviateNumberRu(whole)} точка $fracStr';
    }

    // "ноль точка 45"
    return 'ноль точка $fracStr';
  }

  /// Read a number for speech in English.
  static String _readNumberEn(double num) {
    if (num == 0) return 'zero';
    if (num == num.truncate().toDouble() && num >= 1) {
      return _abbreviateNumberEn(num.truncate());
    }

    final whole = num.truncate();
    final fracStr =
        num.toStringAsFixed(8).split('.')[1].replaceAll(RegExp(r'0+$'), '');

    if (fracStr.isEmpty) return _abbreviateNumberEn(whole);

    if (num < 0.001 && whole == 0) {
      final digits = fracStr.split('').join(' ');
      return 'zero point $digits';
    }

    if (whole > 0) {
      return '${_abbreviateNumberEn(whole)} point $fracStr';
    }

    return 'zero point $fracStr';
  }

  /// Abbreviate large integer for Russian speech.
  static String _abbreviateNumberRu(int n) {
    if (n >= 1000000000) {
      final v = n / 1000000000;
      final s = v == v.truncate().toDouble()
          ? v.truncate().toString()
          : v.toStringAsFixed(1);
      return '$s ${_pluralRu(v.truncate(), 'миллиард', 'миллиарда', 'миллиардов')}';
    }
    if (n >= 1000000) {
      final v = n / 1000000;
      final s = v == v.truncate().toDouble()
          ? v.truncate().toString()
          : v.toStringAsFixed(1);
      return '$s ${_pluralRu(v.truncate(), 'миллион', 'миллиона', 'миллионов')}';
    }
    if (n >= 10000) {
      final v = n / 1000;
      final s = v == v.truncate().toDouble()
          ? v.truncate().toString()
          : v.toStringAsFixed(1);
      return '$s ${_pluralRu(v.truncate(), 'тысяча', 'тысячи', 'тысяч')}';
    }
    return n.toString();
  }

  /// Abbreviate large integer for English speech.
  static String _abbreviateNumberEn(int n) {
    if (n >= 1000000000) {
      final v = n / 1000000000;
      final s = v == v.truncate().toDouble()
          ? v.truncate().toString()
          : v.toStringAsFixed(1);
      return '$s billion';
    }
    if (n >= 1000000) {
      final v = n / 1000000;
      final s = v == v.truncate().toDouble()
          ? v.truncate().toString()
          : v.toStringAsFixed(1);
      return '$s million';
    }
    if (n >= 10000) {
      final v = n / 1000;
      final s = v == v.truncate().toDouble()
          ? v.truncate().toString()
          : v.toStringAsFixed(1);
      return '$s thousand';
    }
    return n.toString();
  }

  /// Russian plural forms (1/2-4/5+).
  static String _pluralRu(int n, String one, String few, String many) {
    final mod10 = n % 10;
    final mod100 = n % 100;
    if (mod100 >= 11 && mod100 <= 19) return many;
    if (mod10 == 1) return one;
    if (mod10 >= 2 && mod10 <= 4) return few;
    return many;
  }
}
