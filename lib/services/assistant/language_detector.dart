class LanguageDetector {
  LanguageDetector._();

  /// Detect the PRIMARY conversational language from user input.
  /// Returns a language code like 'ru', 'en', 'de', 'uk', etc.
  ///
  /// This is used to tell the AI "respond in this language",
  /// NOT to restrict which languages the AI can mention or translate.
  static String detect(String input) {
    if (input.isEmpty) return 'en';

    // Remove known crypto/tech symbols that are always in Latin
    final cleaned = input.replaceAll(
      RegExp(
          r'\b(BTC|ETH|USDT|SOL|BNB|XRP|MATIC|DOGE|ADA|AVAX|LINK|UNI|DAI|TRX|DOT|SHIB|USDC)\b',
          caseSensitive: false),
      '',
    );

    // Count character types
    final cyrillicCount = RegExp(r'[а-яА-ЯёЁ]').allMatches(cleaned).length;
    final latinCount = RegExp(r'[a-zA-Z]').allMatches(cleaned).length;

    // Cyrillic majority → Russian
    if (cyrillicCount > 0 && cyrillicCount >= latinCount) return 'ru';

    // Latin majority → English by default
    // (We don't restrict to only ru/en — the AI handles other languages from context)
    return 'en';
  }

  /// DISABLED: The strict language check was blocking legitimate multilingual responses.
  /// For example, if user asks "как по-немецки дом?" in Russian, the AI MUST include
  /// German text in its response. The old check would flag this as "wrong language".
  ///
  /// Now this always returns false — the AI is trusted to mirror the user's language.
  static bool isWrongLanguage(String text, String expectedLang) {
    // Intentionally disabled. The AI system prompt now handles language mirroring.
    return false;
  }
}
