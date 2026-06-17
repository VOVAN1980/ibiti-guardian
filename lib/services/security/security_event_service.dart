import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/models/security_event.dart';
import 'package:ibiti_guardian/services/database/database_service.dart';
import 'package:ibiti_guardian/services/localization_service.dart';

class SecurityEventService extends ChangeNotifier {
  static final SecurityEventService instance = SecurityEventService._internal();
  SecurityEventService._internal();

  static const _log = GuardianLogger('SecurityEvent');

  final List<SecurityEvent> _cachedEvents = [];
  SecurityEvent? _lastEvent;

  List<SecurityEvent> get cachedEvents => List.unmodifiable(_cachedEvents);
  SecurityEvent? get lastEvent => _lastEvent;
  bool _initialized = false;

  Future<void> init() async {
    // Load historical events from DB
    final history = await DatabaseService.instance.getEvents();
    _cachedEvents
        .clear(); // Clear memory cache to avoid duplicates if re-initialized
    _cachedEvents.addAll(history.reversed);

    if (!_initialized) {
      logSystemInit();
      _initialized = true;
    }
  }

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

    _cachedEvents.add(event);
    _lastEvent = event;
    notifyListeners();

    // Persist to DB
    DatabaseService.instance.insertEvent(event).catchError((e) {
      _log.e('Failed to persist security event', e);
    });

    // Keep cache reasonable
    if (_cachedEvents.length > 100) {
      _cachedEvents.removeAt(0);
    }
  }

  Future<void> clearAll() async {
    _cachedEvents.clear();
    _lastEvent = null;
    await DatabaseService.instance.clearEvents();
    notifyListeners();
  }

  void logSystemInit() {
    final t = LocalizationService.instance;
    emit(SecurityEvent(
      type: SecurityEventType.systemInitialized,
      severity: 'info',
      timestamp: DateTime.now(),
      title: t.t('eventTitleSystemInit'),
      message: t.t('eventMsgSystemInit'),
    ));
  }

  void logManualScan(String address, bool isClean, int riskyCount) {
    final t = LocalizationService.instance;
    emit(SecurityEvent(
      type: SecurityEventType.manualScanCompleted,
      severity: isClean ? 'info' : 'medium',
      timestamp: DateTime.now(),
      walletAddress: address,
      title: isClean ? t.t('eventTitleScanClear') : t.t('eventTitleScanRisks'),
      message: isClean
          ? t.t('eventMsgScanClear')
          : t.t('eventMsgScanRisks', {'count': riskyCount.toString()}),
      metadata: {
        'isClean': isClean,
        'riskyCount': riskyCount,
      },
    ));
  }
}
