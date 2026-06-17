/// Speech text normalizer — transforms raw text into TTS-friendly phrasing.
///
/// Pipeline: raw text → clean → humanize → expand → operator style → TTS.
///
/// This is the LAST transform before text hits OpenAI TTS.
/// Language-aware: handles both Russian and English phrasing patterns.
///
/// Usage:
///   final clean = SpeechNormalizer.normalize(raw, lang: 'ru');
///   await tts.speak(clean);
class SpeechNormalizer {
  SpeechNormalizer._();

  /// Main entry point. Returns clean, operator-grade speakable text.
  static String normalize(String input, {String lang = 'en'}) {
    if (input.isEmpty) return input;
    var s = input;

    // ── 1. Strip markdown formatting ──────────────────────────────────────
    s = _stripMarkdown(s);

    // ── 2. Strip emoji and visual-only symbols ───────────────────────────
    s = _stripVisualSymbols(s);

    // ── 3. Humanize addresses (0x...) ────────────────────────────────────
    s = _humanizeAddresses(s, lang);

    // ── 4. Humanize tx hashes ────────────────────────────────────────────
    s = _humanizeTxHashes(s, lang);

    // ── 5. Humanize numbers (0.000345 → readable) ────────────────────────
    s = _humanizeNumbers(s, lang);

    // ── 6. Expand token symbols ──────────────────────────────────────────
    s = _expandTokenNames(s);

    // ── 7. Expand abbreviations ──────────────────────────────────────────
    s = _expandAbbreviations(s, lang);

    // ── 8. Clean up whitespace ───────────────────────────────────────────
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();

    // ── 9. Operator style: confident, concise, premium tone ──────────────
    s = _applyOperatorStyle(s, lang);

    // ── 10. Ensure sentence ending ───────────────────────────────────────
    if (s.isNotEmpty && !RegExp(r'[.!?]$').hasMatch(s)) {
      s = '$s.';
    }

    return s;
  }

  // ── Markdown ────────────────────────────────────────────────────────────────

  static String _stripMarkdown(String s) {
    s = s.replaceAll(RegExp(r'\*\*|__'), '');
    s = s.replaceAll(RegExp(r'[*_]'), '');
    s = s.replaceAllMapped(
        RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m.group(1) ?? '');
    s = s.replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '');
    s = s.replaceAll(RegExp(r'```[\s\S]*?```'), '');
    s = s.replaceAll(RegExp(r'`([^`]+)`'), r'$1');
    s = s.replaceAll(RegExp(r'^\s*[-*•]\s+', multiLine: true), '');
    return s;
  }

  // ── Visual symbols ─────────────────────────────────────────────────────────

  static String _stripVisualSymbols(String s) {
    const remove = [
      '✓',
      '✔',
      '✗',
      '✘',
      '⚠️',
      '❗',
      '❌',
      '🔍',
      '🔗',
      '⛽',
      '🤖',
      '🙋',
      '🛡',
      '🔒',
      '🔓',
      '💥',
      '🔥',
      '⚡',
      '🎯',
      '💬',
      '👉',
      '📊',
      '📈',
      '📉',
      '🧠',
      '…',
      '...',
      '→',
      '←',
      '↑',
      '↓',
      '⇒',
    ];
    for (final c in remove) {
      s = s.replaceAll(c, '');
    }
    return s;
  }

  // ── Addresses ─────────────────────────────────────────────────────────────

  static String _humanizeAddresses(String s, String lang) {
    return s.replaceAllMapped(RegExp(r'0x[a-fA-F0-9]{40}'), (m) {
      final addr = m.group(0)!;
      final tail = addr.substring(addr.length - 4);
      return lang == 'ru' ? 'адрес $tail' : 'address ending in $tail';
    });
  }

  // ── TX Hashes ────────────────────────────────────────────────────────────

  static String _humanizeTxHashes(String s, String lang) {
    return s.replaceAllMapped(RegExp(r'0x[a-fA-F0-9]{64}'), (m) {
      return lang == 'ru' ? 'хеш транзакции' : 'transaction hash';
    });
  }

  // ── Numbers ─────────────────────────────────────────────────────────────────

  static String _humanizeNumbers(String s, String lang) {
    s = s.replaceAllMapped(
      RegExp(r'(\d+)\.0{4,}\d+'),
      (m) => lang == 'ru' ? 'менее 0.001' : 'less than 0.001',
    );
    s = s.replaceAllMapped(
      RegExp(r'(\d+\.\d{4})\d+'),
      (m) => m.group(1)!,
    );
    s = s.replaceAll('_', '');
    s = s.replaceAllMapped(
      RegExp(r'(\d{10,})\s*(wei|gwei)', caseSensitive: false),
      (m) => lang == 'ru' ? 'комиссия сети' : 'network fee',
    );
    return s;
  }

  // ── Token symbols ──────────────────────────────────────────────────────────

  static String _expandTokenNames(String s) {
    const expansions = {
      'WETH': 'Wrapped Ether',
      'WBTC': 'Wrapped Bitcoin',
      'USDT': 'Tether',
      'USDC': 'USD Coin',
      'BUSD': 'Binance U S D',
      'DAI': 'Die',
      'MATIC': 'Matic',
      'AVAX': 'Avalanche',
      'BNB': 'B N B',
      'ETH': 'Ether',
      'BTC': 'Bitcoin',
      'SOL': 'Solana',
      'TRX': 'Tron',
    };
    for (final entry in expansions.entries) {
      s = s.replaceAllMapped(
        RegExp('\\b${entry.key}\\b'),
        (m) => entry.value,
      );
    }
    return s;
  }

  // ── Abbreviations ──────────────────────────────────────────────────────────

  static String _expandAbbreviations(String s, String lang) {
    if (lang == 'ru') {
      s = s.replaceAll('tx', 'транзакция');
      s = s.replaceAll('Tx', 'Транзакция');
      s = s.replaceAll('TX', 'Транзакция');
      s = s.replaceAll('ERC-20', 'токен');
      s = s.replaceAll('ERC20', 'токен');
      s = s.replaceAll('EPK', 'политика безопасности');
      s = s.replaceAll('RPC', 'сервер');
    } else {
      s = s.replaceAll(RegExp(r'\bEPK\b'), 'security policy');
      s = s.replaceAll(RegExp(r'\bRPC\b'), 'network');
      s = s.replaceAll(RegExp(r'\bERC-?20\b'), 'token');
    }
    return s;
  }

  // ── Operator style ─────────────────────────────────────────────────────────

  /// Transforms plain informational sentences into confident operator phrasing.
  ///
  /// Rules:
  /// - Remove filler words ("please", "trying to", "we are")
  /// - Add confident openers to confirmations
  /// - Shorten passive constructions
  /// - Make error phrases direct, not apologetic
  static String _applyOperatorStyle(String s, String lang) {
    if (s.isEmpty) return s;

    if (lang == 'ru') {
      return _operatorStyleRu(s);
    }
    return _operatorStyleEn(s);
  }

  static String _operatorStyleEn(String s) {
    // ── Remove weak language ──
    s = s.replaceAll(RegExp(r'\bplease\b', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'\btrying to\b', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'\bwe are\b', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r"\bI'm going to\b", caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'\blet me\b', caseSensitive: false), '');

    // ── Confident rewrites ──
    // "Transaction confirmed" → "Confirmed. Transaction executed successfully"
    s = s.replaceAll(
      RegExp(r'^Transaction confirmed\.?$', caseSensitive: false),
      'Confirmed. Transaction executed successfully.',
    );

    // "Transaction sent" → "Executed. Awaiting network confirmation"
    s = s.replaceAll(
      RegExp(r'^Transaction sent\.?$', caseSensitive: false),
      'Executed. Awaiting network confirmation.',
    );

    // "Transaction failed" → "Rejected. Transaction was not executed"
    s = s.replaceAll(
      RegExp(r'^Transaction failed\.?$', caseSensitive: false),
      'Rejected. Transaction was not executed.',
    );

    // "Swap complete" → "Done. Swap executed successfully"
    s = s.replaceAll(
      RegExp(r'^Swap complete\.?$', caseSensitive: false),
      'Done. Swap executed successfully.',
    );

    // "Swap sent" → "Executing swap. Awaiting confirmation"
    s = s.replaceAll(
      RegExp(r'^Swap sent\.?$', caseSensitive: false),
      'Executing swap. Awaiting confirmation.',
    );

    // "Transfer sent" → "Sent. Awaiting network confirmation"
    s = s.replaceAll(
      RegExp(r'^Transfer sent\.?$', caseSensitive: false),
      'Sent. Awaiting network confirmation.',
    );

    // "Transfer confirmed" → "Done. Transfer executed successfully"
    s = s.replaceAll(
      RegExp(r'^Transfer confirmed\.?$', caseSensitive: false),
      'Done. Transfer executed successfully.',
    );

    // "Approval sent" → "Approval submitted. Awaiting confirmation"
    s = s.replaceAll(
      RegExp(r'^Approval sent\.?$', caseSensitive: false),
      'Approval submitted. Awaiting confirmation.',
    );

    // "Approval revoked" → "Done. Approval revoked successfully"
    s = s.replaceAll(
      RegExp(r'^Approval revoked\.?$', caseSensitive: false),
      'Done. Approval revoked successfully.',
    );

    // "Operation blocked" → "Blocked. Security policy prevented this action"
    s = s.replaceAll(
      RegExp(r'^Operation blocked\.?$', caseSensitive: false),
      'Blocked. Security policy prevented this action.',
    );

    // "Operation cancelled" → "Cancelled. No action was taken"
    s = s.replaceAll(
      RegExp(r'^Operation cancelled\.?$', caseSensitive: false),
      'Cancelled. No action was taken.',
    );

    // "No threats found" at the start → "Clear."
    s = s.replaceAll(
      RegExp(r'^No threats found\.?', caseSensitive: false),
      'Clear.',
    );

    // "No assets found" → "No assets detected in this wallet"
    s = s.replaceAll(
      RegExp(r'^No assets found\.?$', caseSensitive: false),
      'No assets detected in this wallet.',
    );

    // Confirmation timeout → direct
    s = s.replaceAll(
      RegExp(r'^Confirmation timeout\.?', caseSensitive: false),
      'Timeout.',
    );

    // "Waiting for confirmation" → "Standing by. Awaiting network confirmation"
    s = s.replaceAll(
      RegExp(r'^Waiting for confirmation\.?$', caseSensitive: false),
      'Standing by. Awaiting network confirmation.',
    );

    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _operatorStyleRu(String s) {
    // ── Remove filler ──
    s = s.replaceAll(RegExp(r'\bпожалуйста\b', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'\bпопробую\b', caseSensitive: false), '');

    // ── Confident rewrites ──
    s = s.replaceAll(
      RegExp(r'^Транзакция подтверждена\.?$'),
      'Подтверждено. Транзакция выполнена.',
    );

    s = s.replaceAll(
      RegExp(r'^Транзакция отправлена\.?$'),
      'Отправлено. Жду подтверждение сети.',
    );

    s = s.replaceAll(
      RegExp(r'^Транзакция не прошла\.?$'),
      'Отклонено. Транзакция не выполнена.',
    );

    s = s.replaceAll(
      RegExp(r'^Обмен выполнен\.?$'),
      'Готово. Обмен выполнен успешно.',
    );

    s = s.replaceAll(
      RegExp(r'^Обмен отправлен\.?$'),
      'Выполняю обмен. Жду подтверждение.',
    );

    s = s.replaceAll(
      RegExp(r'^Перевод отправлен\.?$'),
      'Отправлено. Жду подтверждение сети.',
    );

    s = s.replaceAll(
      RegExp(r'^Перевод выполнен\.?$'),
      'Готово. Перевод выполнен успешно.',
    );

    s = s.replaceAll(
      RegExp(r'^Разрешение выдано\.?$'),
      'Разрешение отправлено. Жду подтверждение.',
    );

    s = s.replaceAll(
      RegExp(r'^Разрешение отозвано\.?$'),
      'Готово. Разрешение отозвано.',
    );

    s = s.replaceAll(
      RegExp(r'^Операция заблокирована\.?$'),
      'Заблокировано. Политика безопасности не позволяет.',
    );

    s = s.replaceAll(
      RegExp(r'^Операция отменена\.?$'),
      'Отменено. Действие не выполнялось.',
    );

    s = s.replaceAll(
      RegExp(r'^Угроз не обнаружено\.?'),
      'Чисто.',
    );

    s = s.replaceAll(
      RegExp(r'^Активы не найдены\.?$'),
      'Активы не обнаружены в этом кошельке.',
    );

    s = s.replaceAll(
      RegExp(r'^Жду подтверждения\.?$'),
      'На связи. Жду подтверждение сети.',
    );

    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
