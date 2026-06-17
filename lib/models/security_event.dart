enum SecurityEventType {
  highRiskApproval,
  unlimitedApproval,
  threatDbHit,
  suspiciousContract,
  panicTriggered,
  revokeCompleted,
  subscriptionExpiring,
  monitoringCheckFailed,
  walletConnected,
  manualScanCompleted,
  systemInitialized;

  String toJson() => name;

  static SecurityEventType fromJson(String json) {
    return SecurityEventType.values.firstWhere(
      (e) => e.name == json,
      orElse: () => SecurityEventType.monitoringCheckFailed,
    );
  }
}

class SecurityEvent {
  final SecurityEventType type;
  final String severity; // e.g., 'critical', 'high', 'medium', 'low', 'info'
  final DateTime timestamp;
  final String? walletAddress;
  final String title;
  final String message;
  final Map<String, dynamic> metadata;

  SecurityEvent({
    required this.type,
    required this.severity,
    required this.timestamp,
    this.walletAddress,
    required this.title,
    required this.message,
    this.metadata = const {},
  });

  Map<String, dynamic> toJson() => {
        'type': type.toJson(),
        'severity': severity,
        'timestamp': timestamp.toIso8601String(),
        'walletAddress': walletAddress,
        'title': title,
        'message': message,
        'metadata': metadata,
      };

  factory SecurityEvent.fromJson(Map<String, dynamic> json) => SecurityEvent(
        type:
            SecurityEventType.fromJson(json['type'] ?? 'monitoringCheckFailed'),
        severity: json['severity'] ?? 'info',
        timestamp: json['timestamp'] != null
            ? DateTime.parse(json['timestamp'])
            : DateTime.now(),
        walletAddress: json['walletAddress'],
        title: json['title'] ?? '',
        message: json['message'] ?? '',
        metadata: json['metadata'] ?? {},
      );
}
