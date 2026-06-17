import 'package:ibiti_guardian/models/intent_data.dart';

/// Deterministic intent parser. Zero AI, zero ML.
/// Maps natural language patterns to structured [IntentData] using regex + keywords.
class IntentParser {
  IntentParser._();

  // --- Regex patterns -----------------------------------------------------------

  /// Matches: "send 20 usdt to 0x1234..."
  static final _sendPattern = RegExp(
    r'send\s+([\d.]+)\s+([a-zA-Z0-9]+)\s+to(?:\s+address|\s+contract)?\s+(0x[a-fA-F0-9]{4,42})',
    caseSensitive: false,
  );

  /// Matches: "send 20 usdt" (no address)
  static final _sendNoAddressPattern = RegExp(
    r'send\s+([\d.]+)\s+([a-zA-Z0-9]+)',
    caseSensitive: false,
  );

  static final _sendTokenToAddressPattern = RegExp(
    r'send\s+([a-zA-Z0-9]+)\s+to(?:\s+address|\s+contract)?\s+(0x[a-fA-F0-9]{4,42})',
    caseSensitive: false,
  );

  static final _sendRuPattern = RegExp(
    r'отправ[^\d]*([\d.]+)\s+([a-zA-Z0-9а-яА-Я]+)\s+(?:на|to)(?:\s+адрес|\s+контракт)?\s+(0x[a-fA-F0-9]{4,42})',
    caseSensitive: false,
  );

  static final _sendRuTokenToAddressPattern = RegExp(
    r'отправ[^\w]*([a-zA-Z0-9а-яА-Я]+)\s+(?:на|to)(?:\s+адрес|\s+контракт)?\s+(0x[a-fA-F0-9]{4,42})',
    caseSensitive: false,
  );

  /// Matches: "отправь 10 USDT" (no address)
  static final _sendRuNoAddressPattern = RegExp(
    r'отправ[^\d]*([\d.,]+)\s+([a-zA-Z0-9а-яА-Я]+)',
    caseSensitive: false,
  );

  /// Matches: "отправь USDT" (token only, no amount, no address)
  static final _sendRuTokenOnlyPattern = RegExp(
    r'отправ\w*\s+([a-zA-Z0-9]{2,10})\b',
    caseSensitive: false,
  );

  /// Matches bare "отправь" / "отправить" without any params
  static final _sendRuIncompletePattern = RegExp(
    r'\bотправ',
    caseSensitive: false,
  );

  static final _swapPattern = RegExp(
    r'swap\s+([\d.]+)\s+([a-zA-Z0-9]+)\s+(?:to|for)\s+([a-zA-Z0-9]+)',
    caseSensitive: false,
  );

  static final _swapAmountAtEndPattern = RegExp(
    r'swap\s+([a-zA-Z0-9]+)\s+(?:to|for)\s+([a-zA-Z0-9]+)\s+for\s+([\d.]+)',
    caseSensitive: false,
  );

  static final _swapNoAmountPattern = RegExp(
    r'swap\s+([a-zA-Z0-9]+)\s+(?:to|for)\s+([a-zA-Z0-9]+)',
    caseSensitive: false,
  );

  static final _swapRuPattern = RegExp(
    r'(?:обменяй|поменяй|свапни|свапнуть)\s+([\d.]+)\s+([a-zA-Z0-9а-яА-Я]+)\s+(?:на|to)\s+([a-zA-Z0-9а-яА-Я]+)',
    caseSensitive: false,
  );

  static final _swapRuAmountAtEndPattern = RegExp(
    r'(?:обменяй|поменяй|свапни|свапнуть)\s+([a-zA-Z0-9а-яА-Я]+)\s+(?:на|to)\s+([a-zA-Z0-9а-яА-Я]+)\s+на\s+([\d.]+)',
    caseSensitive: false,
  );

  static final _swapRuNoAmountPattern = RegExp(
    r'(?:обменяй|поменяй|свапни|свапнуть)\s+([a-zA-Z0-9а-яА-Я]+)\s+(?:на|to)\s+([a-zA-Z0-9а-яА-Я]+)',
    caseSensitive: false,
  );

  // --- Buy Spot Patterns ---
  static final _buyTokenForAmountPattern = RegExp(
    r'(?:buy|купи|купить|возьми)\s+(this\s+coin|эту\s+монету|[a-zA-Z0-9]+)\s+(?:for|на)\s+([\d.,]+)',
    caseSensitive: false,
  );

  static final _buyAmountTokenPattern = RegExp(
    r'(?:buy|купи|купить|возьми)\s+([\d.,]+)\s+(this\s+coin|эту\s+монету|[a-zA-Z0-9]+)',
    caseSensitive: false,
  );

  static final _buyTokenOnlyPattern = RegExp(
    r'(?:buy|купи|купить|возьми)\s+(this\s+coin|эту\s+монету|[a-zA-Z0-9]+)',
    caseSensitive: false,
  );

  // --- Sell Spot Patterns ---
  static final _sellAllPattern = RegExp(
    r'(?:sell|продай|продать|слей)\s+(?:all|всё|все|100%)\s+(this\s+coin|эту\s+монету|[a-zA-Z0-9]+)',
    caseSensitive: false,
  );

  static final _sellPercentPattern = RegExp(
    r'(?:sell|продай|продать|слей)\s+([\d.,]+)%\s+(this\s+coin|эту\s+монету|[a-zA-Z0-9]+)',
    caseSensitive: false,
  );

  static final _sellTokenForAmountPattern = RegExp(
    r'(?:sell|продай|продать|слей)\s+(this\s+coin|эту\s+монету|[a-zA-Z0-9]+)\s+(?:for|на|за)\s+([\d.,]+)',
    caseSensitive: false,
  );

  static final _sellAmountTokenPattern = RegExp(
    r'(?:sell|продай|продать|слей)\s+([\d.,]+)\s+(this\s+coin|эту\s+монету|[a-zA-Z0-9]+)',
    caseSensitive: false,
  );

  static final _sellTokenOnlyPattern = RegExp(
    r'(?:sell|продай|продать|слей)\s+(this\s+coin|эту\s+монету|[a-zA-Z0-9]+)',
    caseSensitive: false,
  );

  /// Matches: "send usdt" or "send 20" (incomplete)
  static final _sendIncompletePattern = RegExp(
    r'\bsend\b',
    caseSensitive: false,
  );

  // ── "Open send window" keywords ─────────────────────────────────────────
  static const _sendOpenKeywords = [
    // RU
    'открой отправку',
    'открой окно отправки',
    'окно отправки',
    'окно для отправки',
    'подготовь отправку',
    'подготовь окно для отправки',
    'хочу отправить',
    'отправить токены',
    'отправить крипту',
    'отправь токены',
    'отправь крипту',
    'отправь монеты',
    // EN
    'open send',
    'send window',
    'i want to send',
    'send tokens',
    'send crypto',
  ];

  // ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

  static const _balanceKeywords = [
    // EN — explicit phrases only (no single words)
    'show balance',
    'my balance',
    'check balance',
    'show my balance',
    'what do i have',
    'my funds',
    'how much do i have',
    'how much money',
    'what is my balance',
    // RU — explicit phrases only
    'мой баланс',
    'покажи баланс',
    'проверь баланс',
    'баланс кошелька',
    'баланс на кошельке',
    'сколько денег',
    'сколько usdt',
    'сколько у меня на балансе',
    'что у меня на балансе',
    'что на балансе',
    'покажи активы',
    'мои активы',
    'мой портфель',
    'покажи портфель',
  ];

  static const _riskKeywords = [
    'show risks',
    'check risks',
    'any risks',
    'risk scan',
    'dangerous approvals',
    'risky approvals',
    'vulnerability scan',
    'покажи риски',
    'есть ли риски',
    'есть риски',
    'проверь риски',
    'опасные разрешения',
    'подозрительные разрешения',
  ];

  static const _scanKeywords = [
    'scan wallet',
    'scan approvals',
    'check approvals',
    'check approval',
    'audit wallet',
    'audit approvals',
    'analyze approvals',
    'inspect approvals',
    'сканируй кошелёк',
    'сканируй кошелек',
    'сканируй разрешения',
    'проверь разрешения',
    'проверь контракты',
    'проверка разрешений',
    'аудит кошелька',
    'аудит разрешений',
  ];

  static const _revokeKeywords = [
    'revoke',
    'remove approval',
    'cancel approval',
    'delete approval',
    'clear approval',
    'отзови',
    'отзыв',
    'ревок',
    'убери разрешение',
    'отмени разрешение',
  ];

  static const _addressKeywords = [
    'my address',
    'wallet address',
    'what is my address',
    'show address',
    'show my address',
    'мой адрес',
    'адрес кошелька',
    'покажи адрес',
    'покажи мой адрес',
  ];

  static const _receiveKeywords = [
    'receive crypto',
    'receive tokens',
    'receive funds',
    'deposit crypto',
    'deposit tokens',
    'получить крипту',
    'получить токены',
    'хочу получить',
    'как получить',
  ];

  static const _historyKeywords = [
    'transaction history',
    'show history',
    'my history',
    'recent transactions',
    'история транзакций',
    'история операций',
    'покажи историю',
    'мои операции',
    'мои транзакции',
    'последние операции',
  ];

  static const _addressBookKeywords = [
    'address book',
    'contact list',
    'my contacts',
    'show contacts',
    'адресная книга',
    'мои контакты',
    'покажи контакты',
    'список контактов',
  ];

  static const _walletSettingsKeywords = [
    'wallet settings',
    'settings wallet',
    'настройки кошелька',
  ];

  static final _walletCardsPattern = RegExp(
    r'(сколько|какие)\s+(у\s+(нас|меня)\s+)?(карт|карточ)|карта\s+(пустая|основная)|(мои|покажи|список)\s+(карты|карточ)|на\s+какой\s+карте|баланс\s+карты|статус\s+карты|карт\s+создано|cards?|card\s+(count|balance|status)|which\s+card|how\s+many\s+(cards|wallets)',
    caseSensitive: false,
  );

  static const _marketKeywords = [
    'open market',
    'show market',
    'go to market',
    'открой рынок',
    'покажи рынок',
    'перейди на рынок',
  ];

  static const _securityCenterKeywords = [
    'security center',
    'open security',
    'центр безопасности',
    'открой безопасность',
    'открой центр безопасности',
  ];

  // в”Ђв”Ђв”Ђ Main parse method в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  /// Parse raw user [input] into a structured [IntentData].
  static IntentData parse(String input) {
    final normalized = input.trim().toLowerCase();

    // --- CEX Buy / Sell Spot Intents ---
    final buyTokenForAmountMatch = _buyTokenForAmountPattern.firstMatch(input);
    if (buyTokenForAmountMatch != null) {
      final token = buyTokenForAmountMatch.group(1);
      final amount = double.tryParse((buyTokenForAmountMatch.group(2) ?? '').replaceAll(',', '.'));
      return IntentData(
        type: IntentType.buyAsset,
        rawInput: input,
        tokenSymbol: token,
        amount: amount,
        isQuantity: false,
      );
    }

    final buyAmountTokenMatch = _buyAmountTokenPattern.firstMatch(input);
    if (buyAmountTokenMatch != null) {
      final amount = double.tryParse((buyAmountTokenMatch.group(1) ?? '').replaceAll(',', '.'));
      final token = buyAmountTokenMatch.group(2);
      return IntentData(
        type: IntentType.buyAsset,
        rawInput: input,
        tokenSymbol: token,
        amount: amount,
        isQuantity: true,
      );
    }

    final buyTokenOnlyMatch = _buyTokenOnlyPattern.firstMatch(input);
    if (buyTokenOnlyMatch != null) {
      final token = buyTokenOnlyMatch.group(1);
      return IntentData(
        type: IntentType.buyAsset,
        rawInput: input,
        tokenSymbol: token,
        amount: null,
        isQuantity: false,
      );
    }

    final sellAllMatch = _sellAllPattern.firstMatch(input);
    if (sellAllMatch != null) {
      final token = sellAllMatch.group(1);
      return IntentData(
        type: IntentType.sellAsset,
        rawInput: input,
        tokenSymbol: token,
        amount: -1.0,
        isQuantity: true,
      );
    }

    final sellPercentMatch = _sellPercentPattern.firstMatch(input);
    if (sellPercentMatch != null) {
      final pctStr = sellPercentMatch.group(1)?.replaceAll(',', '.');
      final pctVal = pctStr != null ? double.tryParse(pctStr) : null;
      final amount = pctVal != null ? -(pctVal / 100.0) : null;
      final token = sellPercentMatch.group(2);
      return IntentData(
        type: IntentType.sellAsset,
        rawInput: input,
        tokenSymbol: token,
        amount: amount,
        isQuantity: true,
      );
    }

    final sellTokenForAmountMatch = _sellTokenForAmountPattern.firstMatch(input);
    if (sellTokenForAmountMatch != null) {
      final token = sellTokenForAmountMatch.group(1);
      final amount = double.tryParse((sellTokenForAmountMatch.group(2) ?? '').replaceAll(',', '.'));
      return IntentData(
        type: IntentType.sellAsset,
        rawInput: input,
        tokenSymbol: token,
        amount: amount,
        isQuantity: false,
      );
    }

    final sellAmountTokenMatch = _sellAmountTokenPattern.firstMatch(input);
    if (sellAmountTokenMatch != null) {
      final amount = double.tryParse((sellAmountTokenMatch.group(1) ?? '').replaceAll(',', '.'));
      final token = sellAmountTokenMatch.group(2);
      return IntentData(
        type: IntentType.sellAsset,
        rawInput: input,
        tokenSymbol: token,
        amount: amount,
        isQuantity: true,
      );
    }

    final sellTokenOnlyMatch = _sellTokenOnlyPattern.firstMatch(input);
    if (sellTokenOnlyMatch != null) {
      final token = sellTokenOnlyMatch.group(1);
      return IntentData(
        type: IntentType.sellAsset,
        rawInput: input,
        tokenSymbol: token,
        amount: null,
        isQuantity: false,
      );
    }

    // 1. Send with full params: amount + token + address
    final sendMatch = _sendPattern.firstMatch(input);
    if (sendMatch != null) {
      final amount =
          double.tryParse((sendMatch.group(1) ?? '').replaceAll(',', '.'));
      final token = sendMatch.group(2)?.toUpperCase();
      final address = sendMatch.group(3);
      return IntentData(
        type: IntentType.sendAsset,
        rawInput: input,
        amount: amount,
        tokenSymbol: token,
        toAddress: address,
      );
    }

    final sendRuMatch = _sendRuPattern.firstMatch(input);
    if (sendRuMatch != null) {
      final amount =
          double.tryParse((sendRuMatch.group(1) ?? '').replaceAll(',', '.'));
      final token = sendRuMatch.group(2)?.toUpperCase();
      final address = sendRuMatch.group(3);
      return IntentData(
        type: IntentType.sendAsset,
        rawInput: input,
        amount: amount,
        tokenSymbol: token,
        toAddress: address,
      );
    }

    final sendTokenToAddressMatch =
        _sendTokenToAddressPattern.firstMatch(input);
    if (sendTokenToAddressMatch != null) {
      return IntentData(
        type: IntentType.sendAsset,
        rawInput: input,
        tokenSymbol: sendTokenToAddressMatch.group(1)?.toUpperCase(),
        toAddress: sendTokenToAddressMatch.group(2),
      );
    }

    final sendRuTokenToAddressMatch =
        _sendRuTokenToAddressPattern.firstMatch(input);
    if (sendRuTokenToAddressMatch != null) {
      return IntentData(
        type: IntentType.sendAsset,
        rawInput: input,
        tokenSymbol: sendRuTokenToAddressMatch.group(1)?.toUpperCase(),
        toAddress: sendRuTokenToAddressMatch.group(2),
      );
    }

    final swapMatch = _swapPattern.firstMatch(input);
    if (swapMatch != null) {
      return IntentData(
        type: IntentType.swapAsset,
        rawInput: input,
        amount:
            double.tryParse((swapMatch.group(1) ?? '').replaceAll(',', '.')),
        sourceTokenSymbol: swapMatch.group(2)?.toUpperCase(),
        targetTokenSymbol: swapMatch.group(3)?.toUpperCase(),
      );
    }

    final swapRuMatch = _swapRuPattern.firstMatch(input);
    if (swapRuMatch != null) {
      return IntentData(
        type: IntentType.swapAsset,
        rawInput: input,
        amount:
            double.tryParse((swapRuMatch.group(1) ?? '').replaceAll(',', '.')),
        sourceTokenSymbol: swapRuMatch.group(2)?.toUpperCase(),
        targetTokenSymbol: swapRuMatch.group(3)?.toUpperCase(),
      );
    }

    final swapAmountAtEndMatch = _swapAmountAtEndPattern.firstMatch(input);
    if (swapAmountAtEndMatch != null) {
      return IntentData(
        type: IntentType.swapAsset,
        rawInput: input,
        sourceTokenSymbol: swapAmountAtEndMatch.group(1)?.toUpperCase(),
        targetTokenSymbol: swapAmountAtEndMatch.group(2)?.toUpperCase(),
        amount:
            double.tryParse((swapAmountAtEndMatch.group(3) ?? '').replaceAll(',', '.')),
      );
    }

    final swapRuAmountAtEndMatch = _swapRuAmountAtEndPattern.firstMatch(input);
    if (swapRuAmountAtEndMatch != null) {
      return IntentData(
        type: IntentType.swapAsset,
        rawInput: input,
        sourceTokenSymbol: swapRuAmountAtEndMatch.group(1)?.toUpperCase(),
        targetTokenSymbol: swapRuAmountAtEndMatch.group(2)?.toUpperCase(),
        amount:
            double.tryParse((swapRuAmountAtEndMatch.group(3) ?? '').replaceAll(',', '.')),
      );
    }

    final swapNoAmountMatch = _swapNoAmountPattern.firstMatch(input);
    if (swapNoAmountMatch != null) {
      return IntentData(
        type: IntentType.swapAsset,
        rawInput: input,
        sourceTokenSymbol: swapNoAmountMatch.group(1)?.toUpperCase(),
        targetTokenSymbol: swapNoAmountMatch.group(2)?.toUpperCase(),
      );
    }

    final swapRuNoAmountMatch = _swapRuNoAmountPattern.firstMatch(input);
    if (swapRuNoAmountMatch != null) {
      return IntentData(
        type: IntentType.swapAsset,
        rawInput: input,
        sourceTokenSymbol: swapRuNoAmountMatch.group(1)?.toUpperCase(),
        targetTokenSymbol: swapRuNoAmountMatch.group(2)?.toUpperCase(),
      );
    }

    // 2. Send with amount + token but no address
    final sendNoAddr = _sendNoAddressPattern.firstMatch(input);
    if (sendNoAddr != null) {
      final amount =
          double.tryParse((sendNoAddr.group(1) ?? '').replaceAll(',', '.'));
      final token = sendNoAddr.group(2)?.toUpperCase();
      return IntentData(
        type: IntentType.sendAsset,
        rawInput: input,
        amount: amount,
        tokenSymbol: token,
        toAddress: null, // missing — will be caught by policy
      );
    }

    // 2b. Russian send with amount + token but no address
    final sendRuNoAddr = _sendRuNoAddressPattern.firstMatch(input);
    if (sendRuNoAddr != null) {
      final rawAmt = (sendRuNoAddr.group(1) ?? '').replaceAll(',', '.');
      final amount = double.tryParse(rawAmt);
      final token = sendRuNoAddr.group(2)?.toUpperCase();
      return IntentData(
        type: IntentType.sendAsset,
        rawInput: input,
        amount: amount,
        tokenSymbol: token,
        toAddress: null,
      );
    }

    // 2c. Russian send with token only (no amount, no address)
    final sendRuTokenOnly = _sendRuTokenOnlyPattern.firstMatch(input);
    if (sendRuTokenOnly != null) {
      final token = sendRuTokenOnly.group(1)?.toUpperCase();
      return IntentData(
        type: IntentType.sendAsset,
        rawInput: input,
        tokenSymbol: token,
        toAddress: null,
      );
    }

    // 2d. "Open send window" keywords (RU/EN) — no specific token
    if (_containsAny(normalized, _sendOpenKeywords)) {
      return IntentData(
        type: IntentType.sendAsset,
        rawInput: input,
        // all fields null — process() will open modal and prompt user
      );
    }

    // 3. Send keyword without enough info (EN or RU)
    if (_sendIncompletePattern.hasMatch(normalized) ||
        _sendRuIncompletePattern.hasMatch(normalized)) {
      return IntentData(
        type: IntentType.sendAsset,
        rawInput: input,
        // all fields null — policy will block with helpful message
      );
    }

    // 4. Revoke keywords
    if (_containsAny(normalized, _revokeKeywords)) {
      return IntentData(type: IntentType.revokeApproval, rawInput: input);
    }

    // 5. Show risks
    if (_containsAny(normalized, _riskKeywords)) {
      return IntentData(type: IntentType.showRisks, rawInput: input);
    }

    // 6. Scan approvals
    if (_containsAny(normalized, _scanKeywords)) {
      return IntentData(type: IntentType.scanApprovals, rawInput: input);
    }

    // 7a. Wallet cards (MUST be checked BEFORE balance to prevent fallthrough)
    if (_walletCardsPattern.hasMatch(normalized)) {
      return IntentData(type: IntentType.showWalletCards, rawInput: input);
    }

    // 7. Show balances
    if (_containsAny(normalized, _balanceKeywords)) {
      return IntentData(type: IntentType.showBalances, rawInput: input);
    }

    // 8. Show address
    if (_containsAny(normalized, _addressKeywords)) {
      return IntentData(type: IntentType.showAddress, rawInput: input);
    }

    if (_containsAny(normalized, _receiveKeywords)) {
      return IntentData(type: IntentType.receiveAsset, rawInput: input);
    }

    if (_containsAny(normalized, _historyKeywords)) {
      return IntentData(type: IntentType.showHistory, rawInput: input);
    }

    if (_containsAny(normalized, _addressBookKeywords)) {
      return IntentData(type: IntentType.openAddressBook, rawInput: input);
    }

    if (_containsAny(normalized, _walletSettingsKeywords)) {
      return IntentData(type: IntentType.openWalletSettings, rawInput: input);
    }

    if (_containsAny(normalized, _marketKeywords)) {
      return IntentData(type: IntentType.openMarket, rawInput: input);
    }

    if (_containsAny(normalized, _securityCenterKeywords)) {
      return IntentData(type: IntentType.openSecurityCenter, rawInput: input);
    }

    // 9. Unknown
    return IntentData(type: IntentType.unknown, rawInput: input);
  }

  // в”Ђв”Ђв”Ђ Helpers в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  static bool _containsAny(String text, List<String> keywords) {
    return keywords.any((kw) => text.contains(kw));
  }

  static double? extractAmount(String input) {
    // 0. Pre-parse common Russian/English word-number fiat patterns
    final lowerInput = input.toLowerCase();
    final wordNumbersMap = {
      // Russian
      'один': 1.0, 'одна': 1.0, 'одно': 1.0,
      'два': 2.0, 'две': 2.0,
      'три': 3.0, 'четыре': 4.0,
      'пять': 5.0, 'шесть': 6.0, 'семь': 7.0, 'восемь': 8.0, 'девять': 9.0,
      'десять': 10.0, 'двадцать': 20.0, 'тридцать': 30.0, 'сорок': 40.0,
      'пятьдесят': 50.0, 'сто': 100.0, 'тысяча': 1000.0, 'тысячу': 1000.0,
      // English
      'one': 1.0, 'two': 2.0, 'three': 3.0, 'four': 4.0, 'five': 5.0,
      'six': 6.0, 'seven': 7.0, 'eight': 8.0, 'nine': 9.0, 'ten': 10.0,
      'twenty': 20.0, 'thirty': 30.0, 'forty': 40.0, 'fifty': 50.0,
      'hundred': 100.0, 'thousand': 1000.0,
    };

    for (final entry in wordNumbersMap.entries) {
      final numWord = entry.key;
      final value = entry.value;
      final pattern = RegExp('(?:$numWord\\s*(?:доллар|долар|долл|дол|бакс|бак|usd|dollar|buck)|(?:на|за|for)\\s+$numWord)');
      if (pattern.hasMatch(lowerInput)) {
        return value;
      }
    }

    // 1. Normalize commas between digits to dots
    String lower = input.replaceAllMapped(
      RegExp(r'(\d+),(\d+)'),
      (match) => '${match.group(1)}.${match.group(2)}',
    ).toLowerCase();

    // 2. Specialized word phrases for "half a dollar/buck" or "one and a half"
    if (lower.contains('полдоллара') ||
        lower.contains('пол доллара') ||
        lower.contains('полбакса') ||
        lower.contains('пол бакса') ||
        lower.contains('пол-бакса') ||
        lower.contains('пол-доллара')) {
      return 0.50;
    }
    if (lower.contains('полтора доллара') ||
        lower.contains('полтора бакса') ||
        lower.contains('полтора косаря')) {
      return 1.50;
    }

    final hasCents = lower.contains('цент') ||
        lower.contains('копее') ||
        lower.contains('копей') ||
        lower.contains('cent');

    if (hasCents) {
      // Check for numeric digit before cents
      final centDigitMatch = RegExp(r'(\d+(?:\.\d+)?)\s*(?:цент|копее|копей|cent)').firstMatch(lower);
      if (centDigitMatch != null) {
        final val = double.tryParse(centDigitMatch.group(1) ?? '');
        if (val != null) {
          return val >= 1.0 ? val / 100.0 : val;
        }
      }

      // Check for word numbers before cents
      final wordMap = {
        'девяносто': 90, 'восемьдесят': 80, 'семьдесят': 70, 'шестьдесят': 60,
        'пятьдесят': 50, 'сорок': 40, 'тридцать': 30, 'двадцать': 20,
        'девятнадцать': 19, 'восемнадцать': 18, 'семнадцать': 17, 'шестнадцать': 16,
        'пятнадцать': 15, 'четырнадцать': 14, 'тринадцать': 13, 'двенадцать': 12,
        'одиннадцать': 11, 'десять': 10,
        'девять': 9, 'восемь': 8, 'семь': 7, 'шесть': 6, 'пять': 5,
        'четыре': 4, 'три': 3, 'два': 2, 'один': 1, 'одна': 1,
      };

      final centIndex = lower.indexOf(RegExp(r'(?:цент|копее|копей|cent)'));
      if (centIndex != -1) {
        final beforeCents = lower.substring(0, centIndex).trim();
        final words = beforeCents.split(RegExp(r'\s+'));
        double wordSum = 0.0;
        int matchedCount = 0;
        
        if (words.isNotEmpty) {
          final lastWord = words.last;
          if (wordMap.containsKey(lastWord)) {
            wordSum += wordMap[lastWord]!;
            matchedCount++;
            
            if (words.length > 1) {
              final secondLastWord = words[words.length - 2];
              if (wordMap.containsKey(secondLastWord)) {
                wordSum += wordMap[secondLastWord]!;
                matchedCount++;
              }
            }
          }
        }
        if (matchedCount > 0) {
          return wordSum / 100.0;
        }
      }
    }

    // 5. Standard dollar pattern: "$50" or "50$"
    final dollarMatch = RegExp(r'\$\s*(\d+(?:\.\d+)?)|(\d+(?:\.\d+)?)\s*\$').firstMatch(lower);
    if (dollarMatch != null) {
      final val = dollarMatch.group(1) ?? dollarMatch.group(2);
      if (val != null) return double.tryParse(val);
    }

    // 6. Pattern: "на/за 50" / "на/за 0.50"
    final prepMatch = RegExp(r'(?:на|за|for)\s+(\d+(?:\.\d+)?)\s*(?:долл|дол|бак|usd|dollar|buck)?').firstMatch(lower);
    if (prepMatch != null) {
      return double.tryParse(prepMatch.group(1) ?? '');
    }

    // 7. Pattern: "50 usdt" / "100 usdc"
    final stableMatch = RegExp(r'(\d+(?:\.\d+)?)\s*(?:usdt|usdc|busd|dai)').firstMatch(lower);
    if (stableMatch != null) {
      return double.tryParse(stableMatch.group(1) ?? '');
    }

    // 8. General number fallback: look for any double/int
    final anyNumMatch = RegExp(r'\b(\d+(?:\.\d+)?)\b').firstMatch(lower);
    if (anyNumMatch != null) {
      return double.tryParse(anyNumMatch.group(1) ?? '');
    }

    return null;
  }
}
