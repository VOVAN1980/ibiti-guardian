/// Represents the aggregated context of a single wallet identity.
/// Used by WalletOrchestrator to feed global risks into PolicyEngine checks.
class WalletContext {
  final String address;
  final int chainId;
  final double totalBalance;

  /// A computed score (0-100) representing exposure risk.
  /// 100 = Extremely high risk (e.g. unknown approvals, recent hacks across connections)
  final int riskScore;

  const WalletContext({
    required this.address,
    required this.chainId,
    required this.totalBalance,
    this.riskScore = 0,
  });

  bool get isHighRisk => riskScore > 75;
}
