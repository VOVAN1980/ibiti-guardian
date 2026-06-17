import 'package:ibiti_guardian/models/intent_data.dart';

/// Types of actions the AI can remotely trigger in the UI.
enum UICommandType {
  /// Open a specific modal (e.g. 'panic_review', 'swap_preview')
  openModal,

  /// Navigate to a new screen (e.g. 'wallet_space', 'security_center')
  navigate,

  /// Fill a text field (payload contains 'field' and 'value')
  fillField,

  /// Select an asset (payload contains 'symbol' or 'address')
  selectToken,

  /// Execute a predefined action (e.g. 'swap_best_price', 'revoke_all')
  executeAction,

  /// Close / dismiss the topmost modal or screen (Navigator.maybePop)
  dismiss,

  /// Display a TradingPlan on the Market Command Center
  showTradingPlan,

  /// No action needed
  none
}

/// A specific command dispatched from the Conversation Brain to the UI Command Bus.
class UICommand {
  final UICommandType type;

  /// The target identifier, e.g., screen name or modal name.
  final String? target;

  /// Any additional parameters needed for the command.
  final Map<String, dynamic>? payload;

  const UICommand({
    required this.type,
    this.target,
    this.payload,
  });

  factory UICommand.fromJson(Map<String, dynamic> json) {
    return UICommand(
      type: UICommandType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => UICommandType.none,
      ),
      target: json['target'] as String?,
      payload: json['payload'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'target': target,
        'payload': payload,
      };
}

/// The structured payload returned by the AI Orchestrator.
/// This replaces a flat text response with a discrete architecture.
class AssistantDirective {
  /// The rich text/markdown to show on the chat screen (detailed, exact).
  final String displayMessage;

  /// The normalized, conversational text explicitly generated for the TTS engine.
  /// (Short, no weird symbols, normalized for voice).
  final String speechText;

  /// The list of actions the UI should enact in response.
  final List<UICommand> uiCommands;

  /// Extracted intent parameters if any (used for routing to Execution Engine).
  final IntentData? explicitIntent;

  const AssistantDirective({
    required this.displayMessage,
    required this.speechText,
    this.uiCommands = const [],
    this.explicitIntent,
  });

  factory AssistantDirective.fromJson(Map<String, dynamic> json) {
    return AssistantDirective(
      displayMessage: json['displayMessage'] ?? '',
      speechText: json['speechText'] ?? '',
      uiCommands: (json['uiCommands'] as List<dynamic>?)
              ?.map((e) => UICommand.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      explicitIntent: json['explicitIntent'] != null
          ? IntentData.fromJson(json['explicitIntent'] as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'displayMessage': displayMessage,
        'speechText': speechText,
        'uiCommands': uiCommands.map((c) => c.toJson()).toList(),
        'explicitIntent': explicitIntent?.toJson(),
      };
}
