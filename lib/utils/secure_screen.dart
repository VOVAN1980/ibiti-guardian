import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Blocks screenshots and hides the app in Recents (Android FLAG_SECURE)
/// while a PIN screen is shown. Reference-counted: nested PIN screens keep
/// it on until the last one closes.
class SecureScreen {
  SecureScreen._();

  static const _channel = MethodChannel('ibiti/secure_screen');
  static int _holders = 0;

  static Future<void> enable() async {
    _holders++;
    if (_holders == 1) await _invoke('enable');
  }

  static Future<void> disable() async {
    if (_holders == 0) return;
    _holders--;
    if (_holders == 0) await _invoke('disable');
  }

  static Future<void> _invoke(String method) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>(method);
    } catch (_) {
      // Older build without the channel: the screen still works.
    }
  }
}
