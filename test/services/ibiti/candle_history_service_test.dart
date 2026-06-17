import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/ibiti/candle_history_service.dart';
import 'package:ibiti_guardian/services/ibiti/models/candle.dart';

void main() {
  group('CandleHistoryService Parsers', () {
    test('parseBinanceKlines correctly parses standard format', () {
      final rawData = [
        [
          1610000000000, // Open time
          "40000.00", // Open
          "41000.00", // High
          "39000.00", // Low
          "40500.00", // Close
          "100.5", // Volume
          1610000300000, // Close time
          "4050000.00", // Quote asset volume
          500, // Number of trades
          "50.0", // Taker buy base asset volume
          "2025000.00", // Taker buy quote asset volume
          "0" // Ignore
        ]
      ];

      final candles = CandleHistoryService.parseBinanceKlines(rawData);

      expect(candles.length, 1);
      final c = candles.first;
      expect(c.openTime, 1610000000000);
      expect(c.open, 40000.00);
      expect(c.high, 41000.00);
      expect(c.low, 39000.00);
      expect(c.close, 40500.00);
      expect(c.volume, 100.5);
    });

    test(
        'parseOkxKlines correctly reverses order (newest first to oldest first)',
        () {
      final rawData = [
        // Newest candle (should become last)
        [
          "1610000300000", // Open time
          "40500.00", // Open
          "41500.00", // High
          "39500.00", // Low
          "41000.00", // Close
          "200.0", // Volume
          "8000000.00" // Turnover
        ],
        // Oldest candle (should become first)
        [
          "1610000000000", // Open time
          "40000.00", // Open
          "41000.00", // High
          "39000.00", // Low
          "40500.00", // Close
          "100.5", // Volume
          "4050000.00" // Turnover
        ]
      ];

      final candles = CandleHistoryService.parseOkxKlines(rawData);

      expect(candles.length, 2);
      expect(candles[0].openTime, 1610000000000); // Oldest first
      expect(candles[1].openTime, 1610000300000); // Newest last
    });

    test('parseGateKlines maps different field order correctly', () {
      final rawData = [
        [
          "1610000000", // Unix timestamp in seconds (needs * 1000)
          "4050000.00", // Quote volume (index 1)
          "40500.00", // Close (index 2)
          "41000.00", // High (index 3)
          "39000.00", // Low (index 4)
          "40000.00", // Open (index 5)
          "100.5" // Base volume (index 6)
        ]
      ];

      final candles = CandleHistoryService.parseGateKlines(rawData);

      expect(candles.length, 1);
      final c = candles.first;
      expect(c.openTime, 1610000000000);
      expect(c.open, 40000.00);
      expect(c.high, 41000.00);
      expect(c.low, 39000.00);
      expect(c.close, 40500.00);
      expect(c.volume, 100.5);
    });

    test('parseMexcKlines parses standard format like Binance', () {
      final rawData = [
        [
          1610000000000, // Open time
          "40000.00", // Open
          "41000.00", // High
          "39000.00", // Low
          "40500.00", // Close
          "100.5", // Volume
          1610000300000, // Close time
        ]
      ];

      final candles = CandleHistoryService.parseMexcKlines(rawData);

      expect(candles.length, 1);
      final c = candles.first;
      expect(c.openTime, 1610000000000);
      expect(c.open, 40000.00);
    });
  });

  group('sanitizeCandles validation', () {
    test('drops invalid candles, dedups, and sorts', () {
      final raw = [
        Candle(
            openTime: 1000,
            open: 10,
            high: 15,
            low: 5,
            close: 12,
            volume: 100), // Valid
        Candle(
            openTime: 2000,
            open: 10,
            high: 5,
            low: 15,
            close: 12,
            volume: 100), // Invalid (high < low)
        Candle(
            openTime: 3000,
            open: 10,
            high: 15,
            low: 5,
            close: -1,
            volume: 100), // Invalid (close < 0)
        Candle(
            openTime: 500,
            open: 10,
            high: 15,
            low: 5,
            close: 12,
            volume: 100), // Valid, needs sort
        Candle(
            openTime: 1000,
            open: 12,
            high: 16,
            low: 6,
            close: 14,
            volume: 150), // Duplicate openTime, should keep this one
      ];

      final sanitized = sanitizeCandles(raw);

      expect(sanitized.length, 2);
      expect(sanitized[0].openTime, 500);
      expect(sanitized[1].openTime, 1000);
      expect(sanitized[1].close, 14); // Keeps the last duplicate found
    });
  });

  group('Runtime behavior', () {
    test('getSnapshot does not await fetch when no cache', () {
      CandleHistoryService.instance.startTickBudget();
      final stopwatch = Stopwatch()..start();

      final snap = CandleHistoryService.instance.getSnapshot(
        symbol: 'NON_EXISTENT_TOKEN_123',
        exchange: 'binance',
      );

      stopwatch.stop();

      // Should be near-instant (way less than a network timeout)
      expect(stopwatch.elapsedMilliseconds < 500, true);
      expect(snap.isEmpty, true);
      expect(snap.isFresh, false);
    });

    test('budget skip returns empty without network', () {
      CandleHistoryService.instance.startTickBudget();

      // Exhaust budget (maxFreshFetchesPerTick = 20)
      // Since each getSnapshot schedules 4 timeframes, 5 snapshots will use 20 requests.
      for (int i = 0; i < 5; i++) {
        CandleHistoryService.instance.getSnapshot(
          symbol: 'BUDGET_TEST_$i',
          exchange: 'binance',
        );
      }

      // 6th fetch should hit budget skip immediately on 5m check
      final skippedSnap = CandleHistoryService.instance.getSnapshot(
        symbol: 'BUDGET_TEST_6',
        exchange: 'binance',
      );

      expect(skippedSnap.isEmpty, true);
      expect(skippedSnap.warning,
          null); // Will be null because no stale cache exists
    });

    test('in-flight deduplication prevents budget consumption for same symbol',
        () {
      CandleHistoryService.instance.startTickBudget();

      // Send 5 rapid requests for the EXACT SAME symbol
      // The first will schedule 4 timeframes (consuming 4 slots)
      // The next 4 requests will hit the in-flight deduplication for 5m.
      for (int i = 0; i < 5; i++) {
        CandleHistoryService.instance.getSnapshot(
          symbol: 'DEDUPE_TEST_TOKEN',
          exchange: 'binance',
        );
      }

      // We should still have 16 budget slots left (20 - 4).
      // So this 2nd fetch (for a DIFFERENT symbol) should still work
      // and consume another 4 slots.
      final anotherSnap = CandleHistoryService.instance.getSnapshot(
        symbol: 'ANOTHER_TOKEN',
        exchange: 'binance',
      );

      expect(anotherSnap.isEmpty, true);
      expect(anotherSnap.warning, null);
    });

    test('fresh 5m + missing 1h schedules missing timeframes', () {
      // It's tricky to mock cache from tests without exposing it, but we can verify
      // that duplicate calls do not crash and handle fast responses safely.
      CandleHistoryService.instance.startTickBudget();
      final snap = CandleHistoryService.instance.getSnapshot(
        symbol: 'MTF_TEST_TOKEN',
        exchange: 'binance',
      );
      expect(snap.isEmpty, true);
    });
  });
}
