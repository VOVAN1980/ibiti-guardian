/// The high-level mode dictating the strictness of the policy engine.
enum PolicyMode { safe, defi, advanced }

/// A persistent snapshot of the user's execution policy rules.
/// Managed by PolicyProfileStore.
class PolicyProfile {
  /// The active security mode determining limits and strictness
  final PolicyMode mode;

  /// Maximum USD equivalent allowed in a single SEND transaction
  final double sendLimitUsd;

  /// Maximum USD equivalent allowed in a single SWAP transaction
  final double swapLimitUsd;

  /// Maximum USD equivalent allowed in an APPROVE transaction
  final double approveLimitUsd;

  /// Expiry timestamps for temporary limits per action ('SEND', 'SWAP', 'APPROVE').
  /// If the timestamp has passed, the limit goes to zero (or fallback behavior).
  final Map<String, DateTime> actionExpiries;

  /// Whether interaction with an unverified/unknown contract is allowed
  final bool allowUnknownContracts;

  /// List of specifically trusted destination addresses (bypasses some checks)
  final List<String> trustedAddresses;

  /// List of specifically trusted smart contracts (bypasses some checks)
  final List<String> trustedContracts;

  const PolicyProfile({
    required this.mode,
    required this.sendLimitUsd,
    required this.swapLimitUsd,
    required this.approveLimitUsd,
    required this.allowUnknownContracts,
    this.actionExpiries = const {},
    this.trustedAddresses = const [],
    this.trustedContracts = const [],
  });

  /// Factory for the default Safe Mode profile.
  factory PolicyProfile.safe() => const PolicyProfile(
        mode: PolicyMode.safe,
        sendLimitUsd: 50.0,
        swapLimitUsd: 500.0,
        approveLimitUsd: 100.0,
        allowUnknownContracts: false,
        actionExpiries: {},
      );

  /// Factory for the DeFi Mode (looser limits, allows unlimited approve).
  factory PolicyProfile.defi() => const PolicyProfile(
        mode: PolicyMode.defi,
        sendLimitUsd: 1000.0,
        swapLimitUsd: 5000.0,
        approveLimitUsd: 5000.0,
        allowUnknownContracts: true,
        actionExpiries: {},
      );

  /// Copies this profile with updated fields.
  PolicyProfile copyWith({
    PolicyMode? mode,
    double? sendLimitUsd,
    double? swapLimitUsd,
    double? approveLimitUsd,
    bool? allowUnknownContracts,
    List<String>? trustedAddresses,
    List<String>? trustedContracts,
    Map<String, DateTime>? actionExpiries,
  }) {
    return PolicyProfile(
      mode: mode ?? this.mode,
      sendLimitUsd: sendLimitUsd ?? this.sendLimitUsd,
      swapLimitUsd: swapLimitUsd ?? this.swapLimitUsd,
      approveLimitUsd: approveLimitUsd ?? this.approveLimitUsd,
      allowUnknownContracts:
          allowUnknownContracts ?? this.allowUnknownContracts,
      trustedAddresses: trustedAddresses ?? this.trustedAddresses,
      trustedContracts: trustedContracts ?? this.trustedContracts,
      actionExpiries: actionExpiries ?? this.actionExpiries,
    );
  }
}
