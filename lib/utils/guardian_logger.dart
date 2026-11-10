import 'package:flutter/foundation.dart';

/// Structured logger for Guardian.
///
/// In debug and profile (internal test) builds: prints all levels with
/// component prefix. In release builds main() drops all output.
///
/// Usage:
///   final _log = GuardianLogger('VaultSigner');
///   _log.d('Signing tx...');          // debug — suppressed in release
///   _log.i('Tx sent. hash=$hash');    // info — suppressed in release
///   _log.w('Nonce conflict');         // warning — always printed
///   _log.e('Fatal signing error', e); // error — always printed
class GuardianLogger {
  final String component;

  const GuardianLogger(this.component);

  /// Debug level — development only, never in release builds.
  void d(String message) {
    if (!kReleaseMode) {
      debugPrint('[$component] $message');
    }
  }

  /// Info level — development only.
  void i(String message) {
    if (!kReleaseMode) {
      debugPrint('[$component] ℹ $message');
    }
  }

  /// Warning level — always printed, with optional error detail.
  void w(String message, [Object? error]) {
    debugPrint('[$component] ⚠ $message${error != null ? ': $error' : ''}');
  }

  /// Error level — always printed with optional exception.
  void e(String message, [Object? error]) {
    debugPrint('[$component] ❌ $message${error != null ? ': $error' : ''}');
  }
}
