import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/models/rpc_simulation_result.dart';
import 'package:ibiti_guardian/models/simulation_result.dart';
import 'package:ibiti_guardian/models/transaction_explanation.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/policy/guardian_policy_engine.dart';

/// Converts execution context into the UI-ready [TransactionExplanation].
class TransactionExplainer {
  TransactionExplainer._();

  static TransactionExplanation explainV3(
    TransactionRequest tx,
    SimulationResult staticSim,
    RpcSimulationResult rpcSim,
    PolicyResult policy,
    PolicyProfile profile,
    ExecutionPath path,
  ) {
    final warnings = <String>[];

    if (path == ExecutionPath.fallback) {
      warnings.add(
        'Protected execution is unavailable on this route. Guardian is using local safeguards only.',
      );
    }
    if (tx.toAddress.isNotEmpty &&
        profile.trustedAddresses.contains(tx.toAddress.toLowerCase())) {
      warnings.add('Destination matches your trusted address book.');
    }
    if (staticSim.hasFlags) {
      warnings.addAll(staticSim.warningLabels);
    }
    if (rpcSim.warnings.isNotEmpty) {
      warnings.addAll(rpcSim.warnings);
    }

    switch (tx.type) {
      case TransactionType.send:
        return _explainSend(tx, staticSim, rpcSim, policy, warnings);
      case TransactionType.revoke:
        return _explainRevoke(tx, rpcSim, warnings);
      case TransactionType.approve:
        return _explainApprove(tx, staticSim, rpcSim, policy, warnings);
      case TransactionType.swap:
        return _explainSwap(tx, staticSim, rpcSim, policy, warnings);
      case TransactionType.unknown:
        return _explainUnknown(policy.severity, warnings);
    }
  }

  static TransactionExplanation _explainSend(
    TransactionRequest tx,
    SimulationResult staticSim,
    RpcSimulationResult rpcSim,
    PolicyResult policy,
    List<String> warnings,
  ) {
    final amount = tx.amount?.toStringAsFixed(2) ?? '?';
    final token = tx.tokenSymbol ?? 'asset';
    final to = _shortAddr(tx.toAddress);

    return TransactionExplanation(
      headline: 'Sending $amount $token',
      detail: policy.blocked
          ? 'Guardian locked this transfer because the current checks see an unsafe execution profile.'
          : 'You are about to transfer $amount $token to $to. Review the recipient and network carefully because this action cannot be undone after confirmation.',
      signingExplanation:
          'You are signing a ${tx.tokenContract == null || tx.tokenContract!.isEmpty ? "native transfer" : "token transfer"} from ${_shortAddr(tx.fromAddress)} to $to on ${tx.networkLabel}.',
      expectedOutcome:
          'If this confirms, $amount $token will leave your wallet and arrive at $to.',
      simulationSummary: rpcSim.success
          ? 'Simulation succeeded on ${tx.networkLabel}. Estimated execution cost: ${_gasLabel(rpcSim)}.'
          : 'Simulation predicts this transfer will revert: ${rpcSim.revertReason ?? "execution reverted"}.',
      riskSummary: _riskSummary(staticSim.risk, rpcSim.success, policy.blocked),
      severity: policy.severity,
      warnings: warnings,
    );
  }

  static TransactionExplanation _explainApprove(
    TransactionRequest tx,
    SimulationResult staticSim,
    RpcSimulationResult rpcSim,
    PolicyResult policy,
    List<String> warnings,
  ) {
    final token = tx.tokenSymbol ?? 'token';
    final spender = _shortAddr(tx.spenderAddress ?? tx.toAddress);
    final limit = tx.isUnlimitedApproval
        ? 'without a spending cap'
        : 'up to ${tx.amount?.toStringAsFixed(2) ?? "the requested amount"} $token';

    return TransactionExplanation(
      headline: tx.isUnlimitedApproval
          ? 'Unlimited Approval Request'
          : 'Approval Request',
      detail: policy.blocked
          ? 'Guardian blocked this approval because the current policy does not trust this permission set.'
          : 'This request would let $spender spend your $token. Approvals stay active until you revoke them.',
      signingExplanation: tx.isUnlimitedApproval
          ? 'You are signing an unlimited token approval for $spender.'
          : 'You are signing a capped token approval for $spender.',
      expectedOutcome:
          '$spender will be able to spend $limit from your wallet after confirmation.',
      simulationSummary: rpcSim.success
          ? 'Simulation shows the approval call can execute on ${tx.networkLabel}.'
          : 'Simulation predicts the approval would fail: ${rpcSim.revertReason ?? "execution reverted"}.',
      riskSummary: tx.isUnlimitedApproval
          ? 'Unlimited approvals create persistent risk until revoked.'
          : _riskSummary(staticSim.risk, rpcSim.success, policy.blocked),
      severity: policy.severity,
      warnings: warnings,
    );
  }

  static TransactionExplanation _explainRevoke(
    TransactionRequest tx,
    RpcSimulationResult rpcSim,
    List<String> warnings,
  ) {
    final token = tx.tokenSymbol ?? 'token';
    final spender = _shortAddr(tx.spenderAddress ?? tx.toAddress);

    return TransactionExplanation(
      headline: 'Revoking $token Approval',
      detail:
          'This is a protective action. Guardian will reset the spender allowance so the contract can no longer move your $token.',
      signingExplanation:
          'You are signing an approval reset that sets the allowance for $spender to zero.',
      expectedOutcome:
          '$spender will lose spending access to your $token after confirmation.',
      simulationSummary: rpcSim.success
          ? 'Simulation shows the revoke transaction should execute normally.'
          : 'Simulation predicts the revoke would fail: ${rpcSim.revertReason ?? "execution reverted"}.',
      riskSummary: 'Protective action verified.',
      severity: PolicySeverity.info,
      warnings: warnings,
    );
  }

  static TransactionExplanation _explainSwap(
    TransactionRequest tx,
    SimulationResult staticSim,
    RpcSimulationResult rpcSim,
    PolicyResult policy,
    List<String> warnings,
  ) {
    final fromAmount = tx.amount?.toStringAsFixed(4) ?? '?';
    final fromToken = tx.tokenSymbol ?? '?';
    final toToken = tx.targetTokenSymbol ?? '?';

    return TransactionExplanation(
      headline: 'Swap Route Execution',
      detail: policy.blocked
          ? 'Guardian blocked this swap because the current route exceeds your active safety envelope.'
          : 'This swap will route through a contract call, not a simple transfer. Check price impact, destination token, and the router before confirming.',
      signingExplanation:
          'You are signing a router call to exchange $fromAmount $fromToken for $toToken.',
      expectedOutcome:
          'If the route stays within its quote limits, the router will take $fromAmount $fromToken and return $toToken to your wallet.',
      simulationSummary: rpcSim.success
          ? 'Simulation succeeded for the routed swap on ${tx.networkLabel}. Estimated execution cost: ${_gasLabel(rpcSim)}.'
          : 'Simulation predicts the swap would fail: ${rpcSim.revertReason ?? "execution reverted"}.',
      riskSummary: _riskSummary(staticSim.risk, rpcSim.success, policy.blocked),
      severity: policy.severity,
      warnings: warnings,
    );
  }

  static TransactionExplanation _explainUnknown(
    PolicySeverity severity,
    List<String> warnings,
  ) {
    return TransactionExplanation(
      headline: 'Unverified Request',
      detail:
          'Guardian could not safely decode this request into a known transfer, approval, revoke, or swap flow.',
      signingExplanation:
          'You are signing a payload that could not be cleanly classified.',
      expectedOutcome:
          'The exact on-chain effect is not fully decoded, so this request should be treated as dangerous.',
      simulationSummary: 'Simulation coverage is incomplete for this payload.',
      riskSummary: 'High potential for hidden behavior.',
      severity: severity,
      warnings: warnings,
    );
  }

  static String _shortAddr(String addr) {
    if (addr.length < 12) return addr;
    return '${addr.substring(0, 6)}...${addr.substring(addr.length - 4)}';
  }

  static String _riskSummary(
    SimulationRisk risk,
    bool rpcOk,
    bool blocked,
  ) {
    if (blocked) return 'Execution safely prevented.';
    if (!rpcOk) {
      return 'On-chain simulation predicts failure. Sending this would likely waste gas.';
    }
    return switch (risk) {
      SimulationRisk.safe =>
        'Simulation and policy checks did not detect a hidden risk pattern.',
      SimulationRisk.caution =>
        'Proceed carefully. Guardian found a caution-level pattern that still needs review.',
      SimulationRisk.warning =>
        'Guardian found multiple warning signals. Extra review is required before confirming.',
      SimulationRisk.critical =>
        'Critical risk pattern detected. This should normally stay blocked.',
    };
  }

  static String _gasLabel(RpcSimulationResult rpcSim) {
    final gas = rpcSim.estimatedGas;
    if (gas == null || gas.isEmpty) return 'unknown gas';
    if (gas.startsWith('0x')) {
      final parsed = int.tryParse(gas.substring(2), radix: 16);
      if (parsed != null) return '$parsed gas';
    }
    return gas;
  }
}
