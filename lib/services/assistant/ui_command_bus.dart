import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/models/assistant_directive.dart';

/// The central messaging bus for delivering remote UI control commands securely
/// from the Assistant Orchestrator to active screens and components.
class UICommandBus {
  UICommandBus._();
  static final instance = UICommandBus._();

  /// Creates a fresh instance for unit testing (avoids singleton state bleed).
  static UICommandBus testInstance() => UICommandBus._();

  final _controller = StreamController<UICommand>.broadcast();

  // ── Timestamped caches ────────────────────────────────────────────────────
  // Each entry carries a timestamp so stale data can be purged automatically.
  // Without TTL, unconsumed voice/AI commands accumulate forever.
  static const _ttl = Duration(seconds: 60);

  final Map<String, String> _latestFieldValues = {};
  final Map<String, DateTime> _fieldTimestamps = {};

  final Map<String, Map<String, dynamic>> _latestPayloads = {};
  final Map<String, DateTime> _payloadTimestamps = {};

  final Map<String, DateTime> _pendingActions = {};

  /// Stream of incoming commands that active screens should listen to.
  Stream<UICommand> get commands => _controller.stream;

  /// Dispatch a single command across the bus.
  void dispatch(UICommand command) {
    final now = DateTime.now();

    if (command.target != null && command.payload != null) {
      _latestPayloads[command.target!] =
          Map<String, dynamic>.from(command.payload!);
      _payloadTimestamps[command.target!] = now;
    }
    if (command.type == UICommandType.executeAction && command.target != null) {
      _pendingActions[command.target!] = now;
    }
    if (command.type == UICommandType.fillField &&
        command.target != null &&
        command.payload?['value'] != null) {
      _latestFieldValues[command.target!] =
          command.payload!['value'].toString();
      _fieldTimestamps[command.target!] = now;
    }
    _controller.add(command);

    // Purge stale entries on every dispatch — cheap O(n) scan.
    _purgeStale(now);
  }

  /// Dispatch multiple commands sequentially.
  void dispatchAll(List<UICommand> commands) {
    for (var cmd in commands) {
      dispatch(cmd);
    }
  }

  void dispose() {
    _controller.close();
  }

  String? latestFieldValue(String field) {
    _purgeStale(DateTime.now());
    return _latestFieldValues[field];
  }

  Map<String, dynamic>? latestPayload(String target) {
    _purgeStale(DateTime.now());
    return _latestPayloads[target];
  }

  bool consumePendingAction(String target) {
    _purgeStale(DateTime.now());
    return _pendingActions.remove(target) != null;
  }

  // ── TTL cleanup ─────────────────────────────────────────────────────────────

  void _purgeStale(DateTime now) {
    _pendingActions.removeWhere((_, ts) => now.difference(ts) > _ttl);

    _fieldTimestamps.removeWhere((key, ts) {
      if (now.difference(ts) > _ttl) {
        _latestFieldValues.remove(key);
        return true;
      }
      return false;
    });

    _payloadTimestamps.removeWhere((key, ts) {
      if (now.difference(ts) > _ttl) {
        _latestPayloads.remove(key);
        return true;
      }
      return false;
    });
  }

  /// Testing only: shift all cached timestamps back by [duration].
  /// Allows verifying TTL purge without waiting real time.
  @visibleForTesting
  void backdateTimestamps(Duration duration) {
    for (final key in _fieldTimestamps.keys.toList()) {
      _fieldTimestamps[key] = _fieldTimestamps[key]!.subtract(duration);
    }
    for (final key in _payloadTimestamps.keys.toList()) {
      _payloadTimestamps[key] = _payloadTimestamps[key]!.subtract(duration);
    }
    for (final key in _pendingActions.keys.toList()) {
      _pendingActions[key] = _pendingActions[key]!.subtract(duration);
    }
  }
}
