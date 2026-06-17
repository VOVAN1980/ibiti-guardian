import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

String _mask(String value) {
  if (value.isEmpty) return '<empty>';
  if (value.length <= 10) return value;
  return '${value.substring(0, 8)}...${value.substring(value.length - 6)}';
}

class PrivyConfigService {
  static final PrivyConfigService instance = PrivyConfigService._internal();
  PrivyConfigService._internal();

  static const _log = GuardianLogger('PrivyConfig');

  String _appId = '';
  String _clientId = '';
  bool _initialized = false;

  String get appId => _appId;
  String get clientId => _clientId;

  Future<void> init() async {
    if (_initialized) return;

    try {
      final str = await rootBundle.loadString('secrets/privy.json');
      _parse(str);
      _initialized = true;

      _log.d('privy.json loaded, isValid=$isValid');
    } catch (e) {
      _appId = '';
      _clientId = '';
      _log.e('Failed to load privy.json', e);
      _initialized = true;
    }
  }

  void _parse(String jsonStr) {
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    _appId = map["PRIVY_APP_ID"]?.toString().trim() ?? '';

    final fallbackClientId = map["PRIVY_CLIENT_ID"]?.toString().trim() ?? '';

    if (!kIsWeb && Platform.isAndroid) {
      final androidId = map["PRIVY_CLIENT_ID_ANDROID"]?.toString().trim() ?? '';
      _clientId = androidId.isNotEmpty ? androidId : fallbackClientId;
    } else if (!kIsWeb && Platform.isIOS) {
      final iosId = map["PRIVY_CLIENT_ID_IOS"]?.toString().trim() ?? '';
      _clientId = iosId.isNotEmpty ? iosId : fallbackClientId;
    } else {
      _clientId = fallbackClientId;
    }
  }

  bool get isValid =>
      _appId.isNotEmpty &&
      _appId != 'YOUR_PRIVY_APP_ID' &&
      _clientId.isNotEmpty &&
      _clientId != 'YOUR_PRIVY_CLIENT_ID';
}
