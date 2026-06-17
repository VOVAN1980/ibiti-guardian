import 'package:ibiti_guardian/models/approval.dart';
import 'package:ibiti_guardian/models/risk_assessment.dart';
import 'package:ibiti_guardian/services/threat_intelligence_service.dart';
import 'package:ibiti_guardian/services/security/monitoring_state_service.dart';

class RiskEngine {
  static final BigInt maxUint256 = BigInt.parse(
    "115792089237316195423570985008687907853269984665640564039457584007913129639935",
  );

  /// Main evaluation method (Backward Compatible)
  static void evaluate(List<ApprovalData> approvals) {
    for (final a in approvals) {
      final signals = _extractSignals(a);
      a.assessment = computeApprovalAssessment(signals);

      // Maintain legacy fields for compatibility until UI is fully migrated
      a.riskLevel = _mapLabelToLegacyLevel(a.assessment.label);
    }
  }

  static void evaluateApprovals(List<ApprovalData> approvals) {
    evaluate(approvals);
  }

  /// Extracts risk signals from ApprovalData
  static ApprovalSignals _extractSignals(ApprovalData a) {
    final threat = ThreatIntelligenceService.instance.lookup(
      a.chainId,
      a.spenderAddress,
    );

    return ApprovalSignals(
      isUnlimited: a.allowance == maxUint256,
      isTrustedSpender: a.reputation == SpenderReputation.trusted,
      isKnownDex: a.isKnownDex || a.reputation == SpenderReputation.dex,
      isDex: a.reputation == SpenderReputation.dex,
      isBridge: a.reputation == SpenderReputation.bridge,
      isKnownBridge: a.reputation == SpenderReputation.bridge,
      isUnknownSpender: a.reputation == SpenderReputation.unknown,
      isSuspiciousSpender: a.reputation == SpenderReputation.suspicious,
      isFlaggedSpender: a.reputation == SpenderReputation.flagged,
      isVerifiedContract: a.isVerified,
      contractAgeDays: a.contractAgeDays,
      isKnownDrainer: threat != null,
      threatReasonKey: threat?.reasonKey,
      threatWeight: threat?.baseRiskWeight ?? 0,
      touchesValuableToken: _isValuableToken(a.chainId, a.token),
      spenderRepeatedAcrossWallet: _isSpenderRepeated(a.spenderAddress),
      // The following signals are currently defaults as the data isn't available yet
      isProxyContract: a.isProxyContract,
      isUpgradeable: a.isUpgradeable,
      hasOwnerPrivileges: a.hasOwnerPrivileges,
      previousInteractions: a.previousInteractions,
      isPopular: a.isPopular,
      popularityScore: a.popularityScore,
      hasDiscoveredName: a.discoveredName != null,
      canPause: a.canPause,
      canMint: a.canMint,
      canBlacklist: a.canBlacklist,
      chainSupported: true,
    );
  }

  static bool _isValuableToken(int chainId, String tokenAddress) {
    final addr = tokenAddress.toLowerCase();
    // Ethereum (1)
    if (chainId == 1) {
      return [
        "0xdac17f958d2ee523a2206206994597c13d831ec7", // USDT
        "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", // USDC
        "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2", // WETH
        "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599", // WBTC
      ].contains(addr);
    }
    // BNB Chain (56)
    if (chainId == 56) {
      return [
        "0x55d398326f99059ff775485246999027b3197955", // USDT
        "0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d", // USDC
        "0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c", // WBNB
        "0x2170ed0880ac9a755fd29b2688956bd959f933f8", // ETH
      ].contains(addr);
    }
    // Polygon (137)
    if (chainId == 137) {
      return [
        "0xc2132d05d31c914a87c6611c10748aeb04b58e8f", // USDT
        "0x2791bca1f2de4661ed88a30c99a7a9449aa84174", // USDC
        "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270", // WMATIC
        "0x7ceb23fd6bc0ad59e62ac25578270cff1b9f6190", // WETH
      ].contains(addr);
    }
    return false;
  }

  static bool _isSpenderRepeated(String spenderAddress) {
    final addr = spenderAddress.toLowerCase();
    return MonitoringStateService.instance
        .isSpenderRepeatedInOtherWallets(addr);
  }

  /// Computes granular assessment for a single approval based on signals
  static ApprovalRiskAssessment computeApprovalAssessment(
    ApprovalSignals signals,
  ) {
    int score = 0;
    final reasons = <RiskReason>[];

    // Scoring weights from requirements
    if (signals.isKnownDrainer) {
      score += signals.threatWeight;
      reasons.add(
        RiskReason(
          code: 'threat_db_hit',
          messageKey: signals.threatReasonKey ?? 'riskReasonKnownDrainer',
          weight: signals.threatWeight,
        ),
      );
    }
    if (signals.isUnlimited) {
      score += 35;
      reasons.add(
        const RiskReason(
          code: 'unlimited_approval',
          messageKey: 'riskReasonUnlimitedApproval',
          weight: 35,
        ),
      );
    }
    if (signals.isFlaggedSpender) {
      score += 60;
      reasons.add(
        const RiskReason(
          code: 'flagged_spender',
          messageKey: 'riskReasonFlaggedSpender',
          weight: 60,
        ),
      );
    }
    if (signals.isSuspiciousSpender) {
      score += 35;
      reasons.add(
        const RiskReason(
          code: 'suspicious_spender',
          messageKey: 'riskReasonSuspiciousSpender',
          weight: 35,
        ),
      );
    }
    if (signals.isUnknownSpender) {
      // Penalty is reduced if we at least discovered a name or have some popularity
      int unknownPenalty = 20;
      if (signals.hasDiscoveredName) unknownPenalty -= 5;

      score += unknownPenalty;
      reasons.add(
        RiskReason(
          code: 'unknown_spender',
          messageKey: 'riskReasonUnknownSpender',
          weight: unknownPenalty,
        ),
      );
    }
    if (!signals.isVerifiedContract) {
      score += 15;
      reasons.add(
        const RiskReason(
          code: 'unverified_contract',
          messageKey: 'riskReasonUnverifiedContract',
          weight: 15,
        ),
      );
    }
    if (signals.isProxyContract) {
      score += 10;
      reasons.add(
        const RiskReason(
          code: 'proxy_contract',
          messageKey: 'riskReasonProxyContract',
          weight: 10,
        ),
      );
    }
    if (signals.isUpgradeable) {
      score += 10;
      reasons.add(
        const RiskReason(
          code: 'upgradeable',
          messageKey: 'riskReasonUpgradeable',
          weight: 10,
        ),
      );
    }
    if (signals.contractAgeDays < 7) {
      score += 25; // More aggressive amplifier
      reasons.add(
        const RiskReason(
          code: 'new_contract_v0',
          messageKey: 'riskReasonNewContractV0',
          weight: 25,
        ),
      );
    } else if (signals.contractAgeDays <= 30) {
      score += 15;
      reasons.add(
        const RiskReason(
          code: 'new_contract_v1',
          messageKey: 'riskReasonNewContractV1',
          weight: 15,
        ),
      );
    } else if (signals.contractAgeDays <= 90) {
      score += 8;
      reasons.add(
        const RiskReason(
          code: 'new_contract_v2',
          messageKey: 'riskReasonNewContractV2',
          weight: 8,
        ),
      );
    }
    if (signals.hasOwnerPrivileges) {
      score += 10;
      reasons.add(
        const RiskReason(
          code: 'owner_privileges',
          messageKey: 'riskReasonOwnerPrivileges',
          weight: 10,
        ),
      );
    }
    if (signals.touchesValuableToken) {
      score += 10;
      reasons.add(
        const RiskReason(
          code: 'valuable_token',
          messageKey: 'riskReasonValuableToken',
          weight: 10,
        ),
      );
    }
    if (signals.previousInteractions == 0) {
      score += 8;
      reasons.add(
        const RiskReason(
          code: 'no_prev_interactions',
          messageKey: 'riskReasonNoPrevInteractions',
          weight: 8,
        ),
      );
    }
    if (signals.spenderRepeatedAcrossWallet) {
      score += 6;
      reasons.add(
        const RiskReason(
          code: 'repeated_spender',
          messageKey: 'riskReasonRepeatedSpender',
          weight: 6,
        ),
      );
    }

    // New: Community Trust (Popularity)
    if (signals.isPopular) {
      int bonus = -15;
      if (signals.popularityScore > 50000) bonus = -25;

      score += bonus;
      reasons.add(
        RiskReason(
          code: 'community_trust',
          messageKey: 'riskReasonTrust', // Reusing trust key or specific one
          weight: bonus,
        ),
      );
    }

    // --- Behavioral Threat Scenarios ---

    // 1. Centralized Freeze Risk
    if (signals.hasOwnerPrivileges && signals.canPause) {
      score += 15;
      reasons.add(
        const RiskReason(
          code: 'scenario_centralized_freeze',
          messageKey: 'riskScenarioCentralizedFreeze',
          weight: 15,
        ),
      );
    }

    // 2. Blacklist Control Risk
    if (signals.hasOwnerPrivileges && signals.canBlacklist) {
      score += 15;
      reasons.add(
        const RiskReason(
          code: 'scenario_blacklist_control',
          messageKey: 'riskScenarioBlacklistControl',
          weight: 15,
        ),
      );
    }

    // 3. Supply Manipulation Risk
    if (signals.hasOwnerPrivileges && signals.canMint) {
      score += 20;
      reasons.add(
        const RiskReason(
          code: 'scenario_supply_manipulation',
          messageKey: 'riskScenarioSupplyManipulation',
          weight: 20,
        ),
      );
    }

    // 4. Stealth Logic Swap Risk
    if (signals.isProxyContract &&
        signals.isUpgradeable &&
        signals.hasOwnerPrivileges) {
      score += 15;
      reasons.add(
        const RiskReason(
          code: 'scenario_stealth_logic_swap',
          messageKey: 'riskScenarioStealthLogicSwap',
          weight: 15,
        ),
      );
    }

    // 5. Isolated Capability (if not already covered by a scenario)
    final hasNoScenario = score < 20; // Heuristic
    if (hasNoScenario) {
      if (signals.canPause) {
        score += 5;
        reasons.add(const RiskReason(
            code: 'cap_pause', messageKey: 'riskCapPause', weight: 5));
      }
      if (signals.canMint) {
        score += 10;
        reasons.add(const RiskReason(
            code: 'cap_mint', messageKey: 'riskCapMint', weight: 10));
      }
      if (signals.canBlacklist) {
        score += 8;
        reasons.add(const RiskReason(
            code: 'cap_blacklist', messageKey: 'riskCapBlacklist', weight: 8));
      }
    }

    // Negative weights (bonuses)
    if (signals.isTrustedSpender) {
      score -= 30;
      reasons.add(
        const RiskReason(
          code: 'trusted_spender',
          messageKey: 'riskReasonTrustedSpender',
          weight: -30,
        ),
      );
    }
    if (signals.isDex || signals.isKnownDex) {
      score -= 25;
      reasons.add(
        const RiskReason(
          code: 'known_dex',
          messageKey: 'riskReasonKnownDex',
          weight: -25,
        ),
      );
    }
    if (signals.isBridge || signals.isKnownBridge) {
      score -= 20;
      reasons.add(
        const RiskReason(
          code: 'known_bridge',
          messageKey: 'riskReasonKnownBridge',
          weight: -20,
        ),
      );
    }

    final finalScore = score.clamp(0, 100);
    final label = _getLabelForScore(finalScore);

    // shouldRevoke logic
    bool shouldRevoke = false;
    if (signals.isKnownDrainer ||
        signals.isFlaggedSpender ||
        signals.isSuspiciousSpender) {
      shouldRevoke = true;
    } else if (signals.isUnlimited && signals.isUnknownSpender) {
      shouldRevoke = true;
    } else if (finalScore >= 55) {
      shouldRevoke = true;
    }

    // Quadruple Threat: unlimited + unknown + new(<7d) + valuable token = CRITICAL
    var finalLabel = label;
    if (signals.isUnlimited &&
        signals.isUnknownSpender &&
        signals.contractAgeDays < 7 &&
        signals.touchesValuableToken) {
      finalLabel = RiskLabel.critical;
      shouldRevoke = true;
    }

    // Sort reasons by weight descending
    reasons.sort((a, b) => b.weight.abs().compareTo(a.weight.abs()));

    return ApprovalRiskAssessment(
      score: finalScore,
      label: finalLabel,
      shouldRevoke: shouldRevoke,
      reasons: reasons,
    );
  }

  /// Aggregates wallet-level risk
  static WalletRiskAssessment computeWalletAssessment(
    List<ApprovalData> approvals,
  ) {
    if (approvals.isEmpty) {
      return const WalletRiskAssessment(
        score: 0,
        label: RiskLabel.safe,
        totalApprovals: 0,
        unlimitedCount: 0,
        dangerousCount: 0,
        suspiciousCount: 0,
        reasons: [],
      );
    }

    int totalScore = 0;
    int unlimited = 0;
    int danger = 0;
    int caution = 0;

    for (var a in approvals) {
      if (a.assessment.label == RiskLabel.critical) {
        totalScore += 30;
        danger++;
      } else if (a.assessment.label == RiskLabel.danger) {
        totalScore += 20;
        danger++;
      } else if (a.assessment.label == RiskLabel.caution) {
        totalScore += 10;
        caution++;
      }
      if (a.allowance == maxUint256) unlimited++;
    }

    // Heavy penalty for volume
    if (approvals.length > 20) totalScore += 15;

    final finalScore = totalScore.clamp(0, 100);

    return WalletRiskAssessment(
      score: finalScore,
      label: _getLabelForScore(finalScore),
      totalApprovals: approvals.length,
      unlimitedCount: unlimited,
      dangerousCount: danger,
      suspiciousCount: caution,
      reasons: [], // Could aggregate overall reasons if needed
    );
  }

  /// Legacy score calculation (Backward Compatible)
  static int calculateOverallScore(List<ApprovalData> approvals) {
    if (approvals.isEmpty) return 100;
    final assessment = computeWalletAssessment(approvals);
    return 100 - assessment.score;
  }

  static RiskLabel _getLabelForScore(int score) {
    if (score < 25) return RiskLabel.safe;
    if (score < 55) return RiskLabel.caution;
    if (score < 80) return RiskLabel.danger;
    return RiskLabel.critical;
  }

  static RiskLevel _mapLabelToLegacyLevel(RiskLabel label) {
    switch (label) {
      case RiskLabel.safe:
        return RiskLevel.safe;
      case RiskLabel.caution:
        return RiskLevel.warning;
      case RiskLabel.danger:
      case RiskLabel.critical:
        return RiskLevel.danger;
    }
  }
}
