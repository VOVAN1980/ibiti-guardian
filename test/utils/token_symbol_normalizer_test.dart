import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/utils/token_symbol_normalizer.dart';

void main() {
  group('TokenSymbolNormalizer', () {
    test('Russian case forms of known aliases', () {
      expect(TokenSymbolNormalizer.normalize('эфира'), 'ETH');
      expect(TokenSymbolNormalizer.normalize('Эфиру'), 'ETH');
      expect(TokenSymbolNormalizer.normalize('тезера'), 'USDT');
    });

    test('exact aliases and plain symbols are unchanged', () {
      expect(TokenSymbolNormalizer.normalize('эфир'), 'ETH');
      expect(TokenSymbolNormalizer.normalize('usdt'), 'USDT');
      expect(TokenSymbolNormalizer.normalize('MANA'), 'MANA');
      expect(TokenSymbolNormalizer.normalize('ЭФИРКА'), 'ЭФИРКА');
    });
  });
}
