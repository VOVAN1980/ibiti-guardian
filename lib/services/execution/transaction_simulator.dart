import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/models/simulation_result.dart';

/// Deterministic static analyzer for [TransactionRequest].
///
/// Phase 4 rules: NO RPC, NO eth_call, NO gas estimation.
/// All analysis is based on known patterns, heuristics, and data in the request.
/// On-chain simulation will be Phase 5.
class TransactionSimulator {
  TransactionSimulator._();

  /// High-value threshold in USD (same as policy max for consistency)
  static const double _highValueThreshold = 500.0;

  /// Analyze a [TransactionRequest] and return a [SimulationResult].
  static SimulationResult analyze(TransactionRequest tx) {
    final flags = <SimulationFlag>[];

    switch (tx.type) {
      case TransactionType.send:
        _analyzeSend(tx, flags);
        break;
      case TransactionType.approve:
        _analyzeApprove(tx, flags);
        break;
      case TransactionType.revoke:
        // Revoke is generally safe — no simulation flags
        break;
      case TransactionType.swap:
        _analyzeSwap(tx, flags);
        break;
      case TransactionType.unknown:
        // Treat as suspicious
        flags.add(SimulationFlag.unknownContract);
        break;
    }

    final risk = _computeRisk(flags);
    return SimulationResult(risk: risk, flags: flags);
  }

  // в”Ђв”Ђв”Ђ Send Analysis в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  static void _analyzeSend(TransactionRequest tx, List<SimulationFlag> flags) {
    // Zero address check
    if (_isZeroAddress(tx.toAddress)) {
      flags.add(SimulationFlag.zeroAddress);
    }

    // High value check
    if (tx.amount != null && tx.amount! > _highValueThreshold) {
      flags.add(SimulationFlag.highValue);
    }

    // Unknown token contract (no contract address provided)
    if (tx.tokenContract == null) {
      flags.add(SimulationFlag.unknownContract);
    }
  }

  // в”Ђв”Ђв”Ђ Approve Analysis в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  static void _analyzeApprove(
      TransactionRequest tx, List<SimulationFlag> flags) {
    // Unlimited approval
    if (tx.isUnlimitedApproval) {
      flags.add(SimulationFlag.unlimitedApproval);
    }

    // No spender address
    if (tx.spenderAddress == null || tx.spenderAddress!.isEmpty) {
      flags.add(SimulationFlag.unknownContract);
    }

    // Zero address spender
    if (tx.spenderAddress != null && _isZeroAddress(tx.spenderAddress!)) {
      flags.add(SimulationFlag.zeroAddress);
    }
  }

  // ─── Swap Analysis ────────────────────────────────────────────────────────

  static void _analyzeSwap(TransactionRequest tx, List<SimulationFlag> flags) {
    if (tx.toAddress == '' || _isZeroAddress(tx.toAddress)) {
      flags.add(SimulationFlag.zeroAddress);
    }

    if (tx.amount != null && tx.amount! > _highValueThreshold) {
      flags.add(SimulationFlag.highValue);
    }

    if (tx.routerAddress == null || tx.routerAddress!.isEmpty) {
      flags.add(SimulationFlag.unknownContract);
    }
  }

  // в”Ђв”Ђв”Ђ Risk Aggregation в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  /// Aggregate flags into an overall risk level.
  /// Worst flag wins.
  static SimulationRisk _computeRisk(List<SimulationFlag> flags) {
    if (flags.isEmpty) return SimulationRisk.safe;

    // Critical flags в†’ immediate critical
    const criticalFlags = {
      SimulationFlag.zeroAddress,
      SimulationFlag.flaggedSpender,
    };
    if (flags.any(criticalFlags.contains)) return SimulationRisk.critical;

    // Warning flags
    const warningFlags = {
      SimulationFlag.unlimitedApproval,
      SimulationFlag.newContract,
      SimulationFlag.proxyContract,
      SimulationFlag.upgradeableContract,
      SimulationFlag.ownerPrivileges,
    };
    if (flags.any(warningFlags.contains)) return SimulationRisk.warning;

    // Caution flags
    const cautionFlags = {
      SimulationFlag.unknownContract,
      SimulationFlag.highValue,
    };
    if (flags.any(cautionFlags.contains)) return SimulationRisk.caution;

    return SimulationRisk.safe;
  }

  // в”Ђв”Ђв”Ђ Helpers в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  static bool _isZeroAddress(String address) {
    final clean = address.toLowerCase().replaceAll('0x', '');
    return clean.isEmpty || clean.replaceAll('0', '').isEmpty;
  }
}
