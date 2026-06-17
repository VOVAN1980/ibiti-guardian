import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/models/audit_log_entry.dart';
import 'package:ibiti_guardian/models/automation_trigger.dart';
import 'package:ibiti_guardian/models/execution_result.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/services/audit_log_service.dart';
import 'package:ibiti_guardian/services/market/automation_dispatch_service.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';

// ─── AutomationEngine ─────────────────────────────────────────────────────────

/// Safe, mode-aware trigger evaluation engine.
///
/// SAFETY CONTRACT (never violated):
/// - All trigger results are evaluated against current [AiMode] and [AutonomyMandate].
/// - Manual mode → notifyOnly regardless of [AutomationTrigger.requestedAction].
/// - Guarded mode → max [TriggerAction.preparePlan].
/// - Full Autonomy → execution allowed, but always routes through
///   [MarketPolicyGate] → [GuardianPolicyEngine] → EPK (same path as manual trades).
/// - This engine NEVER creates its own execution path.
/// - All decisions (fired, blocked, skipped) are logged as [ExecutionSource.automation].
///
/// Polling:
/// - Evaluates all enabled triggers every [_pollIntervalSeconds] seconds.
/// - Uses cached market data from [MarketDataService] — no extra network calls.
/// - Stops polling when disposed.
class AutomationEngine extends ChangeNotifier {
  AutomationEngine._();
  static final AutomationEngine instance = AutomationEngine._();

  static const _log = GuardianLogger('AutomationEngine');

  static const int _pollIntervalSeconds = 30;

  /// Minimum minutes between two fires of the same trigger.
  /// Prevents spam when a condition stays true across multiple poll cycles.
  static const int _cooldownMinutes = 15;

  // ── State ───────────────────────────────────────────────────────────────────
  final List<AutomationTrigger> _triggers = [];
  final List<TriggerEvalResult> _recentResults = [];
  Timer? _pollTimer;
  bool _running = false;

  /// All registered triggers, newest first.
  List<AutomationTrigger> get triggers =>
      List.unmodifiable(_triggers.reversed.toList());

  /// Last evaluation results per trigger (newest first, max 50).
  List<TriggerEvalResult> get recentResults =>
      List.unmodifiable(_recentResults.reversed.toList());

  bool get isRunning => _running;

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  /// Start the polling loop. Safe to call multiple times.
  void start() {
    if (_running) return;
    _running = true;
    _pollTimer = Timer.periodic(
      const Duration(seconds: _pollIntervalSeconds),
      (_) => evaluateAll(),
    );
    _log.d('Started (poll every ${_pollIntervalSeconds}s)');
    notifyListeners();
  }

  /// Stop the polling loop (e.g. when app goes background).
  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _running = false;
    _log.d('Stopped');
    // Defer notification — stop() may be called during dispose() while the
    // widget tree is locked, which would crash with "setState called when
    // widget tree was locked".
    Future.microtask(() {
      try {
        notifyListeners();
      } catch (_) {
        // Widget tree already torn down — safe to ignore.
      }
    });
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  // ── Trigger Registry ────────────────────────────────────────────────────────

  /// Register a new trigger. Auto-generates id if not provided.
  AutomationTrigger addTrigger({
    required String assetSymbol,
    required TriggerType type,
    required TriggerAction requestedAction,
    String label = '',
    double? thresholdUsd,
    double? thresholdPct,
    double? entryPriceUsd,
    bool enabled = true,
  }) {
    final trigger = AutomationTrigger(
      id: '${assetSymbol}_${type.name}_${DateTime.now().millisecondsSinceEpoch}',
      assetSymbol: assetSymbol,
      type: type,
      requestedAction: requestedAction,
      createdAt: DateTime.now(),
      label:
          label.isEmpty ? '${assetSymbol.toUpperCase()} ${type.name}' : label,
      thresholdUsd: thresholdUsd,
      thresholdPct: thresholdPct,
      entryPriceUsd: entryPriceUsd,
      enabled: enabled,
    );
    _triggers.add(trigger);
    _logSystem(
      'Added trigger: ${trigger.label} (${trigger.conditionDescription})',
    );
    notifyListeners();
    return trigger;
  }

  /// Remove a trigger by its id.
  void removeTrigger(String id) {
    final i = _triggers.indexWhere((t) => t.id == id);
    if (i < 0) return;
    final t = _triggers[i];
    _triggers.removeAt(i);
    _logSystem('Removed trigger: ${t.label}');
    notifyListeners();
  }

  /// Remove all triggers for a symbol, optionally filtered by type.
  ///
  /// Used by voice commands: "убери TP", "убери SL".
  /// [onlyType] — if provided, removes only triggers of that type.
  void removeTriggersForSymbol(
    String symbol,
    TriggerAction action, {
    TriggerType? onlyType,
  }) {
    final sym = symbol.toUpperCase();
    final before = _triggers.length;
    _triggers.removeWhere((t) =>
        t.assetSymbol.toUpperCase() == sym &&
        (onlyType == null || t.type == onlyType));
    final removed = before - _triggers.length;
    if (removed > 0) {
      _logSystem('Removed $removed trigger(s) for $sym'
          '${onlyType != null ? ' (${onlyType.name})' : ''}');
      notifyListeners();
    }
  }

  /// Toggle enabled state.
  void toggleTrigger(String id) {
    final i = _triggers.indexWhere((t) => t.id == id);
    if (i < 0) return;
    final t = _triggers[i];
    _triggers[i] = t.copyWith(enabled: !t.enabled);
    _logSystem(
      '${_triggers[i].enabled ? 'Enabled' : 'Disabled'} trigger: ${t.label}',
    );
    notifyListeners();
  }

  // ── Evaluation ──────────────────────────────────────────────────────────────

  /// Evaluate all enabled triggers against current cached market data.
  ///
  /// Called automatically by the poll timer.
  /// Can also be called manually for immediate dry-run evaluation.
  void evaluateAll() {
    final markets = MarketDataService.instance.cachedMarkets;
    if (markets.isEmpty) return;

    // P1 Fix: Skip if market data is stale — prevents phantom signals
    // from frozen data when APIs are down.
    if (MarketDataService.instance.isStale) {
      _log.d('Skipping eval — market data is stale '
          '(last refresh: ${MarketDataService.instance.lastRefreshedAt})');
      return;
    }

    final now = DateTime.now();
    final mode = AiControlService.instance.settings.mode;
    bool anyFired = false;

    for (final trigger in _triggers.where((t) => t.enabled)) {
      // ── Cooldown guard ────────────────────────────────────────────────────
      // Skip evaluation if the trigger fired recently to avoid log spam.
      if (_isCoolingDown(trigger, now)) continue;

      final asset = markets.cast<MarketAsset?>().firstWhere(
            (a) => a!.symbol.toLowerCase() == trigger.assetSymbol.toLowerCase(),
            orElse: () => null,
          );
      if (asset == null) continue; // asset not in cached list, skip

      final result = _evalTrigger(trigger, asset, now, mode);
      _recordResult(result);

      if (result.fired) {
        anyFired = true;
        // ── Liquidity gate: block execution on illiquid assets ──────────
        // Triggers can notify about anything, but execute/plan should
        // only proceed on assets that can actually be traded safely.
        if (result.resolvedAction != TriggerAction.notifyOnly &&
            !_isLiquidEnough(asset)) {
          _log.d('Trigger ${trigger.label} fired but asset ${asset.symbol} '
              'is illiquid (vol: \$${asset.volume.toStringAsFixed(0)}, '
              'mcap: \$${asset.marketCap.toStringAsFixed(0)}). '
              'Demoting to notify-only.');

          // Demote to notification — user sees the signal but we don't
          // blindly trade into an illiquid market.
          final demotedResult = TriggerEvalResult(
            trigger: trigger,
            fired: true,
            reason: '${result.reason} '
                '⚠️ Demoted to notify: low liquidity '
                '(vol: \$${asset.volume.toStringAsFixed(0)}).',
            currentPrice: result.currentPrice,
            timestamp: result.timestamp,
            resolvedAction: TriggerAction.notifyOnly,
          );
          _recordResult(demotedResult);
          _dispatch(demotedResult, asset);
        } else {
          _dispatch(result, asset);
        }
        // Stamp lastFiredAt so the cooldown guard works on next poll.
        final i = _triggers.indexOf(trigger);
        if (i >= 0) {
          _triggers[i] = trigger.copyWith(lastFiredAt: now);
        }
      }
    }

    // Only notify UI if at least one trigger actually fired this cycle.
    // Previously notified every 30s unconditionally, causing needless rebuilds.
    if (anyFired) {
      notifyListeners();
    }
  }

  /// Dry-run: evaluate one trigger without dispatching any actions or logging.
  /// Returns the result for UI preview.
  TriggerEvalResult dryRun(AutomationTrigger trigger, MarketAsset asset) {
    return _evalTrigger(
      trigger,
      asset,
      DateTime.now(),
      AiControlService.instance.settings.mode,
    );
  }

  // ── Private: Evaluation Logic ───────────────────────────────────────────────

  TriggerEvalResult _evalTrigger(
    AutomationTrigger trigger,
    MarketAsset asset,
    DateTime now,
    AiMode mode,
  ) {
    final price = asset.price;

    bool fired = false;
    String reason;

    switch (trigger.type) {
      case TriggerType.priceAbove:
        if (trigger.thresholdUsd == null) {
          reason = 'No threshold set.';
          break;
        }
        fired = price >= trigger.thresholdUsd!;
        reason = fired
            ? '${asset.symbol} price \$${price.toStringAsFixed(2)} ≥ '
                'threshold \$${trigger.thresholdUsd!.toStringAsFixed(2)}.'
            : '${asset.symbol} \$${price.toStringAsFixed(2)} < '
                '\$${trigger.thresholdUsd!.toStringAsFixed(2)} — not triggered.';
      case TriggerType.priceBelow:
        if (trigger.thresholdUsd == null) {
          reason = 'No threshold set.';
          break;
        }
        fired = price <= trigger.thresholdUsd!;
        reason = fired
            ? '${asset.symbol} price \$${price.toStringAsFixed(2)} ≤ '
                'threshold \$${trigger.thresholdUsd!.toStringAsFixed(2)}.'
            : '${asset.symbol} \$${price.toStringAsFixed(2)} > '
                '\$${trigger.thresholdUsd!.toStringAsFixed(2)} — not triggered.';
      case TriggerType.takeProfit:
        if (trigger.entryPriceUsd == null || trigger.thresholdPct == null) {
          reason = 'Entry price or threshold % not set.';
          break;
        }
        final target =
            trigger.entryPriceUsd! * (1 + trigger.thresholdPct! / 100);
        fired = price >= target;
        reason = fired
            ? '${asset.symbol} \$${price.toStringAsFixed(2)} hit take-profit '
                'target \$${target.toStringAsFixed(2)} (+${trigger.thresholdPct!.toStringAsFixed(1)}%).'
            : '${asset.symbol} \$${price.toStringAsFixed(2)} — '
                'take-profit target \$${target.toStringAsFixed(2)} not reached.';
      case TriggerType.stopLoss:
        if (trigger.entryPriceUsd == null || trigger.thresholdPct == null) {
          reason = 'Entry price or threshold % not set.';
          break;
        }
        final stop = trigger.entryPriceUsd! * (1 - trigger.thresholdPct! / 100);
        fired = price <= stop;
        reason = fired
            ? '${asset.symbol} \$${price.toStringAsFixed(2)} hit stop-loss '
                'at \$${stop.toStringAsFixed(2)} (-${trigger.thresholdPct!.toStringAsFixed(1)}%).'
            : '${asset.symbol} \$${price.toStringAsFixed(2)} — '
                'stop-loss \$${stop.toStringAsFixed(2)} not reached.';
      case TriggerType.rebalanceThreshold:
        // Rebalance check uses 24h change as a proxy for drift.
        // Phase 5: replace with real portfolio weight calculation.
        if (trigger.thresholdPct == null) {
          reason = 'No threshold % set.';
          break;
        }
        fired = asset.change24h.abs() >= trigger.thresholdPct!;
        reason = fired
            ? '${asset.symbol} 24h drift ${asset.change24h.toStringAsFixed(1)}% '
                '≥ rebalance threshold ${trigger.thresholdPct!.toStringAsFixed(1)}%.'
            : '${asset.symbol} drift ${asset.change24h.toStringAsFixed(1)}% '
                '< rebalance threshold — stable.';
      case TriggerType.manualDelegate:
        // Manual delegates are pre-dispatched directly by the user via the
        // Market Command Center. They are never evaluated by the polling loop.
        fired = false;
        reason = 'Manual delegate — not evaluated by polling loop.';
    }

    // ── Mode-cap the action ───────────────────────────────────────────────────
    TriggerAction? resolvedAction;
    if (fired) {
      resolvedAction = _capAction(trigger.requestedAction, mode);
    }

    return TriggerEvalResult(
      trigger: trigger,
      fired: fired,
      reason: reason,
      currentPrice: price,
      timestamp: now,
      resolvedAction: resolvedAction,
    );
  }

  // ─── Liquidity gate ───────────────────────────────────────────────────────

  /// Minimum volume and market cap for an asset to be considered liquid
  /// enough for automated execution. Below these thresholds, triggers are
  /// demoted to notify-only to prevent buying assets that can't be sold.
  static const double _minAutoVolume = 50000.0; // $50K 24h volume
  static const double _minAutoMarketCap = 500000.0; // $500K market cap

  bool _isLiquidEnough(MarketAsset asset) {
    if (asset.volume < _minAutoVolume) return false;
    if (asset.marketCap > 0 && asset.marketCap < _minAutoMarketCap)
      return false;
    return true;
  }

  // ─── Mode contract enforcement ──────────────────────────────────────────────

  /// Caps the requested action to what the current mode permits.
  ///
  /// Manual → notifyOnly always.
  /// Guarded → max preparePlan.
  /// Full → execute allowed.
  TriggerAction _capAction(TriggerAction requested, AiMode mode) {
    return switch (mode) {
      AiMode.manual => TriggerAction.notifyOnly,
      AiMode.guarded => requested == TriggerAction.execute
          ? TriggerAction.preparePlan
          : requested,
      AiMode.fullAutonomy => requested,
    };
  }

  // ─── Dispatch ───────────────────────────────────────────────────────────────

  void _dispatch(TriggerEvalResult result, MarketAsset asset) {
    final action = result.resolvedAction ?? TriggerAction.notifyOnly;

    // One audit record per fire — action label encodes the outcome.
    // No separate _logFired() call to avoid duplicate entries.
    final (label, pathLabel, summary) = switch (action) {
      TriggerAction.notifyOnly => (
          'AUTOMATION_NOTIFY',
          'automation_notify',
          '[${result.trigger.label}] ${result.reason}',
        ),
      TriggerAction.preparePlan => (
          'AUTOMATION_PLAN',
          'automation_plan',
          '[${result.trigger.label}] ${result.reason} '
              '\u2192 Plan prepared (Guarded mode).',
        ),
      TriggerAction.execute => (
          'AUTOMATION_EXEC_QUEUED',
          'automation_exec_queued',
          '[${result.trigger.label}] ${result.reason} '
              '\u2192 Dispatched to execution queue (Full Autonomy).',
        ),
    };

    AuditLogService.instance.record(
      intentType: action == TriggerAction.notifyOnly
          ? IntentType.unknown
          : IntentType.swapAsset,
      actionLabel: label,
      summary: summary,
      executionSource: ExecutionSource.automation,
      result: ExecutionResult.success(
        txHash: '',
        pathLabel: pathLabel,
        message: result.reason,
      ),
    );

    // For execute: actually enqueue — not just log.
    if (action == TriggerAction.execute) {
      AutomationDispatchService.instance.enqueue(
        trigger: result.trigger,
        reason: result.reason,
        currentPrice: result.currentPrice,
      );
    }

    _log.d('$label: ${result.reason}');
  }

  // ── Cooldown guard ─────────────────────────────────────────────────────────

  /// Returns true if this trigger has already fired within the cooldown window.
  /// Prevents the same trigger from firing every 30s when condition stays true.
  bool _isCoolingDown(AutomationTrigger trigger, DateTime now) {
    final last = trigger.lastFiredAt;
    if (last == null) return false;
    return now.difference(last).inMinutes < _cooldownMinutes;
  }

  // ─── Result recording ──────────────────────────────────────────────────────

  void _recordResult(TriggerEvalResult result) {
    _recentResults.add(result);
    if (_recentResults.length > 50) _recentResults.removeAt(0);
  }

  // ─── Audit helpers ─────────────────────────────────────────────────────────

  void _logSystem(String message) {
    _log.d(message);
    AuditLogService.instance.recordSystem(
      actionLabel: 'AUTOMATION_SYSTEM',
      summary: message,
      pathLabel: 'automation',
    );
  }
}
