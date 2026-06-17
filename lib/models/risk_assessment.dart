enum RiskLabel { safe, caution, danger, critical }

class RiskReason {
  final String code;
  final String messageKey;
  final int weight;

  const RiskReason({
    required this.code,
    required this.messageKey,
    required this.weight,
  });
}

class ApprovalRiskAssessment {
  final int score; // 0..100 where 100 = max danger
  final RiskLabel label;
  final bool shouldRevoke;
  final List<RiskReason> reasons;

  const ApprovalRiskAssessment({
    required this.score,
    required this.label,
    required this.shouldRevoke,
    required this.reasons,
  });

  // Default "safe" assessment
  factory ApprovalRiskAssessment.safe() => const ApprovalRiskAssessment(
        score: 0,
        label: RiskLabel.safe,
        shouldRevoke: false,
        reasons: [],
      );
}

class WalletRiskAssessment {
  final int score; // 0..100
  final RiskLabel label;
  final int totalApprovals;
  final int unlimitedCount;
  final int dangerousCount;
  final int suspiciousCount;
  final List<RiskReason> reasons;

  const WalletRiskAssessment({
    required this.score,
    required this.label,
    required this.totalApprovals,
    required this.unlimitedCount,
    required this.dangerousCount,
    required this.suspiciousCount,
    required this.reasons,
  });
}

class ApprovalSignals {
  final bool isUnlimited;
  final bool isTrustedSpender;
  final bool isKnownDex;
  final bool isKnownBridge;
  final bool isUnknownSpender;
  final bool isSuspiciousSpender;
  final bool isFlaggedSpender;
  final bool isDex;
  final bool isBridge;
  final bool isVerifiedContract;
  final bool isProxyContract;
  final bool isUpgradeable;
  final int contractAgeDays;
  final bool hasOwnerPrivileges;
  final bool touchesValuableToken;
  final int previousInteractions;
  final bool spenderRepeatedAcrossWallet;
  final bool chainSupported;
  final bool isKnownDrainer;
  final String? threatReasonKey;
  final int threatWeight;
  final bool isPopular;
  final int popularityScore;
  final bool hasDiscoveredName;
  final bool canPause;
  final bool canMint;
  final bool canBlacklist;

  const ApprovalSignals({
    this.isUnlimited = false,
    this.isTrustedSpender = false,
    this.isKnownDex = false,
    this.isKnownBridge = false,
    this.isUnknownSpender = false,
    this.isSuspiciousSpender = false,
    this.isFlaggedSpender = false,
    this.isDex = false,
    this.isBridge = false,
    this.isVerifiedContract = true,
    this.isProxyContract = false,
    this.isUpgradeable = false,
    this.contractAgeDays = 365,
    this.hasOwnerPrivileges = false,
    this.touchesValuableToken = false,
    this.previousInteractions = 0,
    this.spenderRepeatedAcrossWallet = false,
    this.chainSupported = true,
    this.isKnownDrainer = false,
    this.threatReasonKey,
    this.threatWeight = 0,
    this.isPopular = false,
    this.popularityScore = 0,
    this.hasDiscoveredName = false,
    this.canPause = false,
    this.canMint = false,
    this.canBlacklist = false,
  });
}
