import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/utils/guardian_logger.dart';

String getOkxIsoTimestamp() {
  final now = DateTime.now().toUtc();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}T'
      '${now.hour.toString().padLeft(2, '0')}:'
      '${now.minute.toString().padLeft(2, '0')}:'
      '${now.second.toString().padLeft(2, '0')}.'
      '${now.millisecond.toString().padLeft(3, '0')}Z';
}

class ExchangeValidationResult {
  final bool isValid;
  final String? errorMessage;
  final String? warningMessage;
  final double usdtBalance;
  final String? detectedRegion;

  ExchangeValidationResult({
    required this.isValid,
    this.errorMessage,
    this.warningMessage,
    this.usdtBalance = 0.0,
    this.detectedRegion,
  });
}

class ExchangeAccountStore {
  ExchangeAccountStore._() {
    _migrateKeys();
  }
  static final ExchangeAccountStore instance = ExchangeAccountStore._();

  static const _log = GuardianLogger('CEX_STORE');

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  final Map<String, double> _cachedUsdtBalances = {};
  final Map<String, String> _testOverrides = {};

  void setTestOverride(String key, String value) {
    _testOverrides[key] = value;
  }

  void clearTestOverrides() {
    _testOverrides.clear();
  }

  double? getCachedUsdtBalance(String exchangeId) {
    return _cachedUsdtBalances[_canonicalId(exchangeId)];
  }

  /// Normalize and canonicalize exchange IDs before all storage operations:
  /// mexc -> mexc, binance -> binance, gate.io/gateio -> gateio, bybit -> bybit
  String _canonicalId(String exchangeId) {
    final id = exchangeId.trim().toLowerCase();
    if (id == 'gate.io') return 'gateio';
    return id;
  }

  /// Key helper
  String _keyFor(String exchangeId, String type) => 'cex_${_canonicalId(exchangeId)}_$type';

  /// Add migration of keys from non-canonical spellings
  Future<void> _migrateKeys() async {
    final oldSpellings = ['gate.io', 'Gate.io', 'MEXC', 'Binance', 'Bybit'];
    for (final oldId in oldSpellings) {
      final oldKey = 'cex_${oldId}_api_key';
      final oldSecret = 'cex_${oldId}_api_secret';
      
      try {
        final keyVal = await _storage.read(key: oldKey);
        final secretVal = await _storage.read(key: oldSecret);
        
        if (keyVal != null && keyVal.isNotEmpty) {
          final canonical = _canonicalId(oldId);
          final newKey = _keyFor(canonical, 'api_key');
          final newSecret = _keyFor(canonical, 'api_secret');
          
          final exists = await _storage.read(key: newKey);
          if (exists == null || exists.isEmpty) {
            await _storage.write(key: newKey, value: keyVal);
            if (secretVal != null) {
              await _storage.write(key: newSecret, value: secretVal);
            }
            _log.i('[CEX_STORE] migrate $oldId -> $canonical');
          }
          
          // Delete old keys to clean up
          await _storage.delete(key: oldKey);
          await _storage.delete(key: oldSecret);
        }
      } catch (e) {
        _log.e('[CEX_STORE] Error migrating keys for $oldId: $e');
      }
    }
  }

  /// Check if credentials exist for an exchange
  Future<bool> isConnected(String exchangeId) async {
    final canonical = _canonicalId(exchangeId);
    final keyName = _keyFor(canonical, 'api_key');
    if (_testOverrides.containsKey(keyName)) {
      return _testOverrides[keyName]!.isNotEmpty;
    }
    try {
      final key = await _storage.read(key: _keyFor(canonical, 'api_key'));
      final secret = await _storage.read(key: _keyFor(canonical, 'api_secret'));
      final found = key != null && key.isNotEmpty && secret != null && secret.isNotEmpty;
      _log.i('[CEX_STORE] read $canonical found=$found');
      return found;
    } catch (e) {
      _log.e('[CEX_STORE] Error checking isConnected for $canonical: $e');
      return false;
    }
  }

  /// Get credentials for an exchange
  Future<Map<String, String>?> getCredentials(String exchangeId) async {
    final canonical = _canonicalId(exchangeId);
    final keyName = _keyFor(canonical, 'api_key');
    if (_testOverrides.containsKey(keyName)) {
      final key = _testOverrides[keyName];
      final secret = _testOverrides[_keyFor(canonical, 'api_secret')];
      final passphrase = _testOverrides[_keyFor(canonical, 'api_passphrase')];
      final region = _testOverrides[_keyFor(canonical, 'region')];
      if (key == null || key.isEmpty) return null;
      return {
        'apiKey': key,
        'apiSecret': secret ?? '',
        if (passphrase != null) 'passphrase': passphrase,
        if (region != null) 'region': region,
      };
    }
    try {
      final key = await _storage.read(key: _keyFor(canonical, 'api_key'));
      final secret = await _storage.read(key: _keyFor(canonical, 'api_secret'));
      final passphrase = await _storage.read(key: _keyFor(canonical, 'api_passphrase'));
      final region = await _storage.read(key: _keyFor(canonical, 'region'));
      final found = key != null && key.isNotEmpty && secret != null && secret.isNotEmpty;
      _log.i('[CEX_STORE] read $canonical found=$found');
      if (!found) return null;
      return {
        'apiKey': key,
        'apiSecret': secret,
        if (passphrase != null) 'passphrase': passphrase,
        if (region != null) 'region': region,
      };
    } catch (e) {
      _log.e('[CEX_STORE] Error getting credentials for $canonical: $e');
      return null;
    }
  }

  /// Get stored OKX region directly
  Future<String?> getOkxRegion() async {
    final keyName = _keyFor('okx', 'region');
    if (_testOverrides.containsKey(keyName)) {
      return _testOverrides[keyName];
    }
    try {
      return await _storage.read(key: _keyFor('okx', 'region'));
    } catch (_) {
      return null;
    }
  }

  /// Check if OKX region alert was shown for a specific API key + region combination
  Future<bool> hasShownOkxRegionAlert(String apiKey, String region) async {
    try {
      final key = 'okx_region_alert_shown_${apiKey.hashCode}_$region';
      final val = await _storage.read(key: key);
      return val == 'true';
    } catch (_) {
      return false;
    }
  }

  /// Set OKX region alert shown state for a specific API key + region combination
  Future<void> setOkxRegionAlertShown(String apiKey, String region, bool value) async {
    try {
      final key = 'okx_region_alert_shown_${apiKey.hashCode}_$region';
      await _storage.write(key: key, value: value ? 'true' : 'false');
    } catch (_) {}
  }

  /// Save credentials securely
  Future<void> saveCredentials(
    String exchangeId,
    String apiKey,
    String secret, {
    String? passphrase,
    String? region,
  }) async {
    final canonical = _canonicalId(exchangeId);
    _log.i('[CEX_STORE] save $canonical');
    try {
      await _storage.write(key: _keyFor(canonical, 'api_key'), value: apiKey);
      await _storage.write(key: _keyFor(canonical, 'api_secret'), value: secret);
      if (passphrase != null) {
        await _storage.write(key: _keyFor(canonical, 'api_passphrase'), value: passphrase);
      }
      if (region != null) {
        await _storage.write(key: _keyFor(canonical, 'region'), value: region);
      }
    } catch (e) {
      _log.e('[CEX_STORE] Error saving credentials for $canonical: $e');
    }
  }

  /// Disconnect exchange
  Future<void> disconnect(String exchangeId) async {
    final canonical = _canonicalId(exchangeId);
    _log.i('[CEX_STORE] disconnect only user action: $canonical');
    try {
      await _storage.delete(key: _keyFor(canonical, 'api_key'));
      await _storage.delete(key: _keyFor(canonical, 'api_secret'));
      await _storage.delete(key: _keyFor(canonical, 'api_passphrase'));
      await _storage.delete(key: _keyFor(canonical, 'region'));
    } catch (e) {
      _log.e('[CEX_STORE] Error disconnecting $canonical: $e');
    }
  }

  /// Fetch the current USDT balance for a connected exchange.
  /// Returns null if the fetch fails due to network/API error.
  Future<double?> fetchUsdtBalance(String exchangeId) async {
    final canonical = _canonicalId(exchangeId);
    final creds = await getCredentials(canonical);
    if (creds == null) return null;
    try {
      final result = await verifyAndConnect(
        canonical,
        creds['apiKey']!,
        creds['apiSecret']!,
        passphrase: creds['passphrase'],
      );
      if (!result.isValid) {
        _log.e('[CEX_STORE] verifyAndConnect failed for $canonical: ${result.errorMessage}');
        return null;
      }
      _cachedUsdtBalances[canonical] = result.usdtBalance;
      return result.usdtBalance;
    } catch (e) {
      _log.e('[CEX_STORE] fetchUsdtBalance exception for $canonical: $e');
      return null;
    }
  }

  /// Verify and connect a CEX account
  Future<ExchangeValidationResult> verifyAndConnect(
    String exchangeId,
    String apiKey,
    String secret, {
    String? passphrase,
  }) async {
    final id = _canonicalId(exchangeId);
    try {
      if (id == 'mexc') {
        return await _verifyMexc(apiKey, secret);
      } else if (id == 'binance') {
        return await _verifyBinance(apiKey, secret);
      } else if (id == 'okx') {
        return await _verifyOkx(apiKey, secret, passphrase ?? '');
      } else if (id == 'gateio') {
        return await _verifyGateIo(apiKey, secret);
      } else {
        return ExchangeValidationResult(
          isValid: false,
          errorMessage: 'Unsupported exchange: $exchangeId',
        );
      }
    } catch (e) {
      return ExchangeValidationResult(
        isValid: false,
        errorMessage: 'Network or configuration error: $e',
      );
    }
  }

  // ── MEXC Validation ────────────────────────────────────────────────────────
  Future<ExchangeValidationResult> _verifyMexc(String apiKey, String secret) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final queryString = 'timestamp=$timestamp';
    final signature = _hmacSha256(secret, queryString);

    final url = 'https://api.mexc.com/api/v3/account?timestamp=$timestamp&signature=$signature';
    final response = await http.get(Uri.parse(url), headers: {
      'X-MEXC-APIKEY': apiKey,
    });

    if (response.statusCode != 200) {
      final msg = _parseErrorMsg(response.body, 'Invalid API Key or Secret');
      return ExchangeValidationResult(isValid: false, errorMessage: msg);
    }

    final data = jsonDecode(response.body);
    final canTrade = data['canTrade'] == true;

    if (!canTrade) {
      return ExchangeValidationResult(
        isValid: false,
        errorMessage: 'Trading permission is not enabled on this API Key.',
      );
    }

    // Read USDT balance
    double usdtBalance = 0.0;
    final balances = data['balances'] as List?;
    if (balances != null) {
      for (final bal in balances) {
        if (bal['asset'] == 'USDT') {
          usdtBalance = double.tryParse(bal['free'].toString()) ?? 0.0;
          break;
        }
      }
    }

    return ExchangeValidationResult(
      isValid: true,
      usdtBalance: usdtBalance,
      warningMessage: 'Withdraw must be disabled in MEXC API settings.',
    );
  }

  // ── Binance Validation ─────────────────────────────────────────────────────
  Future<ExchangeValidationResult> _verifyBinance(String apiKey, String secret) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final queryString = 'timestamp=$timestamp';
    final signature = _hmacSha256(secret, queryString);

    final url = 'https://api.binance.com/api/v3/account?timestamp=$timestamp&signature=$signature';
    final response = await http.get(Uri.parse(url), headers: {
      'X-MBX-APIKEY': apiKey,
    });

    if (response.statusCode != 200) {
      final msg = _parseErrorMsg(response.body, 'Invalid API Key or Secret');
      return ExchangeValidationResult(isValid: false, errorMessage: msg);
    }

    final data = jsonDecode(response.body);
    final canTrade = data['canTrade'] == true;

    if (!canTrade) {
      return ExchangeValidationResult(
        isValid: false,
        errorMessage: 'Trading permission is not enabled on this API Key.',
      );
    }

    double usdtBalance = 0.0;
    final balances = data['balances'] as List?;
    if (balances != null) {
      for (final bal in balances) {
        if (bal['asset'] == 'USDT') {
          usdtBalance = double.tryParse(bal['free'].toString()) ?? 0.0;
          break;
        }
      }
    }

    return ExchangeValidationResult(
      isValid: true,
      usdtBalance: usdtBalance,
      warningMessage: 'Withdraw must be disabled in Binance API settings.',
    );
  }

  // ── OKX Validation ─────────────────────────────────────────────────────────
  Future<ExchangeValidationResult> _tryOkxEndpoint(
    String domain,
    String apiKey,
    String secret,
    String passphrase,
  ) async {
    try {
      final timestamp = getOkxIsoTimestamp();
      const method = 'GET';
      final isEea = domain.contains('eea');
      final targetCcy = isEea ? 'USDC' : 'USDT';
      final requestPath = '/api/v5/account/balance?ccy=$targetCcy';
      const body = '';
      
      final prehash = '$timestamp$method$requestPath$body';
      final keyBytes = utf8.encode(secret);
      final prehashBytes = utf8.encode(prehash);
      final hmac = Hmac(sha256, keyBytes);
      final digest = hmac.convert(prehashBytes);
      final signature = base64.encode(digest.bytes);

      final response = await http.get(
        Uri.parse('$domain$requestPath'),
        headers: {
          'OK-ACCESS-KEY': apiKey,
          'OK-ACCESS-SIGN': signature,
          'OK-ACCESS-TIMESTAMP': timestamp,
          'OK-ACCESS-PASSPHRASE': passphrase,
          'accept': 'application/json',
          'Content-Type': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        final err = _parseErrorMsg(response.body, 'HTTP ${response.statusCode}');
        return ExchangeValidationResult(
          isValid: false,
          errorMessage: 'HTTP status ${response.statusCode}: $err',
        );
      }

      if (response.body.trim().isEmpty) {
        return ExchangeValidationResult(
          isValid: false,
          errorMessage: 'Empty response',
        );
      }

      dynamic respData;
      try {
        respData = jsonDecode(response.body);
      } catch (e) {
        return ExchangeValidationResult(
          isValid: false,
          errorMessage: 'Invalid JSON response: $e',
        );
      }

      if (respData is! Map<String, dynamic>) {
        return ExchangeValidationResult(
          isValid: false,
          errorMessage: 'Unexpected JSON format',
        );
      }

      final code = respData['code']?.toString();
      if (code != '0') {
        final msg = respData['msg']?.toString() ?? 'Error code $code';
        return ExchangeValidationResult(
          isValid: false,
          errorMessage: msg,
        );
      }

      final dataList = respData['data'] as List?;
      double usdtBalance = 0.0;
      if (dataList != null && dataList.isNotEmpty) {
        final balanceData = dataList[0] as Map<String, dynamic>?;
        if (balanceData != null) {
          final details = balanceData['details'] as List?;
          if (details != null) {
            for (final detail in details) {
              if (detail is Map<String, dynamic> && detail['ccy'] == targetCcy) {
                usdtBalance = double.tryParse(detail['availBal']?.toString() ?? '') ?? 0.0;
                break;
              }
            }
          }
        }
      }

      return ExchangeValidationResult(
        isValid: true,
        usdtBalance: usdtBalance,
        warningMessage: 'Withdraw must be disabled in OKX API settings.',
      );
    } catch (e) {
      return ExchangeValidationResult(
        isValid: false,
        errorMessage: e.toString(),
      );
    }
  }

  Future<ExchangeValidationResult> _verifyOkx(String apiKey, String secret, String passphrase) async {
    final trimmedKey = apiKey.trim();
    final trimmedSecret = secret.trim();
    final trimmedPassphrase = passphrase.trim();
    
    if (trimmedKey.isEmpty || trimmedSecret.isEmpty || trimmedPassphrase.isEmpty) {
      return ExchangeValidationResult(
        isValid: false,
        errorMessage: 'OKX requires API Key, Secret, and Passphrase.',
      );
    }

    // Check if we already have a saved region to speed up subsequent checks
    final storedRegion = await getOkxRegion();
    if (storedRegion == 'eea') {
      final eeaResult = await _tryOkxEndpoint(
        'https://eea.okx.com',
        trimmedKey,
        trimmedSecret,
        trimmedPassphrase,
      );
      if (eeaResult.isValid) {
        return ExchangeValidationResult(
          isValid: true,
          usdtBalance: eeaResult.usdtBalance,
          warningMessage: eeaResult.warningMessage,
          detectedRegion: 'eea',
        );
      }
    } else if (storedRegion == 'global') {
      final globalResult = await _tryOkxEndpoint(
        'https://www.okx.com',
        trimmedKey,
        trimmedSecret,
        trimmedPassphrase,
      );
      if (globalResult.isValid) {
        return ExchangeValidationResult(
          isValid: true,
          usdtBalance: globalResult.usdtBalance,
          warningMessage: globalResult.warningMessage,
          detectedRegion: 'global',
        );
      }
    }

    // 1. Try Global first
    final globalResult = await _tryOkxEndpoint(
      'https://www.okx.com',
      trimmedKey,
      trimmedSecret,
      trimmedPassphrase,
    );

    if (globalResult.isValid) {
      return ExchangeValidationResult(
        isValid: true,
        usdtBalance: globalResult.usdtBalance,
        warningMessage: globalResult.warningMessage,
        detectedRegion: 'global',
      );
    }

    // 2. Try EEA next
    final eeaResult = await _tryOkxEndpoint(
      'https://eea.okx.com',
      trimmedKey,
      trimmedSecret,
      trimmedPassphrase,
    );

    if (eeaResult.isValid) {
      return ExchangeValidationResult(
        isValid: true,
        usdtBalance: eeaResult.usdtBalance,
        warningMessage: eeaResult.warningMessage,
        detectedRegion: 'eea',
      );
    }

    // If both failed, return a combined error message
    final errMsg = 'Global OKX error: ${globalResult.errorMessage}. EEA OKX error: ${eeaResult.errorMessage}.';
    return ExchangeValidationResult(
      isValid: false,
      errorMessage: errMsg,
    );
  }

  // ── Gate.io Validation ─────────────────────────────────────────────────────
  Future<ExchangeValidationResult> _verifyGateIo(String apiKey, String secret) async {
    final trimmedKey = apiKey.trim();
    final trimmedSecret = secret.trim();
    final timestamp = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    const emptyPayloadHash = 'cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e';

    // 1. Check permissions via /api/v4/wallet/key_info (Optional)
    final path = '/api/v4/wallet/key_info';
    try {
      final stringToSign = 'GET\n$path\n\n$emptyPayloadHash\n$timestamp';
      final signature = _hmacSha512(trimmedSecret, stringToSign);

      final response = await http.get(
        Uri.parse('https://api.gateio.ws$path'),
        headers: {
          'KEY': trimmedKey,
          'Timestamp': timestamp,
          'SIGN': signature,
          'Content-Type': 'application/json',
        },
      );

      final bodyPreview = response.body.length > 200 ? response.body.substring(0, 200) : response.body;
      _log.i('[verifyGateIo] GET $path | status=${response.statusCode} | body_preview: $bodyPreview');

      if (response.statusCode == 200 && response.body.trim().isNotEmpty) {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic>) {
          final perms = data['perms'] as List?;
          if (perms != null) {
            for (final p in perms) {
              final name = p['name']?.toString().toLowerCase() ?? '';
              if (name == 'withdraw' || name == 'withdrawal') {
                return ExchangeValidationResult(
                  isValid: false,
                  errorMessage: 'Safety violation: API Key has withdrawal permission enabled. Please disable it.',
                );
              }
            }
          }
        }
      } else {
        _log.w('[verifyGateIo] GET $path returned status=${response.statusCode} or empty body. Skipping key_info permissions validation.');
      }
    } catch (e) {
      _log.w('[verifyGateIo] Failed to perform optional key_info validation: $e. Skipping permissions check.');
    }

    // 2. Fetch USDT balance via /api/v4/spot/accounts (Primary validation check)
    double usdtBalance = 0.0;
    try {
      final spotPath = '/api/v4/spot/accounts';
      final spotStringToSign = 'GET\n$spotPath\n\n$emptyPayloadHash\n$timestamp';
      final spotSignature = _hmacSha512(trimmedSecret, spotStringToSign);

      final spotResponse = await http.get(
        Uri.parse('https://api.gateio.ws$spotPath'),
        headers: {
          'KEY': trimmedKey,
          'Timestamp': timestamp,
          'SIGN': spotSignature,
          'Content-Type': 'application/json',
        },
      );

      final spotBodyPreview = spotResponse.body.length > 200 ? spotResponse.body.substring(0, 200) : spotResponse.body;
      _log.i('[verifyGateIo] GET $spotPath | status=${spotResponse.statusCode} | body_preview: $spotBodyPreview');

      if (spotResponse.statusCode != 200) {
        final err = _parseErrorMsg(spotResponse.body, 'HTTP ${spotResponse.statusCode}');
        return ExchangeValidationResult(
          isValid: false,
          errorMessage: 'Invalid Gate.io API Key or Secret (Spot Accounts: $err)',
        );
      }

      final spotBody = spotResponse.body;
      if (spotBody.trim().isEmpty) {
        return ExchangeValidationResult(
          isValid: false,
          errorMessage: 'Gate.io returned empty response from /spot/accounts',
        );
      }

      dynamic spotData;
      try {
        spotData = jsonDecode(spotBody);
      } catch (e) {
        return ExchangeValidationResult(
          isValid: false,
          errorMessage: 'Gate.io returned invalid JSON response from /spot/accounts: $e',
        );
      }

      if (spotData is List) {
        for (final item in spotData) {
          if (item is Map<String, dynamic> && item['currency'] == 'USDT') {
            usdtBalance = double.tryParse(item['available'].toString()) ?? 0.0;
            break;
          }
        }
      }
    } catch (e) {
      return ExchangeValidationResult(
        isValid: false,
        errorMessage: 'Connection verification failed during Spot Accounts query: $e',
      );
    }

    return ExchangeValidationResult(
      isValid: true,
      usdtBalance: usdtBalance,
      warningMessage: 'Withdraw must be disabled in Gate API settings.',
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  String _hmacSha256(String secret, String input) {
    final keyBytes = utf8.encode(secret);
    final inputBytes = utf8.encode(input);
    final hmac = Hmac(sha256, keyBytes);
    return hmac.convert(inputBytes).toString();
  }

  String _hmacSha512(String secret, String input) {
    final keyBytes = utf8.encode(secret);
    final inputBytes = utf8.encode(input);
    final hmac = Hmac(sha512, keyBytes);
    return hmac.convert(inputBytes).toString();
  }

  String _parseErrorMsg(String body, String fallback) {
    try {
      final json = jsonDecode(body);
      return json['msg']?.toString() ?? json['message']?.toString() ?? fallback;
    } catch (_) {
      return fallback;
    }
  }
}
