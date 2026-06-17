import 'package:ibiti_guardian/models/audit_log_entry.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';

// ─── Trigger Type ──────────────────────────────────────────────────────────────

enum TriggerType {
  /// Fire when price rises above [thresholdUsd].
  priceAbove,

  /// Fire when price falls below [thresholdUsd].
  priceBelow,

  /// Fire when price rises X% above entry price (take-profit).
  takeProfit,

  /// Fire when price falls X% below entry price (stop-loss).
  stopLoss,

  /// Fire when allocation in this asset drifts beyond [thresholdPct] of portfolio.
  rebalanceThreshold,

  /// User manually delegated this asset from the Market Command Center.
  /// Not a price condition — represents a direct user intent to execute.
  manualDelegate,
}

// ─── Trigger Action ────────────────────────────────────────────────────────────

/// What the automation engine should do when a trigger fires.
/// Enforced by mode contract — never promoted beyond what the mode allows.
enum TriggerAction {
  /// Notify only. No trade preparation. (Manual mode forced to this level.)
  notifyOnly,

  /// Build and show a TradingPlan. No execution. (Guarded mode ceiling.)
  preparePlan,

  /// Execute via the same hardened path (MarketPolicyGate → Policy → EPK).
  /// Only available in Full Autonomy mode.
  execute,
}

// ─── Automation Trigger ────────────────────────────────────────────────────────

/// A single automation rule attached to one asset.
///
/// Immutable — mutations return a new instance via [copyWith].
class AutomationTrigger {
  /// Unique ID, assigned at creation.
  final String id;

  /// Asset ticker this trigger watches (e.g. "BTC", "ETH").
  final String assetSymbol;

  /// Human-readable label. Auto-generated if not provided.
  final String label;

  /// What condition fires this trigger.
  final TriggerType type;

  /// USD price threshold for [TriggerType.priceAbove] / [TriggerType.priceBelow].
  final double? thresholdUsd;

  /// Percentage threshold for [TriggerType.takeProfit] / [TriggerType.stopLoss]
  /// / [TriggerType.rebalanceThreshold].
  final double? thresholdPct;

  /// Reference price used for %-based triggers (entry price at creation time).
  final double? entryPriceUsd;

  /// Whether this trigger is currently active.
  final bool enabled;

  /// What to do when triggered. Capped by current [AiMode] at eval time.
  final TriggerAction requestedAction;

  /// When this trigger was created.
  final DateTime createdAt;

  /// When this trigger last fired (null = never).
  final DateTime? lastFiredAt;

  const AutomationTrigger({
    required this.id,
    required this.assetSymbol,
    required this.type,
    required this.requestedAction,
    required this.createdAt,
    this.label = '',
    this.thresholdUsd,
    this.thresholdPct,
    this.entryPriceUsd,
    this.enabled = true,
    this.lastFiredAt,
  });

  AutomationTrigger copyWith({
    bool? enabled,
    DateTime? lastFiredAt,
    String? label,
    double? thresholdUsd,
    double? thresholdPct,
    TriggerAction? requestedAction,
  }) =>
      AutomationTrigger(
        id: id,
        assetSymbol: assetSymbol,
        type: type,
        requestedAction: requestedAction ?? this.requestedAction,
        createdAt: createdAt,
        label: label ?? this.label,
        thresholdUsd: thresholdUsd ?? this.thresholdUsd,
        thresholdPct: thresholdPct ?? this.thresholdPct,
        entryPriceUsd: entryPriceUsd,
        enabled: enabled ?? this.enabled,
        lastFiredAt: lastFiredAt ?? this.lastFiredAt,
      );

  /// Human-readable description of the trigger condition.
  String get conditionDescription {
    switch (type) {
      case TriggerType.priceAbove:
        return 'Price above \$${thresholdUsd?.toStringAsFixed(2) ?? "?"}';
      case TriggerType.priceBelow:
        return 'Price below \$${thresholdUsd?.toStringAsFixed(2) ?? "?"}';
      case TriggerType.takeProfit:
        final pct = thresholdPct?.toStringAsFixed(1) ?? '?';
        final target = entryPriceUsd != null && thresholdPct != null
            ? ' → \$${(entryPriceUsd! * (1 + thresholdPct! / 100)).toStringAsFixed(2)}'
            : '';
        return 'Take profit +$pct%$target';
      case TriggerType.stopLoss:
        final pct = thresholdPct?.toStringAsFixed(1) ?? '?';
        final target = entryPriceUsd != null && thresholdPct != null
            ? ' → \$${(entryPriceUsd! * (1 - thresholdPct! / 100)).toStringAsFixed(2)}'
            : '';
        return 'Stop loss -$pct%$target';
      case TriggerType.rebalanceThreshold:
        return 'Rebalance if allocation drifts >${thresholdPct?.toStringAsFixed(0) ?? "?"}%';
      case TriggerType.manualDelegate:
        return 'Manually delegated from Market Command Center';
    }
  }
}

// ─── Trigger Eval Result ───────────────────────────────────────────────────────

/// Result of evaluating a single [AutomationTrigger] against current market data.
class TriggerEvalResult {
  /// The trigger that was evaluated.
  final AutomationTrigger trigger;

  /// Whether the trigger condition was met.
  final bool fired;

  /// Human-readable reason (why it fired or why it didn't).
  final String reason;

  /// The action the engine will take, capped by current [AiMode].
  /// Null if [fired] is false.
  final TriggerAction? resolvedAction;

  /// Source label for audit trail.
  final ExecutionSource executionSource = ExecutionSource.automation;

  /// The price at evaluation time.
  final double currentPrice;

  /// When this evaluation happened.
  final DateTime timestamp;

  const TriggerEvalResult({
    required this.trigger,
    required this.fired,
    required this.reason,
    required this.currentPrice,
    required this.timestamp,
    this.resolvedAction,
  });
}
