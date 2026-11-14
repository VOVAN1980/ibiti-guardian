import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/models/tx_status.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Global transaction state registry — single source of truth
/// for ALL in-flight and recently completed transactions.
///
/// Consumers (wallet header, system status, history) listen via
/// [ValueListenable] — zero extra boilerplate needed.
///
/// [TxStatusPoller] pushes every status update here automatically.
///
/// Finished transactions are kept on the device (last [_keepCount], at most
/// [_keepFor] old), so the wallet's "Recent" list and system status survive
/// an app restart instead of disappearing with the process.
class TxRegistry extends ChangeNotifier {
  TxRegistry._();
  static final instance = TxRegistry._();

  static const _log = GuardianLogger('TxRegistry');
  static const _prefsKey = 'tx_registry_recent_v1';
  static const _keepCount = 20;
  static const _keepFor = Duration(days: 30);

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

  /// Restores finished transactions saved by an earlier run. Events pushed
  /// in this run before the load finishes stay and win over saved copies.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final cutoff = DateTime.now().subtract(_keepFor);
      final saved = (jsonDecode(raw) as List)
          .map((e) => _fromJson(Map<String, dynamic>.from(e as Map)))
          .whereType<TxStatusEvent>()
          .where((e) => e.isTerminal && e.timestamp.isAfter(cutoff))
          .where((e) => !_history.any((h) => h.txHash == e.txHash))
          .toList();
      if (saved.isEmpty) return;
      _history.insertAll(0, saved);
      notifyListeners();
    } catch (e) {
      _log.w('could not restore recent transactions', e);
    }
  }

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
    if (event.isTerminal) _save();
  }

  /// Clear all terminal transactions older than [maxAge].
  void pruneOld({Duration maxAge = const Duration(hours: 24)}) {
    final cutoff = DateTime.now().subtract(maxAge);
    _history.removeWhere((e) => e.isTerminal && e.timestamp.isBefore(cutoff));
    notifyListeners();
    _save();
  }

  /// Clear everything — useful for testing/logout.
  void clear() {
    _history.clear();
    notifyListeners();
    _save();
  }

  Future<void> _saving = Future<void>.value();

  /// Writes run one after another and each takes its snapshot when it runs,
  /// so two quick updates can never land in the wrong order.
  Future<void> _save() => _saving = _saving.then((_) => _write());

  Future<void> _write() async {
    try {
      final finished = _history.where((e) => e.isTerminal).toList();
      final keep = finished.length > _keepCount
          ? finished.sublist(finished.length - _keepCount)
          : finished;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _prefsKey, jsonEncode(keep.map(_toJson).toList()));
    } catch (e) {
      _log.w('could not save recent transactions', e);
    }
  }

  static Map<String, dynamic> _toJson(TxStatusEvent e) => {
        'status': e.status.name,
        'txHash': e.txHash,
        if (e.walletAddress != null) 'walletAddress': e.walletAddress,
        if (e.blockNumber != null) 'blockNumber': e.blockNumber,
        if (e.errorReason != null) 'errorReason': e.errorReason,
        'timestamp': e.timestamp.toIso8601String(),
        if (e.operationLabel != null) 'operationLabel': e.operationLabel,
        if (e.assetLabel != null) 'assetLabel': e.assetLabel,
      };

  static TxStatusEvent? _fromJson(Map<String, dynamic> m) {
    final status = TxStatus.values
        .where((s) => s.name == m['status'])
        .cast<TxStatus?>()
        .firstWhere((_) => true, orElse: () => null);
    final hash = m['txHash']?.toString();
    final time = DateTime.tryParse(m['timestamp']?.toString() ?? '');
    if (status == null || hash == null || hash.isEmpty || time == null) {
      return null;
    }
    return TxStatusEvent(
      status: status,
      txHash: hash,
      walletAddress: m['walletAddress']?.toString(),
      blockNumber: (m['blockNumber'] as num?)?.toInt(),
      errorReason: m['errorReason']?.toString(),
      timestamp: time,
      operationLabel: m['operationLabel']?.toString(),
      assetLabel: m['assetLabel']?.toString(),
    );
  }
}
