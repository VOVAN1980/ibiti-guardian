import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/models/audit_log_entry.dart';
import 'package:ibiti_guardian/models/automation_trigger.dart';
import 'package:ibiti_guardian/models/dispatch_item.dart';
import 'package:ibiti_guardian/models/execution_result.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/services/audit_log_service.dart';
import 'package:ibiti_guardian/services/execution/ai_onchain_executor.dart';
import 'package:ibiti_guardian/services/execution/guardian_execution_controller.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
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
/// No item ever executes by jumping straight to the chain: the swap preview
/// goes through [AiOnchainExecutor] and so through [AiActionGate] (card + PIN,
/// or no PIN within the daily limit, «AI Мандат», EPK and trusted targets).
/// If the mode changed since enqueueing, the item is blocked immediately.
/// The user's Cancel wins, also while the confirmation card is open.
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

  /// Pause after the gate could not ask anybody (app in the background), the
  /// card closed unanswered, or another AI operation held the lock, so a
  /// waiting item is not re-quoted every tick.
  static const Duration _deferDelay = Duration(seconds: 30);

  final List<DispatchItem> _queue = [];
  Timer? _processorTimer;
  bool _isProcessing = false;
  DateTime? _deferredUntil;

  /// Test seam: replaces the controller's orchestrate call.
  @visibleForTesting
  Future<AssistantResponse> Function(IntentAction action)? orchestrateOverride;

  /// Test seam: replaces [AiOnchainExecutor.executePreview].
  @visibleForTesting
  Future<AiExecResult> Function(
    AssistantResponse preview, {
    required String source,
    bool Function()? stillWanted,
  })? executeOverride;

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
    // Hard guard: only «Автономный» (fullAutonomy) gets real queue execution.
    final mode = AiControlService.instance.settings.mode;
    if (mode != AiMode.fullAutonomy) {
      _logAudit(
        label: 'DISPATCH_REJECTED_MODE',
        summary: 'Enqueue rejected for ${trigger.assetSymbol}: '
            'mode is ${_modeName(mode)}, Autonomous mode required.',
        status: DispatchStatus.blocked,
        trigger: trigger,
        reason: 'Mode is ${_modeName(mode)} — execution enqueue requires '
            'Autonomous mode.',
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

    // A trade waits for the user: the confirmation card and the PIN need
    // the app on screen. In the background the item simply stays pending.
    if (!_appInForeground) return;
    final deferredUntil = _deferredUntil;
    if (deferredUntil != null && DateTime.now().isBefore(deferredUntil)) {
      return;
    }

    final nextIndex = _queue.indexWhere((i) => i.isPending);
    if (nextIndex < 0) return; // nothing to do

    _processItem(nextIndex);
  }

  /// Runs the next pending item now (tests; no timer needed).
  @visibleForTesting
  Future<void> processNextForTest() async {
    final nextIndex = _queue.indexWhere((i) => i.isPending);
    if (nextIndex < 0) return;
    await _processItem(nextIndex);
  }

  @visibleForTesting
  void resetForTest() {
    stop();
    _queue.clear();
    _isProcessing = false;
    _deferredUntil = null;
    orchestrateOverride = null;
    executeOverride = null;
  }

  static bool get _appInForeground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
  }

  /// The item is still the one being processed — false once the user
  /// cancelled it (cancelItem marks it blocked).
  bool _stillProcessing(String id) {
    final i = _queue.indexWhere((item) => item.id == id);
    return i >= 0 && _queue[i].isProcessing;
  }

  /// Puts a processing item back in the queue (nobody could be asked).
  void _requeue(String id, String why) {
    final i = _queue.indexWhere((item) => item.id == id);
    if (i < 0 || !_queue[i].isProcessing) return;
    _queue[i] = _queue[i].copyWith(status: DispatchStatus.pending);
    _deferredUntil = DateTime.now().add(_deferDelay);
    _log.d('Deferred ${_queue[i].id}: $why');
    notifyListeners();
  }

  /// [_resolveItem] by id, unless the user's Cancel already resolved it.
  void _resolveById(
    String id,
    DispatchStatus status,
    String? blockReason, {
    String? doneMessage,
  }) {
    final i = _queue.indexWhere((item) => item.id == id);
    if (i < 0 || !_queue[i].isProcessing) return; // cancel won
    _resolveItem(i, status, blockReason, doneMessage: doneMessage);
  }

  /// Runs one item. Whatever happens inside (an exception included), the
  /// queue is free again afterwards and the item does not stay "processing".
  Future<void> _processItem(int index) async {
    final id = _queue[index].id;
    try {
      await _processItemSteps(index);
    } catch (e, st) {
      _log.e('Processing $id threw\n$st', e);
      _resolveById(id, DispatchStatus.failed, 'Processing failed: $e');
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _processItemSteps(int index) async {
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
        intentResult.reason,
      );
      _isProcessing = false;
      return;
    }
    final ready = intentResult as AutomationIntentReady;
    final intent = ready.intent;

    // C8: the trade is quoted and signed on the active network only.
    final activeChain = WalletAdapter.instance.chainKey;
    final tradeChain = ready.chainKey;
    if (tradeChain != null && tradeChain != activeChain) {
      final tradeNet = PrivyChainRegistry.getChain(tradeChain).displayName;
      final activeNet = PrivyChainRegistry.getChain(activeChain).displayName;
      _resolveItem(
        index,
        DispatchStatus.blocked,
        _t(
          'dispatchWrongNetwork',
          '${item.assetSymbol}: the AI would trade on $tradeNet, but the wallet '
              'is on $activeNet. Switch the network and delegate again.',
          {
            'asset': item.assetSymbol,
            'chain': tradeNet,
            'active': activeNet,
          },
        ),
      );
      _isProcessing = false;
      return;
    }

    // ── Hand off to GuardianExecutionController ───────────────────────────────
    // The swap intent comes back as a preview (quote + policy + AI checks);
    // nothing has moved yet.
    AssistantResponse response;
    try {
      final action = IntentAction(
        intent: intent,
        requiresExecution: true,
        requiresConfirmation: false,
      );
      response = await (orchestrateOverride ??
          GuardianExecutionController.instance.orchestrate)(action);
    } catch (e) {
      _resolveById(
        item.id,
        DispatchStatus.failed,
        'Execution controller threw: $e',
      );
      _isProcessing = false;
      return;
    }

    // The user may have cancelled while the quote was fetched.
    if (!_stillProcessing(item.id)) {
      _isProcessing = false;
      return;
    }

    // ── Map response to dispatch status ───────────────────────────────────────
    if (response.type == ResponseType.error) {
      _resolveById(
        item.id,
        DispatchStatus.failed,
        'Execution failed: ${response.message}',
      );
    } else if (response.type == ResponseType.action) {
      _resolveById(
        item.id,
        DispatchStatus.done,
        null,
        doneMessage: '[${item.trigger.label}] Executed via automation path. '
            '${response.message}',
      );
    } else if (response.type == ResponseType.preview &&
        (response.swapPlan != null || response.pendingTransaction != null)) {
      // ── Execute through the AI action gate ──────────────────────────────────
      final override = executeOverride;
      final AiExecResult result;
      try {
        result = override != null
            ? await override(
                response,
                source: 'delegate',
                stillWanted: () => _stillProcessing(item.id),
              )
            : await AiOnchainExecutor.instance.executePreview(
                response,
                source: 'delegate',
                stillWanted: () => _stillProcessing(item.id),
              );
      } catch (e) {
        _resolveById(item.id, DispatchStatus.failed, 'Execution threw: $e');
        _isProcessing = false;
        return;
      }

      if (result.executed) {
        final hash = result.txHash;
        _resolveById(
          item.id,
          DispatchStatus.done,
          null,
          doneMessage: '[${item.trigger.label}] ${result.message}'
              '${hash != null && hash.isNotEmpty ? ' tx $hash' : ''}',
        );
      } else if (result.deferred) {
        // Nobody could be asked (app in the background, no screen), the card
        // closed without an answer (the app went to the background, or it
        // timed out), or another AI operation held the lock: the user did
        // not say no — try again later, do not burn the item.
        _requeue(item.id, result.message);
      } else if (result.cancelled) {
        // Only an explicit «Отмена» / «нет» (or a refused PIN / sign-in) is
        // a decline. A mode switch or a lapsed confirmation keeps its own
        // reason. (The queue's own Cancel already resolved the item.)
        _resolveById(
          item.id,
          DispatchStatus.blocked,
          result.declined
              ? _t('dispatchDeclined', 'Declined by user.')
              : result.message,
        );
      } else if (result.failed) {
        _resolveById(item.id, DispatchStatus.failed, result.message);
      } else {
        _resolveById(item.id, DispatchStatus.blocked, result.message);
      }
    } else {
      // Info / warning: the controller explained why there is no trade.
      _resolveById(
        item.id,
        DispatchStatus.blocked,
        _t(
          'dispatchNoPlan',
          'The AI could not build a trade for ${item.assetSymbol}: '
              '${response.message}',
          {'asset': item.assetSymbol, 'reason': response.message},
        ),
      );
    }

    _isProcessing = false;
  }

  static String _t(String key, String fallback,
          [Map<String, dynamic> args = const {}]) =>
      LocalizationService.instance.t(key, {...args, 'default': fallback});

  /// The English mode names the user sees (code names stay manual /
  /// guarded / fullAutonomy): «Советник» Advisor, «Ручной» Manual,
  /// «Автономный» Autonomous.
  static String _modeName(AiMode mode) => switch (mode) {
        AiMode.manual => 'Advisor',
        AiMode.guarded => 'Manual',
        AiMode.fullAutonomy => 'Autonomous',
      };

  // ── Safety re-check ─────────────────────────────────────────────────────────

  /// Validates all safety conditions at the moment the item is about to execute.
  /// Returns a human-readable block reason, or null if everything is clear.
  String? _reCheckSafety(DispatchItem item) {
    final settings = AiControlService.instance.settings;

    // 1. Mode must still be «Автономный» (fullAutonomy).
    if (settings.mode != AiMode.fullAutonomy) {
      return 'Mode changed to ${_modeName(settings.mode)} since enqueue — '
          'execution blocked. Only Autonomous mode carries out queued trades.';
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
