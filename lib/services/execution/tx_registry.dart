import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/models/tx_status.dart';

/// Global transaction state registry — single source of truth
/// for ALL in-flight and recently completed transactions.
///
/// Consumers (wallet header, system status, history) listen via
/// [ValueListenable] — zero extra boilerplate needed.
///
/// [TxStatusPoller] pushes every status update here automatically.
class TxRegistry extends ChangeNotifier {
  TxRegistry._();
  static final instance = TxRegistry._();

  final List<TxStatusEvent> _history = [];

  /// Full ordered list (oldest first).
  List<TxStatusEvent> get history => List.unmodifiable(_history);

  /// The last event pushed, regardless of tx hash.
  TxStatusEvent? get latest => _history.isEmpty ? null : _history.last;

  /// True when at least one non-terminal tx is in flight.
  bool get hasPending => _history.any((e) => !e.isTerminal);

  /// The single active in-flight tx, if any (most recent non-terminal).
  TxStatusEvent? get activeTx => _history
      .where((e) => !e.isTerminal)
      .fold<TxStatusEvent?>(null, (_, e) => e);

  /// Push a new event.
  ///
  /// - If [txHash] is already in history → update in-place.
  /// - Otherwise → append.
  void push(TxStatusEvent event) {
    final index = _history.indexWhere((e) => e.txHash == event.txHash);
    if (index >= 0) {
      _history[index] = event;
    } else {
      _history.add(event);
    }
    notifyListeners();
  }

  /// Clear all terminal transactions older than [maxAge].
  void pruneOld({Duration maxAge = const Duration(hours: 24)}) {
    final cutoff = DateTime.now().subtract(maxAge);
    _history.removeWhere((e) => e.isTerminal && e.timestamp.isBefore(cutoff));
    notifyListeners();
  }

  /// Clear everything — useful for testing/logout.
  void clear() {
    _history.clear();
    notifyListeners();
  }
}
