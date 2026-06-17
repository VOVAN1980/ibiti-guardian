import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

class MoralisConfigService {
  static final MoralisConfigService instance = MoralisConfigService._internal();
  MoralisConfigService._internal();
  static const _log = GuardianLogger('MoralisConfig');

  String _apiKey = '';
  String _defaultChain = 'bsc';
  bool _initialized = false;

  String get apiKey => _apiKey;
  String get defaultChain => _defaultChain;

  Future<void> init() async {
    if (_initialized) return;

    try {
      // First try rootBundle (ideal for deployed app)
      final str = await rootBundle.loadString('secrets/moralis.json');
      _parse(str);
      _initialized = true;
      return;
    } catch (e) {
      _log.d('rootBundle load skipped: $e');
    }

    try {
      // Fallback to File (good for background tasks or local execution)
      final file = File('secrets/moralis.json');
      if (file.existsSync()) {
        final str = await file.readAsString();
        _parse(str);
        _initialized = true;
        return;
      }
    } catch (e) {
      _log.d('File fallback skipped: $e');
    }

    _initialized = true;
  }

  void _parse(String jsonStr) {
    try {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      _apiKey = map["MORALIS_API_KEY"]?.toString() ?? '';
      _defaultChain = map["CHAIN"]?.toString() ?? 'bsc';
    } catch (_) {
      // Keep defaults if parsing fails
    }
  }

  /// Synchronous helper for when you are SURE init() was called.
  /// If not initialized, it returns empty strings.
  static String get key => instance.apiKey;
}
