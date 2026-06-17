import 'package:ibiti_guardian/models/automation_trigger.dart';

// ─── Queue Item Status ─────────────────────────────────────────────────────────

/// Lifecycle state of a single automation dispatch item.
enum DispatchStatus {
  /// Waiting in queue — not yet picked up by the processor.
  pending,

  /// Currently being validated and executed by the processor.
  processing,

  /// Passed all checks and executed (or execution handed to EPK).
  done,

  /// Blocked by policy / mandate / mode change / wallet disconnect.
  blocked,

  /// Unexpected error during processing.
  failed,
}

// ─── DispatchItem ──────────────────────────────────────────────────────────────

/// A single automation execution intent waiting in the dispatch queue.
///
/// Immutable — mutations return new instances via [copyWith].
class DispatchItem {
  /// Auto-generated unique ID.
  final String id;

  /// The trigger that created this item.
  final AutomationTrigger trigger;

  /// Symbol the action targets.
  final String assetSymbol;

  /// Price at the time the trigger fired.
  final double triggerPrice;

  /// Human-readable description of what happened.
  final String reason;

  /// Current processing state.
  final DispatchStatus status;

  /// When this item was added to the queue.
  final DateTime enqueuedAt;

  /// When processing started. Null if still pending.
  final DateTime? processingStartedAt;

  /// When processing finished (done, blocked, or failed).
  final DateTime? resolvedAt;

  /// Why the item was blocked or failed. Null when pending/processing/done.
  final String? blockReason;

  bool get isPending => status == DispatchStatus.pending;
  bool get isProcessing => status == DispatchStatus.processing;
  bool get isDone => status == DispatchStatus.done;
  bool get isTerminal =>
      status == DispatchStatus.done ||
      status == DispatchStatus.blocked ||
      status == DispatchStatus.failed;

  const DispatchItem({
    required this.id,
    required this.trigger,
    required this.assetSymbol,
    required this.triggerPrice,
    required this.reason,
    required this.enqueuedAt,
    this.status = DispatchStatus.pending,
    this.processingStartedAt,
    this.resolvedAt,
    this.blockReason,
  });

  DispatchItem copyWith({
    DispatchStatus? status,
    DateTime? processingStartedAt,
    DateTime? resolvedAt,
    String? blockReason,
  }) =>
      DispatchItem(
        id: id,
        trigger: trigger,
        assetSymbol: assetSymbol,
        triggerPrice: triggerPrice,
        reason: reason,
        enqueuedAt: enqueuedAt,
        status: status ?? this.status,
        processingStartedAt: processingStartedAt ?? this.processingStartedAt,
        resolvedAt: resolvedAt ?? this.resolvedAt,
        blockReason: blockReason ?? this.blockReason,
      );

  /// Short label for UI display.
  String get statusLabel => switch (status) {
        DispatchStatus.pending => 'Pending',
        DispatchStatus.processing => 'Processing…',
        DispatchStatus.done => 'Done',
        DispatchStatus.blocked => 'Blocked',
        DispatchStatus.failed => 'Failed',
      };
}
