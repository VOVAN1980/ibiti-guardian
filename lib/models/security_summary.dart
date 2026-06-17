import 'package:ibiti_guardian/models/security_event.dart';

enum VerificationStatus { safe, caution, warning, dangerous }

class SecuritySummary {
  final String statusLabel;
  final VerificationStatus status;
  final int riskyApprovalsCount;
  final int recentEventsCount;
  final List<String> warnings;
  final DateTime? lastScanAt;
  final int activeApprovalsCount;
  final List<SecurityEvent> recentEvents;

  SecuritySummary({
    required this.statusLabel,
    required this.status,
    required this.riskyApprovalsCount,
    required this.recentEventsCount,
    required this.warnings,
    this.lastScanAt,
    required this.activeApprovalsCount,
    required this.recentEvents,
  });

  factory SecuritySummary.empty() {
    return SecuritySummary(
      statusLabel: 'securityStatusNotScanned',
      status: VerificationStatus.safe,
      riskyApprovalsCount: 0,
      recentEventsCount: 0,
      warnings: [],
      activeApprovalsCount: 0,
      recentEvents: [],
    );
  }
}
