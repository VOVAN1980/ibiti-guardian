import 'package:ibiti_guardian/services/ibiti/ibiti_database.dart';
import 'package:ibiti_guardian/services/market/market_memory_entry.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

// ─── Market Memory Service ──────────────────────────────────────────────────────
//
// Clean memory for market user commands and their outcomes.
//
// Records: buy/sell/tp/sl/alert/favorite/rocket commands
// Sources: voice, chat, UI
// Results: opened_form, blocked, failed, confirmed, notified
//
// NO old JARVIS brain/gate/debate.
// NO strategy_knowledge, counterfactual, eternal_memory.
// NO _archive imports.
// ─────────────────────────────────────────────────────────────────────────────────

const _log = GuardianLogger('MarketMemory');

class MarketMemoryService {
  MarketMemoryService._();
  static final MarketMemoryService instance = MarketMemoryService._();

  static const _table = 'market_memory';
  bool _ready = false;

  // ── Init ─────────────────────────────────────────────────────────────────

  /// Ensure the table exists. Call once after IbitiDatabase.init().
  Future<void> ensureTable() async {
    if (_ready) return;
    final db = IbitiDatabase.instance;
    if (!db.isOpen) return;
    try {
      await db.db.execute('''
        CREATE TABLE IF NOT EXISTS $_table (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          timestamp TEXT NOT NULL,
          action TEXT NOT NULL,
          symbol TEXT NOT NULL,
          source TEXT NOT NULL DEFAULT 'voice',
          ai_mode TEXT NOT NULL DEFAULT 'manual',
          result TEXT NOT NULL DEFAULT 'opened_form',
          amount REAL,
          price_then REAL,
          reason TEXT,
          raw_input TEXT NOT NULL DEFAULT ''
        )
      ''');
      _ready = true;
      _log.i('Table $_table ready');
    } catch (e) {
      _log.e('Failed to create $_table', e);
    }
  }

  // ── Write ────────────────────────────────────────────────────────────────

  /// Record a market command. Fire-and-forget — never blocks the UI.
  Future<void> record({
    required String action,
    required String symbol,
    required String source,
    required String aiMode,
    required String result,
    double? amount,
    double? priceThen,
    String? reason,
    String rawInput = '',
  }) async {
    if (!_ready) await ensureTable();
    if (!_ready) return; // DB not available

    final entry = MarketMemoryEntry(
      timestamp: DateTime.now(),
      action: action,
      symbol: symbol.toUpperCase(),
      source: source,
      aiMode: aiMode,
      result: result,
      amount: amount,
      priceThen: priceThen,
      reason: reason,
      rawInput: rawInput,
    );

    try {
      await IbitiDatabase.instance.db.insert(_table, entry.toMap());
      _log.d('Recorded: ${entry.summary}');
    } catch (e) {
      _log.e('Failed to record market memory', e);
    }
  }

  // ── Read ─────────────────────────────────────────────────────────────────

  /// Get recent entries (newest first). Default limit 20.
  Future<List<MarketMemoryEntry>> recent({int limit = 20}) async {
    if (!_ready) await ensureTable();
    if (!_ready) return const [];

    try {
      final rows = await IbitiDatabase.instance.db.query(
        _table,
        orderBy: 'id DESC',
        limit: limit,
      );
      return rows.map(MarketMemoryEntry.fromMap).toList();
    } catch (e) {
      _log.e('Failed to read market memory', e);
      return const [];
    }
  }

  /// Get entries for a specific symbol (newest first).
  Future<List<MarketMemoryEntry>> forSymbol(String symbol,
      {int limit = 10}) async {
    if (!_ready) await ensureTable();
    if (!_ready) return const [];

    try {
      final rows = await IbitiDatabase.instance.db.query(
        _table,
        where: 'symbol = ?',
        whereArgs: [symbol.toUpperCase()],
        orderBy: 'id DESC',
        limit: limit,
      );
      return rows.map(MarketMemoryEntry.fromMap).toList();
    } catch (e) {
      _log.e('Failed to read market memory for $symbol', e);
      return const [];
    }
  }

  /// Get entries by action type (newest first).
  Future<List<MarketMemoryEntry>> byAction(String action,
      {int limit = 10}) async {
    if (!_ready) await ensureTable();
    if (!_ready) return const [];

    try {
      final rows = await IbitiDatabase.instance.db.query(
        _table,
        where: 'action = ?',
        whereArgs: [action],
        orderBy: 'id DESC',
        limit: limit,
      );
      return rows.map(MarketMemoryEntry.fromMap).toList();
    } catch (e) {
      _log.e('Failed to read market memory by action $action', e);
      return const [];
    }
  }

  /// Total count for stats.
  Future<int> count() async {
    if (!_ready) await ensureTable();
    if (!_ready) return 0;

    try {
      final result = await IbitiDatabase.instance.db
          .rawQuery('SELECT COUNT(*) as c FROM $_table');
      return (result.first['c'] as int?) ?? 0;
    } catch (e) {
      return 0;
    }
  }

  /// Build a compact summary for voice: "3 покупки, 2 алерта, 1 TP за сегодня"
  Future<String> todaySummary({String lang = 'ru'}) async {
    if (!_ready) await ensureTable();
    if (!_ready) {
      return lang == 'ru' ? 'Память недоступна.' : 'Memory unavailable.';
    }

    try {
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final rows = await IbitiDatabase.instance.db.query(
        _table,
        where: "timestamp >= ?",
        whereArgs: ['${today}T00:00:00'],
        orderBy: 'id DESC',
      );

      if (rows.isEmpty) {
        return lang == 'ru'
            ? 'Сегодня рыночных команд не было.'
            : 'No market commands today.';
      }

      final entries = rows.map(MarketMemoryEntry.fromMap).toList();
      final actionCounts = <String, int>{};
      for (final e in entries) {
        actionCounts[e.action] = (actionCounts[e.action] ?? 0) + 1;
      }

      final parts = <String>[];
      for (final MapEntry(key: action, value: count) in actionCounts.entries) {
        final label = lang == 'ru'
            ? switch (action) {
                'buy' => 'покуп.',
                'sell' => 'продаж.',
                'tp' => 'TP',
                'sl' => 'SL',
                'alert' => 'алерт.',
                'favorite' => 'избр.',
                _ => action,
              }
            : action;
        parts.add('$count $label');
      }

      final prefix =
          lang == 'ru' ? 'Сегодня: ' : 'Today: ';
      return '$prefix${parts.join(', ')}.';
    } catch (e) {
      _log.e('Failed to build today summary', e);
      return lang == 'ru' ? 'Ошибка памяти.' : 'Memory error.';
    }
  }

  Future<void> clearForTest() async {
    final db = IbitiDatabase.instance;
    if (!db.isOpen) return;
    if (!_ready) await ensureTable();
    if (!_ready) return;
    try {
      await db.db.delete(_table);
    } catch (_) {}
  }
}
