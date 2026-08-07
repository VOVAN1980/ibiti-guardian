/// Converts user-facing text into language-aware, TTS-friendly speech.
///
/// The formatter deliberately turns numbers into words before they reach TTS.
/// Numeric glyphs are often spoken much faster than surrounding prose, which
/// makes balances, prices and policy limits sound swallowed or sped up.
class SpeechFormatter {
  SpeechFormatter._();

  /// Main entry point used by every conversational speech path.
  static String normalize(String text, {String lang = 'ru'}) {
    if (text.trim().isEmpty) return '';
    final language = lang.toLowerCase().startsWith('ru') ? 'ru' : 'en';
    var result = text;

    result = _stripMarkdown(result);
    result = _stripEmoji(result);
    result = _humanizeTechnicalIdentifiers(result, language);
    result = _normalizeDollarAmounts(result, language);
    result = _normalizeCryptoAmounts(result, language);
    result = _normalizePercentages(result, language);
    result = _normalizeStandaloneNumbers(result, language);
    result = _normalizeTokenSymbols(result, language);
    result = _normalizePunctuation(result);

    return result.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _stripMarkdown(String text) {
    var result = text;
    result = result.replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '');
    result = result.replaceAll(RegExp(r'\*{1,3}'), '');
    result = result.replaceAll(RegExp(r'_{1,3}'), ' ');
    result = result.replaceAll(RegExp(r'```[\s\S]*?```'), '');
    result = result.replaceAll(RegExp(r'`([^`]+)`'), r'$1');
    result = result.replaceAll(RegExp(r'^[\-•]\s+', multiLine: true), '');
    result = result.replaceAll(RegExp(r'^\d+\.\s+', multiLine: true), '');
    result = result.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^)]+\)'),
      (match) => match.group(1) ?? '',
    );
    return result;
  }

  static String _stripEmoji(String text) {
    return text.replaceAll(
      RegExp(
        r'[\u{1F300}-\u{1F9FF}]|[\u{2600}-\u{26FF}]|'
        r'[\u{2700}-\u{27BF}]|[\u{FE00}-\u{FE0F}]|'
        r'[\u{1F000}-\u{1F02F}]|[\u{200D}]|[\u{20E3}]|'
        r'[\u{E0020}-\u{E007F}]',
        unicode: true,
      ),
      '',
    );
  }

  static String _humanizeTechnicalIdentifiers(String text, String lang) {
    var result = text.replaceAll(
      RegExp(r'0x[a-fA-F0-9]{64}'),
      lang == 'ru' ? 'хеш транзакции' : 'transaction hash',
    );
    result = result.replaceAll(
      RegExp(r'0x[a-fA-F0-9]{40}'),
      lang == 'ru' ? 'адрес кошелька' : 'wallet address',
    );
    return result;
  }

  static const _numberSource = r'([+\-]?\d(?:[\d\s\u00A0.,\x27\u2019]*\d)?)';

  static final _dollarPattern = RegExp('~?\\\$\\s*$_numberSource');

  static String _normalizeDollarAmounts(String text, String lang) {
    return text.replaceAllMapped(_dollarPattern, (match) {
      final parsed = _parseNumber(
        match.group(1)!,
        lang: lang,
        currencyStyle: true,
      );
      if (parsed == null) return match.group(0)!;
      return _currencyWords(parsed, lang);
    });
  }

  static final _cryptoPattern = RegExp(
    '$_numberSource\\s*'
    r'(BTC|ETH|SOL|BNB|USDT|USDC|IBIT|IBITI|DAI|BUSD|MATIC|XRP|'
    r'DOGE|ADA|DOT|AVAX|LINK|UNI|ATOM|FTM|NEAR|APT|ARB|OP|TRX|'
    r'LTC|BCH|ETC|FIL|HBAR|ICP|VET|ALGO|SAND|MANA|AXS|GALA|APE|'
    r'PEPE|SHIB|WIF|BONK|FLOKI|BRETT)',
    caseSensitive: false,
  );

  static String _normalizeCryptoAmounts(String text, String lang) {
    return text.replaceAllMapped(_cryptoPattern, (match) {
      final parsed = _parseNumber(match.group(1)!, lang: lang);
      if (parsed == null) return match.group(0)!;
      final symbol = match.group(2)!.toUpperCase();
      final number =
          lang == 'ru' ? _numberWordsRu(parsed) : _numberWordsEn(parsed);
      return '$number ${_cryptoUnit(symbol, parsed, lang)}';
    });
  }

  static final _percentPattern = RegExp('$_numberSource\\s*%');

  static String _normalizePercentages(String text, String lang) {
    return text.replaceAllMapped(_percentPattern, (match) {
      final parsed = _parseNumber(match.group(1)!, lang: lang);
      if (parsed == null) return match.group(0)!;
      final number =
          lang == 'ru' ? _numberWordsRu(parsed) : _numberWordsEn(parsed);
      if (lang == 'ru') {
        final unit = parsed.fraction.isNotEmpty
            ? 'процента'
            : _pluralRuBigInt(parsed.whole, 'процент', 'процента', 'процентов');
        return '$number $unit';
      }
      final unit = parsed.isExactlyOne ? 'percent' : 'percent';
      return '$number $unit';
    });
  }

  // Dates, versions, IP addresses and identifiers joined with a dash/dot are
  // intentionally excluded. They need domain-specific pronunciation instead
  // of a blind numeric rewrite.
  static final _standaloneNumberPattern = RegExp(
    r'(?<![\w.\-])'
    r'([+\-]?\d{1,3}(?:[\s\u00A0]\d{3})+(?:[.,]\d+)?|'
    r'[+\-]?\d+(?:[.,]\d+)?)'
    r'(?![\w\-]|\.\d)',
  );

  static String _normalizeStandaloneNumbers(String text, String lang) {
    return text.replaceAllMapped(_standaloneNumberPattern, (match) {
      final parsed = _parseNumber(match.group(1)!, lang: lang);
      if (parsed == null) return match.group(0)!;
      return lang == 'ru' ? _numberWordsRu(parsed) : _numberWordsEn(parsed);
    });
  }

  static String _normalizeTokenSymbols(String text, String lang) {
    const symbols = [
      'USDT',
      'USDC',
      'IBITI',
      'IBIT',
      'BTC',
      'ETH',
      'SOL',
      'BNB',
      'TRX',
      'DAI',
      'BUSD',
      'MATIC',
      'XRP',
      'DOGE',
      'ADA',
      'DOT',
      'AVAX',
      'LINK',
      'UNI',
      'ATOM',
      'LTC',
      'BCH',
    ];
    var result = text;
    for (final symbol in symbols) {
      result = result.replaceAllMapped(
        RegExp('\\b$symbol\\b', caseSensitive: false),
        (_) => _standaloneTokenName(symbol, lang),
      );
    }
    return result;
  }

  static String _normalizePunctuation(String text) {
    // Literal ellipses inserted by the old formatter caused exaggerated pauses.
    var result = text.replaceAll(RegExp(r'\.{3,}'), '.');
    result = result.replaceAll(RegExp(r'\s+([,.;:!?])'), r'$1');
    result = result.replaceAll(RegExp(r'([,.;:!?])(?!\s|$)'), r'$1 ');
    return result;
  }

  static _SpokenNumber? _parseNumber(
    String raw, {
    required String lang,
    bool currencyStyle = false,
  }) {
    var value = raw
        .trim()
        .replaceAll('\u00a0', '')
        .replaceAll(' ', '')
        .replaceAll("'", '')
        .replaceAll('’', '');
    if (value.isEmpty) return null;

    var negative = false;
    var explicitPlus = false;
    if (value.startsWith('-')) {
      negative = true;
      value = value.substring(1);
    } else if (value.startsWith('+')) {
      explicitPlus = true;
      value = value.substring(1);
    }
    if (value.isEmpty) return null;

    final commaCount = ','.allMatches(value).length;
    final dotCount = '.'.allMatches(value).length;
    String wholePart;
    String fractionPart = '';

    if (commaCount > 0 && dotCount > 0) {
      final commaIndex = value.lastIndexOf(',');
      final dotIndex = value.lastIndexOf('.');
      final decimalSeparator = commaIndex > dotIndex ? ',' : '.';
      final decimalIndex = value.lastIndexOf(decimalSeparator);
      wholePart = value
          .substring(0, decimalIndex)
          .replaceAll(',', '')
          .replaceAll('.', '');
      fractionPart = value.substring(decimalIndex + 1);
    } else if (commaCount > 0 || dotCount > 0) {
      final separator = commaCount > 0 ? ',' : '.';
      final parts = value.split(separator);
      final looksGrouped =
          parts.length > 2 && parts.skip(1).every((part) => part.length == 3);
      final singleCurrencyThousands = currencyStyle &&
          parts.length == 2 &&
          parts.first.isNotEmpty &&
          parts.first.length <= 3 &&
          parts.last.length == 3;
      final englishCommaThousands = lang == 'en' &&
          separator == ',' &&
          parts.length == 2 &&
          parts.last.length == 3;
      if (looksGrouped || singleCurrencyThousands || englishCommaThousands) {
        wholePart = parts.join();
      } else {
        wholePart = parts.first;
        fractionPart = parts.skip(1).join();
      }
    } else {
      wholePart = value;
    }

    if (!RegExp(r'^\d+$').hasMatch(wholePart) ||
        (fractionPart.isNotEmpty && !RegExp(r'^\d+$').hasMatch(fractionPart))) {
      return null;
    }

    fractionPart = fractionPart.replaceFirst(RegExp(r'0+$'), '');
    return _SpokenNumber(
      whole: BigInt.parse(wholePart),
      fraction: fractionPart,
      negative: negative,
      explicitPlus: explicitPlus,
    );
  }

  static String _currencyWords(_SpokenNumber number, String lang) {
    if (number.whole == BigInt.zero &&
        number.fraction.isNotEmpty &&
        int.parse(number.fraction.padRight(2, '0').substring(0, 2)) == 0) {
      return lang == 'ru' ? 'меньше одного цента' : 'less than one cent';
    }

    if (number.fraction.length > 2) {
      final spoken =
          lang == 'ru' ? _numberWordsRu(number) : _numberWordsEn(number);
      return lang == 'ru' ? '$spoken доллара США' : '$spoken US dollars';
    }

    final sign = number.negative
        ? (lang == 'ru' ? 'минус ' : 'minus ')
        : number.explicitPlus
            ? (lang == 'ru' ? 'плюс ' : 'plus ')
            : '';
    final wholeWords = lang == 'ru'
        ? _integerWordsRu(number.whole)
        : _integerWordsEn(number.whole);
    final cents = number.fraction.isEmpty
        ? 0
        : int.parse(number.fraction.padRight(2, '0').substring(0, 2));

    if (lang == 'ru') {
      final dollars = _pluralRuBigInt(
        number.whole,
        'доллар',
        'доллара',
        'долларов',
      );
      if (cents == 0) return '$sign$wholeWords $dollars';
      final centWords = _integerWordsRu(BigInt.from(cents));
      final centUnit = _pluralRu(cents, 'цент', 'цента', 'центов');
      return '$sign$wholeWords $dollars $centWords $centUnit';
    }

    final dollars = number.whole == BigInt.one ? 'dollar' : 'dollars';
    if (cents == 0) return '$sign$wholeWords $dollars';
    final centWords = _integerWordsEn(BigInt.from(cents));
    final centUnit = cents == 1 ? 'cent' : 'cents';
    return '$sign$wholeWords $dollars $centWords $centUnit';
  }

  static String _numberWordsRu(_SpokenNumber number) {
    final sign = number.negative
        ? 'минус '
        : number.explicitPlus
            ? 'плюс '
            : '';
    final whole = _integerWordsRu(number.whole);
    if (number.fraction.isEmpty) return '$sign$whole';

    if (number.fraction.length > _fractionUnitsRu.length) {
      final digits = number.fraction
          .split('')
          .map((digit) => _digitRu[int.parse(digit)])
          .join(', ');
      return '$sign$whole целых, $digits';
    }

    final numerator = BigInt.parse(number.fraction);
    final wholeUnit = _endsInOne(number.whole) ? 'целая' : 'целых';
    final numeratorWords = _integerWordsRu(numerator, feminine: true);
    final units = _fractionUnitsRu[number.fraction.length - 1];
    final fractionUnit = numerator == BigInt.one ? units.$1 : units.$2;
    return '$sign$whole $wholeUnit $numeratorWords $fractionUnit';
  }

  static String _numberWordsEn(_SpokenNumber number) {
    final sign = number.negative
        ? 'minus '
        : number.explicitPlus
            ? 'plus '
            : '';
    final whole = _integerWordsEn(number.whole);
    if (number.fraction.isEmpty) return '$sign$whole';
    final digits = number.fraction
        .split('')
        .map((digit) => _digitEn[int.parse(digit)])
        .join(' ');
    return '$sign$whole point $digits';
  }

  static String _integerWordsRu(BigInt value, {bool feminine = false}) {
    if (value == BigInt.zero) return 'ноль';
    if (value < BigInt.zero) return 'минус ${_integerWordsRu(-value)}';

    final groups = <int>[];
    var remaining = value;
    final thousand = BigInt.from(1000);
    while (remaining > BigInt.zero) {
      groups.add((remaining % thousand).toInt());
      remaining ~/= thousand;
    }
    if (groups.length > _scaleRu.length) {
      return value
          .toString()
          .split('')
          .map((d) => _digitRu[int.parse(d)])
          .join(' ');
    }

    final parts = <String>[];
    for (var index = groups.length - 1; index >= 0; index--) {
      final group = groups[index];
      if (group == 0) continue;
      final groupWords = _threeDigitsRu(
        group,
        feminine: index == 1 || (index == 0 && feminine),
      );
      parts.add(groupWords);
      if (index > 0) {
        final scale = _scaleRu[index];
        parts.add(_pluralRu(group, scale.$1, scale.$2, scale.$3));
      }
    }
    return parts.join(' ');
  }

  static String _threeDigitsRu(int value, {required bool feminine}) {
    final parts = <String>[];
    final hundreds = value ~/ 100;
    final remainder = value % 100;
    if (hundreds > 0) parts.add(_hundredsRu[hundreds]);
    if (remainder >= 10 && remainder <= 19) {
      parts.add(_teensRu[remainder - 10]);
      return parts.join(' ');
    }
    final tens = remainder ~/ 10;
    final units = remainder % 10;
    if (tens > 1) parts.add(_tensRu[tens]);
    if (units > 0) {
      if (feminine && units == 1) {
        parts.add('одна');
      } else if (feminine && units == 2) {
        parts.add('две');
      } else {
        parts.add(_unitsRu[units]);
      }
    }
    return parts.join(' ');
  }

  static String _integerWordsEn(BigInt value) {
    if (value == BigInt.zero) return 'zero';
    if (value < BigInt.zero) return 'minus ${_integerWordsEn(-value)}';

    final groups = <int>[];
    var remaining = value;
    final thousand = BigInt.from(1000);
    while (remaining > BigInt.zero) {
      groups.add((remaining % thousand).toInt());
      remaining ~/= thousand;
    }
    if (groups.length > _scaleEn.length) {
      return value
          .toString()
          .split('')
          .map((d) => _digitEn[int.parse(d)])
          .join(' ');
    }

    final parts = <String>[];
    for (var index = groups.length - 1; index >= 0; index--) {
      final group = groups[index];
      if (group == 0) continue;
      parts.add(_threeDigitsEn(group));
      if (index > 0) parts.add(_scaleEn[index]);
    }
    return parts.join(' ');
  }

  static String _threeDigitsEn(int value) {
    final parts = <String>[];
    final hundreds = value ~/ 100;
    final remainder = value % 100;
    if (hundreds > 0) {
      parts.add('${_unitsEn[hundreds]} hundred');
    }
    if (remainder >= 10 && remainder <= 19) {
      parts.add(_teensEn[remainder - 10]);
    } else {
      final tens = remainder ~/ 10;
      final units = remainder % 10;
      if (tens > 1 && units > 0) {
        parts.add('${_tensEn[tens]} ${_unitsEn[units]}');
      } else if (tens > 1) {
        parts.add(_tensEn[tens]);
      } else if (units > 0) {
        parts.add(_unitsEn[units]);
      }
    }
    return parts.join(' ');
  }

  static String _cryptoUnit(
    String symbol,
    _SpokenNumber number,
    String lang,
  ) {
    if (lang != 'ru') {
      final name = _tokenEn[symbol] ?? (symbol, symbol);
      return number.isExactlyOne ? name.$1 : name.$2;
    }

    final forms = _tokenRu[symbol];
    if (forms == null) return 'токенов ${_spellLatin(symbol)}';
    if (forms.$1 == forms.$2 && forms.$2 == forms.$3) return forms.$1;
    if (number.fraction.isNotEmpty) return forms.$2;
    return _pluralRuBigInt(number.whole, forms.$1, forms.$2, forms.$3);
  }

  static String _standaloneTokenName(String symbol, String lang) {
    if (lang != 'ru') return (_tokenEn[symbol] ?? (symbol, symbol)).$1;
    return (_tokenRu[symbol] ??
            (_spellLatin(symbol), _spellLatin(symbol), _spellLatin(symbol)))
        .$1;
  }

  static String _spellLatin(String value) {
    const names = {
      'A': 'эй',
      'B': 'би',
      'C': 'си',
      'D': 'ди',
      'E': 'и',
      'F': 'эф',
      'G': 'джи',
      'H': 'эйч',
      'I': 'ай',
      'J': 'джей',
      'K': 'кей',
      'L': 'эл',
      'M': 'эм',
      'N': 'эн',
      'O': 'оу',
      'P': 'пи',
      'Q': 'кью',
      'R': 'ар',
      'S': 'эс',
      'T': 'ти',
      'U': 'ю',
      'V': 'ви',
      'W': 'дабл-ю',
      'X': 'икс',
      'Y': 'уай',
      'Z': 'зед',
    };
    return value.toUpperCase().split('').map((c) => names[c] ?? c).join(' ');
  }

  static bool _endsInOne(BigInt value) {
    final mod100 = (value % BigInt.from(100)).toInt();
    return value % BigInt.from(10) == BigInt.one && mod100 != 11;
  }

  static String _pluralRuBigInt(
    BigInt value,
    String one,
    String few,
    String many,
  ) {
    final mod100 = (value % BigInt.from(100)).toInt();
    final mod10 = (value % BigInt.from(10)).toInt();
    if (mod100 >= 11 && mod100 <= 19) return many;
    if (mod10 == 1) return one;
    if (mod10 >= 2 && mod10 <= 4) return few;
    return many;
  }

  static String _pluralRu(int value, String one, String few, String many) {
    final mod100 = value % 100;
    final mod10 = value % 10;
    if (mod100 >= 11 && mod100 <= 19) return many;
    if (mod10 == 1) return one;
    if (mod10 >= 2 && mod10 <= 4) return few;
    return many;
  }

  static const _digitRu = [
    'ноль',
    'один',
    'два',
    'три',
    'четыре',
    'пять',
    'шесть',
    'семь',
    'восемь',
    'девять',
  ];
  static const _unitsRu = [
    '',
    'один',
    'два',
    'три',
    'четыре',
    'пять',
    'шесть',
    'семь',
    'восемь',
    'девять',
  ];
  static const _teensRu = [
    'десять',
    'одиннадцать',
    'двенадцать',
    'тринадцать',
    'четырнадцать',
    'пятнадцать',
    'шестнадцать',
    'семнадцать',
    'восемнадцать',
    'девятнадцать',
  ];
  static const _tensRu = [
    '',
    '',
    'двадцать',
    'тридцать',
    'сорок',
    'пятьдесят',
    'шестьдесят',
    'семьдесят',
    'восемьдесят',
    'девяносто',
  ];
  static const _hundredsRu = [
    '',
    'сто',
    'двести',
    'триста',
    'четыреста',
    'пятьсот',
    'шестьсот',
    'семьсот',
    'восемьсот',
    'девятьсот',
  ];
  static const _scaleRu = [
    ('', '', ''),
    ('тысяча', 'тысячи', 'тысяч'),
    ('миллион', 'миллиона', 'миллионов'),
    ('миллиард', 'миллиарда', 'миллиардов'),
    ('триллион', 'триллиона', 'триллионов'),
    ('квадриллион', 'квадриллиона', 'квадриллионов'),
    ('квинтиллион', 'квинтиллиона', 'квинтиллионов'),
  ];
  static const _fractionUnitsRu = [
    ('десятая', 'десятых'),
    ('сотая', 'сотых'),
    ('тысячная', 'тысячных'),
    ('десятитысячная', 'десятитысячных'),
    ('стотысячная', 'стотысячных'),
    ('миллионная', 'миллионных'),
    ('десятимиллионная', 'десятимиллионных'),
    ('стомиллионная', 'стомиллионных'),
    ('миллиардная', 'миллиардных'),
    ('десятимиллиардная', 'десятимиллиардных'),
    ('стомиллиардная', 'стомиллиардных'),
    ('триллионная', 'триллионных'),
  ];

  static const _digitEn = [
    'zero',
    'one',
    'two',
    'three',
    'four',
    'five',
    'six',
    'seven',
    'eight',
    'nine',
  ];
  static const _unitsEn = [
    '',
    'one',
    'two',
    'three',
    'four',
    'five',
    'six',
    'seven',
    'eight',
    'nine',
  ];
  static const _teensEn = [
    'ten',
    'eleven',
    'twelve',
    'thirteen',
    'fourteen',
    'fifteen',
    'sixteen',
    'seventeen',
    'eighteen',
    'nineteen',
  ];
  static const _tensEn = [
    '',
    '',
    'twenty',
    'thirty',
    'forty',
    'fifty',
    'sixty',
    'seventy',
    'eighty',
    'ninety',
  ];
  static const _scaleEn = [
    '',
    'thousand',
    'million',
    'billion',
    'trillion',
    'quadrillion',
    'quintillion',
  ];

  static const _tokenRu = <String, (String, String, String)>{
    'BTC': ('биткоин', 'биткоина', 'биткоинов'),
    'ETH': ('эфир', 'эфира', 'эфиров'),
    'SOL': ('токен Солана', 'токена Солана', 'токенов Солана'),
    'TRX': ('трон', 'трона', 'тронов'),
    'USDT': ('ю эс ди ти', 'ю эс ди ти', 'ю эс ди ти'),
    'USDC': ('ю эс ди си', 'ю эс ди си', 'ю эс ди си'),
    'BNB': ('би эн би', 'би эн би', 'би эн би'),
    'IBITI': ('ибити', 'ибити', 'ибити'),
    'IBIT': ('ибит', 'ибита', 'ибитов'),
    'DAI': ('дай', 'дай', 'дай'),
    'BUSD': ('би ю эс ди', 'би ю эс ди', 'би ю эс ди'),
    'MATIC': ('матик', 'матика', 'матиков'),
    'XRP': ('икс ар пи', 'икс ар пи', 'икс ар пи'),
    'DOGE': ('додж', 'доджа', 'доджей'),
    'ADA': ('ада', 'ады', 'ад'),
    'DOT': ('дот', 'дота', 'дотов'),
    'AVAX': ('аваланч', 'аваланча', 'аваланчей'),
    'LINK': ('линк', 'линка', 'линков'),
    'UNI': ('юни', 'юни', 'юни'),
    'ATOM': ('атом', 'атома', 'атомов'),
    'LTC': ('лайткоин', 'лайткоина', 'лайткоинов'),
    'BCH': ('биткоин кэш', 'биткоин кэш', 'биткоин кэш'),
  };

  static const _tokenEn = <String, (String, String)>{
    'BTC': ('bitcoin', 'bitcoins'),
    'ETH': ('ether', 'ether'),
    'SOL': ('Solana token', 'Solana tokens'),
    'TRX': ('Tron token', 'Tron tokens'),
    'USDT': ('U S D T', 'U S D T'),
    'USDC': ('U S D C', 'U S D C'),
    'BNB': ('B N B', 'B N B'),
    'IBITI': ('ih bit ee', 'ih bit ee'),
  };
}

class _SpokenNumber {
  const _SpokenNumber({
    required this.whole,
    required this.fraction,
    required this.negative,
    required this.explicitPlus,
  });

  final BigInt whole;
  final String fraction;
  final bool negative;
  final bool explicitPlus;

  bool get isExactlyOne => !negative && whole == BigInt.one && fraction.isEmpty;
}
