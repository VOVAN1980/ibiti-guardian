import 'package:ibiti_guardian/services/assistant/guardian_assistant_service.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/models/automation_rule.dart';

/// Broadcasts automation telemetry events to the chat UI.
/// NOTE: This is a UI-side event bus, NOT the real [AutomationEngine]
/// which lives in services/market/automation_engine.dart.
class AutomationTelemetryBus {
  AutomationTelemetryBus._();
  static final instance = AutomationTelemetryBus._();

  final List<AutomationRule> _rules = [];

  /// Stub UI listener registry for Phase 6 previews
  final List<Function(String)> _telemetryListeners = [];

  void addListener(Function(String) callback) =>
      _telemetryListeners.add(callback);
  void removeListener(Function(String) callback) =>
      _telemetryListeners.remove(callback);

  /// Phase 6 explicit requirement: simulateTrigger() for testing
  /// In a production environment, this is hooked replacing EventBus/WebSockets.
  Future<void> simulateTrigger(String triggerEvent) async {
    _broadcastUI('Trigger fired: $triggerEvent');

    // 1. Find matched rules
    final matches = _rules.where((r) => r.trigger == triggerEvent).toList();
    if (matches.isEmpty) {
      _broadcastUI('No automated rules mapped to $triggerEvent.');
      return;
    }

    // 2. Process actions sequentially
    for (var rule in matches) {
      _broadcastUI('Executing rule [${rule.id}] -> Action: ${rule.action}');

      // If the rule demands a distinct AI sandbox boundary, temporarily mount it.
      if (rule.scope != null &&
          DelegationController.instance.store.getActive() == null) {
        DelegationController.instance.store.setScope(rule.scope!);
      }

      // 3. The raw string action needs to be routed exactly like user text
      // to ensure NO bypasses exist.
      // E.g., rule.action = "revoke approval from 0xBAD..."

      try {
        if (!rule.autoExecute && !rule.requireConfirmationFallback) {
          _broadcastUI(
              'Rule [${rule.id}] is alert-only. No execution or preview requested.');
          continue;
        }

        final result = rule.autoExecute
            ? await GuardianAssistantService.instance.processAutomatedSignal(
                '_AUTO_ $triggerEvent||${rule.action}',
              )
            : await GuardianAssistantService.instance.process(rule.action, source: AssistantInputSource.automated);

        _broadcastUI(
            'Rule execution complete. UI Response: ${result.type.name}');
      } catch (e) {
        _broadcastUI('Automation Error: $e');
      }
    }
  }

  /// Registers a new active automation rule into the engine
  void registerRule(AutomationRule rule) {
    _rules.removeWhere((r) => r.id == rule.id); // Upsert
    _rules.add(rule);
    _broadcastUI('Rule registered: ${rule.trigger} -> ${rule.action}');
  }

  void clearRules() {
    _rules.clear();
  }

  void _broadcastUI(String msg) {
    for (final l in _telemetryListeners) {
      l(msg);
    }
  }
}
