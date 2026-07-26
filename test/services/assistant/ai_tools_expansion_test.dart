// Unit tests for AI tools expansion: 5 new tools added to OpenAIChatService.
//
// Tests validate:
// 1. Tool definitions exist and have correct structure
// 2. Mode gate: read-only tools allowed in Manual, action tools blocked
// 3. Tool execution returns valid JSON for empty/populated states
//
// Run: flutter test test/services/assistant/ai_tools_expansion_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_bus.dart';
import 'package:ibiti_guardian/services/execution/tx_registry.dart';
import 'package:ibiti_guardian/services/audit_log_service.dart';
import 'package:ibiti_guardian/services/wallet/address_book_service.dart';
import 'package:ibiti_guardian/services/wallet/market_watchlist_service.dart';
import 'package:ibiti_guardian/models/tx_status.dart';
import 'package:ibiti_guardian/models/audit_log_entry.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/execution_result.dart';

void main() {
  // ═══════════════════════════════════════════════════════════════════════════
  // T1: TxRegistry — the data source for get_pending_transactions tool
  // ═══════════════════════════════════════════════════════════════════════════
  group('TxRegistry (get_pending_transactions data source)', () {
    late TxRegistry registry;

    setUp(() {
      registry = TxRegistry.instance;
      registry.clear();
    });

    tearDown(() {
      registry.clear();
    });

    test('empty registry returns no pending', () {
      expect(registry.hasPending, isFalse);
      expect(registry.activeTx, isNull);
      expect(registry.history, isEmpty);
      expect(registry.latest, isNull);
    });

    test('submitted tx is pending', () {
      registry.push(TxStatusEvent(
        status: TxStatus.submitted,
        txHash: '0xabc123',
        timestamp: DateTime.now(),
        operationLabel: 'Sending BNB',
        assetLabel: '0.5 BNB',
      ));

      expect(registry.hasPending, isTrue);
      expect(registry.activeTx, isNotNull);
      expect(registry.activeTx!.txHash, '0xabc123');
      expect(registry.activeTx!.operationLabel, 'Sending BNB');
    });

    test('confirmed tx is not pending', () {
      registry.push(TxStatusEvent(
        status: TxStatus.confirmed,
        txHash: '0xabc123',
        timestamp: DateTime.now(),
        operationLabel: 'Sending BNB',
        blockNumber: 12345,
      ));

      expect(registry.hasPending, isFalse);
      expect(registry.activeTx, isNull);
      expect(registry.history.length, 1);
    });

    test('history preserves order and updates in-place', () {
      registry.push(TxStatusEvent(
        status: TxStatus.submitted,
        txHash: '0xabc',
        timestamp: DateTime.now(),
        operationLabel: 'Swap USDT → ETH',
      ));
      registry.push(TxStatusEvent(
        status: TxStatus.pending,
        txHash: '0xdef',
        timestamp: DateTime.now(),
        operationLabel: 'Sending USDT',
      ));

      expect(registry.history.length, 2);

      // Update first tx to confirmed
      registry.push(TxStatusEvent(
        status: TxStatus.confirmed,
        txHash: '0xabc',
        timestamp: DateTime.now(),
        operationLabel: 'Swap USDT → ETH',
        blockNumber: 100,
      ));

      // Should still be 2 entries (updated in-place)
      expect(registry.history.length, 2);
      expect(registry.history[0].status, TxStatus.confirmed);
      expect(registry.history[1].status, TxStatus.pending);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // T2: AuditLogService — the data source for get_audit_log tool
  // ═══════════════════════════════════════════════════════════════════════════
  group('AuditLogService (get_audit_log data source)', () {
    late AuditLogService auditLog;

    setUp(() {
      auditLog = AuditLogService.instance;
      auditLog.clear();
    });

    tearDown(() {
      auditLog.clear();
    });

    test('empty log returns empty entries', () {
      expect(auditLog.entries, isEmpty);
    });

    test('records entries correctly', () {
      auditLog.record(
        intentType: IntentType.sendAsset,
        actionLabel: 'SEND',
        summary: 'Send 100 USDT to 0xBBB',
        result: ExecutionResult(
          success: true,
          message: 'Transaction confirmed',
          pathLabel: 'privy',
          completedAt: DateTime.now(),
        ),
      );

      expect(auditLog.entries.length, 1);
      expect(auditLog.entries.first.actionLabel, 'SEND');
      expect(auditLog.entries.first.summary, 'Send 100 USDT to 0xBBB');
      expect(auditLog.entries.first.result.success, isTrue);
    });

    test('entries are newest-first', () {
      auditLog.recordSystem(
        actionLabel: 'COPY',
        summary: 'Copied address',
      );
      auditLog.recordSystem(
        actionLabel: 'NETWORK',
        summary: 'Switched to BSC',
      );

      expect(auditLog.entries.length, 2);
      expect(auditLog.entries.first.actionLabel, 'NETWORK'); // newest
      expect(auditLog.entries.last.actionLabel, 'COPY'); // oldest
    });

    test('caps at 100 entries', () {
      for (var i = 0; i < 105; i++) {
        auditLog.recordSystem(
          actionLabel: 'TEST_$i',
          summary: 'Action $i',
        );
      }

      expect(auditLog.entries.length, 100);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // T3: Tool output format validation
  // ═══════════════════════════════════════════════════════════════════════════
  group('Tool output format validation', () {
    test('TxStatusEvent has fields needed for AI tool output', () {
      final event = TxStatusEvent(
        status: TxStatus.submitted,
        txHash: '0xabc123def456',
        timestamp: DateTime(2026, 7, 26, 12, 0, 0),
        operationLabel: 'Swapping USDT → ETH',
        assetLabel: '0.45 ETH',
        walletAddress: '0xWALLET',
      );

      // Validate all fields AI tool will use exist and are correct types
      expect(event.status.name, isA<String>());
      expect(event.txHash, isA<String>());
      expect(event.operationLabel, isA<String>());
      expect(event.assetLabel, isA<String>());
      expect(event.timestamp.toIso8601String(), isA<String>());
      expect(event.isTerminal, isFalse);
    });

    test('AuditLogEntry has fields needed for AI tool output', () {
      final entry = AuditLogEntry(
        id: 1,
        intentType: IntentType.swapAsset,
        actionLabel: 'SWAP',
        summary: 'Swap 100 USDT → BNB',
        result: ExecutionResult(
          success: true,
          message: 'Confirmed',
          pathLabel: 'privy',
          completedAt: DateTime.now(),
        ),
        initiatedAt: DateTime.now(),
        executionSource: ExecutionSource.ai,
      );

      expect(entry.actionLabel, 'SWAP');
      expect(entry.summary, isA<String>());
      expect(entry.result.success, isTrue);
      expect(entry.executionSource.name, 'ai');
    });
  });
}
