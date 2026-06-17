import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/models/simulation_result.dart';
import 'package:ibiti_guardian/models/rpc_simulation_result.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/swap/swap_provider.dart'
    show SwapSlippagePolicy;

/// Severity level of a policy decision.
/// Maps directly to UI colors: info=green, warning=yellow, danger=red.
enum PolicySeverity { safe, info, warning, danger }

/// The result of a policy evaluation.
class PolicyResult {
  final bool allowed;
  final bool blocked;
  final String? reason;
  final bool requiresConfirmation;
  final PolicySeverity severity;
  final List<String> appliedRules;

  // Phase 5 specific EPK flags
  final bool epkRequired;
  final bool epkAvailable;

  const PolicyResult({
    required this.allowed,
    required this.severity,
    this.blocked = false,
    this.reason,
    this.requiresConfirmation = false,
    this.appliedRules = const [],
    this.epkRequired = false,
    this.epkAvailable = false,
  });

  factory PolicyResult.allow(
          {List<String> rules = const [],
          bool epkRequired = false,
          bool epkAvailable = false}) =>
      PolicyResult(
        allowed: true,
        severity: PolicySeverity.info,
        appliedRules: rules,
        epkRequired: epkRequired,
        epkAvailable: epkAvailable,
      );

  factory PolicyResult.confirm(String reason,
          {PolicySeverity severity = PolicySeverity.warning,
          List<String> rules = const [],
          bool epkRequired = false,
          bool epkAvailable = false}) =>
      PolicyResult(
        allowed: true,
        severity: severity,
        reason: reason,
        requiresConfirmation: true,
        appliedRules: rules,
        epkRequired: epkRequired,
        epkAvailable: epkAvailable,
      );

  factory PolicyResult.block(String reason,
          {PolicySeverity severity = PolicySeverity.danger,
          List<String> rules = const [],
          bool epkRequired = false,
          bool epkAvailable = false}) =>
      PolicyResult(
        allowed: false,
        blocked: true,
        severity: severity,
        reason: reason,
        appliedRules: rules,
        epkRequired: epkRequired,
        epkAvailable: epkAvailable,
      );
}

/// Guardian Policy Engine V3 — Profile, EPK & RPC aware.
class GuardianPolicyEngine {
  GuardianPolicyEngine._();

  // ─── Phase 5 V3 Pipeline ──────────────────────────────────────────────────

  /// Brain orchestrator calls V3 passing all context parameters.
  static PolicyResult checkV3(
    TransactionRequest tx,
    SimulationResult staticSim,
    RpcSimulationResult rpcSim,
    PolicyProfile profile,
    ExecutionPath path,
  ) {
    final rules = <String>['EVAL_${profile.mode.name.toUpperCase()}'];
    final epkAvail = path == ExecutionPath.epkProtected;
    final aiSettings = AiControlService.instance.settings;

    // ── AI Mode Gate (Check 0) ───────────────────────────────────────────────
    // Manual mode means the AI may NOT execute anything.
    // This is enforced here so changing the mode in AI Center
    // immediately closes the execution path for ALL transaction types.
    if (aiSettings.mode == AiMode.manual) {
      rules.add('AI_MODE_MANUAL_BLOCK');
      return PolicyResult.block(
        'AI mode is set to Manual. Execution is disabled. '
        'Switch to Guarded or Full Autonomy to proceed.',
        rules: rules,
        severity: PolicySeverity.warning,
        epkAvailable: epkAvail,
      );
    }

    // ── Allowed Actions Check (Check 0b) ─────────────────────────────────────
    // AI Center lets the user whitelist specific action types.
    // If the action is not in the allowlist, block here.
    final aiAction = _txTypeToAiAction(tx.type);
    if (aiAction != null && !aiSettings.allowedActions.contains(aiAction)) {
      rules.add('AI_ACTION_NOT_ALLOWED');
      return PolicyResult.block(
        'The action "${tx.type.name}" is not enabled in your AI settings. '
        'Enable it in AI Center → Allowed Actions.',
        rules: rules,
        severity: PolicySeverity.warning,
        epkAvailable: epkAvail,
      );
    }

    // ── AI Per-Tx Limit Check (Check 0c) ─────────────────────────────────────
    // AI Center defines a hard per-transaction cap.
    // Policy profile has its own per-action limit.
    // Strictest wins: if amount exceeds AI cap, block before profile check.
    if (tx.amount != null && tx.amount! > aiSettings.perTxLimit) {
      rules.add('AI_PER_TX_LIMIT_EXCEEDED');
      return PolicyResult.block(
        'Amount exceeds your AI per-transaction limit '
        '(\$${aiSettings.perTxLimit.toStringAsFixed(0)}). '
        'Adjust in AI Center → AI Limits.',
        rules: rules,
        severity: PolicySeverity.warning,
        epkAvailable: epkAvail,
      );
    }

    // Check 1: Real On-Chain RPC Simulation Revert
    if (!rpcSim.success) {
      rules.add('RPC_REVERT_DETECTED');
      return PolicyResult.block(
        'Transaction would fail on-chain: ${rpcSim.revertReason ?? "Execution reverted."}',
        rules: rules,
        epkAvailable: epkAvail,
      );
    }

    // Check 2: Static Critical Risk
    if (staticSim.isCritical) {
      // Phase 5 Check: if address is specifically trusted in the profile, downgrade to Warning
      if (tx.toAddress.isNotEmpty &&
          profile.trustedAddresses.contains(tx.toAddress.toLowerCase())) {
        rules.add('STATIC_CRITICAL_TRUST_DOWNGRADE');
      } else {
        rules.add('STATIC_CRITICAL_BLOCK');
        return PolicyResult.block(
          'Critical risk detected and destination is not trusted.',
          severity: PolicySeverity.danger,
          rules: rules,
          epkAvailable: epkAvail,
        );
      }
    }

    // Check 3: TX specific limits & approvals vs Profile
    switch (tx.type) {
      case TransactionType.send:
        return _enforceEpkRequirement(
          _checkSendV3(tx, staticSim, rpcSim, profile, path, rules),
        );
      case TransactionType.revoke:
        return _checkRevokeV3();
      case TransactionType.approve:
        return _enforceEpkRequirement(
          _checkApproveV3(tx, staticSim, rpcSim, profile, path, rules),
        );
      case TransactionType.swap:
        return _enforceEpkRequirement(
          _checkSwapV3(tx, staticSim, rpcSim, profile, path, rules),
        );
      case TransactionType.unknown:
        return PolicyResult.block(
            'Unknown transaction type cannot be safely executed.',
            rules: rules);
    }
  }

  /// Maps a [TransactionType] to its corresponding [AiAction] for allowlist checking.
  /// Returns null for types that don't have a direct AI action mapping.
  static AiAction? _txTypeToAiAction(TransactionType type) {
    switch (type) {
      case TransactionType.send:
        return AiAction.send;
      case TransactionType.swap:
        return AiAction.swap;
      case TransactionType.approve:
        return AiAction.approve;
      case TransactionType.revoke:
        return AiAction.revoke;
      case TransactionType.unknown:
        return null;
    }
  }

  static PolicyResult _enforceEpkRequirement(PolicyResult result) {
    if (!result.epkRequired || result.epkAvailable) {
      return result;
    }

    final nextRules = [...result.appliedRules, 'EPK_REQUIRED_UNAVAILABLE'];
    return PolicyResult.block(
      'This action requires active on-chain EPK protection. Resume or deploy EPK before executing it.',
      severity: PolicySeverity.danger,
      rules: nextRules,
      epkRequired: true,
      epkAvailable: false,
    );
  }

  // в”Ђв”Ђв”Ђ Send V3 в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  static PolicyResult _checkSendV3(
    TransactionRequest tx,
    SimulationResult staticSim,
    RpcSimulationResult rpcSim,
    PolicyProfile profile,
    ExecutionPath path,
    List<String> rules,
  ) {
    final epkAvail = path == ExecutionPath.epkProtected;

    // Dollar Value limit checks against Profile
    if (tx.amount != null && tx.amount! > profile.sendLimitUsd) {
      rules.add('PROFILE_LIMIT_EXCEEDED');
      return PolicyResult.block(
        'Send amount exceeds your active profile limit (\$${profile.sendLimitUsd.toStringAsFixed(0)}).',
        rules: rules,
        epkAvailable: epkAvail,
      );
    }

    if (staticSim.risk == SimulationRisk.warning) {
      rules.add('STATIC_WARNING_CONFIRM');
      return PolicyResult.confirm(
        'Transaction has warnings. Review carefully.',
        severity: PolicySeverity.danger,
        rules: rules,
        epkAvailable: epkAvail,
      );
    }

    rules.add('SEND_STANDARD_CONFIRM');
    return PolicyResult.confirm(
      'Please confirm the transaction.',
      severity: PolicySeverity.info,
      rules: rules,
      epkAvailable: epkAvail,
      epkRequired:
          tx.amount != null && tx.amount! > 1000, // example dynamic requirement
    );
  }

  // в”Ђв”Ђв”Ђ Revoke V3 в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  static PolicyResult _checkRevokeV3() {
    return PolicyResult.confirm(
      'Revoking this approval requires a gas transaction. Confirm?',
      severity: PolicySeverity.warning,
      rules: const ['REVOKE_CONFIRM'],
    );
  }

  // ─── Swap V3 ──────────────────────────────────────────────────────────────

  static PolicyResult _checkSwapV3(
    TransactionRequest tx,
    SimulationResult staticSim,
    RpcSimulationResult rpcSim,
    PolicyProfile profile,
    ExecutionPath path,
    List<String> rules,
  ) {
    final epkAvail = path == ExecutionPath.epkProtected;

    // Check 0: Hard slippage cap — AI CANNOT override this.
    // slippageBps is stored in quoteSummary['slippageSet'] as a percentage string
    // e.g. '1.0%' or in extraSummary as int 'slippageBps'.
    final rawSlippageBps = tx.quoteSummary?['slippageBps'];
    final slippageBps = rawSlippageBps is num ? rawSlippageBps.toInt() : 0;
    if (slippageBps > SwapSlippagePolicy.maxBps) {
      rules.add('SWAP_SLIPPAGE_CAP_EXCEEDED');
      return PolicyResult.block(
        'Swap slippage (${(slippageBps / 100).toStringAsFixed(1)}%) exceeds the '
        'maximum allowed (${(SwapSlippagePolicy.maxBps / 100).toStringAsFixed(1)}%). '
        'Reduce slippage in your request.',
        severity: PolicySeverity.danger,
        rules: rules,
        epkAvailable: epkAvail,
      );
    }

    // Check 1: Spend limit vs profile
    if (tx.amount != null && tx.amount! > profile.swapLimitUsd) {
      rules.add('SWAP_PROFILE_LIMIT_EXCEEDED');
      return PolicyResult.block(
        'Swap amount exceeds your active profile limit (\$${profile.swapLimitUsd.toStringAsFixed(0)}).',
        rules: rules,
        epkAvailable: epkAvail,
      );
    }

    // Check 2: Price impact (from quoteSummary injected into TransactionRequest)
    final rawImpact = tx.quoteSummary?['priceImpactPct'];
    final priceImpact = rawImpact is num ? rawImpact.toDouble() : 0.0;
    if (priceImpact > 5.0) {
      rules.add('SWAP_HIGH_PRICE_IMPACT');
      return PolicyResult.confirm(
        'High price impact (${priceImpact.toStringAsFixed(1)}%). '
        'You may receive significantly less than expected.',
        severity: PolicySeverity.danger,
        rules: rules,
        epkAvailable: epkAvail,
      );
    } else if (priceImpact > 1.0) {
      rules.add('SWAP_MODERATE_PRICE_IMPACT');
    }

    // Check 3: Unknown router — warn but don't block (router may simply be new)
    if (tx.routerAddress != null &&
        tx.routerAddress!.isNotEmpty &&
        !profile.allowUnknownContracts &&
        !profile.trustedContracts.contains(tx.routerAddress!.toLowerCase())) {
      rules.add('SWAP_UNKNOWN_ROUTER_WARN');
    }

    rules.add('SWAP_STANDARD_CONFIRM');
    return PolicyResult.confirm(
      'Review the swap route and confirm.',
      severity:
          (priceImpact > 1.0) ? PolicySeverity.warning : PolicySeverity.info,
      rules: rules,
      epkAvailable: epkAvail,
      epkRequired: tx.amount != null && tx.amount! > 1000,
    );
  }

  // ─── Approve V3 ───────────────────────────────────────────────────────────

  static PolicyResult _checkApproveV3(
    TransactionRequest tx,
    SimulationResult staticSim,
    RpcSimulationResult rpcSim,
    PolicyProfile profile,
    ExecutionPath path,
    List<String> rules,
  ) {
    final epkAvail = path == ExecutionPath.epkProtected;

    if (tx.isUnlimitedApproval && !profile.allowUnlimitedApprove) {
      rules.add('PROFILE_UNLIMITED_DENIED');
      return PolicyResult.block(
        'Unlimited approvals are disabled in your active policy profile.',
        severity: PolicySeverity.danger,
        rules: rules,
        epkAvailable: epkAvail,
      );
    }

    if (!tx.isUnlimitedApproval &&
        tx.amount != null &&
        tx.amount! > profile.approveLimitUsd) {
      rules.add('APPROVE_PROFILE_LIMIT_EXCEEDED');
      return PolicyResult.block(
        'Approve amount exceeds your profile limit (\$${profile.approveLimitUsd.toStringAsFixed(0)}).',
        severity: PolicySeverity.danger,
        rules: rules,
        epkAvailable: epkAvail,
      );
    }

    if (staticSim.flags.contains(SimulationFlag.unknownContract) &&
        !profile.allowUnknownContracts) {
      // Is the specific contract manually trusted?
      if (tx.spenderAddress == null ||
          !profile.trustedContracts
              .contains(tx.spenderAddress!.toLowerCase())) {
        rules.add('PROFILE_UNKNOWN_CONTRACT_DENIED');
        return PolicyResult.block(
          'Approving unknown/unverified contracts is disabled in your active policy profile.',
          severity: PolicySeverity.danger,
          rules: rules,
          epkAvailable: epkAvail,
        );
      }
    }

    rules.add('APPROVE_CONFIRM');
    return PolicyResult.confirm(
      'You are granting spending permission to a contract. Confirm?',
      severity: PolicySeverity.warning,
      rules: rules,
      epkAvailable: epkAvail,
    );
  }
}
