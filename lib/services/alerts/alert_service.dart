import 'package:ibiti_guardian/services/security/security_event_service.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/services/alerts/notification_service.dart';
import 'package:ibiti_guardian/models/security_event.dart';

/// Turns security events into notifications.
///
/// Guardian sends one kind: the result of a permission revoke (Safe Scan and
/// Panic). DrainShield's threat, monitoring and subscription alerts are gone.
class AlertService {
  static final AlertService instance = AlertService._();
  AlertService._();

  SecurityEvent? _lastProcessedEvent;

  Future<void> init() async {
    SecurityEventService.instance.addListener(_onServiceUpdate);
  }

  void _onServiceUpdate() {
    final event = SecurityEventService.instance.lastEvent;
    if (event != null && event != _lastProcessedEvent) {
      _lastProcessedEvent = event;
      _onSecurityEvent(event);
    }
  }

  void _onSecurityEvent(SecurityEvent event) {
    if (event.type != SecurityEventType.revokeCompleted) return;
    final notifications = SettingsService.instance.settings.notificationSettings;
    if (!notifications.revokeResultAlerts) return;

    NotificationService.instance.showWarningAlert(
      event.title,
      event.message,
      payload: {
        'type': 'revoke_event',
        'walletAddress': event.walletAddress,
        'metadata': event.metadata,
      },
    );
  }

  void dispose() {
    SecurityEventService.instance.removeListener(_onServiceUpdate);
  }
}
