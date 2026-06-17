import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/models/simulation_result.dart';
import 'package:ibiti_guardian/models/rpc_simulation_result.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/models/wallet_context.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/sandbox_decision.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/services/policy/guardian_policy_engine.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';

/// The absolute gatekeeper for automation within Phase 6.
/// Evaluates whether a background payload can safely execute without user confirmation.
class SandboxGuard {
  SandboxGuard._();
  static final instance = SandboxGuard._();

  final _delegation = DelegationController.instance;

  AiAction? _requiredAction(TransactionRequest tx) {
    switch (tx.type) {
      case TransactionType.send:
        return AiAction.send;
      case TransactionType.swap:
      case TransactionType.approve:
        return AiAction.swap;
      case TransactionType.revoke:
        return AiAction.revoke;
      case TransactionType.unknown:
        return null;
    }
  }

  /// Crucial rule: "Allowed ONLY IF:
  /// delegation OK AND policy OK AND NOT blocked AND executionPath != fallback"
  SandboxDecision evaluate({
    required TransactionRequest tx,
    required SimulationResult staticSim,
    required RpcSimulationResult rpcSim,
    required PolicyProfile profile,
    required WalletContext walletContext,
    required ExecutionPath path,
    required PolicyResult policy,
  }) {
    final aiSettings = AiControlService.instance.settings;
    final mandate = aiSettings.mandate;

    if (aiSettings.mode != AiMode.fullAutonomy) {
      return SandboxDecision.manual(
        'AI autonomy mode requires manual confirmation for automated execution.',
      );
    }

    if (!aiSettings.allowedActions.contains(AiAction.scheduledActions)) {
      return SandboxDecision.manual(
        'Automated execution is disabled because scheduled actions are not allowed.',
      );
    }

    final requiredAction = _requiredAction(tx);
    if (requiredAction != null &&
        !aiSettings.allowedActions.contains(requiredAction)) {
      return SandboxDecision.block(
        'Automated action blocked by AI permissions: ${requiredAction.name} is not allowed.',
      );
    }

    // 1. Never Auto-Execute on Fallback Path. It lacks on-chain enforcement.
    if (path == ExecutionPath.fallback) {
      return SandboxDecision.manual(
          'Fallback path prohibits autonomous execution.');
    }

    // 2. Outright Blocked Payload (Risk/Network Revert/Global limits blown)
    if (policy.blocked || !rpcSim.success) {
      return SandboxDecision.block(
          'Action blocked by underlying logic or RPC simulation revert.');
    }

    if (!mandate.allowsNetwork(tx.chainKey)) {
      return SandboxDecision.block(
          'Action blocked by autonomy mandate: network not allowed.');
    }

    if (!mandate.allowsAsset(tx.tokenSymbol) ||
        !mandate.allowsAsset(tx.targetTokenSymbol)) {
      return SandboxDecision.block(
          'Action blocked by autonomy mandate: asset not allowed.');
    }

    if (!mandate.allowsVenue(tx.routerAddress ?? tx.spenderAddress)) {
      return SandboxDecision.block(
          'Action blocked by autonomy mandate: venue not allowed.');
    }

    // 3. Multi-Wallet Risk checks (Adaptive Policy tightening)
    if (walletContext.isHighRisk) {
      return SandboxDecision.manual(
          'High systemic risk detected on associated global credentials.');
    }

    // 4. Verify AI limits via Delegation Controller
    if (!_delegation.isAuthorized(tx)) {
      return SandboxDecision.manual(
          'Transaction payload breaches the active delegated constraints.');
    }

    // 5. Passed all sandbox traps.
    return SandboxDecision.approved(
        'Action perfectly mapped into delegated boundaries.');
  }
}
