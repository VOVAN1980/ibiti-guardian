import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

/// Reads the Ankr Advanced API key from the bundled `secrets/ankr.json`
/// (`{"ANKR_API_KEY": "..."}`). A missing file or an empty key simply means
/// "not configured": history then falls back to the next source.
class AnkrConfigService {
  static final AnkrConfigService instance = AnkrConfigService._internal();
  AnkrConfigService._internal();
  static const _log = GuardianLogger('AnkrConfig');

  String _apiKey = '';
  Future<void>? _loading;

  String get apiKey => _apiKey;
  bool get isConfigured => _apiKey.isNotEmpty;

  /// Loads the key once; concurrent callers wait for the same load.
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final str = await rootBundle.loadString('secrets/ankr.json');
      final map = jsonDecode(str) as Map<String, dynamic>;
      _apiKey = (map['ANKR_API_KEY'] ?? '').toString().trim();
    } catch (e) {
      _log.d('secrets/ankr.json not loaded (${e.runtimeType})');
    }
  }

  /// Test hook: pretend the key was loaded.
  void setKeyForTest(String key) {
    _apiKey = key;
    _loading = Future<void>.value();
  }
}
