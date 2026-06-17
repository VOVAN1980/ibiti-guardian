import 'package:ibiti_guardian/utils/guardian_logger.dart';

/// Normalizes spoken/typed market commands to canonical form.
///
/// Provides:
/// - Synonym detection for TP, SL, Alert, Favorite, Remove actions
/// - Spoken number parser (RU + EN) — "пять процентов" → 5.0
/// - Market-keyword guard to prevent dismiss/close handler stealing market commands
class MarketIntentNormalizer {
  MarketIntentNormalizer._();
  static final instance = MarketIntentNormalizer._();

  // ignore: unused_field
  static const _log = GuardianLogger('MarketIntentNormalizer');

  // ── Synonym dictionaries ────────────────────────────────────────────────────

  static const _tpKeywords = [
    'тейк', 'тп', 'тейкпрофит',
    'верхняя планка', 'верхний предел', 'верхняя точка', 'верхний уровень',
    'продай когда вырастет', 'продай когда дойдёт', 'продай когда достигнет',
    'зафиксируй прибыль', 'зафикси прибыль', 'фиксируй прибыль',
    'когда вырастет на', 'когда дойдёт до', 'когда станет',
    'take profit', 'tp', 'profit target', 'target price',
    'sell when it reaches', 'lock profit', 'take gains',
  ];

  static const _slKeywords = [
    'стоп лосс', 'стоплос', 'стопак',
    'нижняя планка', 'нижний предел', 'нижний уровень', 'нижняя точка',
    'защита снизу', 'защити снизу', 'нижняя защита',
    'продай если упадёт', 'срежь если падает',
    'защити если минус', 'страхуй снизу',
    'когда упадёт на', 'когда потеряет', 'если упадёт до',
    'стоп потери', 'ограничь потери',
    'stop loss', 'stop-loss', 'cut loss',
    'protect downside', 'if it falls', 'if it drops',
  ];

  // NOTE: bare 'стоп' is intentionally NOT in _slKeywords to avoid false positives
  // with "стоп, покажи" etc. It is checked separately with context in the handler.

  static const _alertKeywords = [
    'алерт', 'колокольчик', 'уведомь', 'уведоми', 'уведомление',
    'напомни когда', 'сообщи когда',
    'маякни', 'пикни',
    'скажи мне когда', 'скажи если', 'скажи когда',
    'когда прыгнет', 'когда взлетит', 'когда рванёт',
    'когда пробьёт цену', 'когда пробьёт уровень',
    'следи и скажи',
    'alert', 'notify me', 'let me know when', 'tell me when',
    'ping me when', 'remind me when',
    'when it jumps', 'when it spikes',
  ];

  static const _favoriteKeywords = [
    'в избранное', 'добавь в избранное',
    'звёздочка', 'поставь звезду', 'звёздочку',
    'запомни монету', 'запомни её', 'запомни эту монету',
    'следи за ней', 'следи за монетой',
    'добавь монету', 'добавь в список', 'в вотчлист',
    'вотчлист',
    'add to favorites', 'add to watchlist', 'add to favourite',
    'watchlist', 'star it', 'save this coin', 'track this',
  ];

  static const _removeFavoriteKeywords = [
    'убери из избранного', 'удали из избранного', 'убери из вотчлиста',
    'сними звёздочку', 'убери звезду',
    'перестань следить', 'убери из списка',
    'remove from favorites', 'remove from watchlist',
    'unstar', 'unfavorite',
  ];

  static const _removeTpKeywords = [
    'убери тейк', 'убери tp', 'убери тп',
    'удали тейк', 'удали take profit', 'снять тейк',
    'сними тейк', 'сними tp', 'отмени тейк', 'отмени tp',
    'убери верхнюю планку', 'убери верхний предел',
    'remove tp', 'remove take profit', 'cancel take profit',
    'delete tp', 'clear tp',
  ];

  static const _removeSlKeywords = [
    'убери стоп лосс', 'убери sl', 'убери стоп-лосс',
    'удали стоп', 'снять стоп', 'сними стоп', 'сними sl',
    'отмени стоп', 'отмени стоп лосс',
    'убери нижнюю планку', 'убери нижний предел',
    'remove sl', 'remove stop loss', 'cancel stop loss',
    'delete sl', 'clear sl',
  ];

  static const _removeAlertKeywords = [
    'убери алерт', 'удали алерт', 'отмени алерт',
    'убери уведомление', 'сними уведомление', 'убери колокольчик',
    'отмени уведомление',
    'remove alert', 'cancel alert', 'delete alert', 'clear alert',
    'turn off alert',
  ];

  // ── Public detectors ────────────────────────────────────────────────────────

  bool hasTpKeyword(String lower) => _containsAny(lower, _tpKeywords);
  bool hasSlKeyword(String lower) => _containsAny(lower, _slKeywords);
  bool hasAlertKeyword(String lower) => _containsAny(lower, _alertKeywords);
  bool hasFavoriteKeyword(String lower) =>
      _containsAny(lower, _favoriteKeywords);
  bool hasRemoveFavoriteKeyword(String lower) =>
      _containsAny(lower, _removeFavoriteKeywords);
  bool hasRemoveTpKeyword(String lower) =>
      _containsAny(lower, _removeTpKeywords);
  bool hasRemoveSlKeyword(String lower) =>
      _containsAny(lower, _removeSlKeywords);
  bool hasRemoveAlertKeyword(String lower) =>
      _containsAny(lower, _removeAlertKeywords);

  /// Returns true if the input contains ANY market-action keyword.
  /// Used to prevent dismiss/close handler from stealing market commands.
  /// Example: "убери TP" → true → dismiss handler skips
  bool isMarketCommand(String lower) =>
      hasTpKeyword(lower) ||
      hasSlKeyword(lower) ||
      hasAlertKeyword(lower) ||
      hasFavoriteKeyword(lower) ||
      hasRemoveFavoriteKeyword(lower) ||
      hasRemoveTpKeyword(lower) ||
      hasRemoveSlKeyword(lower) ||
      hasRemoveAlertKeyword(lower);

  // ── Spoken number parser ────────────────────────────────────────────────────

  /// Parse a percentage value from natural language.
  ///
  /// "пять процентов" → 5.0
  /// "+10%" → 10.0
  /// "полтора процента" → 1.5
  /// "двадцать пять" (in % context) → 25.0
  double? parsePercent(String lower) {
    // 1. Numeric: "10%", "+15%", "5,5%"
    final numPct =
        RegExp(r'([+-]?\s*\d+(?:[.,]\d+)?)\s*%').firstMatch(lower);
    if (numPct != null) {
      final raw = numPct.group(1)!.replaceAll(' ', '').replaceAll(',', '.');
      return double.tryParse(raw)?.abs();
    }

    // 2. Spoken number
    final spoken = _spokenToNumber(lower);
    if (spoken != null) {
      if (lower.contains('процент') ||
          lower.contains('%') ||
          lower.contains('percent') ||
          lower.contains('pct')) {
        return spoken;
      }
      // In market context small numbers without % → treat as percent
      if (spoken <= 100) return spoken;
    }
    return null;
  }

  /// Parse a USD amount from natural language.
  ///
  /// "десять баксов" → 10.0
  /// "$20" → 20.0
  /// "полтинник" → 50.0
  /// "100 usdt" → 100.0
  double? parseUsd(String lower) {
    // 1. Numeric with $ or currency word
    final numUsd = RegExp(
      r'\$\s*(\d+(?:[.,]\d+)?)|(\d+(?:[.,]\d+)?)\s*(?:usdt|usd|бакс|долл|\$)',
      caseSensitive: false,
    ).firstMatch(lower);
    if (numUsd != null) {
      final raw =
          (numUsd.group(1) ?? numUsd.group(2) ?? '').replaceAll(',', '.');
      return double.tryParse(raw);
    }

    // 2. Spoken + currency context
    final spoken = _spokenToNumber(lower);
    if (spoken != null &&
        (lower.contains('бакс') ||
            lower.contains('долл') ||
            lower.contains('usd') ||
            lower.contains('usdt') ||
            lower.contains('dollar') ||
            lower.contains('buck'))) {
      return spoken;
    }
    return null;
  }

  // ── Spoken number dictionary ────────────────────────────────────────────────

  static const Map<String, double> _ones = {
    // RU cardinal + slang
    'ноль': 0, 'нул': 0,
    'один': 1, 'одну': 1, 'одна': 1,
    'два': 2, 'две': 2,
    'три': 3, 'четыре': 4, 'пять': 5,
    'шесть': 6, 'семь': 7, 'восемь': 8,
    'девять': 9, 'десять': 10,
    'одиннадцать': 11, 'двенадцать': 12, 'тринадцать': 13,
    'четырнадцать': 14, 'пятнадцать': 15,
    'шестнадцать': 16, 'семнадцать': 17, 'восемнадцать': 18,
    'девятнадцать': 19, 'двадцать': 20,
    'тридцать': 30, 'сорок': 40, 'пятьдесят': 50,
    'шестьдесят': 60, 'семьдесят': 70, 'восемьдесят': 80,
    'девяносто': 90, 'сто': 100,
    // Slang RU
    'десятку': 10, 'двадцатку': 20, 'тридцатку': 30,
    'полтинник': 50, 'полтос': 50,
    'сотку': 100, 'стольник': 100,
    // Fractions
    'полтора': 1.5, 'полторы': 1.5, 'половину': 0.5, 'половина': 0.5,
    'четверть': 0.25,
    // EN
    'zero': 0, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5,
    'six': 6, 'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10,
    'eleven': 11, 'twelve': 12, 'thirteen': 13, 'fourteen': 14,
    'fifteen': 15, 'sixteen': 16, 'seventeen': 17, 'eighteen': 18,
    'nineteen': 19, 'twenty': 20, 'thirty': 30, 'forty': 40,
    'fifty': 50, 'sixty': 60, 'seventy': 70, 'eighty': 80,
    'ninety': 90, 'hundred': 100,
  };

  double? _spokenToNumber(String lower) {
    var total = 0.0;
    var found = false;
    for (final entry in _ones.entries) {
      if (lower.contains(entry.key)) {
        total += entry.value;
        found = true;
      }
    }
    return found ? total : null;
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  static bool _containsAny(String text, List<String> keywords) =>
      keywords.any((kw) => text.contains(kw));
}
