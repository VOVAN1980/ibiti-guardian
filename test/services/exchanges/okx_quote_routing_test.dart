import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/exchanges/okx_exchange_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_interface.dart';

void main() {
  group('OKX Quote Routing Tests', () {
    setUp(() {
      OkxExchangeService.instance.clearTickersForTest();
    });

    test('EEA profile correctly routes SOL -> SOL-USDC if present', () async {
      OkxExchangeService.instance.setTickerForTest(
        'SOLUSDC',
        const LiveTicker(
          symbol: 'SOLUSDC',
          baseAsset: 'SOL',
          lastPrice: 150.0,
          priceChangePercent24h: 1.0,
          volume24h: 1000.0,
          quoteVolume24h: 150000.0,
          highPrice24h: 155.0,
          lowPrice24h: 145.0,
        ),
      );

      final pair = await OkxExchangeService.instance.findBestPair('SOL', 'eea');
      expect(pair, 'SOL-USDC');
    });

    test('Global profile correctly routes SOL -> SOL-USDT if present', () async {
      OkxExchangeService.instance.setTickerForTest(
        'SOLUSDT',
        const LiveTicker(
          symbol: 'SOLUSDT',
          baseAsset: 'SOL',
          lastPrice: 150.0,
          priceChangePercent24h: 1.0,
          volume24h: 1000.0,
          quoteVolume24h: 150000.0,
          highPrice24h: 155.0,
          lowPrice24h: 145.0,
        ),
      );

      final pair = await OkxExchangeService.instance.findBestPair('SOL', 'global');
      expect(pair, 'SOL-USDT');
    });

    test('EEA falls back to SOL-USDT if SOL-USDC is not present', () async {
      OkxExchangeService.instance.setTickerForTest(
        'SOLUSDT',
        const LiveTicker(
          symbol: 'SOLUSDT',
          baseAsset: 'SOL',
          lastPrice: 150.0,
          priceChangePercent24h: 1.0,
          volume24h: 1000.0,
          quoteVolume24h: 150000.0,
          highPrice24h: 155.0,
          lowPrice24h: 145.0,
        ),
      );

      final pair = await OkxExchangeService.instance.findBestPair('SOL', 'eea');
      expect(pair, 'SOL-USDT');
    });

    test('Unsupported pair (not in tickers) returns null', () async {
      final pair = await OkxExchangeService.instance.findBestPair('UNKNOWN', 'eea');
      expect(pair, isNull);
    });
  });
}
