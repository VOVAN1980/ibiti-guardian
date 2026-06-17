import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';

/// Resolves pronouns and demonstratives ("this coin", "эта монета") into
/// concrete symbol names using ScreenContextService.
///
/// Called at the VERY START of process(), BEFORE IntentParser and FastPathHandler.
/// This way "купи эту монету" becomes "купи MOVR" and hits the fast path instantly.
class PronounResolver {
  PronounResolver._();

  // ── Pure pronoun patterns (replace the match with SYMBOL) ─────────────────
  // These are noun phrases where the entire match should become the symbol.
  static final _purePatterns = [
    // Russian: "эта монета", "эту крипту", "текущий токен"
    RegExp(r'\bэт(?:а|у|ой|от|о|им|ого|их)\s+монет[аыуе]?\b',
        caseSensitive: false),
    RegExp(r'\bэт(?:а|у|ой|от|о|им|ого|их)\s+крипт[аыуое]?\b',
        caseSensitive: false),
    RegExp(r'\bэт(?:а|у|ой|от|о|им|ого|их)\s+токен[аыуе]?\b',
        caseSensitive: false),
    RegExp(r'\bэт(?:а|у|ой|от|о|им|ого|их)\s+монетк[аыуе]?\b',
        caseSensitive: false),
    RegExp(r'\bвот\s+эт(?:а|у|ой|от|о)\s+монет[аыуе]?\b', caseSensitive: false),
    RegExp(r'\bтекущ(?:ая|ий|ую|ей|его)\s+монет[аыуе]?\b',
        caseSensitive: false),
    RegExp(r'\bтекущ(?:ая|ий|ую|ей|его)\s+токен[аыуе]?\b',
        caseSensitive: false),
    // English: "this coin", "current token"
    RegExp(r'\bthis\s+coin\b', caseSensitive: false),
    RegExp(r'\bthis\s+token\b', caseSensitive: false),
    RegExp(r'\bthis\s+crypto\b', caseSensitive: false),
    RegExp(r'\bcurrent\s+coin\b', caseSensitive: false),
    RegExp(r'\bcurrent\s+token\b', caseSensitive: false),
  ];

  // ── Command patterns (replace pronoun but KEEP the verb) ──────────────────
  // Each entry: (pattern, replacementTemplate) where $s will be replaced by symbol.
  static final _commandPatterns = <_CommandPattern>[
    // Russian question patterns: preserve question structure
    _CommandPattern(
        RegExp(r'\bчто\s+это\s+за\s+монет[аыуе]?\b', caseSensitive: false),
        'что такое \$s'),
    _CommandPattern(
        RegExp(r'\bчто\s+это\s+за\s+токен[аыуе]?\b', caseSensitive: false),
        'что такое \$s'),
    _CommandPattern(
        RegExp(r'\bчто\s+это\s+за\s+крипт[аыуое]?\b', caseSensitive: false),
        'что такое \$s'),
    _CommandPattern(
        RegExp(r'\bчто\s+это\s+за\s+монетк[аыуе]?\b', caseSensitive: false),
        'что такое \$s'),
    // Russian pronouns with context: preserve sentence structure
    _CommandPattern(RegExp(r'\bпро\s+неё\b', caseSensitive: false), 'про \$s'),
    _CommandPattern(RegExp(r'\bо\s+ней\b', caseSensitive: false), 'о \$s'),
    _CommandPattern(
        RegExp(r'\bеё\s+цен[аыуе]?\b', caseSensitive: false), 'цена \$s'),
    _CommandPattern(
        RegExp(r'\bкакая\s+у\s+неё\s+цен[аыуе]?\b', caseSensitive: false),
        'какая цена \$s'),
    _CommandPattern(RegExp(r'\bсколько\s+она\s+стоит\b', caseSensitive: false),
        'сколько стоит \$s'),
    // Russian: "купи её" → "купи MOVR"
    _CommandPattern(RegExp(r'\bкупи\s+её\b', caseSensitive: false), 'купи \$s'),
    _CommandPattern(
        RegExp(r'\bпродай\s+её\b', caseSensitive: false), 'продай \$s'),
    _CommandPattern(RegExp(r'\bрасскажи\s+про\s+неё\b', caseSensitive: false),
        'расскажи про \$s'),
    _CommandPattern(RegExp(r'\bкак\s+она\b', caseSensitive: false), 'как \$s'),
    _CommandPattern(
        RegExp(r'\bчто\s+с\s+ней\b', caseSensitive: false), 'что с \$s'),
    _CommandPattern(
        RegExp(r'\bпочему\s+она\b', caseSensitive: false), 'почему \$s'),
    // English question patterns
    _CommandPattern(
        RegExp(r'\bwhat\s+is\s+this\s+coin\b', caseSensitive: false),
        'what is \$s'),
    _CommandPattern(
        RegExp(r'\bwhat\s+coin\s+is\s+this\b', caseSensitive: false),
        'what is \$s'),
    _CommandPattern(
        RegExp(r'\bwhy\s+is\s+it\s+dropping\b', caseSensitive: false),
        'why is \$s dropping'),
    _CommandPattern(RegExp(r'\bwhat\s+about\s+it\b', caseSensitive: false),
        'what about \$s'),
    // English: "buy it" → "buy MOVR"
    _CommandPattern(RegExp(r'\bbuy\s+it\b', caseSensitive: false), 'buy \$s'),
    _CommandPattern(RegExp(r'\bsell\s+it\b', caseSensitive: false), 'sell \$s'),
    _CommandPattern(RegExp(r'\btell\s+me\s+about\s+it\b', caseSensitive: false),
        'tell me about \$s'),
    _CommandPattern(
        RegExp(r'\babout\s+it\b', caseSensitive: false), 'about \$s'),
  ];

  /// Replaces pronoun references with the actual focused symbol.
  ///
  /// Returns [input] unchanged if no symbol is focused or no pattern matches.
  static String resolve(String input) {
    final ctx = ScreenContextService.instance;
    final symbol = ctx.focusedSymbol;
    if (symbol == null) return input;

    String result = input;

    // First pass: command patterns (verb + pronoun → verb + SYMBOL)
    for (final cmd in _commandPatterns) {
      result = result.replaceAll(
          cmd.pattern, cmd.template.replaceAll('\$s', symbol));
    }

    // Second pass: pure pronoun patterns (noun phrase → SYMBOL)
    for (final pattern in _purePatterns) {
      result = result.replaceAll(pattern, symbol);
    }

    return result;
  }

  /// Returns true if the input contains pronoun references that would be
  /// resolved. Useful for logging.
  static bool containsPronouns(String input) {
    if (_purePatterns.any((p) => p.hasMatch(input))) return true;
    if (_commandPatterns.any((c) => c.pattern.hasMatch(input))) return true;
    return false;
  }
}

/// Internal helper pairing a regex with its replacement template.
class _CommandPattern {
  final RegExp pattern;
  final String template; // Use $s as placeholder for symbol.
  const _CommandPattern(this.pattern, this.template);
}
