import 'package:ibiti_guardian/services/security/security_event_service.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/services/alerts/notification_service.dart';
import 'package:ibiti_guardian/services/audio_manager.dart';
import 'package:ibiti_guardian/models/security_event.dart';

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
    final settings = SettingsService.instance.settings;
    final notifications = settings.notificationSettings;

    // 1. Determine if notification should be shown
    bool shouldNotify = false;
    bool isCritical = false;

    // Severity check (Priority to severity field)
    if (event.severity == 'critical') isCritical = true;

    switch (event.type) {
      case SecurityEventType.highRiskApproval:
        shouldNotify = notifications.highRiskApprovalAlerts;
        break;
      case SecurityEventType.unlimitedApproval:
        shouldNotify = notifications.unlimitedApprovalAlerts;
        break;
      case SecurityEventType.panicTriggered:
        shouldNotify = notifications.panicAlerts;
        isCritical = true;
        break;
      case SecurityEventType.revokeCompleted:
        shouldNotify = notifications.revokeResultAlerts;
        break;
      case SecurityEventType.threatDbHit:
        shouldNotify = notifications.threatDatabaseAlerts;
        isCritical = true;
        break;
      case SecurityEventType.monitoringCheckFailed:
        shouldNotify = notifications.monitoringHealthAlerts;
        break;
      case SecurityEventType.subscriptionExpiring:
        shouldNotify = notifications.subscriptionReminders;
        break;
      default:
        break;
    }

    if (shouldNotify) {
      final payload = {
        'type': _mapEventTypeToPayloadType(event.type),
        'walletAddress': event.walletAddress,
        'metadata': event.metadata,
      };

      if (isCritical) {
        NotificationService.instance.showCriticalAlert(
          event.title,
          event.message,
          payload: payload,
        );
        AudioManager.instance.playCritical();
      } else {
        NotificationService.instance.showWarningAlert(
          event.title,
          event.message,
          payload: payload,
        );
        AudioManager.instance.playAlert();
      }
    }
  }

  String _mapEventTypeToPayloadType(SecurityEventType type) {
    switch (type) {
      case SecurityEventType.highRiskApproval:
      case SecurityEventType.unlimitedApproval:
      case SecurityEventType.threatDbHit:
        return 'security_alert';
      case SecurityEventType.panicTriggered:
      case SecurityEventType.revokeCompleted:
        return 'revoke_event';
      case SecurityEventType.subscriptionExpiring:
        return 'subscription_expiry';
      default:
        return 'general';
    }
  }

  void dispose() {
    SecurityEventService.instance.removeListener(_onServiceUpdate);
  }
}
