import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/intents/intent_parser.dart';

/// Local helper class that processes voice trading intents with slang and context.
class MarketVoiceBrain {
  MarketVoiceBrain._();

  static const _assetAliases = <String, String>{
    'биток': 'BTC',
    'биткоин': 'BTC',
    'bitcoin': 'BTC',
    'эфир': 'ETH',
    'эфириум': 'ETH',
    'ethereum': 'ETH',
    'бнб': 'BNB',
    'солана': 'SOL',
    'solana': 'SOL',
    'usdt': 'USDT',
    'тезер': 'USDT',
    'tether': 'USDT',
    'usdc': 'USDC',
    'юсдк': 'USDC',
    'busd': 'BUSD',
    'wbnb': 'WBNB',
    'соль': 'SOL',
    'кефир': 'ETH',
    'рипл': 'XRP',
    'доги': 'DOGE',
  };

  /// Sanitizes input: removes common Russian/English profanity and filler words.
  static String sanitize(String input) {
    String lower = input.toLowerCase().trim();
    
    // Clean punctuation except decimals
    lower = lower.replaceAll(RegExp(r'(?<!\d)[.,]|[.,](?!\d)'), ' ');
    lower = lower.replaceAll(RegExp(r'[!?]'), ' ');
    // Clean multiple spaces
    lower = lower.replaceAll(RegExp(r'\s+'), ' ').trim();
    return lower;
  }

  /// Checks if a string is a valid token symbol in cached markets, aliases, or active portfolio.
  static bool isValidToken(String token) {
    // Check alias map keys
    if (_assetAliases.containsKey(token.toLowerCase())) return true;

    final t = token.toUpperCase();
    
    // Check focusedSymbol
    final focused = ScreenContextService.instance.focusedSymbol;
    if (focused != null && focused.toUpperCase() == t) return true;
    
    // Check alias map values
    if (_assetAliases.values.contains(t)) return true;
    
    // Check cached markets
    final markets = MarketDataService.instance.cachedMarkets;
    for (final m in markets) {
      if (m.symbol.toUpperCase() == t) return true;
    }
    
    // Check wallet portfolio assets
    final summary = VaultPortfolioListener.instance.summary;
    final walletAssets = summary?.allAssets ?? const [];
    for (final a in walletAssets) {
      if (a.symbol.toUpperCase() == t) return true;
    }
    
    return false;
  }

  /// Resolves voice buy/sell trade commands using local heuristics.
  /// Returns [IntentData] if a trade intent is confidently detected, or null otherwise.
  static IntentData? parseTradeIntent(String input) {
    final sanitized = sanitize(input);
    if (sanitized.isEmpty) return null;

    final words = sanitized.split(' ');
    
    final buyKeywords = ['купи', 'купить', 'возьми', 'взять', 'buy'];
    final sellKeywords = ['продай', 'продать', 'слей', 'слить', 'sell', 'dump'];

    bool isBuy = false;
    bool isSell = false;
    
    for (final word in words) {
      if (buyKeywords.any((k) => word == k || word.startsWith(k))) {
        isBuy = true;
      }
      if (sellKeywords.any((k) => word == k || word.startsWith(k))) {
        isSell = true;
      }
    }

    if (!isBuy && !isSell) {
      return null;
    }

    final IntentType type = isBuy ? IntentType.buyAsset : IntentType.sellAsset;
    String? symbol;

    // 1. Resolve token symbol
    // Explicit token/alias from user must override focusedSymbol.
    // Look for aliases first
    for (final alias in _assetAliases.keys) {
      if (words.contains(alias)) {
        symbol = _assetAliases[alias];
        break;
      }
    }

    if (symbol == null) {
      // Look for valid tokens in the input words
      for (final word in words) {
        if (isValidToken(word)) {
          symbol = word.toUpperCase();
          break;
        }
      }
    }

    if (symbol == null) {
      // Current-token detection must not use raw contains('it'). Use token/phrase boundaries.
      final refersToCurrent = words.contains('it') ||
          words.contains('эту') ||
          words.contains('её') ||
          words.contains('here') ||
          words.contains('сюда') ||
          words.contains('монету') ||
          words.contains('монета') ||
          words.contains('токен') ||
          words.contains('токена') ||
          words.contains('коин') ||
          words.contains('коина') ||
          words.contains('coin') ||
          words.contains('token') ||
          sanitized.contains('this coin') ||
          sanitized.contains('this token') ||
          sanitized.contains('эту монету');
      if (refersToCurrent) {
        symbol = ScreenContextService.instance.focusedSymbol;
      }
    }

    // Check if the input contains an explicit but invalid/unknown token symbol
    bool hasInvalidSymbol = false;
    final nonSymbolWords = {
      // Verbs / commands
      'купи', 'купить', 'возьми', 'взять', 'buy',
      'продай', 'продать', 'слей', 'слить', 'sell', 'dump',
      'хочу', 'надо', 'нужно',
      // Prepositions / conjunctions
      'на', 'за', 'в', 'во', 'для', 'по', 'с', 'со', 'и', 'а', 'но', 'или',
      'for', 'to', 'the', 'a', 'an', 'of', 'at', 'in', 'on',
      // Pronouns / token nouns
      'эту', 'это', 'этот', 'эти', 'монету', 'монета', 'монеты', 'монет',
      'монетку', 'монетка', 'монетку', 'токен', 'токены', 'токенов', 'токена',
      'крипту', 'крипта', 'крипты', 'коин', 'коины', 'коина',
      'её', 'его', 'их', 'it', 'this', 'coin', 'token', 'here', 'сюда',
      'мне', 'нам', 'себе', 'я',
      // Slang amounts / currencies
      'полбакса', 'полдоллара', 'полтора', 'косарь', 'косарик', 'десятку', 'десятка', 'сотку', 'сотка',
      'долларов', 'доллара', 'доллар', 'доллары', 'долар', 'долара', 'доларов', 'долары', 'бакс', 'баксов', 'бакса', 'баксы',
      'центов', 'центы', 'цент', 'копеек', 'копейки', 'копейка',
      'cents', 'cent', 'dollars', 'dollar',
      // Filler words
      'чуть-чуть', 'чуть', 'немного', 'немножко', 'few', 'some', 'little', 'bit',
      'пол', 'пожалуйста', 'давай', 'тут', 'здесь', 'сейчас', 'ну', 'короче',
      'плиз', 'please', 'просто', 'также', 'еще', 'ещё',
      'он', 'она', 'оно', 'они', 'мы', 'вы', 'ты', 'меня', 'тебя', 'его', 'ее', 'её', 'их', 'нам', 'вам', 'им',
      'говорю', 'говорит', 'говоришь', 'сказал', 'сказала', 'сказали', 'пишет', 'пишу', 'написал', 'отвечает', 'ответил', 'скажи', 'спроси',
      'режим', 'режиме', 'режима', 'режимы', 'фул', 'фулл', 'full', 'mode',
      'что', 'как', 'почему', 'зачем', 'где', 'когда', 'кто', 'же', 'ли', 'бы', 'так', 'тут', 'там', 'вот', 'опять', 'снова',
      'сумма', 'сумму', 'суммы',

      // Russian Word Numbers
      'один', 'одна', 'одно', 'два', 'две', 'три', 'четыре', 'пять', 'шесть', 'семь', 'восемь', 'девять', 'десять',
      'одиннадцать', 'двенадцать', 'тринадцать', 'четырнадцать', 'пятнадцать', 'шестнадцать', 'семнадцать', 'восемнадцать', 'девятнадцать',
      'двадцать', 'тридцать', 'сорок', 'пятьдесят', 'шестьдесят', 'семьдесят', 'восемьдесят', 'девяносто',
      'сто', 'двести', 'триста', 'четыреста', 'пятьсот', 'шестьсот', 'семьсот', 'восемьсот', 'девятьсот',
      'тысяча', 'тысячу', 'тысячи',
      // English Word Numbers
      'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten',
      'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen',
      'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety',
      'hundred', 'thousand'
    };

    for (final word in words) {
      if (word.isEmpty ||
          double.tryParse(word.replaceAll(',', '.')) != null ||
          nonSymbolWords.contains(word)) {
        continue;
      }
      if (!isValidToken(word)) {
        hasInvalidSymbol = true;
        break;
      }
    }

    if (symbol == null && !hasInvalidSymbol) {
      symbol = ScreenContextService.instance.focusedSymbol;
    }

    // 2. Resolve amount and isQuantity
    double? amount;
    bool isQuantity = false;

    // Slang check for percentages/all/half
    if (type == IntentType.sellAsset) {
      if (sanitized.contains('все') ||
          sanitized.contains('всё') ||
          sanitized.contains('all') ||
          sanitized.contains('100%')) {
        amount = -1.0;
        isQuantity = true;
      } else if (sanitized.contains('половин') ||
          sanitized.contains('half') ||
          sanitized.contains('50%')) {
        amount = -0.5;
        isQuantity = true;
      }
    }

    // Slang check for absolute amounts
    if (amount == null) {
      if (sanitized.contains('полбакса') ||
          sanitized.contains('пол бакса') ||
          sanitized.contains('пол-бакса') ||
          sanitized.contains('полдоллара') ||
          sanitized.contains('пол доллара') ||
          sanitized.contains('пол-доллара')) {
        amount = 0.50;
      } else if (sanitized.contains('полтора доллара') ||
          sanitized.contains('полтора бакса') ||
          sanitized.contains('полтора косаря')) {
        amount = 1.50;
      } else if (sanitized.contains('десятку') || sanitized.contains('десятка')) {
        amount = 10.0;
      } else if (sanitized.contains('сотку') || sanitized.contains('сотка')) {
        amount = 100.0;
      } else if (sanitized.contains('косарь') || sanitized.contains('косарик')) {
        amount = 1000.0;
      }
    }

    // Fallback to standard double parsing
    if (amount == null) {
      amount = IntentParser.extractAmount(input);
    }

    // Determine if isQuantity based on patterns
    if (amount != null && !isQuantity) {
      final isQuoteValue = sanitized.contains('\$') ||
          sanitized.contains('доллар') ||
          sanitized.contains('бакс') ||
          sanitized.contains('usd') ||
          sanitized.contains('usdt') ||
          sanitized.contains('usdc') ||
          sanitized.contains('цент') ||
          sanitized.contains('cent') ||
          sanitized.contains('на') ||
          sanitized.contains('за') ||
          sanitized.contains('for');
          
      if (isQuoteValue) {
        isQuantity = false;
      } else {
        if (symbol != null) {
          final symLower = symbol.toLowerCase();
          final amtPattern = RegExp('(\\d+(?:\\.\\d+)?)\\s+$symLower');
          if (amtPattern.hasMatch(sanitized)) {
            isQuantity = true;
          } else {
            isQuantity = false;
          }
        } else {
          isQuantity = false;
        }
      }
    }

    return IntentData(
      type: type,
      rawInput: input,
      tokenSymbol: symbol,
      amount: amount,
      isQuantity: isQuantity,
    );
  }
}
