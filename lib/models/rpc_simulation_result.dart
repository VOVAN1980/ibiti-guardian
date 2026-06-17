/// Preflight outcome containing data from a real RPC simulation (eth_call/estimateGas).
class RpcSimulationResult {
  /// Whether the transaction would succeed on-chain
  final bool success;

  /// E.g., 'ERC20: transfer amount exceeds balance' or 'execution reverted'
  final String? revertReason;

  /// Estimated gas cost string in wei/hex, or null if it failed
  final String? estimatedGas;

  /// Any RPC-specific warnings (e.g. execution took too long, state mismatch)
  final List<String> warnings;

  /// Whether the simulation detected a permanent state change
  /// (e.g. transfer/approve, vs a pure view call)
  final bool stateChangeDetected;

  /// True if the transaction outright reverted on the simulated chain
  bool get isReverted => !success && revertReason != null;

  const RpcSimulationResult({
    required this.success,
    this.revertReason,
    this.estimatedGas,
    this.warnings = const [],
    this.stateChangeDetected = true,
  });

  /// Factory for a simulated failure
  factory RpcSimulationResult.revert(String reason) => RpcSimulationResult(
        success: false,
        revertReason: reason,
        stateChangeDetected: false,
      );

  /// Factory for a successful simulation
  factory RpcSimulationResult.ok(
          {String? gas, List<String> warnings = const []}) =>
      RpcSimulationResult(
        success: true,
        estimatedGas: gas,
        warnings: warnings,
        stateChangeDetected: true,
      );

  /// Factory for an intentionally skipped simulation.
  ///
  /// Used when a prerequisite step (e.g. ERC-20 approve) must complete
  /// before the swap can be simulated. Marked as success so the policy
  /// engine does not block the preview — the real simulation will run
  /// when the user presses "Continue swap" after approval.
  factory RpcSimulationResult.deferred() => const RpcSimulationResult(
        success: true,
        estimatedGas: null,
        warnings: ['Swap simulation deferred until approval completes.'],
        stateChangeDetected: false,
      );
}
