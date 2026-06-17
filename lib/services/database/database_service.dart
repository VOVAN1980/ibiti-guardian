import 'dart:async';
import 'dart:convert';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:ibiti_guardian/models/security_event.dart';

class DatabaseService {
  static final DatabaseService instance = DatabaseService._internal();
  DatabaseService._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'IBITI Guardian.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDb,
    );
  }

  Future<void> _createDb(Database db, int version) async {
    await db.execute('''
      CREATE TABLE security_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        type TEXT NOT NULL,
        severity TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        walletAddress TEXT,
        title TEXT NOT NULL,
        message TEXT NOT NULL,
        metadata TEXT
      )
    ''');
  }

  Future<void> insertEvent(SecurityEvent event) async {
    final db = await database;
    await db.insert(
      'security_events',
      {
        'type': event.type.name,
        'severity': event.severity,
        'timestamp': event.timestamp.toIso8601String(),
        'walletAddress': event.walletAddress,
        'title': event.title,
        'message': event.message,
        'metadata': json.encode(event.metadata),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<SecurityEvent>> getEvents({int limit = 100}) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'security_events',
      orderBy: 'timestamp DESC',
      limit: limit,
    );

    return List.generate(maps.length, (i) {
      return SecurityEvent(
        type: SecurityEventType.values.firstWhere(
          (e) => e.name == maps[i]['type'],
          orElse: () => SecurityEventType.monitoringCheckFailed,
        ),
        severity: maps[i]['severity'],
        timestamp: DateTime.parse(maps[i]['timestamp']),
        walletAddress: maps[i]['walletAddress'],
        title: maps[i]['title'],
        message: maps[i]['message'],
        metadata:
            maps[i]['metadata'] != null ? json.decode(maps[i]['metadata']) : {},
      );
    });
  }

  Future<void> clearEvents() async {
    final db = await database;
    await db.delete('security_events');
  }
}
