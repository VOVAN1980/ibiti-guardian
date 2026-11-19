enum VerificationStatus { safe, caution, warning, dangerous }

class SecuritySummary {
  final String statusLabel;
  final VerificationStatus status;
  final int riskyApprovalsCount;
  final List<String> warnings;
  final DateTime? lastScanAt;
  final int activeApprovalsCount;

  SecuritySummary({
    required this.statusLabel,
    required this.status,
    required this.riskyApprovalsCount,
    required this.warnings,
    this.lastScanAt,
    required this.activeApprovalsCount,
  });

  factory SecuritySummary.empty() {
    return SecuritySummary(
      statusLabel: 'securityStatusNotScanned',
      status: VerificationStatus.safe,
      riskyApprovalsCount: 0,
      warnings: [],
      activeApprovalsCount: 0,
    );
  }
}
