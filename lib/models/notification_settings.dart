class NotificationSettings {
  final bool criticalThreatAlerts;
  final bool highRiskApprovalAlerts;
  final bool unlimitedApprovalAlerts;
  final bool threatDatabaseAlerts;
  final bool panicAlerts;
  final bool revokeResultAlerts;
  final bool subscriptionReminders;
  final bool monitoringHealthAlerts;

  NotificationSettings({
    this.criticalThreatAlerts = true,
    this.highRiskApprovalAlerts = true,
    this.unlimitedApprovalAlerts = true,
    this.threatDatabaseAlerts = true,
    this.panicAlerts = true,
    this.revokeResultAlerts = true,
    this.subscriptionReminders = true,
    this.monitoringHealthAlerts = true,
  });

  Map<String, dynamic> toJson() => {
        'criticalThreatAlerts': criticalThreatAlerts,
        'highRiskApprovalAlerts': highRiskApprovalAlerts,
        'unlimitedApprovalAlerts': unlimitedApprovalAlerts,
        'threatDatabaseAlerts': threatDatabaseAlerts,
        'panicAlerts': panicAlerts,
        'revokeResultAlerts': revokeResultAlerts,
        'subscriptionReminders': subscriptionReminders,
        'monitoringHealthAlerts': monitoringHealthAlerts,
      };

  factory NotificationSettings.fromJson(Map<String, dynamic> json) =>
      NotificationSettings(
        criticalThreatAlerts: json['criticalThreatAlerts'] ?? true,
        highRiskApprovalAlerts: json['highRiskApprovalAlerts'] ?? true,
        unlimitedApprovalAlerts: json['unlimitedApprovalAlerts'] ?? true,
        threatDatabaseAlerts: json['threatDatabaseAlerts'] ?? true,
        panicAlerts: json['panicAlerts'] ?? true,
        revokeResultAlerts: json['revokeResultAlerts'] ?? true,
        subscriptionReminders: json['subscriptionReminders'] ?? true,
        monitoringHealthAlerts: json['monitoringHealthAlerts'] ?? true,
      );

  NotificationSettings copyWith({
    bool? criticalThreatAlerts,
    bool? highRiskApprovalAlerts,
    bool? unlimitedApprovalAlerts,
    bool? threatDatabaseAlerts,
    bool? panicAlerts,
    bool? revokeResultAlerts,
    bool? subscriptionReminders,
    bool? monitoringHealthAlerts,
  }) =>
      NotificationSettings(
        criticalThreatAlerts: criticalThreatAlerts ?? this.criticalThreatAlerts,
        highRiskApprovalAlerts:
            highRiskApprovalAlerts ?? this.highRiskApprovalAlerts,
        unlimitedApprovalAlerts:
            unlimitedApprovalAlerts ?? this.unlimitedApprovalAlerts,
        threatDatabaseAlerts: threatDatabaseAlerts ?? this.threatDatabaseAlerts,
        panicAlerts: panicAlerts ?? this.panicAlerts,
        revokeResultAlerts: revokeResultAlerts ?? this.revokeResultAlerts,
        subscriptionReminders:
            subscriptionReminders ?? this.subscriptionReminders,
        monitoringHealthAlerts:
            monitoringHealthAlerts ?? this.monitoringHealthAlerts,
      );
}
