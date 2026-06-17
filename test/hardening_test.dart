// Unit tests for Phase G: Money Model, IntentData serialization, UICommandBus TTL.
//
// Run: flutter test test/hardening_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_bus.dart';
import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/services/pro/pro_service.dart';

/// Helper to create a minimal IntentData for test transactions.
IntentData _stubIntent([String raw = 'test']) =>
    IntentData(type: IntentType.unknown, rawInput: raw);

void main() {
  // ═══════════════════════════════════════════════════════════════════════════
  // G1: TransactionRequest.atomicAmount
  // ═══════════════════════════════════════════════════════════════════════════
  group('TransactionRequest.atomicAmount', () {
    test('returns rawAmount when set (source of truth)', () {
      final raw = BigInt.parse('20000000000000000000');
      final tx = TransactionRequest(
        type: TransactionType.send,
        fromAddress: '0xAAA',
        toAddress: '0xBBB',
        tokenSymbol: 'USDT',
        tokenContract: '0x55d398326f99059fF775485246999027B3197955',
        amount: 20.0,
        rawAmount: raw,
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent: _stubIntent(),
      );
      expect(tx.atomicAmount, equals(raw));
    });

    test('returns null for ERC-20 without rawAmount', () {
      final tx = TransactionRequest(
        type: TransactionType.send,
        fromAddress: '0xAAA',
        toAddress: '0xBBB',
        tokenSymbol: 'USDT',
        tokenContract: '0x55d398326f99059fF775485246999027B3197955',
        amount: 20.0,
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent: _stubIntent(),
      );
      // ERC-20 token → rawAmount must be set explicitly
      expect(tx.atomicAmount, isNull);
    });

    test('computes fallback for verified native BNB send', () {
      final tx = TransactionRequest(
        type: TransactionType.send,
        fromAddress: '0xAAA',
        toAddress: '0xBBB',
        tokenSymbol: 'BNB',
        amount: 1.0,
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent: _stubIntent(),
      );
      // Native BNB send → fallback from amount * 10^18
      expect(tx.atomicAmount, isNotNull);
      expect(tx.atomicAmount, equals(BigInt.from(10).pow(18)));
    });

    test('returns null for native symbol mismatch (USDT with no contract)', () {
      final tx = TransactionRequest(
        type: TransactionType.send,
        fromAddress: '0xAAA',
        toAddress: '0xBBB',
        tokenSymbol: 'USDT',
        // tokenContract is null, but symbol is NOT native → blocked
        amount: 20.0,
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent: _stubIntent(),
      );
      expect(tx.atomicAmount, isNull);
    });

    test('returns null for approve type even with native symbol', () {
      final tx = TransactionRequest(
        type: TransactionType.approve,
        fromAddress: '0xAAA',
        toAddress: '0xBBB',
        tokenSymbol: 'BNB',
        amount: 100.0,
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent: _stubIntent(),
      );
      // Approve MUST have rawAmount — no fallback
      expect(tx.atomicAmount, isNull);
    });

    test('returns null for swap type', () {
      final tx = TransactionRequest(
        type: TransactionType.swap,
        fromAddress: '0xAAA',
        toAddress: '0xBBB',
        tokenSymbol: 'BNB',
        amount: 5.0,
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent: _stubIntent(),
      );
      expect(tx.atomicAmount, isNull);
    });

    test('returns BigInt.zero for revoke with rawAmount=0', () {
      final tx = TransactionRequest(
        type: TransactionType.revoke,
        fromAddress: '0xAAA',
        toAddress: '0xBBB',
        rawAmount: BigInt.zero,
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent: _stubIntent(),
      );
      expect(tx.atomicAmount, equals(BigInt.zero));
    });

    test('returns null when both rawAmount and amount are null', () {
      final tx = TransactionRequest(
        type: TransactionType.send,
        fromAddress: '0xAAA',
        toAddress: '0xBBB',
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent: _stubIntent(),
      );
      expect(tx.atomicAmount, isNull);
    });

    test('native ETH send on Ethereum computes correctly', () {
      final tx = TransactionRequest(
        type: TransactionType.send,
        fromAddress: '0xAAA',
        toAddress: '0xBBB',
        tokenSymbol: 'ETH',
        amount: 0.5,
        chainId: 1,
        chainKey: 'eth',
        sourceIntent: _stubIntent(),
      );
      expect(tx.atomicAmount, isNotNull);
      // 0.5 * 10^18 = 500000000000000000
      expect(tx.atomicAmount, equals(BigInt.parse('500000000000000000')));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // G2: IntentData JSON round-trip
  // ═══════════════════════════════════════════════════════════════════════════
  group('IntentData JSON round-trip', () {
    test('preserves all fields through toJson/fromJson', () {
      final original = IntentData(
        type: IntentType.swapAsset,
        rawInput: 'swap 10 USDT to BNB',
        tokenSymbol: 'USDT',
        amount: 10.0,
        rawAmount: BigInt.parse('10000000000000000000'),
        sourceTokenSymbol: 'USDT',
        sourceTokenAddress: '0xUSDT',
        targetTokenSymbol: 'BNB',
        targetTokenAddress: '0xBNB',
        sourceTokenDecimals: 18,
        targetTokenDecimals: 18,
        slippageBps: 50,
        sourceTrigger: 'voice',
      );

      final json = original.toJson();
      final restored = IntentData.fromJson(json);

      expect(restored.type, equals(IntentType.swapAsset));
      expect(restored.rawInput, equals('swap 10 USDT to BNB'));
      expect(restored.tokenSymbol, equals('USDT'));
      expect(restored.amount, equals(10.0));
      expect(restored.rawAmount, equals(BigInt.parse('10000000000000000000')));
      expect(restored.sourceTokenSymbol, equals('USDT'));
      expect(restored.sourceTokenAddress, equals('0xUSDT'));
      expect(restored.targetTokenSymbol, equals('BNB'));
      expect(restored.targetTokenAddress, equals('0xBNB'));
      expect(restored.sourceTokenDecimals, equals(18));
      expect(restored.targetTokenDecimals, equals(18));
      expect(restored.slippageBps, equals(50));
      expect(restored.sourceTrigger, equals('voice'));
    });

    test('rawAmount survives as string in JSON (no precision loss)', () {
      final big = BigInt.parse('999999999999999999999999999');
      final intent = IntentData(
        type: IntentType.sendAsset,
        rawInput: 'send big amount',
        rawAmount: big,
      );

      final json = intent.toJson();
      final params = json['params'] as Map<String, dynamic>;
      // rawAmount stored as String, not number
      expect(params['rawAmount'], equals(big.toString()));

      final restored = IntentData.fromJson(json);
      expect(restored.rawAmount, equals(big));
    });

    test('handles null optional fields gracefully', () {
      final intent = IntentData(
        type: IntentType.unknown,
        rawInput: 'test',
      );

      final json = intent.toJson();
      final restored = IntentData.fromJson(json);

      expect(restored.rawAmount, isNull);
      expect(restored.sourceTokenDecimals, isNull);
      expect(restored.targetTokenDecimals, isNull);
      expect(restored.sourceTrigger, isNull);
      expect(restored.slippageBps, isNull);
    });

    test('6-decimal token decimals survive round-trip', () {
      final intent = IntentData(
        type: IntentType.sendAsset,
        rawInput: 'send USDC',
        sourceTokenDecimals: 6,
        targetTokenDecimals: 8,
      );

      final json = intent.toJson();
      final restored = IntentData.fromJson(json);

      expect(restored.sourceTokenDecimals, equals(6));
      expect(restored.targetTokenDecimals, equals(8));
    });

    test('isAutomated flag persists via sourceTrigger', () {
      final intent = IntentData(
        type: IntentType.swapAsset,
        rawInput: 'auto swap',
        sourceTrigger: 'market_scout',
      );

      expect(intent.isAutomated, isTrue);

      final restored = IntentData.fromJson(intent.toJson());
      expect(restored.isAutomated, isTrue);
      expect(restored.sourceTrigger, equals('market_scout'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // G3: UICommandBus TTL
  // ═══════════════════════════════════════════════════════════════════════════
  group('UICommandBus TTL', () {
    test('field value is readable after dispatch', () {
      final bus = UICommandBus.testInstance();

      bus.dispatch(UICommand(
        type: UICommandType.fillField,
        target: 'amount_field',
        payload: {'value': '100'},
      ));

      expect(bus.latestFieldValue('amount_field'), equals('100'));
    });

    test('pending action can be consumed once', () {
      final bus = UICommandBus.testInstance();

      bus.dispatch(UICommand(
        type: UICommandType.executeAction,
        target: 'confirm_send',
      ));

      expect(bus.consumePendingAction('confirm_send'), isTrue);
      // Second consume should return false
      expect(bus.consumePendingAction('confirm_send'), isFalse);
    });

    test('payload is accessible after dispatch', () {
      final bus = UICommandBus.testInstance();

      bus.dispatch(UICommand(
        type: UICommandType.fillField,
        target: 'swap_config',
        payload: {'tokenIn': 'USDT', 'tokenOut': 'BNB'},
      ));

      final payload = bus.latestPayload('swap_config');
      expect(payload, isNotNull);
      expect(payload!['tokenIn'], equals('USDT'));
      expect(payload['tokenOut'], equals('BNB'));
    });

    test('unknown field returns null', () {
      final bus = UICommandBus.testInstance();
      expect(bus.latestFieldValue('nonexistent'), isNull);
      expect(bus.latestPayload('nonexistent'), isNull);
      expect(bus.consumePendingAction('nonexistent'), isFalse);
    });

    test('entries older than 60s are purged on read', () {
      final bus = UICommandBus.testInstance();

      // Dispatch all three types of cached data.
      bus.dispatch(UICommand(
        type: UICommandType.fillField,
        target: 'amount',
        payload: {'value': '42'},
      ));
      bus.dispatch(UICommand(
        type: UICommandType.fillField,
        target: 'config',
        payload: {'slippage': '50'},
      ));
      bus.dispatch(UICommand(
        type: UICommandType.executeAction,
        target: 'confirm',
      ));

      // Sanity: all accessible before backdate.
      expect(bus.latestFieldValue('amount'), equals('42'));
      expect(bus.latestPayload('config'), isNotNull);

      // Simulate 61 seconds passing.
      bus.backdateTimestamps(const Duration(seconds: 61));

      // After TTL: all three caches should return null/false.
      expect(bus.latestFieldValue('amount'), isNull);
      expect(bus.latestPayload('config'), isNull);
      expect(bus.consumePendingAction('confirm'), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // G4: Review mode flag sanity
  // ═══════════════════════════════════════════════════════════════════════════
  group('Review mode flag', () {
    test('isReviewBuild defaults to false in normal builds', () {
      // bool.fromEnvironment('REVIEW_BUILD') is false unless
      // --dart-define=REVIEW_BUILD=true is passed at build time.
      expect(ProService.isReviewBuild, isFalse);
    });

    test('isProActive returns false for fresh instance without review flag',
        () {
      // In a normal build (isReviewBuild == false), a fresh ProService
      // starts with ProStatus.free() → isProActive() must be false.
      final pro = ProService.instance;
      // Since isReviewBuild is false in test, and no subscription loaded:
      expect(pro.isProActive(), isFalse);
    });
  });
}
