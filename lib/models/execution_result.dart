/// The result of a fully dispatched execution step.
///
/// Produced by [GuardianExecutionService] after a transaction has been
/// signed and submitted. Passed to the audit log and displayed in the chat.
class ExecutionResult {
  /// On-chain transaction hash (null if execution failed before broadcast).
  final String? txHash;

  /// Whether the execution was considered successful on our side.
  final bool success;

  /// Human-readable status message for the UI.
  final String message;

  /// Estimated gas used (in Wei units), if available from simulation.
  final BigInt? gasUsedWei;

  /// The execution path label used (localProtected / epkProtected / fallback).
  final String pathLabel;

  /// ISO-8601 timestamp of when execution completed.
  final DateTime completedAt;

  const ExecutionResult({
    required this.success,
    required this.message,
    required this.pathLabel,
    required this.completedAt,
    this.txHash,
    this.gasUsedWei,
  });

  factory ExecutionResult.success({
    required String txHash,
    required String pathLabel,
    String message = 'Transaction executed successfully.',
    BigInt? gasUsedWei,
  }) =>
      ExecutionResult(
        success: true,
        txHash: txHash,
        message: message,
        pathLabel: pathLabel,
        completedAt: DateTime.now(),
        gasUsedWei: gasUsedWei,
      );

  factory ExecutionResult.failure({
    required String message,
    required String pathLabel,
  }) =>
      ExecutionResult(
        success: false,
        message: message,
        pathLabel: pathLabel,
        completedAt: DateTime.now(),
      );

  /// Short string for audit log display.
  String get auditSummary =>
      success ? '✓ ${txHash?.substring(0, 10) ?? 'ok'}' : '✗ $message';
}
