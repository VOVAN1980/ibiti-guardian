import 'package:ibiti_guardian/models/subscription_plan.dart';

class ProStatus {
  final bool isPro;
  final SubscriptionPlan plan;
  final DateTime? expiryDate;
  final bool autoRenewing;
  final int maxWallets;
  final bool monitoringEnabledByPlan;
  final bool bulkRevokeEnabled;
  final bool premiumAlertsEnabled;
  final bool epkInDevelopmentVisible;
  final bool erkInDevelopmentVisible;
  final bool fvInDevelopmentVisible;
  final bool aiFirewallInDevelopmentVisible;

  final String? purchaseId;
  final DateTime? lastVerified;

  ProStatus({
    this.isPro = false,
    this.plan = SubscriptionPlan.free,
    this.expiryDate,
    this.autoRenewing = false,
    this.maxWallets = 1,
    this.monitoringEnabledByPlan = false,
    this.bulkRevokeEnabled = false,
    this.premiumAlertsEnabled = false,
    this.epkInDevelopmentVisible = false,
    this.erkInDevelopmentVisible = false,
    this.fvInDevelopmentVisible = false,
    this.aiFirewallInDevelopmentVisible = false,
    this.purchaseId,
    this.lastVerified,
  });

  bool get isExpired {
    if (!isPro) return true;
    if (expiryDate == null) return false;
    return expiryDate!.isBefore(DateTime.now());
  }

  factory ProStatus.free() => ProStatus();

  Map<String, dynamic> toJson() => {
        'isPro': isPro,
        'plan': plan.toJson(),
        'expiryDate': expiryDate?.toIso8601String(),
        'autoRenewing': autoRenewing,
        'maxWallets': maxWallets,
        'monitoringEnabledByPlan': monitoringEnabledByPlan,
        'bulkRevokeEnabled': bulkRevokeEnabled,
        'premiumAlertsEnabled': premiumAlertsEnabled,
        'epkInDevelopmentVisible': epkInDevelopmentVisible,
        'erkInDevelopmentVisible': erkInDevelopmentVisible,
        'fvInDevelopmentVisible': fvInDevelopmentVisible,
        'aiFirewallInDevelopmentVisible': aiFirewallInDevelopmentVisible,
        'purchaseId': purchaseId,
        'lastVerified': lastVerified?.toIso8601String(),
      };

  factory ProStatus.fromJson(Map<String, dynamic> json) => ProStatus(
        isPro: json['isPro'] ?? false,
        plan: SubscriptionPlan.fromJson(json['plan'] ?? 'free'),
        expiryDate: json['expiryDate'] != null
            ? DateTime.tryParse(json['expiryDate'])
            : null,
        autoRenewing: json['autoRenewing'] ?? false,
        maxWallets: json['maxWallets'] ?? 1,
        monitoringEnabledByPlan: json['monitoringEnabledByPlan'] ?? false,
        bulkRevokeEnabled: json['bulkRevokeEnabled'] ?? false,
        premiumAlertsEnabled: json['premiumAlertsEnabled'] ?? false,
        epkInDevelopmentVisible: json['epkInDevelopmentVisible'] ?? false,
        erkInDevelopmentVisible: json['erkInDevelopmentVisible'] ?? false,
        fvInDevelopmentVisible: json['fvInDevelopmentVisible'] ?? false,
        aiFirewallInDevelopmentVisible:
            json['aiFirewallInDevelopmentVisible'] ?? false,
        purchaseId: json['purchaseId'],
        lastVerified: json['lastVerified'] != null
            ? DateTime.tryParse(json['lastVerified'])
            : null,
      );
}
