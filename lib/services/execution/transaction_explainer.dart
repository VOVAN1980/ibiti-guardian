import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/models/rpc_simulation_result.dart';
import 'package:ibiti_guardian/models/simulation_result.dart';
import 'package:ibiti_guardian/models/transaction_explanation.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
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
    final from = _shortAddr(tx.fromAddress);
    final network = tx.networkLabel;
    final isNative = tx.tokenContract == null || tx.tokenContract!.isEmpty;
    final reason = rpcSim.revertReason ?? 'execution reverted';
    final gas = _gasLabel(rpcSim);
    final args = <String, Object>{
      'amount': amount,
      'token': token,
      'from': from,
      'to': to,
      'network': network,
      'gas': gas,
      'reason': reason,
    };

    return TransactionExplanation(
      headline: _l('txExplainSendHeadline', 'Sending $amount $token', args),
      detail: policy.blocked
          ? _l('txExplainSendBlocked',
              'Guardian locked this transfer because the current checks see an unsafe execution profile.')
          : _l(
              'txExplainSendDetail',
              'You are about to transfer $amount $token to $to. Review the recipient and network carefully because this action cannot be undone after confirmation.',
              args),
      signingExplanation: isNative
          ? _l(
              'txExplainSendSigningNative',
              'You are signing a native transfer from $from to $to on $network.',
              args)
          : _l(
              'txExplainSendSigningToken',
              'You are signing a token transfer from $from to $to on $network.',
              args),
      expectedOutcome: _l(
          'txExplainSendOutcome',
          'If this confirms, $amount $token will leave your wallet and arrive at $to.',
          args),
      simulationSummary: rpcSim.success
          ? _l(
              'txExplainSendSimOk',
              'Simulation succeeded on $network. Estimated execution cost: $gas.',
              args)
          : _l('txExplainSendSimFail',
              'Simulation predicts this transfer will revert: $reason.', args),
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
    final amount = tx.amount?.toStringAsFixed(2);
    final network = tx.networkLabel;
    final reason = rpcSim.revertReason ?? 'execution reverted';
    final args = <String, Object>{
      'token': token,
      'spender': spender,
      'amount': amount ?? '',
      'network': network,
      'reason': reason,
    };

    final String expectedOutcome;
    if (tx.isUnlimitedApproval) {
      expectedOutcome = _l(
          'txExplainApproveOutcomeUnlimited',
          '$spender will be able to spend without a spending cap from your wallet after confirmation.',
          args);
    } else if (amount == null) {
      expectedOutcome = _l(
          'txExplainApproveOutcomeRequested',
          '$spender will be able to spend up to the requested amount $token from your wallet after confirmation.',
          args);
    } else {
      expectedOutcome = _l(
          'txExplainApproveOutcomeCapped',
          '$spender will be able to spend up to $amount $token from your wallet after confirmation.',
          args);
    }

    return TransactionExplanation(
      headline: tx.isUnlimitedApproval
          ? _l('txExplainApproveUnlimitedHeadline', 'Unlimited Approval Request')
          : _l('txExplainApproveHeadline', 'Approval Request'),
      detail: policy.blocked
          ? _l('txExplainApproveBlocked',
              'Guardian blocked this approval because the current policy does not trust this permission set.')
          : _l(
              'txExplainApproveDetail',
              'This request would let $spender spend your $token. Approvals stay active until you revoke them.',
              args),
      signingExplanation: tx.isUnlimitedApproval
          ? _l('txExplainApproveSigningUnlimited',
              'You are signing an unlimited token approval for $spender.', args)
          : _l('txExplainApproveSigningCapped',
              'You are signing a capped token approval for $spender.', args),
      expectedOutcome: expectedOutcome,
      simulationSummary: rpcSim.success
          ? _l('txExplainApproveSimOk',
              'Simulation shows the approval call can execute on $network.', args)
          : _l('txExplainApproveSimFail',
              'Simulation predicts the approval would fail: $reason.', args),
      riskSummary: tx.isUnlimitedApproval
          ? _l('txExplainApproveUnlimitedRisk',
              'Unlimited approvals create persistent risk until revoked.')
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
    final reason = rpcSim.revertReason ?? 'execution reverted';
    final args = <String, Object>{
      'token': token,
      'spender': spender,
      'reason': reason,
    };

    return TransactionExplanation(
      headline:
          _l('txExplainRevokeHeadline', 'Revoking $token Approval', args),
      detail: _l(
          'txExplainRevokeDetail',
          'This is a protective action. Guardian will reset the spender allowance so the contract can no longer move your $token.',
          args),
      signingExplanation: _l(
          'txExplainRevokeSigning',
          'You are signing an approval reset that sets the allowance for $spender to zero.',
          args),
      expectedOutcome: _l(
          'txExplainRevokeOutcome',
          '$spender will lose spending access to your $token after confirmation.',
          args),
      simulationSummary: rpcSim.success
          ? _l('txExplainRevokeSimOk',
              'Simulation shows the revoke transaction should execute normally.')
          : _l('txExplainRevokeSimFail',
              'Simulation predicts the revoke would fail: $reason.', args),
      riskSummary: _l('txExplainRevokeRisk', 'Protective action verified.'),
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
    final network = tx.networkLabel;
    final gas = _gasLabel(rpcSim);
    final reason = rpcSim.revertReason ?? 'execution reverted';
    final args = <String, Object>{
      'fromAmount': fromAmount,
      'fromToken': fromToken,
      'toToken': toToken,
      'network': network,
      'gas': gas,
      'reason': reason,
    };

    return TransactionExplanation(
      headline: _l('txExplainSwapHeadline', 'Swap Route Execution'),
      detail: policy.blocked
          ? _l('txExplainSwapBlocked',
              'Guardian blocked this swap because the current route exceeds your active safety envelope.')
          : _l('txExplainSwapDetail',
              'This swap will route through a contract call, not a simple transfer. Check price impact, destination token, and the router before confirming.'),
      signingExplanation: _l(
          'txExplainSwapSigning',
          'You are signing a router call to exchange $fromAmount $fromToken for $toToken.',
          args),
      expectedOutcome: _l(
          'txExplainSwapOutcome',
          'If the route stays within its quote limits, the router will take $fromAmount $fromToken and return $toToken to your wallet.',
          args),
      simulationSummary: rpcSim.success
          ? _l(
              'txExplainSwapSimOk',
              'Simulation succeeded for the routed swap on $network. Estimated execution cost: $gas.',
              args)
          : _l('txExplainSwapSimFail',
              'Simulation predicts the swap would fail: $reason.', args),
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
      headline: _l('txExplainUnknownHeadline', 'Unverified Request'),
      detail: _l('txExplainUnknownDetail',
          'Guardian could not safely decode this request into a known transfer, approval, revoke, or swap flow.'),
      signingExplanation: _l('txExplainUnknownSigning',
          'You are signing a payload that could not be cleanly classified.'),
      expectedOutcome: _l('txExplainUnknownOutcome',
          'The exact on-chain effect is not fully decoded, so this request should be treated as dangerous.'),
      simulationSummary: _l('txExplainUnknownSim',
          'Simulation coverage is incomplete for this payload.'),
      riskSummary:
          _l('txExplainUnknownRisk', 'High potential for hidden behavior.'),
      severity: severity,
      warnings: warnings,
    );
  }

  /// Localized text. [fallback] is the English text with values already
  /// substituted — LocalizationService returns defaults uninterpolated.
  /// Warnings stay English: the preview card picks badges by their words.
  static String _l(String key, String fallback,
      [Map<String, Object> args = const {}]) {
    return LocalizationService.instance.t(key, {...args, 'default': fallback});
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
    if (blocked) {
      return _l('txExplainRiskBlocked', 'Execution safely prevented.');
    }
    if (!rpcOk) {
      return _l('txExplainRiskSimFail',
          'On-chain simulation predicts failure. Sending this would likely waste gas.');
    }
    return switch (risk) {
      SimulationRisk.safe => _l('txExplainRiskSafe',
          'Simulation and policy checks did not detect a hidden risk pattern.'),
      SimulationRisk.caution => _l('txExplainRiskCaution',
          'Proceed carefully. Guardian found a caution-level pattern that still needs review.'),
      SimulationRisk.warning => _l('txExplainRiskWarning',
          'Guardian found multiple warning signals. Extra review is required before confirming.'),
      SimulationRisk.critical => _l('txExplainRiskCritical',
          'Critical risk pattern detected. This should normally stay blocked.'),
    };
  }

  static String _gasLabel(RpcSimulationResult rpcSim) {
    final gas = rpcSim.estimatedGas;
    if (gas == null || gas.isEmpty) {
      return _l('txExplainGasUnknown', 'unknown gas');
    }
    if (gas.startsWith('0x')) {
      final parsed = int.tryParse(gas.substring(2), radix: 16);
      if (parsed != null) {
        return _l('txExplainGasUnits', '$parsed gas', {'gas': parsed});
      }
    }
    return gas;
  }
}
