import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_chart_service.dart';

void main() {
  group('ExchangeChartService Candle Parsing Tests', () {
    late ExchangeChartService service;

    setUp(() {
      service = ExchangeChartService.instance;
    });

    test('Binance candlestick parsing works correctly', () async {
      final mockBinanceResponse = [
        [
          1610000000000, // Open time
          "1.0", // Open
          "1.5", // High
          "0.9", // Low
          "1.2", // Close
          "100.0", // Volume
          1610000300000, // Close time
          "120.0", // Quote volume
          10, // Trade count
          "50.0", // Taker buy volume
          "60.0", // Taker buy quote volume
          "0"
        ]
      ];

      service.client = MockClient((request) async {
        if (request.url.host.contains('binance')) {
          return http.Response(jsonEncode(mockBinanceResponse), 200);
        }
        return http.Response('Not found', 404);
      });

      final candles = await service.fetchCandles('BTC',
          rangeKey: '1m', sourceId: 'binance');

      expect(candles.length, 1);
      final c = candles.first;
      expect(c.time,
          DateTime.fromMillisecondsSinceEpoch(1610000000000, isUtc: true));
      expect(c.open, 1.0);
      expect(c.high, 1.5);
      expect(c.low, 0.9);
      expect(c.close, 1.2);
      expect(c.volume, 100.0);
    });

    test('MEXC candlestick parsing works correctly', () async {
      final mockMexcResponse = [
        [
          1620000000000, // Open time
          "2.0", // Open
          "2.5", // High
          "1.8", // Low
          "2.2", // Close
          "200.0", // Volume
          1620000300000
        ]
      ];

      service.client = MockClient((request) async {
        if (request.url.host.contains('mexc')) {
          return http.Response(jsonEncode(mockMexcResponse), 200);
        }
        return http.Response('Not found', 404);
      });

      final candles = await service.fetchCandles('ETH',
          rangeKey: '5m', sourceId: 'mexc');

      expect(candles.length, 1);
      final c = candles.first;
      expect(c.time,
          DateTime.fromMillisecondsSinceEpoch(1620000000000, isUtc: true));
      expect(c.open, 2.0);
      expect(c.high, 2.5);
      expect(c.low, 1.8);
      expect(c.close, 2.2);
      expect(c.volume, 200.0);
    });

    test('Gate.io candlestick parsing works correctly', () async {
      final mockGateResponse = [
        [
          "1630000000", // Start time (sec)
          "300.0", // Volume
          "3.2", // Close
          "3.5", // High
          "2.9", // Low
          "3.0", // Open
        ]
      ];

      service.client = MockClient((request) async {
        if (request.url.host.contains('gateio')) {
          return http.Response(jsonEncode(mockGateResponse), 200);
        }
        return http.Response('Not found', 404);
      });

      final candles = await service.fetchCandles('SOL',
          rangeKey: '15m', sourceId: 'gateio');

      expect(candles.length, 1);
      final c = candles.first;
      expect(c.time,
          DateTime.fromMillisecondsSinceEpoch(1630000000000, isUtc: true));
      expect(c.open, 3.0);
      expect(c.high, 3.5);
      expect(c.low, 2.9);
      expect(c.close, 3.2);
      expect(c.volume, 300.0);
    });

    test('OKX candlestick parsing sorts ascending correctly', () async {
      final mockOkxResponse = {
        "code": "0",
        "msg": "",
        "data": [
          [
            "1640000600000", // T2: Newest candle (time order reversed from OKX API)
            "4.1", // Open
            "4.6", // High
            "3.9", // Low
            "4.4", // Close
            "400.0", // Volume
          ],
          [
            "1640000000000", // T1: Oldest candle
            "4.0", // Open
            "4.5", // High
            "3.8", // Low
            "4.2", // Close
            "350.0", // Volume
          ]
        ]
      };

      service.client = MockClient((request) async {
        if (request.url.host.contains('okx')) {
          return http.Response(jsonEncode(mockOkxResponse), 200);
        }
        return http.Response('Not found', 404);
      });

      final candles = await service.fetchCandles('ADA',
          rangeKey: '30m', sourceId: 'okx');

      // The service must sort ascending by time, so oldest first
      expect(candles.length, 2);
      expect(candles[0].time,
          DateTime.fromMillisecondsSinceEpoch(1640000000000, isUtc: true));
      expect(candles[0].close, 4.2);

      expect(candles[1].time,
          DateTime.fromMillisecondsSinceEpoch(1640000600000, isUtc: true));
      expect(candles[1].close, 4.4);
    });

    test('Legacy fetchPrices wrapper works and maps close prices', () async {
      final mockBinanceResponse = [
        [
          1610000000000,
          "1.0",
          "1.5",
          "0.9",
          "1.2", // Close
          "100.0"
        ],
        [
          1610000060000,
          "1.2",
          "1.8",
          "1.1",
          "1.6", // Close
          "150.0"
        ]
      ];

      service.client = MockClient((request) async {
        return http.Response(jsonEncode(mockBinanceResponse), 200);
      });

      final prices = await service.fetchPrices('BTC',
          rangeKey: '1m', sourceId: 'binance');

      expect(prices, [1.2, 1.6]);
    });
  });
}
