/// Risk level detected by the simulation layer.
/// Maps directly to UI color: safe=green, caution=yellow, warning=orange, critical=red.
enum SimulationRisk { safe, caution, warning, critical }

/// Simulation flag identifiers — deterministic pattern names.
/// These feed directly into the Explain Layer for human-readable warnings.
enum SimulationFlag {
  zeroAddress,
  unlimitedApproval,
  unknownContract,
  highValue,
  newContract,
  flaggedSpender,
  proxyContract,
  upgradeableContract,
  ownerPrivileges,
}

/// Extension to convert flags to human-readable warning strings.
extension SimulationFlagLabel on SimulationFlag {
  String get label {
    switch (this) {
      case SimulationFlag.zeroAddress:
        return 'Destination is the zero address — funds will be lost';
      case SimulationFlag.unlimitedApproval:
        return 'Unlimited spending permission requested';
      case SimulationFlag.unknownContract:
        return 'Unknown or unverified contract';
      case SimulationFlag.highValue:
        return 'High-value transaction';
      case SimulationFlag.newContract:
        return 'Contract deployed less than 30 days ago';
      case SimulationFlag.flaggedSpender:
        return 'This address has been flagged as suspicious';
      case SimulationFlag.proxyContract:
        return 'Proxy contract — implementation can change';
      case SimulationFlag.upgradeableContract:
        return 'Contract logic can be upgraded by its owner';
      case SimulationFlag.ownerPrivileges:
        return 'Contract owner has elevated privileges';
    }
  }
}

/// The result of running a [TransactionRequest] through the simulation layer.
/// All analysis is deterministic — no RPC or on-chain calls.
class SimulationResult {
  /// Overall risk level for this transaction
  final SimulationRisk risk;

  /// All detected flags — used by Explain Layer for warning bullets
  final List<SimulationFlag> flags;

  /// Whether the overall simulation passed (risk < critical)
  bool get passed => risk != SimulationRisk.critical;

  /// Whether the simulation detected a critical risk — convenience for PolicyEngine
  bool get isCritical => risk == SimulationRisk.critical;

  /// Whether any flags were detected
  bool get hasFlags => flags.isNotEmpty;

  /// Human-readable warning strings derived from flags
  List<String> get warningLabels => flags.map((f) => f.label).toList();

  const SimulationResult({
    required this.risk,
    required this.flags,
  });

  /// Clean result — no issues detected
  factory SimulationResult.clean() => const SimulationResult(
        risk: SimulationRisk.safe,
        flags: [],
      );
}
