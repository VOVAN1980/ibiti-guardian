import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/models/audit_log_entry.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/execution_result.dart';

/// In-memory audit log for all executed actions in this session.
///
/// Phase 8: capped at 100 entries per session.
/// Phase 9+: persist to local SQLite / Hive.
class AuditLogService extends ChangeNotifier {
  AuditLogService._();
  static final instance = AuditLogService._();

  static const _log = GuardianLogger('AuditLog');

  final List<AuditLogEntry> _entries = [];
  int _nextId = 1;

  /// All recorded entries, newest first.
  List<AuditLogEntry> get entries =>
      List.unmodifiable(_entries.reversed.toList());

  /// Add a new entry. Called by execution services after each dispatched tx.
  void record({
    required IntentType intentType,
    required String actionLabel,
    required String summary,
    required ExecutionResult result,
    DateTime? initiatedAt,
    ExecutionSource executionSource = ExecutionSource.user,
  }) {
    final entry = AuditLogEntry(
      id: _nextId++,
      intentType: intentType,
      actionLabel: actionLabel,
      summary: summary,
      result: result,
      initiatedAt: initiatedAt ?? DateTime.now(),
      executionSource: executionSource,
    );

    _entries.add(entry);

    // Cap at 100 — drop oldest
    if (_entries.length > 100) {
      _entries.removeAt(0);
    }

    _log.d('#${entry.id} [${entry.executionSource.name}] '
        '${entry.actionLabel}: ${entry.result.auditSummary}');
    notifyListeners();
  }

  void recordSystem({
    required String actionLabel,
    required String summary,
    bool success = true,
    String message = '',
    String pathLabel = 'system',
  }) {
    record(
      intentType: IntentType.unknown,
      actionLabel: actionLabel,
      summary: summary,
      result: ExecutionResult(
        success: success,
        message: message,
        pathLabel: pathLabel,
        completedAt: DateTime.now(),
      ),
    );
  }

  void recordAddressCopy({
    required String address,
    required String networkLabel,
  }) {
    recordSystem(
      actionLabel: 'COPY',
      summary: 'Copied $networkLabel address ${_short(address)}',
    );
  }

  void recordNetworkSwitch({
    required String fromNetwork,
    required String toNetwork,
    required bool success,
    String? message,
  }) {
    recordSystem(
      actionLabel: 'NETWORK',
      summary: 'Switched network $fromNetwork -> $toNetwork',
      success: success,
      message: message ?? '',
    );
  }

  void recordPolicyBlock({
    required IntentType intentType,
    required String actionLabel,
    required String summary,
    required String reason,
    ExecutionSource executionSource = ExecutionSource.user,
  }) {
    record(
      intentType: intentType,
      actionLabel: actionLabel,
      summary: summary,
      executionSource: executionSource,
      result: ExecutionResult.failure(
        message: reason,
        pathLabel: 'policy_block',
      ),
    );
  }

  /// Records a policy block that originated from the Market screen.
  /// Convenience method — always tags with [ExecutionSource.market].
  void recordMarketPolicyBlock({
    required String assetSymbol,
    required String reason,
  }) {
    recordPolicyBlock(
      intentType: IntentType.swapAsset,
      actionLabel: 'MARKET_SWAP_BLOCKED',
      summary: 'Market swap for $assetSymbol blocked before UI opened.',
      reason: reason,
      executionSource: ExecutionSource.market,
    );
  }

  /// Clear all entries (e.g. on wallet disconnect / logout).
  void clear() {
    _entries.clear();
    notifyListeners();
  }

  String _short(String value) {
    if (value.length < 12) return value;
    return '${value.substring(0, 6)}...${value.substring(value.length - 4)}';
  }
}
