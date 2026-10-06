import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/swap/zerox_swap_provider.dart';

void main() {
  group('ZeroXSwapProvider.normalizeToken', () {
    test('maps native aliases to the 0x sentinel', () {
      for (final alias in ['', 'native', 'BNB', 'bnb', 'ETH', 'POL', ' AVAX ']) {
        expect(ZeroXSwapProvider.normalizeToken(alias),
            ZeroXSwapProvider.nativeTokenSentinel,
            reason: 'alias "$alias"');
      }
    });

    test('keeps ERC-20 contract addresses unchanged', () {
      const usdt = '0x55d398326f99059fF775485246999027B3197955';
      expect(ZeroXSwapProvider.normalizeToken(usdt), usdt);
      expect(
          ZeroXSwapProvider.normalizeToken(
              ZeroXSwapProvider.nativeTokenSentinel),
          ZeroXSwapProvider.nativeTokenSentinel);
    });
  });
}
