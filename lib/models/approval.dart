import 'package:ibiti_guardian/models/risk_assessment.dart';

enum RiskLevel { safe, warning, danger }

enum SpenderReputation {
  trusted,
  unknown,
  suspicious,
  flagged,
  dex,
  bridge,
  safety
}

class ApprovalData {
  final int chainId; // 56
  final String token; // token contract 0x...
  final String? tokenName;
  final String? tokenSymbol;
  final String spenderAddress; // spender 0x...
  final String spender; // label for UI
  BigInt allowance;
  final int decimals; // token decimals

  final String? walletAddress; // owner of the approval
  final bool isKnownDex;
  final bool isVerified;
  final int contractAgeDays;
  bool isProxyContract;
  bool isUpgradeable;
  bool hasOwnerPrivileges;
  int previousInteractions;
  int popularityScore;
  bool isPopular;
  String? discoveredName;
  bool canPause;
  bool canMint;
  bool canBlacklist;

  RiskLevel riskLevel;
  SpenderReputation reputation;

  // New granular assessment field
  ApprovalRiskAssessment assessment;

  /// Convenience getter: true if riskLevel is warning or danger.
  bool get isRisky =>
      riskLevel == RiskLevel.warning || riskLevel == RiskLevel.danger;

  ApprovalData({
    this.chainId = 56,
    required this.token,
    this.tokenName,
    this.tokenSymbol,
    required this.spenderAddress,
    required this.spender,
    required this.allowance,
    this.decimals = 18,
    this.isKnownDex = false,
    this.isVerified = false,
    this.contractAgeDays = 0,
    this.riskLevel = RiskLevel.safe,
    this.reputation = SpenderReputation.unknown,
    this.walletAddress,
    this.isProxyContract = false,
    this.isUpgradeable = false,
    this.hasOwnerPrivileges = false,
    this.previousInteractions = 0,
    this.popularityScore = 0,
    this.isPopular = false,
    this.discoveredName,
    this.canPause = false,
    this.canMint = false,
    this.canBlacklist = false,
    ApprovalRiskAssessment? assessment,
  }) : assessment = assessment ?? ApprovalRiskAssessment.safe();

  void copyWithEnrichment({
    bool? isProxyContract,
    bool? isUpgradeable,
    bool? hasOwnerPrivileges,
    int? previousInteractions,
    int? popularityScore,
    bool? isPopular,
    String? discoveredName,
    bool? canPause,
    bool? canMint,
    bool? canBlacklist,
  }) {
    if (isProxyContract != null) this.isProxyContract = isProxyContract;
    if (isUpgradeable != null) this.isUpgradeable = isUpgradeable;
    if (hasOwnerPrivileges != null) {
      this.hasOwnerPrivileges = hasOwnerPrivileges;
    }
    if (previousInteractions != null) {
      this.previousInteractions = previousInteractions;
    }
    if (popularityScore != null) this.popularityScore = popularityScore;
    if (isPopular != null) this.isPopular = isPopular;
    if (discoveredName != null) this.discoveredName = discoveredName;
    if (canPause != null) this.canPause = canPause;
    if (canMint != null) this.canMint = canMint;
    if (canBlacklist != null) this.canBlacklist = canBlacklist;
  }
}
