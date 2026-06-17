import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/models/audit_log_entry.dart';
import 'package:ibiti_guardian/models/automation_trigger.dart';
import 'package:ibiti_guardian/models/dispatch_item.dart';
import 'package:ibiti_guardian/models/execution_result.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/services/audit_log_service.dart';
import 'package:ibiti_guardian/services/execution/guardian_execution_controller.dart';
import 'package:ibiti_guardian/services/market/automation_intent_builder.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/market/market_policy_gate.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';

// ─── AutomationDispatchService ─────────────────────────────────────────────────

/// Manages the queue of automation execution intents and processes them
/// safely through the existing policy/execution tunnel.
///
/// ## Safety contract (never violated):
/// ```
/// Trigger fires
///   → enqueue()         [AutomationEngine puts item here]
///   → processNext()     [timer picks up pending item]
///   → _reCheck()        [mode / mandate / wallet re-validated at execution time]
///   → MarketPolicyGate  [planning-layer policy gate]
///   → GuardianPolicyEngine [non-bypassable execution gate — Phase 5b]
///   → EPK / execution controller
/// ```
///
/// No item ever executes by jumping straight to the chain.
/// If the mode changed since enqueueing, the item is blocked immediately.
/// All transitions are logged as [ExecutionSource.automation].
///
/// ## Queue rules
/// - Max [_maxQueueSize] pending items. New items beyond that are dropped (logged).
/// - Items older than [_maxAgeMinutes] are expired before processing.
/// - Only one item processes at a time (serial queue).
/// - Terminal items are kept for [_historySize] entries for UI display.
class AutomationDispatchService extends ChangeNotifier {
  AutomationDispatchService._();
  static final AutomationDispatchService instance =
      AutomationDispatchService._();

  static const _log = GuardianLogger('Dispatch');

  static const int _maxQueueSize = 10;
  static const int _maxAgeMinutes = 60;
  static const int _historySize = 30;
  static const int _processingIntervalSeconds = 5;

  final List<DispatchItem> _queue = [];
  Timer? _processorTimer;
  bool _isProcessing = false;

  // ── Public accessors ────────────────────────────────────────────────────────

  /// All queue items (pending + active), newest first.
  List<DispatchItem> get pendingItems =>
      _queue.where((i) => !i.isTerminal).toList().reversed.toList();

  /// Terminal items kept for history display, newest first.
  List<DispatchItem> get historyItems => _queue
      .where((i) => i.isTerminal)
      .toList()
      .reversed
      .take(_historySize)
      .toList();

  /// Full queue (for status badges etc.), newest first.
  List<DispatchItem> get allItems =>
      List.unmodifiable(_queue.reversed.toList());

  int get pendingCount => _queue.where((i) => i.isPending).length;

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  void start() {
    _processorTimer?.cancel();
    _processorTimer = Timer.periodic(
      const Duration(seconds: _processingIntervalSeconds),
      (_) => _processorTick(),
    );
    _log.d('Started (tick every ${_processingIntervalSeconds}s)');
  }

  void stop() {
    _processorTimer?.cancel();
    _processorTimer = null;
    _log.d('Stopped');
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  // ── Enqueue ─────────────────────────────────────────────────────────────────

  /// Add an automation execution intent to the queue.
  ///
  /// Called by [AutomationEngine] when a trigger fires with
  /// [TriggerAction.execute] and mode is [AiMode.fullAutonomy].
  ///
  /// Returns null if the item was rejected (queue full, or mode not Full).
  DispatchItem? enqueue({
    required AutomationTrigger trigger,
    required String reason,
    required double currentPrice,
  }) {
    // Hard guard: only Full Autonomy mode gets real queue execution.
    final mode = AiControlService.instance.settings.mode;
    if (mode != AiMode.fullAutonomy) {
      _logAudit(
        label: 'DISPATCH_REJECTED_MODE',
        summary: 'Enqueue rejected for ${trigger.assetSymbol}: '
            'mode is ${mode.name}, Full Autonomy required.',
        status: DispatchStatus.blocked,
        trigger: trigger,
        reason:
            'Mode is ${mode.name} — execution enqueue requires Full Autonomy.',
      );
      return null;
    }

    // Capacity guard.
    final pendingNow = _queue.where((i) => i.isPending).length;
    if (pendingNow >= _maxQueueSize) {
      _logAudit(
        label: 'DISPATCH_QUEUE_FULL',
        summary: 'Queue full ($pendingNow pending). '
            'Dropping ${trigger.label}.',
        status: DispatchStatus.blocked,
        trigger: trigger,
        reason: 'Queue is full — item dropped.',
      );
      return null;
    }

    final item = DispatchItem(
      id: '${trigger.id}_${DateTime.now().millisecondsSinceEpoch}',
      trigger: trigger,
      assetSymbol: trigger.assetSymbol,
      triggerPrice: currentPrice,
      reason: reason,
      enqueuedAt: DateTime.now(),
      status: DispatchStatus.pending,
    );

    _queue.add(item);
    _logAudit(
      label: 'DISPATCH_ENQUEUED',
      summary: '[${trigger.label}] Queued: $reason '
          '(price: \$${currentPrice.toStringAsFixed(2)})',
      status: DispatchStatus.pending,
      trigger: trigger,
      reason: reason,
    );
    _log.d('Enqueued: ${item.id}');
    notifyListeners();
    return item;
  }

  // ── Manual controls ─────────────────────────────────────────────────────────

  /// Cancel a pending item before it is processed.
  void cancelItem(String id) {
    final i = _queue.indexWhere((item) => item.id == id);
    if (i < 0) return;
    if (_queue[i].isTerminal) return; // already resolved
    _queue[i] = _queue[i].copyWith(
      status: DispatchStatus.blocked,
      resolvedAt: DateTime.now(),
      blockReason: 'Cancelled by user.',
    );
    _logAudit(
      label: 'DISPATCH_CANCELLED',
      summary: 'Item ${_queue[i].trigger.label} cancelled by user.',
      status: DispatchStatus.blocked,
      trigger: _queue[i].trigger,
      reason: 'User cancelled.',
    );
    notifyListeners();
  }

  // ── Processor tick ──────────────────────────────────────────────────────────

  void _processorTick() {
    if (_isProcessing) return; // serial — only one at a time
    _expireOldItems();

    final nextIndex = _queue.indexWhere((i) => i.isPending);
    if (nextIndex < 0) return; // nothing to do

    _processItem(nextIndex);
  }

  Future<void> _processItem(int index) async {
    _isProcessing = true;
    final now = DateTime.now();

    // Mark as processing.
    _queue[index] = _queue[index].copyWith(
      status: DispatchStatus.processing,
      processingStartedAt: now,
    );
    notifyListeners();

    final item = _queue[index];
    _log.d('Processing: ${item.id}');

    _logAudit(
      label: 'DISPATCH_PROCESSING',
      summary: '[${item.trigger.label}] Processing started.',
      status: DispatchStatus.processing,
      trigger: item.trigger,
      reason: item.reason,
    );

    // ── Re-check: Everything must still be valid at execution time ────────────
    final blockReason = _reCheckSafety(item);
    if (blockReason != null) {
      _resolveItem(index, DispatchStatus.blocked, blockReason);
      _isProcessing = false;
      return;
    }

    // ── Market policy gate ────────────────────────────────────────────────────
    final asset = MarketDataService.instance.cachedMarkets
        .cast<MarketAsset?>()
        .firstWhere(
          (a) => a!.symbol.toLowerCase() == item.assetSymbol.toLowerCase(),
          orElse: () => null,
        );

    if (asset == null) {
      _resolveItem(index, DispatchStatus.failed,
          'Asset ${item.assetSymbol} not found in market cache at execution time.');
      _isProcessing = false;
      return;
    }

    final gateResult = MarketPolicyGate.instance.checkSwap(asset);
    if (gateResult.isBlocked) {
      _resolveItem(
        index,
        DispatchStatus.blocked,
        'Policy gate: ${gateResult.reason}',
      );
      _isProcessing = false;
      return;
    }

    // ── Build IntentData from the dispatch item ───────────────────────────────
    final intentResult = AutomationIntentBuilder.buildBuy(item);
    if (intentResult is AutomationIntentBlocked) {
      _resolveItem(
        index,
        DispatchStatus.blocked,
        'Intent build: ${intentResult.reason}',
      );
      _isProcessing = false;
      return;
    }
    final intent = (intentResult as AutomationIntentReady).intent;

    // ── Hand off to GuardianExecutionController ───────────────────────────────
    // This goes through the full hardened path:
    //   intent.isAutomated == true
    //     → _orchestrateSwap() → GuardianPolicyEngine → SandboxGuard
    //     → approvedForAuto → _executor.dispatchConfiguredPath()
    // All policy and EPK checks happen inside the controller — no bypass.
    AssistantResponse response;
    try {
      response = await GuardianExecutionController.instance.orchestrate(
        IntentAction(
          intent: intent,
          requiresExecution: true,
          requiresConfirmation: false, // Full Autonomy: no user confirmation
        ),
      );
    } catch (e) {
      _resolveItem(
        index,
        DispatchStatus.failed,
        'Execution controller threw: $e',
      );
      _isProcessing = false;
      return;
    }

    // ── Map response to dispatch status ───────────────────────────────────────
    if (response.type == ResponseType.error) {
      _resolveItem(
        index,
        DispatchStatus.failed,
        'Execution failed: ${response.message}',
      );
    } else if (response.type == ResponseType.action) {
      _resolveItem(
        index,
        DispatchStatus.done,
        null,
        doneMessage: '[${item.trigger.label}] Executed via automation path. '
            '${response.message}',
      );
    } else {
      // requireManualReview or preview — sandbox demoted to user review.
      // This is NOT an error — it means the trade is safe but needs eyes.
      _resolveItem(
        index,
        DispatchStatus.blocked,
        'Sandbox requires manual review — trade demoted to user queue. '
        'Check the Assistant tab for preview.',
      );
    }

    _isProcessing = false;
  }

  // ── Safety re-check ─────────────────────────────────────────────────────────

  /// Validates all safety conditions at the moment the item is about to execute.
  /// Returns a human-readable block reason, or null if everything is clear.
  String? _reCheckSafety(DispatchItem item) {
    final settings = AiControlService.instance.settings;

    // 1. Mode must still be Full Autonomy.
    if (settings.mode != AiMode.fullAutonomy) {
      return 'Mode changed to ${settings.mode.name} since enqueue — '
          'execution blocked. Only Full Autonomy can execute automatically.';
    }

    // 2. Wallet must still be connected.
    if (!WalletAdapter.instance.isConnected) {
      return 'Wallet disconnected since enqueue — execution blocked.';
    }

    // 3. Asset must still be in mandate.
    if (!settings.mandate.allowsAsset(item.assetSymbol)) {
      return '${item.assetSymbol} is no longer in mandate allowed-assets — '
          'execution blocked.';
    }

    // 4. Network must still be in mandate.
    final chainKey = WalletAdapter.instance.chainKey;
    if (chainKey.isNotEmpty && !settings.mandate.allowsNetwork(chainKey)) {
      return 'Network $chainKey is no longer in mandate — execution blocked.';
    }

    return null; // all clear
  }

  // ── Expiry ──────────────────────────────────────────────────────────────────

  void _expireOldItems() {
    final cutoff =
        DateTime.now().subtract(const Duration(minutes: _maxAgeMinutes));
    for (int i = 0; i < _queue.length; i++) {
      final item = _queue[i];
      if (item.isPending && item.enqueuedAt.isBefore(cutoff)) {
        _queue[i] = item.copyWith(
          status: DispatchStatus.blocked,
          resolvedAt: DateTime.now(),
          blockReason: 'Item expired after $_maxAgeMinutes minutes in queue.',
        );
        _logAudit(
          label: 'DISPATCH_EXPIRED',
          summary: '[${item.trigger.label}] Expired after $_maxAgeMinutes min.',
          status: DispatchStatus.blocked,
          trigger: item.trigger,
          reason: 'Queue item age exceeded limit.',
        );
      }
    }
    // Trim history to _historySize terminal items.
    final terminal = _queue.where((i) => i.isTerminal).toList();
    if (terminal.length > _historySize) {
      final toRemove = terminal.take(terminal.length - _historySize).toSet();
      _queue.removeWhere(toRemove.contains);
    }
  }

  // ── Internal helpers ────────────────────────────────────────────────────────

  void _resolveItem(
    int index,
    DispatchStatus status,
    String? blockReason, {
    String? doneMessage,
  }) {
    final item = _queue[index];
    _queue[index] = item.copyWith(
      status: status,
      resolvedAt: DateTime.now(),
      blockReason: blockReason,
    );

    final label = switch (status) {
      DispatchStatus.done => 'DISPATCH_DONE',
      DispatchStatus.blocked => 'DISPATCH_BLOCKED',
      DispatchStatus.failed => 'DISPATCH_FAILED',
      _ => 'DISPATCH_RESOLVED',
    };

    _logAudit(
      label: label,
      summary: doneMessage ??
          '[${item.trigger.label}] ${status.name}: '
              '${blockReason ?? "completed"}',
      status: status,
      trigger: item.trigger,
      reason: blockReason ?? doneMessage ?? status.name,
    );

    _log.d('$label: ${item.id}');
    notifyListeners();
  }

  void _logAudit({
    required String label,
    required String summary,
    required DispatchStatus status,
    required AutomationTrigger trigger,
    required String reason,
  }) {
    final success = status == DispatchStatus.done ||
        status == DispatchStatus.pending ||
        status == DispatchStatus.processing;

    AuditLogService.instance.record(
      intentType: IntentType.swapAsset,
      actionLabel: label,
      summary: summary,
      executionSource: ExecutionSource.automation,
      result: success
          ? ExecutionResult.success(
              txHash: '',
              pathLabel: 'automation_dispatch',
              message: reason,
            )
          : ExecutionResult.failure(
              pathLabel: 'automation_dispatch',
              message: reason,
            ),
    );
  }
}
