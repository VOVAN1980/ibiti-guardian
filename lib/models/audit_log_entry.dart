import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/execution_result.dart';

/// Origin of an execution attempt — used to trace where an action was triggered.
enum ExecutionSource {
  /// Initiated directly by the user (manually typed / tapped).
  user,

  /// Initiated by the AI assistant (voice command, chat, intent).
  ai,

  /// Initiated from the Market screen trading plan flow.
  market,

  /// Initiated by the Automation Engine (price trigger, scheduled).
  automation,

  /// Internal system event (audit only).
  system,
}

/// A single entry in the in-memory execution audit log.
///
/// Written after every executed action (send, revoke, swap, approve).
/// In Phase 8 this lives in [AuditLogService] (in-memory, capped at 100 entries).
/// Persistence to local DB is a Phase 9 concern.
class AuditLogEntry {
  /// Unique monotonic ID for this session.
  final int id;

  /// What the user wanted to do.
  final IntentType intentType;

  /// Human-readable label, e.g. "SWAP" / "SEND" / "REVOKE".
  final String actionLabel;

  /// Concise summary, e.g. "Swap 100 USDT → BNB"
  final String summary;

  /// The result of execution.
  final ExecutionResult result;

  /// When the intent was initiated.
  final DateTime initiatedAt;

  /// Where this action originated — used by audit trail and analytics.
  final ExecutionSource executionSource;

  const AuditLogEntry({
    required this.id,
    required this.intentType,
    required this.actionLabel,
    required this.summary,
    required this.result,
    required this.initiatedAt,
    this.executionSource = ExecutionSource.user,
  });
}
