import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ibiti_guardian/services/ibiti/models/market_event.dart';
import 'package:ibiti_guardian/services/ibiti/models/ibiti_decision.dart';
import 'package:ibiti_guardian/services/ibiti/models/ibiti_hypothesis.dart';
import 'package:ibiti_guardian/services/ibiti/models/postmortem_entry.dart';
import 'package:ibiti_guardian/services/ibiti/models/token_profile.dart';
import 'package:ibiti_guardian/services/ibiti/models/exchange_profile.dart';
import 'package:ibiti_guardian/services/ibiti/models/pattern_lesson.dart';
import 'package:ibiti_guardian/services/ibiti/models/paper_trade.dart';
import 'package:ibiti_guardian/services/ibiti/models/market_phase.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/services/market/market_memory_service.dart';

import 'package:shared_preferences/shared_preferences.dart';

const _log = GuardianLogger('IbitiDB');

/// Maximum number of automatic backups to keep.
const _maxBackups = 20;

class IbitiDatabase {
  IbitiDatabase._();
  static final IbitiDatabase instance = IbitiDatabase._();

  Database? _db;
  Database get db => _db!;
  bool get isOpen => _db != null;

  /// The absolute path of the active database file.
  String? dbPath;

  // в”Ђв”Ђ Batch queue for market_events в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
  final List<MarketEvent> _eventQueue = [];
  Timer? _flushTimer;
  static const _flushInterval = Duration(seconds: 5);

  // в”Ђв”Ђ Stable DB Path в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
  //
  // Memory is sacred. Build artifacts are disposable. Never mix them.
  //
  // On Windows dev: D:\Guardian\data\jarvis\ibiti_memory.db
  //   в†’ survives flutter clean, rebuild, anything.
  //
  // On Android/iOS: ApplicationSupportDirectory/jarvis/ibiti_memory.db
  //   в†’ stable across app updates, not wiped by cache clear.

  /// Returns the stable directory for JARVIS memory, creating it if needed.
  Future<String> _stableDbDir() async {
    // Windows dev: use project-local stable path.
    if (Platform.isWindows) {
      // Detect if we're running from a Guardian project directory.
      final guardianDataDir = Directory(r'D:\Guardian\data\jarvis');
      await guardianDataDir.create(recursive: true);
      return guardianDataDir.path;
    }
    // Mobile / other: use platform's persistent application support dir.
    // This is NOT cleared by flutter clean and survives app updates.
    final appSupport = await getApplicationSupportDirectory();
    final jarvisDir = Directory(p.join(appSupport.path, 'jarvis'));
    await jarvisDir.create(recursive: true);
    return jarvisDir.path;
  }

  /// Migrate DB from old volatile path to stable path if needed.
  Future<void> _migrateFromVolatilePath(String stablePath) async {
    try {
      final oldPath = p.join(await getDatabasesPath(), 'ibiti_memory.db');
      final oldFile = File(oldPath);
      final stableFile = File(stablePath);

      // If stable DB already exists and has data, skip migration.
      if (await stableFile.exists() && await stableFile.length() > 0) return;

      // If old volatile DB exists and has data, copy it to stable path.
      if (await oldFile.exists() && await oldFile.length() > 0) {
        await oldFile.copy(stablePath);
        _log.w('[DB_MIGRATE] Copied memory from volatile path to stable path');
        _log.w('[DB_MIGRATE] Old: $oldPath (${await oldFile.length()} bytes)');
        _log.w('[DB_MIGRATE] New: $stablePath');
      }
    } catch (e) {
      _log.e('[DB_MIGRATE] Migration from volatile path failed', e);
    }
  }

  /// Create an automatic backup of the database.
  Future<void> _autoBackup(String dbFilePath) async {
    try {
      final dbFile = File(dbFilePath);
      if (!await dbFile.exists() || await dbFile.length() == 0) return;

      final backupDir = Directory(p.join(p.dirname(dbFilePath), 'backups'));
      await backupDir.create(recursive: true);

      final now = DateTime.now();
      final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}_'
          '${now.hour.toString().padLeft(2, '0')}'
          '${now.minute.toString().padLeft(2, '0')}';
      final backupPath = p.join(backupDir.path, 'ibiti_memory_$stamp.db');

      // Don't backup if same-minute backup exists.
      if (await File(backupPath).exists()) return;

      await dbFile.copy(backupPath);
      _log.i('[DB_BACKUP] Created: $backupPath '
          '(${(await dbFile.length() / 1024).toStringAsFixed(0)} KB)');

      // Prune old backups: keep only the most recent _maxBackups.
      final backups = backupDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.db'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      if (backups.length > _maxBackups) {
        for (final old in backups.skip(_maxBackups)) {
          await old.delete();
          _log.d('[DB_BACKUP] Pruned old backup: ${p.basename(old.path)}');
        }
      }
    } catch (e) {
      _log.e('[DB_BACKUP] Backup failed', e);
    }
  }

  /// If the DB opened empty but backups exist, warn loudly.
  Future<void> _checkEmptyWithBackups(String dbFilePath) async {
    try {
      final backupDir = Directory(p.join(p.dirname(dbFilePath), 'backups'));
      if (!await backupDir.exists()) return;

      final backups = backupDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.db') && f.lengthSync() > 0)
          .toList();

      if (backups.isEmpty) return;

      // Check if current DB is effectively empty.
      final count = await _db!.rawQuery(
        'SELECT (SELECT count(*) FROM paper_trades) + '
        '(SELECT count(*) FROM decisions) + '
        '(SELECT count(*) FROM market_events) AS total',
      );
      final total = (count.first['total'] as int?) ?? 0;
      if (total == 0 && backups.isNotEmpty) {
        final newest = backups..sort((a, b) => b.path.compareTo(a.path));
        _log.w('в•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђ');
        _log.w('[JARVIS_MEMORY_WARNING] Database is EMPTY but '
            '${backups.length} backup(s) exist!');
        _log.w('[JARVIS_MEMORY_WARNING] Newest backup: '
            '${p.basename(newest.first.path)} '
            '(${(newest.first.lengthSync() / 1024).toStringAsFixed(0)} KB)');
        _log.w('[JARVIS_MEMORY_WARNING] To restore: copy backup over '
            'ibiti_memory.db and restart.');
        _log.w('в•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђ');
      }
    } catch (e) {
      _log.e('[DB_BACKUP] Empty check failed', e);
    }
  }

  // в”Ђв”Ђ Initialize в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  Future<void> initialize() async {
    if (_db != null) return;

    // 1. Resolve stable, persistent DB path.
    final stableDir = await _stableDbDir();
    final stableDbPath = p.join(stableDir, 'ibiti_memory.db');

    // 2. Migrate from volatile path if old DB exists there.
    await _migrateFromVolatilePath(stableDbPath);

    // 3. Backup existing DB before opening (protects against corruption).
    await _autoBackup(stableDbPath);

    // 4. Open database from stable path.
    dbPath = stableDbPath;
    _log.w('[DB_PATH] $stableDbPath');

    _db = await openDatabase(
      stableDbPath,
      version: 19,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );

    // Phase 5E: clean market memory table (the ONLY actively-used table now)
    await MarketMemoryService.instance.ensureTable();

    _flushTimer = Timer.periodic(_flushInterval, (_) => flushEventQueue());

    // 5. Check for empty-DB-with-backups situation.
    await _checkEmptyWithBackups(stableDbPath);

    await _logSummary();
    _log.i('Database initialized: ibiti_memory.db v19 (cleaned)');
  }

  // в”Ђв”Ђв”Ђ Dead ensure methods removed (Phase 6 cleanup) в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
  // Removed 14 _ensure* / _normalize* methods (570 lines) that created tables
  // only used by archived autotrader code (_archive/). See git history.



  Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();

    batch.execute('''
      CREATE TABLE market_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        event_type TEXT NOT NULL,
        severity TEXT NOT NULL,
        symbol TEXT NOT NULL,
        exchange TEXT NOT NULL,
        price REAL NOT NULL,
        change_percent REAL NOT NULL,
        volume_24h REAL NOT NULL,
        trigger_value REAL NOT NULL,
        description TEXT,
        timestamp TEXT NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE decisions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        event_id INTEGER,
        exchange TEXT NOT NULL,
        symbol TEXT NOT NULL,
        verdict TEXT NOT NULL,
        reason TEXT,
        rules_fired TEXT,
        mode TEXT NOT NULL,
        price_at_decision REAL NOT NULL,
        executed INTEGER DEFAULT 0,
        decided_at TEXT NOT NULL,
        FOREIGN KEY (event_id) REFERENCES market_events(id)
      )
    ''');

    batch.execute('''
      CREATE TABLE postmortems (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        decision_id INTEGER,
        symbol TEXT NOT NULL,
        exchange TEXT NOT NULL,
        original_verdict TEXT NOT NULL,
        price_at_decision REAL NOT NULL,
        price_15m REAL,
        price_30m REAL,
        price_60m REAL,
        outcome TEXT DEFAULT 'inconclusive',
        lesson TEXT,
        market_phase TEXT,
        decided_at TEXT NOT NULL,
        evaluated_at TEXT,
        FOREIGN KEY (decision_id) REFERENCES decisions(id)
      )
    ''');

    batch.execute('''
      CREATE TABLE token_profiles (
        key TEXT PRIMARY KEY,
        exchange TEXT NOT NULL,
        symbol TEXT NOT NULL,
        times_seen INTEGER DEFAULT 0,
        times_watched INTEGER DEFAULT 0,
        times_rejected INTEGER DEFAULT 0,
        times_acted INTEGER DEFAULT 0,
        times_would_buy INTEGER DEFAULT 0,
        times_won INTEGER DEFAULT 0,
        times_lost INTEGER DEFAULT 0,
        avg_pump_before_dump REAL DEFAULT 0,
        fake_breakout_rate REAL DEFAULT 0,
        best_signal_type TEXT,
        last_fail_reason TEXT,
        last_seen_price REAL DEFAULT 0,
        last_seen_at TEXT,
        recent_reasons TEXT
      )
    ''');

    batch.execute('''
      CREATE TABLE exchange_profiles (
        exchange TEXT PRIMARY KEY,
        total_events INTEGER DEFAULT 0,
        fake_breakouts INTEGER DEFAULT 0,
        successful_signals INTEGER DEFAULT 0,
        avg_slippage_percent REAL DEFAULT 0,
        avg_spread_percent REAL DEFAULT 0,
        reliability REAL DEFAULT 0.5,
        last_updated TEXT
      )
    ''');

    batch.execute('''
      CREATE TABLE lessons (
        id TEXT PRIMARY KEY,
        pattern TEXT NOT NULL,
        lesson TEXT NOT NULL,
        related_event_type TEXT,
        symbol TEXT,
        learned_in_phase TEXT,
        rule_weight REAL DEFAULT 0,
        confirmations INTEGER DEFAULT 1,
        confidence REAL DEFAULT 0.5,
        learned_at TEXT,
        last_confirmed_at TEXT
      )
    ''');

    batch.execute('''
      CREATE TABLE paper_trades (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        decision_id INTEGER,
        exchange TEXT NOT NULL,
        symbol TEXT NOT NULL,
        strategy_type TEXT DEFAULT 'normalMomentum',
        entry_price REAL NOT NULL,
        exit_price REAL,
        initial_size_usd REAL NOT NULL,
        remaining_size_usd REAL,
        gross_pnl REAL,
        fees_estimate REAL,
        slippage_estimate REAL,
        net_pnl REAL,
        reason TEXT,
        status TEXT DEFAULT 'open',
        close_reason TEXT,
        peak_price REAL,
        entry_quality REAL DEFAULT 0,
        role TEXT DEFAULT 'active',
        take_profit_price REAL,
        stop_loss_price REAL,
        opened_at TEXT NOT NULL,
        closed_at TEXT,
        expires_at TEXT NOT NULL,
        extensions INTEGER DEFAULT 0,
        is_confirmation_pending INTEGER DEFAULT 0,
        confirmation_started_at TEXT,
        confirmation_ticks INTEGER DEFAULT 0,
        confirmation_peak REAL DEFAULT 0,
        confirmation_higher_low_count INTEGER DEFAULT 0,
        initial_flow_class TEXT,
        promoted_from_scout INTEGER DEFAULT 0,
        initial_stop_loss_price REAL,
        realized_gross_pnl REAL DEFAULT 0,
        realized_fees REAL DEFAULT 0,
        realized_slippage REAL DEFAULT 0,
        tranche1_closed INTEGER DEFAULT 0,
        tranche2_closed INTEGER DEFAULT 0,
        candle_timing_role TEXT,
        scale_count INTEGER DEFAULT 0,
        last_scale_at TEXT,
        total_invested_usd REAL DEFAULT 0,
        position_quantity REAL DEFAULT 0,
        average_entry_price REAL,
        market_phase_at_entry TEXT,
        heartbeat_at_entry TEXT,
        asset_category TEXT,
        rr_ratio_at_entry REAL DEFAULT 0,
        flow_score_at_entry REAL DEFAULT 0,
        flow_at_exit TEXT,
        market_phase_at_exit TEXT,
        max_drawdown_pct REAL DEFAULT 0,
        FOREIGN KEY (decision_id) REFERENCES decisions(id)
      )
    ''');

    batch.execute('''
      CREATE TABLE ibiti_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    // Indexes
    batch.execute('CREATE INDEX idx_events_symbol ON market_events(symbol)');
    batch
        .execute('CREATE INDEX idx_events_exchange ON market_events(exchange)');
    batch.execute('CREATE INDEX idx_events_ts ON market_events(timestamp)');
    batch.execute('CREATE INDEX idx_decisions_symbol ON decisions(symbol)');
    batch.execute('CREATE INDEX idx_decisions_verdict ON decisions(verdict)');
    batch.execute('CREATE INDEX idx_decisions_at ON decisions(decided_at)');
    batch.execute('CREATE INDEX idx_pm_outcome ON postmortems(outcome)');
    batch.execute('CREATE INDEX idx_pt_status ON paper_trades(status)');
    batch.execute(
      'CREATE INDEX idx_pt_exchange_symbol_status '
      'ON paper_trades(exchange, symbol, status)',
    );

    await batch.commit(noResult: true);
    _log.i('Schema created: core tables + indexes');


    // Phase 6 v2: observation_log пїЅ used by getPendingObservations/updateObservationPrice.
    // Phase 6 v2: observation_log вЂ” researchOnly signals learn without trading.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS observation_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        exchange TEXT NOT NULL,
        symbol TEXT NOT NULL,
        signal_type TEXT,
        flow_class TEXT,
        entry_quality REAL,
        strategy_type TEXT,
        price_at_signal REAL NOT NULL,
        volume_24h REAL,
        observed_at TEXT NOT NULL,
        price_after_1h REAL,
        price_after_4h REAL,
        hypothetical_pnl_1h REAL,
        hypothetical_pnl_4h REAL,
        check_1h_at TEXT,
        check_4h_at TEXT,
        lesson TEXT,
        market_phase TEXT,
        heartbeat TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_obs_symbol ON observation_log(exchange, symbol)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_obs_pending ON observation_log(price_after_1h)',
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN slippage_estimate REAL');
      await db.execute('ALTER TABLE paper_trades ADD COLUMN close_reason TEXT');
      await db.execute('ALTER TABLE paper_trades ADD COLUMN peak_price REAL');
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN take_profit_price REAL');
      await db
          .execute('ALTER TABLE paper_trades ADD COLUMN stop_loss_price REAL');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_pt_exchange_symbol_status '
        'ON paper_trades(exchange, symbol, status)',
      );
      _log.i('Migrated v1в†’v2: paper_trades +5 columns, +1 index');
    }
    if (oldVersion < 3) {
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN entry_quality REAL DEFAULT 0');
      _log.i('Migrated v2в†’v3: paper_trades +entry_quality');
    }
    if (oldVersion < 4) {
      await db.execute(
          'ALTER TABLE lessons ADD COLUMN confidence REAL DEFAULT 0.5');
      _log.i('Migrated v3в†’v4: lessons +confidence');
    }
    if (oldVersion < 19) {
      await db.execute(
          "ALTER TABLE paper_trades ADD COLUMN extensions INTEGER DEFAULT 0");
      _log.i('Migrated v18->19: paper_trades +extensions');
    }
    if (oldVersion < 5) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ibiti_state (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
      _log.i('Migrated v4в†’v5: +ibiti_state table');
    }
    if (oldVersion < 6) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS exit_profiles (
          key TEXT PRIMARY KEY,
          strategy_type TEXT NOT NULL,
          token_maturity TEXT NOT NULL,
          rocket_stage TEXT NOT NULL,
          samples INTEGER DEFAULT 0,
          avg_mfe_pct REAL DEFAULT 0,
          avg_mae_pct REAL DEFAULT 0,
          avg_time_to_peak_min REAL DEFAULT 0,
          avg_time_to_failure_min REAL DEFAULT 0,
          best_tp_pct REAL DEFAULT 0,
          best_sl_pct REAL DEFAULT 0,
          expectancy REAL DEFAULT 0,
          profit_factor REAL DEFAULT 0,
          updated_at TEXT
        )
      ''');
      _log.i('Migrated v5в†’v6: +exit_profiles table');
    }
    if (oldVersion < 7) {
      await db.execute(
          "ALTER TABLE paper_trades ADD COLUMN role TEXT DEFAULT 'active'");
      _log.i('Migrated v6в†’7: paper_trades +role');
    }
    if (oldVersion < 8) {
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN is_confirmation_pending INTEGER DEFAULT 0');
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN confirmation_started_at TEXT');
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN confirmation_ticks INTEGER DEFAULT 0');
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN confirmation_peak REAL DEFAULT 0');
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN confirmation_higher_low_count INTEGER DEFAULT 0');
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN initial_flow_class TEXT');
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN promoted_from_scout INTEGER DEFAULT 0');
      _log.i('Migrated v7в†’8: paper_trades +confirmation fields');
    }
    if (oldVersion < 9) {
      // We rename size_usd to initial_size_usd by adding columns, we can't easily rename in old SQLite without recreation.
      // Wait, SQLite starting 3.25 supports RENAME COLUMN, but let's just add new columns and copy data.
      await db
          .execute('ALTER TABLE paper_trades ADD COLUMN initial_size_usd REAL');
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN remaining_size_usd REAL');
      await db.execute(
          'UPDATE paper_trades SET initial_size_usd = size_usd, remaining_size_usd = size_usd');
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN initial_stop_loss_price REAL');
      await db.execute(
          'UPDATE paper_trades SET initial_stop_loss_price = stop_loss_price');
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN realized_gross_pnl REAL DEFAULT 0');
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN realized_fees REAL DEFAULT 0');
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN realized_slippage REAL DEFAULT 0');
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN tranche1_closed INTEGER DEFAULT 0');
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN tranche2_closed INTEGER DEFAULT 0');
      _log.i('Migrated v8в†’9: paper_trades +16D partial exit fields');
    }
    if (oldVersion < 10) {
      // Properly recreate the table to drop the legacy NOT NULL `size_usd` column
      await db.execute('''
        CREATE TABLE paper_trades_v10 (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          decision_id INTEGER,
          exchange TEXT NOT NULL,
          symbol TEXT NOT NULL,
          entry_price REAL NOT NULL,
          exit_price REAL,
          initial_size_usd REAL NOT NULL,
          remaining_size_usd REAL,
          gross_pnl REAL,
          fees_estimate REAL,
          slippage_estimate REAL,
          net_pnl REAL,
          reason TEXT,
          status TEXT DEFAULT 'open',
          close_reason TEXT,
          peak_price REAL,
          entry_quality REAL DEFAULT 0,
          role TEXT DEFAULT 'active',
          take_profit_price REAL,
          stop_loss_price REAL,
          opened_at TEXT NOT NULL,
          closed_at TEXT,
          expires_at TEXT NOT NULL,
          extensions INTEGER DEFAULT 0,
          is_confirmation_pending INTEGER DEFAULT 0,
          confirmation_started_at TEXT,
          confirmation_ticks INTEGER DEFAULT 0,
          confirmation_peak REAL DEFAULT 0,
          confirmation_higher_low_count INTEGER DEFAULT 0,
          initial_flow_class TEXT,
          promoted_from_scout INTEGER DEFAULT 0,
          initial_stop_loss_price REAL,
          realized_gross_pnl REAL DEFAULT 0,
          realized_fees REAL DEFAULT 0,
          realized_slippage REAL DEFAULT 0,
          tranche1_closed INTEGER DEFAULT 0,
          tranche2_closed INTEGER DEFAULT 0,
          FOREIGN KEY (decision_id) REFERENCES decisions(id)
        )
      ''');
      await db.execute('''
        INSERT INTO paper_trades_v10 SELECT
          id, decision_id, exchange, symbol, entry_price, exit_price, initial_size_usd, remaining_size_usd,
          gross_pnl, fees_estimate, slippage_estimate, net_pnl, reason, status, close_reason, peak_price,
          entry_quality, role, take_profit_price, stop_loss_price, opened_at, closed_at, expires_at,
          0 AS extensions,
          is_confirmation_pending, confirmation_started_at, confirmation_ticks, confirmation_peak,
          confirmation_higher_low_count, initial_flow_class, promoted_from_scout, initial_stop_loss_price,
          realized_gross_pnl, realized_fees, realized_slippage, tranche1_closed, tranche2_closed
        FROM paper_trades
      ''');
      await db.execute('DROP TABLE paper_trades');
      await db.execute('ALTER TABLE paper_trades_v10 RENAME TO paper_trades');
      await db.execute('CREATE INDEX idx_pt_status ON paper_trades(status)');
      await db.execute(
          'CREATE INDEX idx_pt_exchange_symbol_status ON paper_trades(exchange, symbol, status)');
      _log.i('Migrated v9в†’10: Dropped legacy size_usd column properly.');
    }
    if (oldVersion < 11) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS opportunity_log (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          exchange TEXT NOT NULL,
          symbol TEXT NOT NULL,
          first_seen_at TEXT NOT NULL,
          first_seen_price REAL NOT NULL,
          max_price REAL NOT NULL,
          min_price REAL NOT NULL,
          last_price REAL NOT NULL,
          event_type TEXT,
          volume_24h REAL,
          flow_class TEXT,
          flow_5m_usd REAL,
          decisions TEXT,
          missed_pnl_percent REAL,
          was_traded INTEGER DEFAULT 0,
          tracking_minutes INTEGER DEFAULT 0
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_opp_symbol ON opportunity_log(exchange, symbol)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_opp_missed ON opportunity_log(missed_pnl_percent)',
      );
      _log.i('Migrated v10в†’11: +opportunity_log table (Phase 17B)');
    }
    if (oldVersion < 12) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS shadow_trades (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          exchange TEXT NOT NULL,
          symbol TEXT NOT NULL,
          shadow_type TEXT NOT NULL,
          blocked_by_rule TEXT NOT NULL,
          entry_price REAL NOT NULL,
          exit_price REAL,
          peak_price REAL,
          tp_price REAL,
          sl_price REAL,
          gross_pnl REAL,
          fees REAL,
          slippage REAL,
          net_pnl REAL,
          close_reason TEXT,
          opened_at TEXT NOT NULL,
          closed_at TEXT,
          duration_minutes INTEGER DEFAULT 0
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_shadow_rule ON shadow_trades(blocked_by_rule)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_shadow_pnl ON shadow_trades(net_pnl)',
      );
      _log.i('Migrated v11в†’12: +shadow_trades table (Phase 17C)');
    }
    if (oldVersion < 13) {
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN candle_timing_role TEXT');
      _log.i('Migrated v12в†’13: paper_trades +candle_timing_role');
    }
    if (oldVersion < 14) {
      // Phase 18G: Eternal Memory tables (inlined from archived EternalMemorySchema).
      await db.execute('CREATE TABLE IF NOT EXISTS jarvis_thoughts (id INTEGER PRIMARY KEY AUTOINCREMENT, symbol TEXT NOT NULL, exchange TEXT NOT NULL, decision TEXT NOT NULL, confidence REAL NOT NULL, risk_level TEXT, reasoning TEXT, thought TEXT, rules_overridden TEXT, memory_used TEXT, lesson_preview TEXT, provider TEXT, latency_ms INTEGER, context_snapshot TEXT, timestamp TEXT NOT NULL)');
      await db.execute('CREATE TABLE IF NOT EXISTS jarvis_rocket_memory (id INTEGER PRIMARY KEY AUTOINCREMENT, symbol TEXT NOT NULL, exchange TEXT NOT NULL, category TEXT, entry_change_pct REAL, peak_change_pct REAL, flow_at_entry TEXT, volume_flow_score REAL, rocket_stage TEXT, continued_after INTEGER DEFAULT 0, outcome TEXT, lesson TEXT, timestamp TEXT NOT NULL)');
      await db.execute('CREATE TABLE IF NOT EXISTS jarvis_missed_opps (id INTEGER PRIMARY KEY AUTOINCREMENT, symbol TEXT NOT NULL, exchange TEXT NOT NULL, blocked_by TEXT NOT NULL, blocked_at_price REAL NOT NULL, later_peak_price REAL, missed_pnl_pct REAL, flow_class TEXT, category TEXT, lesson TEXT, timestamp TEXT NOT NULL)');
      await db.execute('CREATE TABLE IF NOT EXISTS jarvis_rule_impact (rule_id TEXT PRIMARY KEY, helped INTEGER DEFAULT 0, hurt INTEGER DEFAULT 0, total_saved_pnl REAL DEFAULT 0, total_missed_pnl REAL DEFAULT 0, last_updated TEXT)');
      await db.execute('CREATE TABLE IF NOT EXISTS jarvis_sector_knowledge (id INTEGER PRIMARY KEY AUTOINCREMENT, sector TEXT NOT NULL, performance_7d REAL, trend TEXT, hot_tokens TEXT, notes TEXT, timestamp TEXT NOT NULL)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_jt_symbol ON jarvis_thoughts(symbol)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_jt_decision ON jarvis_thoughts(decision)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_jt_ts ON jarvis_thoughts(timestamp)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_jrm_symbol ON jarvis_rocket_memory(symbol)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_jmo_symbol ON jarvis_missed_opps(symbol)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_jmo_rule ON jarvis_missed_opps(blocked_by)');
      _log.i('Migrated v13в†’14: +jarvis_thoughts, +jarvis_rocket_memory, '
          '+jarvis_missed_opps, +jarvis_rule_impact, +jarvis_sector_knowledge '
          '(Phase 18G Eternal Memory)');
    }
    if (oldVersion < 15) {
      // Phase 19C: Strategy Memory Lifecycle columns.
      await db.execute(
          "ALTER TABLE exit_profiles ADD COLUMN status TEXT DEFAULT 'active'");
      await db.execute(
          "ALTER TABLE exit_profiles ADD COLUMN quarantine_reason TEXT DEFAULT ''");
      await db.execute(
          'ALTER TABLE exit_profiles ADD COLUMN epoch_samples INTEGER DEFAULT 0');
      await db.execute(
          'ALTER TABLE exit_profiles ADD COLUMN epoch_wins INTEGER DEFAULT 0');
      await db.execute(
          'ALTER TABLE exit_profiles ADD COLUMN epoch_losses INTEGER DEFAULT 0');
      await db.execute(
          'ALTER TABLE exit_profiles ADD COLUMN epoch_gross_win_usd REAL DEFAULT 0');
      await db.execute(
          'ALTER TABLE exit_profiles ADD COLUMN epoch_gross_loss_usd REAL DEFAULT 0');
      await db.execute(
          'ALTER TABLE exit_profiles ADD COLUMN status_changed_at TEXT');
      _log.i('Migrated v14в†’15: exit_profiles +lifecycle fields (Phase 19C)');
    }

    if (oldVersion < 16) {
      // Phase 20: Thesis-Based Hold Engine вЂ” store strategy type per trade.
      await db.execute(
          "ALTER TABLE paper_trades ADD COLUMN strategy_type TEXT DEFAULT 'normalMomentum'");
      _log.i('Migrated v15в†’16: paper_trades +strategy_type (Phase 20)');
    }

    if (oldVersion < 17) {
      // Phase 4C: Scaling fields
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN scale_count INTEGER DEFAULT 0');
      await db
          .execute('ALTER TABLE paper_trades ADD COLUMN last_scale_at TEXT');
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN total_invested_usd REAL DEFAULT 0');
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN position_quantity REAL DEFAULT 0');
      await db.execute(
          'ALTER TABLE paper_trades ADD COLUMN average_entry_price REAL');

      // Update existing records to have initial sizes as total/average
      await db.execute('''
        UPDATE paper_trades
        SET total_invested_usd = initial_size_usd,
            position_quantity = initial_size_usd / entry_price,
            average_entry_price = entry_price
        WHERE entry_price > 0 AND total_invested_usd = 0
      ''');
      _log.i('Migrated v16в†’17: paper_trades +scaling fields (Phase 4C)');
    }

    if (oldVersion < 18) {
      // Phase 9: Schema finalization.
      // observation_log and daily_reports are created by self-healing guards,
      // but bump version to mark schema as complete v2.
      _log.i('Migrated v17в†’18: Phase 9 schema finalization');
    }
  }

  // в”Ђв”Ђ Writers в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  /// Queue a market event for batch insert (flushed every 5s).
  void queueEvent(MarketEvent event) {
    _eventQueue.add(event);
  }

  /// Flush queued events to DB. Called by timer or on stop().
  Future<void> flushEventQueue() async {
    if (_eventQueue.isEmpty || _db == null) return;
    final events = List<MarketEvent>.from(_eventQueue);
    _eventQueue.clear();
    final batch = _db!.batch();
    for (final e in events) {
      batch.insert('market_events', _eventToRow(e));
    }
    await batch.commit(noResult: true);
  }

  /// Insert a decision immediately. Returns row id.
  Future<int> insertDecision(IbitiDecision d, {int? eventId}) async {
    return await db.insert('decisions', {
      'event_id': eventId,
      'exchange': d.event.exchange,
      'symbol': d.event.symbol,
      'verdict': d.verdict.name,
      'reason': d.reason,
      'rules_fired': jsonEncode(d.rulesFired),
      'mode': d.mode.name,
      'price_at_decision': d.priceAtDecision,
      'executed': d.executed ? 1 : 0,
      'decided_at': d.decidedAt.toIso8601String(),
    });
  }

  /// Insert a postmortem immediately. Sets entry.dbId on success.
  Future<int> insertPostmortem(PostmortemEntry p) async {
    final rowId = await db.insert('postmortems', {
      'decision_id': p.decisionDbId,
      'symbol': p.symbol,
      'exchange': p.exchange,
      'original_verdict': p.originalVerdict.name,
      'price_at_decision': p.priceAtDecision,
      'price_15m': p.priceAfter15min,
      'price_30m': p.priceAfter30min,
      'price_60m': p.priceAfter60min,
      'outcome': p.outcome.name,
      'lesson': p.lesson,
      'market_phase': p.marketPhase.name,
      'decided_at': p.decidedAt.toIso8601String(),
      'evaluated_at': p.evaluatedAt?.toIso8601String(),
    });
    p.dbId = rowId;
    return rowId;
  }

  /// Update postmortem prices.
  Future<void> updatePostmortemPrices(
    int id, {
    double? p15,
    double? p30,
    double? p60,
    PostmortemOutcome? outcome,
    String? lesson,
  }) async {
    final values = <String, dynamic>{};
    if (p15 != null) values['price_15m'] = p15;
    if (p30 != null) values['price_30m'] = p30;
    if (p60 != null) values['price_60m'] = p60;
    if (outcome != null) values['outcome'] = outcome.name;
    if (lesson != null) values['lesson'] = lesson;
    if (p60 != null) {
      values['evaluated_at'] = DateTime.now().toIso8601String();
    }
    if (values.isNotEmpty) {
      await db.update('postmortems', values, where: 'id = ?', whereArgs: [id]);
    }
  }

  /// Upsert token profile.
  Future<void> upsertTokenProfile(TokenProfile tp) async {
    await db.insert(
      'token_profiles',
      {
        'key': tp.key,
        'exchange': tp.exchange,
        'symbol': tp.symbol,
        'times_seen': tp.timesSeen,
        'times_watched': tp.timesWatched,
        'times_rejected': tp.timesRejected,
        'times_acted': tp.timesActed,
        'times_would_buy': tp.timesWouldBuy,
        'times_won': tp.timesWon,
        'times_lost': tp.timesLost,
        'avg_pump_before_dump': tp.avgPumpBeforeDump,
        'fake_breakout_rate': tp.fakeBreakoutRate,
        'best_signal_type': tp.bestSignalType?.name,
        'last_fail_reason': tp.lastFailReason,
        'last_seen_price': tp.lastSeenPrice,
        'last_seen_at': tp.lastSeenAt.toIso8601String(),
        'recent_reasons': jsonEncode(tp.recentReasons),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Upsert exchange profile.
  Future<void> upsertExchangeProfile(ExchangeProfile ep) async {
    await db.insert(
      'exchange_profiles',
      {
        'exchange': ep.exchange,
        'total_events': ep.totalEvents,
        'fake_breakouts': ep.fakeBreakouts,
        'successful_signals': ep.successfulSignals,
        'avg_slippage_percent': ep.avgSlippagePercent,
        'avg_spread_percent': ep.avgSpreadPercent,
        'reliability': ep.reliability,
        'last_updated': ep.lastUpdated.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Upsert a pattern lesson.
  Future<void> upsertLesson(PatternLesson l) async {
    await db.insert(
      'lessons',
      {
        'id': l.id,
        'pattern': l.pattern,
        'lesson': l.lesson,
        'related_event_type': l.relatedEventType?.name,
        'symbol': l.symbol,
        'learned_in_phase': l.learnedInPhase.name,
        'rule_weight': l.ruleWeight,
        'confirmations': l.confirmations,
        'confidence': l.confidence,
        'learned_at': l.learnedAt.toIso8601String(),
        'last_confirmed_at': l.lastConfirmedAt.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Insert a paper trade.

  // -- Dead CRUD removed: insertPaperTrade, insertOpportunity, insertShadowTrade, insertObservation


  /// Get observations that need price check (1h or 4h not yet filled).
  Future<List<Map<String, dynamic>>> getPendingObservations() async {
    if (_db == null) return [];
    return await db.rawQuery('''
      SELECT * FROM observation_log
      WHERE (price_after_1h IS NULL AND check_1h_at <= ?)
         OR (price_after_4h IS NULL AND check_4h_at <= ?)
      LIMIT 50
    ''', [
      DateTime.now().toIso8601String(),
      DateTime.now().toIso8601String(),
    ]);
  }

  /// Update observation with actual price after 1h or 4h.
  Future<void> updateObservationPrice({
    required int id,
    double? priceAfter1h,
    double? priceAfter4h,
    double? hypotheticalPnl1h,
    double? hypotheticalPnl4h,
    String? lesson,
  }) async {
    if (_db == null) return;
    final values = <String, dynamic>{};
    if (priceAfter1h != null) values['price_after_1h'] = priceAfter1h;
    if (priceAfter4h != null) values['price_after_4h'] = priceAfter4h;
    if (hypotheticalPnl1h != null) {
      values['hypothetical_pnl_1h'] = hypotheticalPnl1h;
    }
    if (hypotheticalPnl4h != null) {
      values['hypothetical_pnl_4h'] = hypotheticalPnl4h;
    }
    if (lesson != null) values['lesson'] = lesson;
    if (values.isEmpty) return;
    await db
        .update('observation_log', values, where: 'id = ?', whereArgs: [id]);
  }

  // -- Dead CRUD removed: insertDailyReport, insertCounterfactualReport,
  //    loadRecentCounterfactualReportRows, updatePaperTrade, loadOpenPaperTrades,
  //    loadClosedTradesSince, loadRecentCounterfactualReports, loadPaperStats


  /// Full diagnostic report for a time window.
  /// Returns a Map with all metrics needed to understand where Jarvis
  /// loses money and why.
  Future<Map<String, dynamic>> overnightReport({
    required DateTime since,
  }) async {
    if (!isOpen) return {};

    final sinceIso = since.toIso8601String();

    // в”Ђв”Ђ 1. Core stats: trades, wins, losses, PnL в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
    final coreRows = await db.rawQuery('''
      SELECT
        COUNT(*) as total,
        SUM(CASE WHEN net_pnl > 0 THEN 1 ELSE 0 END) as wins,
        SUM(CASE WHEN net_pnl <= 0 THEN 1 ELSE 0 END) as losses,
        COALESCE(SUM(net_pnl), 0) as total_net_pnl,
        COALESCE(SUM(gross_pnl), 0) as total_gross_pnl,
        COALESCE(SUM(fees_estimate), 0) as total_fees,
        COALESCE(SUM(slippage_estimate), 0) as total_slippage,
        COALESCE(MAX(net_pnl), 0) as best_trade,
        COALESCE(MIN(net_pnl), 0) as worst_trade,
        COALESCE(SUM(CASE WHEN gross_pnl > 0 THEN gross_pnl ELSE 0 END), 0) as gross_wins,
        COALESCE(SUM(CASE WHEN gross_pnl <= 0 THEN ABS(gross_pnl) ELSE 0 END), 0) as gross_losses,
        COALESCE(SUM(CASE WHEN net_pnl > 0 THEN net_pnl ELSE 0 END), 0) as net_wins,
        COALESCE(SUM(CASE WHEN net_pnl <= 0 THEN ABS(net_pnl) ELSE 0 END), 0) as net_losses
      FROM paper_trades
      WHERE status IN ('closed', 'expired') AND closed_at >= ? AND close_reason NOT IN ('promoted', 'scoutRejected')
        AND COALESCE(strategy_type, '') != 'flowScalper'
    ''', [sinceIso]);

    final c = coreRows.isNotEmpty ? coreRows.first : {};
    final totalTrades = (c['total'] as int?) ?? 0;
    final wins = (c['wins'] as int?) ?? 0;
    final losses = (c['losses'] as int?) ?? 0;
    final totalNetPnl = (c['total_net_pnl'] as num?)?.toDouble() ?? 0;
    final totalGrossPnl = (c['total_gross_pnl'] as num?)?.toDouble() ?? 0;
    final totalFees = (c['total_fees'] as num?)?.toDouble() ?? 0;
    final totalSlippage = (c['total_slippage'] as num?)?.toDouble() ?? 0;
    final bestTrade = (c['best_trade'] as num?)?.toDouble() ?? 0;
    final worstTrade = (c['worst_trade'] as num?)?.toDouble() ?? 0;
    final grossWinSum = (c['gross_wins'] as num?)?.toDouble() ?? 0;
    final grossLossSum = (c['gross_losses'] as num?)?.toDouble() ?? 0;
    final netWinSum = (c['net_wins'] as num?)?.toDouble() ?? 0;
    final netLossSum = (c['net_losses'] as num?)?.toDouble() ?? 0;

    final winRate = totalTrades > 0 ? wins / totalTrades : 0.0;
    final grossPF = grossLossSum > 0
        ? grossWinSum / grossLossSum
        : (grossWinSum > 0 ? double.infinity : 0.0);
    final netPF = netLossSum > 0
        ? netWinSum / netLossSum
        : (netWinSum > 0 ? double.infinity : 0.0);

    // в”Ђв”Ђ 2. Open trades count в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
    final openRows = await db.rawQuery(
      "SELECT COUNT(*) as c FROM paper_trades WHERE status = 'open' AND COALESCE(strategy_type, '') != 'flowScalper'",
    );
    final openCount = (openRows.first['c'] as int?) ?? 0;

    // в”Ђв”Ђ 3. Top 5 winners by token (with trade count) в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
    final winnersRows = await db.rawQuery('''
      SELECT symbol, SUM(net_pnl) as pnl, COUNT(*) as cnt
      FROM paper_trades
      WHERE status IN ('closed', 'expired') AND closed_at >= ? AND close_reason NOT IN ('promoted', 'scoutRejected')
        AND COALESCE(strategy_type, '') != 'flowScalper'
      GROUP BY symbol
      HAVING pnl > 0
      ORDER BY pnl DESC
      LIMIT 5
    ''', [sinceIso]);

    // в”Ђв”Ђ 4. Top 5 losers by token (with trade count) в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
    final losersRows = await db.rawQuery('''
      SELECT symbol, SUM(net_pnl) as pnl, COUNT(*) as cnt
      FROM paper_trades
      WHERE status IN ('closed', 'expired') AND closed_at >= ? AND close_reason NOT IN ('promoted', 'scoutRejected')
        AND COALESCE(strategy_type, '') != 'flowScalper'
      GROUP BY symbol
      HAVING pnl < 0
      ORDER BY pnl ASC
      LIMIT 5
    ''', [sinceIso]);

    // в”Ђв”Ђ 5. Per-exchange breakdown в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
    final exchangeRows = await db.rawQuery('''
      SELECT exchange,
             COUNT(*) as count,
             SUM(CASE WHEN net_pnl > 0 THEN 1 ELSE 0 END) as wins
      FROM paper_trades
      WHERE status IN ('closed', 'expired') AND closed_at >= ? AND close_reason NOT IN ('promoted', 'scoutRejected')
        AND COALESCE(strategy_type, '') != 'flowScalper'
      GROUP BY exchange
      ORDER BY count DESC
    ''', [sinceIso]);

    final exchanges = <String, Map<String, dynamic>>{};
    for (final ex in exchangeRows) {
      final exName = ex['exchange'] as String;
      final exTotal = (ex['count'] as int?) ?? 0;
      final exWins = (ex['wins'] as int?) ?? 0;
      exchanges[exName] = {
        'total': exTotal,
        'wins': exWins,
        'wr': exTotal > 0 ? exWins / exTotal : 0.0,
      };
    }

    // в”Ђв”Ђ 6. Close reasons breakdown в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
    final reasonRows = await db.rawQuery('''
      SELECT close_reason, COUNT(*) as cnt
      FROM paper_trades
      WHERE status IN ('closed', 'expired') AND closed_at >= ?
        AND close_reason IS NOT NULL AND close_reason != 'promoted'
        AND COALESCE(strategy_type, '') != 'flowScalper'
      GROUP BY close_reason
    ''', [sinceIso]);

    final closeReasons = <String, int>{};
    for (final r in reasonRows) {
      closeReasons[r['close_reason'] as String] = (r['cnt'] as int?) ?? 0;
    }

    // в”Ђв”Ђ 7. Average hold time: wins vs losses (in minutes) в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
    final holdRows = await db.rawQuery('''
      SELECT
        COALESCE(AVG(CASE WHEN net_pnl > 0
          THEN (julianday(closed_at) - julianday(opened_at)) * 1440
          ELSE NULL END), 0) as avg_win_min,
        COALESCE(AVG(CASE WHEN net_pnl <= 0
          THEN (julianday(closed_at) - julianday(opened_at)) * 1440
          ELSE NULL END), 0) as avg_loss_min
      FROM paper_trades
      WHERE status IN ('closed', 'expired') AND close_reason NOT IN ('promoted', 'scoutRejected')
        AND closed_at >= ? AND closed_at IS NOT NULL
        AND COALESCE(strategy_type, '') != 'flowScalper'
    ''', [sinceIso]);

    final avgWinMin = (holdRows.first['avg_win_min'] as num?)?.toDouble() ?? 0;
    final avgLossMin =
        (holdRows.first['avg_loss_min'] as num?)?.toDouble() ?? 0;

    // в”Ђв”Ђ 8. New lessons count в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
    final lessonsRow = await db.rawQuery(
      'SELECT COUNT(*) as c FROM lessons WHERE learned_at >= ?',
      [sinceIso],
    );
    final newLessons = (lessonsRow.first['c'] as int?) ?? 0;

    return {
      // Core
      'trades': totalTrades,
      'wins': wins,
      'losses': losses,
      'openCount': openCount,
      'winRate': winRate,
      'netPnl': totalNetPnl,
      'grossPnl': totalGrossPnl,
      'totalFees': totalFees,
      'totalSlippage': totalSlippage,
      'bestTrade': bestTrade,
      'worstTrade': worstTrade,
      // PF
      'grossPF': grossPF,
      'netPF': netPF,
      // Tokens
      'topWinners': winnersRows
          .map((e) => {
                'symbol': e['symbol'],
                'pnl': e['pnl'],
                'count': e['cnt'],
              })
          .toList(),
      'topLosers': losersRows
          .map((e) => {
                'symbol': e['symbol'],
                'pnl': e['pnl'],
                'count': e['cnt'],
              })
          .toList(),
      // Exchanges
      'exchanges': exchanges,
      // Close reasons
      'closeReasons': closeReasons,
      // Hold time
      'avgWinHoldMin': avgWinMin,
      'avgLossHoldMin': avgLossMin,
      // Lessons
      'newLessons': newLessons,
    };
  }

  // в”Ђв”Ђ Readers в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  Future<Map<String, TokenProfile>> loadAllTokenProfiles() async {
    final rows = await db.query('token_profiles');
    final map = <String, TokenProfile>{};
    for (final r in rows) {
      final tp = _rowToTokenProfile(r);
      map[tp.key] = tp;
    }
    return map;
  }

  Future<Map<String, ExchangeProfile>> loadAllExchangeProfiles() async {
    final rows = await db.query('exchange_profiles');
    final map = <String, ExchangeProfile>{};
    for (final r in rows) {
      final ep = ExchangeProfile(
        exchange: r['exchange'] as String,
        totalEvents: r['total_events'] as int? ?? 0,
        fakeBreakouts: r['fake_breakouts'] as int? ?? 0,
        successfulSignals: r['successful_signals'] as int? ?? 0,
        avgSlippagePercent:
            (r['avg_slippage_percent'] as num?)?.toDouble() ?? 0,
        avgSpreadPercent: (r['avg_spread_percent'] as num?)?.toDouble() ?? 0,
        reliability: (r['reliability'] as num?)?.toDouble() ?? 0.5,
        lastUpdated: DateTime.tryParse(r['last_updated'] as String? ?? ''),
      );
      map[ep.exchange] = ep;
    }
    return map;
  }

  Future<List<PatternLesson>> loadAllLessons() async {
    final rows = await db.query('lessons');
    return rows.map(_rowToLesson).toList();
  }

  Future<List<PostmortemEntry>> loadPendingPostmortems() async {
    final rows = await db.rawQuery(
      'SELECT * FROM postmortems WHERE price_60m IS NULL '
      'ORDER BY decided_at ASC LIMIT 200',
    );
    return rows.map(_rowToPostmortem).toList();
  }

  // в”Ђв”Ђ Key-value state (ibiti_state) в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  /// Get a string value from the state table. Returns null if not found.
  Future<String?> getState(String key) async {
    final rows = await db.query(
      'ibiti_state',
      where: 'key = ?',
      whereArgs: [key],
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  /// Get a double value from the state table. Returns [fallback] if not found.
  Future<double> getStateDouble(String key, {double fallback = 0}) async {
    final raw = await getState(key);
    if (raw == null) return fallback;
    return double.tryParse(raw) ?? fallback;
  }

  /// Get an int value from the state table. Returns [fallback] if not found.
  Future<int> getStateInt(String key, {int fallback = 0}) async {
    final raw = await getState(key);
    if (raw == null) return fallback;
    return int.tryParse(raw) ?? fallback;
  }

  /// Upsert a value in the state table.
  Future<void> setState(String key, String value) async {
    await db.insert(
      'ibiti_state',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // в”Ђв”Ђ Analytics в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  Future<int> countRows(String table) async {
    try {
      final r = await db.rawQuery('SELECT COUNT(*) as c FROM $table');
      return Sqflite.firstIntValue(r) ?? 0;
    } catch (_) {
      return 0; // Table may not exist yet
    }
  }

  Future<int> dbSizeBytes() async {
    final activePath = dbPath;
    if (activePath == null) return 0;
    final file = File(activePath);
    return file.existsSync() ? await file.length() : 0;
  }

  // в”Ђв”Ђ Maintenance в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
  Future<void> clearAll() async {
    for (final t in [
      'market_events',
      'decisions',
      'postmortems',
      'token_profiles',
      'exchange_profiles',
      'lessons',
      'paper_trades',
    ]) {
      await db.delete(t);
    }
    _log.i('рџ§№ All IBITI tables cleared');
  }

  /// Shutdown: flush queue, cancel timer.
  Future<void> close() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await flushEventQueue();
    await _db?.close();
    _db = null;
  }

  // в”Ђв”Ђ Migration from SharedPreferences в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  Future<void> migrateFromSharedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = [
      'ibiti_token_profiles',
      'ibiti_exchange_profiles',
      'ibiti_lessons',
      'ibiti_postmortems',
    ];
    final hasData = keys.any((k) => prefs.containsKey(k));
    if (!hasData) return;

    _log.i('Migration: found SharedPreferences data, importing...');
    int migrated = 0;

    // Token profiles
    final tpRaw = prefs.getString('ibiti_token_profiles');
    if (tpRaw != null && tpRaw.isNotEmpty) {
      final list = jsonDecode(tpRaw) as List;
      for (final item in list) {
        final tp = TokenProfile.fromJson(item as Map<String, dynamic>);
        await upsertTokenProfile(tp);
        migrated++;
      }
    }

    // Exchange profiles
    final epRaw = prefs.getString('ibiti_exchange_profiles');
    if (epRaw != null && epRaw.isNotEmpty) {
      final list = jsonDecode(epRaw) as List;
      for (final item in list) {
        final ep = ExchangeProfile.fromJson(item as Map<String, dynamic>);
        await upsertExchangeProfile(ep);
        migrated++;
      }
    }

    // Lessons
    final lRaw = prefs.getString('ibiti_lessons');
    if (lRaw != null && lRaw.isNotEmpty) {
      final list = jsonDecode(lRaw) as List;
      for (final item in list) {
        final l = PatternLesson.fromJson(item as Map<String, dynamic>);
        await upsertLesson(l);
        migrated++;
      }
    }

    // Postmortems
    final pmRaw = prefs.getString('ibiti_postmortems');
    if (pmRaw != null && pmRaw.isNotEmpty) {
      final list = jsonDecode(pmRaw) as List;
      for (final item in list) {
        final pm = PostmortemEntry.fromJson(item as Map<String, dynamic>);
        await insertPostmortem(pm);
        migrated++;
      }
    }

    // Remove old keys
    for (final k in keys) {
      await prefs.remove(k);
    }
    await prefs.remove('ibiti_decisions');

    _log.i('Migration complete: $migrated records imported. '
        'SharedPreferences keys removed.');
  }

  // в”Ђв”Ђ Diagnostics в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  Future<void> _logSummary() async {
    if (_db == null) return;
    final events = await countRows('market_events');
    final decisions = await countRows('decisions');
    final pms = await countRows('postmortems');
    final profiles = await countRows('token_profiles');
    final exchanges = await countRows('exchange_profiles');
    final lessonsCount = await countRows('lessons');
    final papers = await countRows('paper_trades');
    final observations = await countRows('observation_log');
    final size = await dbSizeBytes();
    final sizeKb = (size / 1024).toStringAsFixed(1);
    _log.i('[Summary] events=$events decisions=$decisions '
        'postmortems=$pms profiles=$profiles exchanges=$exchanges '
        'lessons=$lessonsCount papers=$papers obs=$observations '
        'size=${sizeKb}KB');
  }

  // в”Ђв”Ђ Row converters в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  Map<String, dynamic> _eventToRow(MarketEvent e) => {
        'event_type': e.type.name,
        'severity': e.severity.name,
        'symbol': e.symbol,
        'exchange': e.exchange,
        'price': e.price,
        'change_percent': e.changePercent,
        'volume_24h': e.volume24h,
        'trigger_value': e.triggerValue,
        'description': e.description,
        'timestamp': e.timestamp.toIso8601String(),
      };

  TokenProfile _rowToTokenProfile(Map<String, dynamic> r) {
    List<String>? reasons;
    if (r['recent_reasons'] != null) {
      try {
        reasons =
            (jsonDecode(r['recent_reasons'] as String) as List).cast<String>();
      } catch (_) {}
    }
    return TokenProfile(
      key: r['key'] as String,
      exchange: r['exchange'] as String? ?? '',
      symbol: r['symbol'] as String? ?? '',
      timesSeen: r['times_seen'] as int? ?? 0,
      timesWatched: r['times_watched'] as int? ?? 0,
      timesRejected: r['times_rejected'] as int? ?? 0,
      timesActed: r['times_acted'] as int? ?? 0,
      timesWouldBuy: r['times_would_buy'] as int? ?? 0,
      timesWon: r['times_won'] as int? ?? 0,
      timesLost: r['times_lost'] as int? ?? 0,
      avgPumpBeforeDump: (r['avg_pump_before_dump'] as num?)?.toDouble() ?? 0,
      fakeBreakoutRate: (r['fake_breakout_rate'] as num?)?.toDouble() ?? 0,
      bestSignalType: r['best_signal_type'] != null
          ? MarketEventType.values.firstWhere(
              (e) => e.name == r['best_signal_type'],
              orElse: () => MarketEventType.volumeSpike,
            )
          : null,
      lastFailReason: r['last_fail_reason'] as String?,
      lastSeenPrice: (r['last_seen_price'] as num?)?.toDouble() ?? 0,
      lastSeenAt: DateTime.tryParse(r['last_seen_at'] as String? ?? ''),
      recentReasons: reasons,
    );
  }

  PatternLesson _rowToLesson(Map<String, dynamic> r) => PatternLesson(
        id: r['id'] as String? ?? '',
        pattern: r['pattern'] as String? ?? '',
        lesson: r['lesson'] as String? ?? '',
        relatedEventType: r['related_event_type'] != null
            ? MarketEventType.values.firstWhere(
                (e) => e.name == r['related_event_type'],
                orElse: () => MarketEventType.volumeSpike,
              )
            : null,
        symbol: r['symbol'] as String?,
        learnedInPhase: MarketPhase.values.firstWhere(
          (e) => e.name == r['learned_in_phase'],
          orElse: () => MarketPhase.sideways,
        ),
        ruleWeight: (r['rule_weight'] as num?)?.toDouble() ?? 0,
        confirmations: r['confirmations'] as int? ?? 1,
        confidence: (r['confidence'] as num?)?.toDouble() ?? 0.5,
        learnedAt: DateTime.tryParse(r['learned_at'] as String? ?? ''),
        lastConfirmedAt:
            DateTime.tryParse(r['last_confirmed_at'] as String? ?? ''),
      );

  PostmortemEntry _rowToPostmortem(Map<String, dynamic> r) => PostmortemEntry(
        dbId: r['id'] as int?,
        decisionId: r['decision_id']?.toString() ?? '',
        decisionDbId: r['decision_id'] as int?,
        symbol: r['symbol'] as String? ?? '',
        exchange: r['exchange'] as String? ?? '',
        originalVerdict: IbitiVerdict.values.firstWhere(
          (e) => e.name == r['original_verdict'],
          orElse: () => IbitiVerdict.reject,
        ),
        priceAtDecision: (r['price_at_decision'] as num?)?.toDouble() ?? 0,
        priceAfter15min: (r['price_15m'] as num?)?.toDouble(),
        priceAfter30min: (r['price_30m'] as num?)?.toDouble(),
        priceAfter60min: (r['price_60m'] as num?)?.toDouble(),
        outcome: PostmortemOutcome.values.firstWhere(
          (e) => e.name == r['outcome'],
          orElse: () => PostmortemOutcome.inconclusive,
        ),
        lesson: r['lesson'] as String?,
        marketPhase: MarketPhase.values.firstWhere(
          (e) => e.name == r['market_phase'],
          orElse: () => MarketPhase.sideways,
        ),
        decidedAt: DateTime.tryParse(r['decided_at'] as String? ?? '') ??
            DateTime.now(),
        evaluatedAt: r['evaluated_at'] != null
            ? DateTime.tryParse(r['evaluated_at'] as String)
            : null,
      );

  PaperTrade rowToPaperTrade(Map<String, dynamic> r) => PaperTrade(
        id: r['id'] as int?,
        decisionId: r['decision_id'] as int?,
        exchange: r['exchange'] as String? ?? '',
        symbol: r['symbol'] as String? ?? '',
        entryPrice: (r['entry_price'] as num?)?.toDouble() ?? 0,
        exitPrice: (r['exit_price'] as num?)?.toDouble(),
        initialSizeUsd: (r['initial_size_usd'] as num?)?.toDouble() ??
            (r['size_usd'] as num?)?.toDouble() ??
            3,
        remainingSizeUsd: (r['remaining_size_usd'] as num?)?.toDouble() ??
            (r['size_usd'] as num?)?.toDouble() ??
            3,
        grossPnl: (r['gross_pnl'] as num?)?.toDouble(),
        feesEstimate: (r['fees_estimate'] as num?)?.toDouble(),
        slippageEstimate: (r['slippage_estimate'] as num?)?.toDouble(),
        netPnl: (r['net_pnl'] as num?)?.toDouble(),
        reason: r['reason'] as String? ?? '',
        status: PaperTradeStatus.values.firstWhere(
          (e) => e.name == (r['status'] as String? ?? 'open'),
          orElse: () => PaperTradeStatus.open,
        ),
        closeReason: r['close_reason'] != null
            ? PaperCloseReason.values.firstWhere(
                (e) => e.name == r['close_reason'],
                orElse: () => PaperCloseReason.expired,
              )
            : null,
        peakPrice: (r['peak_price'] as num?)?.toDouble(),
        entryQuality: (r['entry_quality'] as num?)?.toDouble() ?? 0,
        role: PositionRole.values.firstWhere(
          (e) => e.name == (r['role'] as String? ?? 'active'),
          orElse: () => PositionRole.active,
        ),
        takeProfitPrice: (r['take_profit_price'] as num?)?.toDouble(),
        stopLossPrice: (r['stop_loss_price'] as num?)?.toDouble(),
        initialStopLossPrice:
            (r['initial_stop_loss_price'] as num?)?.toDouble() ??
                (r['stop_loss_price'] as num?)?.toDouble(),
        openedAt: DateTime.tryParse(r['opened_at'] as String? ?? '') ??
            DateTime.now(),
        closedAt: r['closed_at'] != null
            ? DateTime.tryParse(r['closed_at'] as String)
            : null,
        expiresAt: r['expires_at'] != null
            ? DateTime.tryParse(r['expires_at'] as String)
            : null,
        extensions: (r['extensions'] as num?)?.toInt() ?? 0,
        isConfirmationPending: (r['is_confirmation_pending'] as int?) == 1,
        confirmationStartedAt: r['confirmation_started_at'] != null
            ? DateTime.tryParse(r['confirmation_started_at'] as String)
            : null,
        confirmationTicks: r['confirmation_ticks'] as int? ?? 0,
        confirmationPeak: (r['confirmation_peak'] as num?)?.toDouble() ?? 0,
        confirmationHigherLowCount:
            r['confirmation_higher_low_count'] as int? ?? 0,
        initialFlowClass: r['initial_flow_class'] as String? ?? '',
        promotedFromScout: (r['promoted_from_scout'] as int?) == 1,
        realizedGrossPnl: (r['realized_gross_pnl'] as num?)?.toDouble() ?? 0.0,
        realizedFees: (r['realized_fees'] as num?)?.toDouble() ?? 0.0,
        realizedSlippage: (r['realized_slippage'] as num?)?.toDouble() ?? 0.0,
        tranche1Closed: (r['tranche1_closed'] as int?) == 1,
        tranche2Closed: (r['tranche2_closed'] as int?) == 1,
        candleTimingRole: r['candle_timing_role'] as String? ?? '',
        strategyType: r['strategy_type'] as String? ?? 'normalMomentum',
        scaleCount: r['scale_count'] as int? ?? 0,
        lastScaleAt: r['last_scale_at'] != null
            ? DateTime.tryParse(r['last_scale_at'] as String)
            : null,
        totalInvestedUsd: (r['total_invested_usd'] as num?)?.toDouble() ?? 0,
        positionQuantity: (r['position_quantity'] as num?)?.toDouble() ?? 0,
        averageEntryPrice: (r['average_entry_price'] as num?)?.toDouble(),
        // Phase 10A: Diagnostic evidence
        marketPhaseAtEntry: r['market_phase_at_entry'] as String? ?? '',
        heartbeatAtEntry: r['heartbeat_at_entry'] as String? ?? '',
        assetCategory: r['asset_category'] as String? ?? '',
        rrRatioAtEntry: (r['rr_ratio_at_entry'] as num?)?.toDouble() ?? 0,
        flowScoreAtEntry: (r['flow_score_at_entry'] as num?)?.toDouble() ?? 0,
        flowAtExit: r['flow_at_exit'] as String? ?? '',
        marketPhaseAtExit: r['market_phase_at_exit'] as String? ?? '',
        maxDrawdownPct: (r['max_drawdown_pct'] as num?)?.toDouble() ?? 0,
      );

  // в”Ђв”Ђ Memory Compactor в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

  /// Garbage-collect old raw data. Knowledge stays in profiles + lessons.
  /// Call once per day from IbitiLoop.
  ///
  /// Deletes:
  ///   - market_events older than 7 days
  ///   - decisions older than 30 days
  ///   - completed postmortems older than 14 days
  ///   - closed paper_trades older than 30 days
  ///
  /// Does NOT delete: token_profiles, exchange_profiles, pattern_lessons.
  /// Those are the "compressed atoms" вЂ” permanent knowledge.
  Future<void> compactMemory() async {
    if (!isOpen) return;

    try {
      final now = DateTime.now();
      final cutoff7d = now.subtract(const Duration(days: 7)).toIso8601String();
      final cutoff14d =
          now.subtract(const Duration(days: 14)).toIso8601String();
      final cutoff30d =
          now.subtract(const Duration(days: 30)).toIso8601String();

      // 1. Raw events: oldest first, keep last 7 days.
      final eventsDeleted = await db.delete(
        'market_events',
        where: 'timestamp < ?',
        whereArgs: [cutoff7d],
      );

      // 2. Decisions: keep last 30 days.
      final decisionsDeleted = await db.delete(
        'decisions',
        where: 'decided_at < ?',
        whereArgs: [cutoff30d],
      );

      // 3. Completed postmortems: keep last 14 days.
      final postmortemsDeleted = await db.delete(
        'postmortems',
        where: 'evaluated_at IS NOT NULL AND evaluated_at < ?',
        whereArgs: [cutoff14d],
      );

      // 4. Closed paper trades: keep last 30 days.
      final papersDeleted = await db.delete(
        'paper_trades',
        where: "status = 'closed' AND closed_at < ?",
        whereArgs: [cutoff30d],
      );

      final total =
          eventsDeleted + decisionsDeleted + postmortemsDeleted + papersDeleted;

      if (total > 0) {
        _log.i('рџ§№ Memory compacted: '
            'events=$eventsDeleted decisions=$decisionsDeleted '
            'postmortems=$postmortemsDeleted papers=$papersDeleted '
            '(total=$total rows freed)');

        // Reclaim disk space.
        await db.execute('VACUUM');
      } else {
        _log.d('Memory compactor: nothing to clean');
      }
    } catch (e) {
      _log.e('Memory compactor failed', e);
    }
  }


  // -- Dead CRUD removed: emergencyCleanup, loadAllExitProfiles,
  //    upsertExitProfile, saveCoinDNA, saveCoinDNAWave
}

