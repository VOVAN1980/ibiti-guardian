import 'package:flutter/material.dart';
import 'package:ibiti_guardian/services/security/approval_scan_service.dart';
import 'package:ibiti_guardian/services/risk_engine.dart';
import 'package:ibiti_guardian/services/revoke_service.dart';
import 'package:ibiti_guardian/services/security/security_event_service.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/models/approval.dart';
import 'package:ibiti_guardian/models/risk_assessment.dart';
import 'package:ibiti_guardian/models/security_summary.dart';

class SecurityAdapter extends ChangeNotifier {
  static final SecurityAdapter instance = SecurityAdapter._internal();
  factory SecurityAdapter() => instance;
  SecurityAdapter._internal();

  Future<List<ApprovalData>> startScan(String address, int chainId) async {
    if (address.isEmpty) return [];
    final approvals = await ApprovalScanService.scan(address, chainId: chainId);
    notifyListeners();
    return approvals;
  }

  Future<SecuritySummary> getSummary(String address, int chainId) async {
    if (ApprovalScanService.lastScanTime == null) {
      return SecuritySummary.empty();
    }

    final approvals = ApprovalScanService.lastScannedApprovals;
    final walletAssessment = RiskEngine.computeWalletAssessment(approvals);
    final recentEvents = SecurityEventService.instance.cachedEvents
        .where((e) => e.walletAddress == address)
        .toList();

    return SecuritySummary(
      statusLabel: _getStatusLabel(walletAssessment.label),
      status: _mapStatus(walletAssessment.label),
      riskyApprovalsCount:
          walletAssessment.dangerousCount + walletAssessment.suspiciousCount,
      recentEventsCount: recentEvents.length,
      warnings: approvals
          .where((a) => a.assessment.shouldRevoke)
          .map((a) => LocalizationService.instance
              .t('warningRiskyApproval', {'symbol': a.tokenSymbol}))
          .toList(),
      lastScanAt: ApprovalScanService.lastScanTime,
      activeApprovalsCount: approvals.length,
      recentEvents: recentEvents.take(10).toList(),
    );
  }

  Future<String> revoke(ApprovalData approval) async {
    final txHash = await RevokeService.revokeApproval(a: approval);
    notifyListeners();
    return txHash;
  }

  VerificationStatus _mapStatus(RiskLabel label) {
    switch (label) {
      case RiskLabel.safe:
        return VerificationStatus.safe;
      case RiskLabel.caution:
        return VerificationStatus.caution;
      case RiskLabel.danger:
        return VerificationStatus.warning;
      case RiskLabel.critical:
        return VerificationStatus.dangerous;
    }
  }

  String _getStatusLabel(RiskLabel label) {
    switch (label) {
      case RiskLabel.safe:
        return 'securityStatusSecured';
      case RiskLabel.caution:
        return 'securityStatusCaution';
      case RiskLabel.danger:
        return 'securityStatusRiskDetected';
      case RiskLabel.critical:
        return 'securityStatusCriticalRisk';
    }
  }
}
