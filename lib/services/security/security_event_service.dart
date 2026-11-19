import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/models/security_event.dart';

/// In-memory feed of security events.
///
/// Keeps only the latest event so listeners (AlertService) can react to it,
/// for example the revoke-result notification. Nothing is stored on disk.
class SecurityEventService extends ChangeNotifier {
  static final SecurityEventService instance = SecurityEventService._internal();
  SecurityEventService._internal();

  static const _log = GuardianLogger('SecurityEvent');

  SecurityEvent? _lastEvent;

  SecurityEvent? get lastEvent => _lastEvent;

  void emit(SecurityEvent event) {
    // Basic deduplication to prevent double-clicks or redundant background checks
    if (_lastEvent != null &&
        _lastEvent!.type == event.type &&
        _lastEvent!.title == event.title &&
        _lastEvent!.message == event.message &&
        event.timestamp.difference(_lastEvent!.timestamp).inSeconds.abs() < 2) {
      _log.d('Skipping duplicate event: ${event.type}');
      return;
    }

    _lastEvent = event;
    notifyListeners();
  }
}
