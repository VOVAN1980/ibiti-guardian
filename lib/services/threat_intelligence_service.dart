import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:http/http.dart' as http;

enum IntelSource {
  remote,
  cache,
  fallback,
}

enum ThreatCategory {
  drainer,
  scamRouter,
  maliciousPermitSpender,
  fakeBridge,
  phishingContract,
}

class ThreatRecord {
  final int chainId;
  final String address;
  final String label;
  final ThreatCategory category;
  final String reasonKey;
  final int baseRiskWeight;

  const ThreatRecord({
    required this.chainId,
    required this.address,
    required this.label,
    required this.category,
    required this.reasonKey,
    required this.baseRiskWeight,
  });

  factory ThreatRecord.fromJson(Map<String, dynamic> json) => ThreatRecord(
        chainId: json['chainId'] as int,
        address: json['address'] as String,
        label: json['label'] as String,
        category: ThreatCategory.values.firstWhere(
          (e) => e.toString().split('.').last == json['category'],
          orElse: () => ThreatCategory.drainer,
        ),
        reasonKey: json['reasonKey'] as String,
        baseRiskWeight: json['baseRiskWeight'] as int,
      );

  Map<String, dynamic> toJson() => {
        'chainId': chainId,
        'address': address,
        'label': label,
        'category': category.toString().split('.').last,
        'reasonKey': reasonKey,
        'baseRiskWeight': baseRiskWeight,
      };
}

class ThreatIntelligenceService extends ChangeNotifier {
  static final ThreatIntelligenceService instance =
      ThreatIntelligenceService._internal();
  ThreatIntelligenceService._internal();

  static const _log = GuardianLogger('ThreatIntel');

  static const String _remoteUrl =
      'https://raw.githubusercontent.com/vovan1980/aimoney_guardian/main/threat-intel/feed.json';
  static const String _cacheKey = 'threat_cache';
  static const String _timestampKey = 'threat_last_sync';
  static const int _supportedVersion = 1;

  List<ThreatRecord> _threats = [];
  DateTime? _lastSync;
  bool _isSyncing = false;
  IntelSource _source = IntelSource.fallback;

  List<ThreatRecord> get threats => List.unmodifiable(_threats);
  DateTime? get lastSync => _lastSync;
  bool get isSyncing => _isSyncing;
  IntelSource get source => _source;

  bool get isStale =>
      _lastSync == null || DateTime.now().difference(_lastSync!).inHours > 24;

  static List<ThreatRecord> get _hardcodedFallback {
    final t = LocalizationService.instance;
    return [
      ThreatRecord(
        chainId: 56,
        address: "0x6666666666666666666666666666666666666666",
        label: t.t('riskLabelKnownDrainer'),
        category: ThreatCategory.drainer,
        reasonKey: "riskReasonKnownDrainer",
        baseRiskWeight: 80,
      ),
      ThreatRecord(
        chainId: 56,
        address: "0x7777777777777777777777777777777777777777",
        label: t.t('riskLabelScamRouter'),
        category: ThreatCategory.scamRouter,
        reasonKey: "riskReasonScamRouter",
        baseRiskWeight: 70,
      ),
      ThreatRecord(
        chainId: 1,
        address: "0x8888888888888888888888888888888888888888",
        label: t.t('riskLabelMaliciousPermit'),
        category: ThreatCategory.maliciousPermitSpender,
        reasonKey: "riskReasonMaliciousPermitSpender",
        baseRiskWeight: 75,
      ),
    ];
  }

  Future<void> init() async {
    await loadCache();
    // Do not await sync, let it happen in background to keep startup fast
    syncWithRemote();
  }

  Future<void> loadCache() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_cacheKey);
    final timestampStr = prefs.getString(_timestampKey);

    if (timestampStr != null) {
      _lastSync = DateTime.tryParse(timestampStr);
    }

    if (jsonStr != null) {
      try {
        final List<dynamic> jsonList = json.decode(jsonStr);
        _threats = jsonList.map((e) => ThreatRecord.fromJson(e)).toList();
        _source = IntelSource.cache;
        _log.d('Cache loaded: ${_threats.length} records');
      } catch (e) {
        _log.e('Cache corrupt', e);
        _threats = _hardcodedFallback;
        _source = IntelSource.fallback;
      }
    } else {
      _threats = _hardcodedFallback;
      _source = IntelSource.fallback;
    }
    notifyListeners();
  }

  Future<void> syncWithRemote() async {
    if (_isSyncing) return;
    _isSyncing = true;
    notifyListeners();

    try {
      final response = await http.get(Uri.parse(_remoteUrl)).timeout(
            const Duration(seconds: 15),
          );

      if (response.statusCode == 200) {
        final Map<String, dynamic> envelope = json.decode(response.body);

        // 1. Validate Envelope & Versioning
        final version = envelope['version'] as int?;
        final remoteThreatsJson = envelope['threats'] as List?;

        if (version != _supportedVersion) {
          throw Exception(
              'Unsupported feed version: $version (expected $_supportedVersion)');
        }

        if (remoteThreatsJson == null) {
          throw Exception('Missing threats field in feed envelope');
        }

        // 2. Atomic Swap (only if validation passes)
        final List<ThreatRecord> newThreats = remoteThreatsJson
            .map((e) => ThreatRecord.fromJson(e as Map<String, dynamic>))
            .toList();

        // 3. Update State
        _threats = newThreats;
        _lastSync = DateTime.now();
        _source = IntelSource.remote;
        await _saveToCache();
        _log.d('Remote sync success: ${_threats.length} records');
      } else {
        throw Exception('Server returned ${response.statusCode}');
      }
    } catch (e) {
      _log.w('Remote sync failed: $e. Staying on $_source');
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  Future<void> _saveToCache() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = json.encode(_threats.map((e) => e.toJson()).toList());
    await prefs.setString(_cacheKey, jsonStr);
    if (_lastSync != null) {
      await prefs.setString(_timestampKey, _lastSync!.toIso8601String());
    }
  }

  ThreatRecord? lookup(int chainId, String address) {
    final addr = address.toLowerCase();
    for (final record in _threats) {
      if (record.chainId == chainId && record.address.toLowerCase() == addr) {
        return record;
      }
    }
    return null;
  }
}
