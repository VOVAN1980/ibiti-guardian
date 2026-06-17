import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/models/transaction_explanation.dart';
import 'package:ibiti_guardian/services/policy/guardian_policy_engine.dart';
import 'package:ibiti_guardian/models/rpc_simulation_result.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/swap_execution_plan.dart';

import 'package:ibiti_guardian/models/assistant_directive.dart';

enum ResponseType {
  info,
  warning,
  error,
  action,
  preview, // Needs user confirmation via widget card
  guardianRevoke, // Triggers Guardian modal (safe or panic) from AI
}

/// Normalized response from the Assistant.
class AssistantResponse {
  final String message; // display message
  final String speechText;
  final List<UICommand> uiCommands;
  final ResponseType type;
  final String? detail;
  final IntentData? sourceIntent;

  // в”Ђв”Ђв”Ђ Phase 4 & 5 Preview Data в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  /// The transaction built waiting for user confirmation
  final TransactionRequest? pendingTransaction;

  /// The static & profile policy validation result
  final PolicyResult? policy;

  /// The human-readable explanation mapping the consequences
  final TransactionExplanation? explanation;

  // в”Ђв”Ђв”Ђ Phase 5 Specific Data в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  /// Preflight simulated outcomes directly from the RPC boundary
  final RpcSimulationResult? rpcSimulation;

  /// The calculated execution route ensuring capability vs intent
  final ExecutionPath? executionPath;

  /// Full SWAP plan — set only for swapAsset previews.
  /// Contains both approveStep (optional) and swapStep.
  final SwapExecutionPlan? swapPlan;

  /// Human-readable label of the decided routing path
  String get executionPathLabel => executionPath?.label ?? 'Unrouted';

  /// Whether this is a swap preview (requires special two-step UI).
  bool get isSwapPreview => swapPlan != null;

  /// Whether the payload travels via a secured, simulated, and audited boundary
  bool get usesProtectedExecution =>
      executionPath == ExecutionPath.localProtected ||
      executionPath == ExecutionPath.epkProtected;

  const AssistantResponse({
    required this.message,
    this.speechText = '',
    this.uiCommands = const [],
    this.type = ResponseType.info,
    this.detail,
    this.sourceIntent,
    this.pendingTransaction,
    this.policy,
    this.explanation,
    this.rpcSimulation,
    this.executionPath,
    this.swapPlan,
  });

  // Basic factories
  factory AssistantResponse.info(String msg,
          {String speechText = '',
          List<UICommand> commands = const [],
          String? detail,
          IntentData? intent}) =>
      AssistantResponse(
          message: msg,
          speechText: speechText.isEmpty ? msg : speechText,
          uiCommands: commands,
          detail: detail,
          sourceIntent: intent);

  factory AssistantResponse.warning(String msg,
          {String? detail, IntentData? intent}) =>
      AssistantResponse(
          message: msg,
          type: ResponseType.warning,
          detail: detail,
          sourceIntent: intent);

  factory AssistantResponse.error(String msg,
          {String? detail, IntentData? intent}) =>
      AssistantResponse(
          message: msg,
          type: ResponseType.error,
          detail: detail,
          sourceIntent: intent);

  factory AssistantResponse.unknown() => const AssistantResponse(
      message: "I couldn't understand that command.", type: ResponseType.error);

  /// Factory specifically for generating Phase 5 transactional previews.
  factory AssistantResponse.preview({
    required TransactionRequest transaction,
    required TransactionExplanation explanation,
    required PolicyResult policy,
    required RpcSimulationResult rpcSimulation,
    required ExecutionPath executionPath,
  }) =>
      AssistantResponse(
        message: 'Please review and confirm this transaction.',
        speechText:
            'Please review and confirm this transaction on your screen.',
        type: ResponseType.preview,
        pendingTransaction: transaction,
        policy: policy,
        explanation: explanation,
        rpcSimulation: rpcSimulation,
        executionPath: executionPath,
      );
}
