/// Which notifications the app shows.
///
/// Only the revoke result has a switch: it is the one security event Guardian
/// sends. Settings saved by older builds (DrainShield's threat, monitoring and
/// subscription alerts) are ignored when loaded.
class NotificationSettings {
  final bool revokeResultAlerts;

  NotificationSettings({
    this.revokeResultAlerts = true,
  });

  Map<String, dynamic> toJson() => {
        'revokeResultAlerts': revokeResultAlerts,
      };

  factory NotificationSettings.fromJson(Map<String, dynamic> json) =>
      NotificationSettings(
        revokeResultAlerts: json['revokeResultAlerts'] ?? true,
      );

  NotificationSettings copyWith({
    bool? revokeResultAlerts,
  }) =>
      NotificationSettings(
        revokeResultAlerts: revokeResultAlerts ?? this.revokeResultAlerts,
      );
}
