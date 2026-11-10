import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// PIN hashing. Current format: PBKDF2-HMAC-SHA256, stored as
/// "pbkdf2-sha256$<iterations>$<hex>". Legacy format: one SHA-256 of
/// pin+salt (a 6-digit PIN fell to a laptop in seconds if the stored hash
/// leaked); it still verifies and is upgraded on the next correct entry.
class PinHasher {
  PinHasher._();

  static const iterations = 20000;
  static const _prefix = 'pbkdf2-sha256';

  /// New hash, computed off the UI isolate.
  static Future<String> hash(String pin, String salt) async {
    final hex = await compute(_pbkdf2Isolate, [pin, salt, iterations]);
    return '$_prefix\$$iterations\$$hex';
  }

  static bool isLegacy(String stored) => !stored.startsWith('$_prefix\$');

  static Future<bool> verify(String pin, String salt, String stored) async {
    if (isLegacy(stored)) return _equals(legacyHash(pin, salt), stored);
    final parts = stored.split('\$');
    if (parts.length != 3) return false;
    final rounds = int.tryParse(parts[1]);
    if (rounds == null || rounds <= 0) return false;
    final hex = await compute(_pbkdf2Isolate, [pin, salt, rounds]);
    return _equals(hex, parts[2]);
  }

  static String legacyHash(String pin, String salt) =>
      sha256.convert(utf8.encode(pin + salt)).toString();

  /// PBKDF2-HMAC-SHA256 with a 32-byte output, hex encoded.
  @visibleForTesting
  static String pbkdf2Hex(String password, String salt, int rounds) {
    final hmac = Hmac(sha256, utf8.encode(password));
    var u = hmac.convert([...utf8.encode(salt), 0, 0, 0, 1]).bytes;
    final out = List<int>.of(u);
    for (var i = 1; i < rounds; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Comparison whose time doesn't depend on where the strings differ.
  static bool _equals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

String _pbkdf2Isolate(List<Object> args) => PinHasher.pbkdf2Hex(
    args[0] as String, args[1] as String, args[2] as int);
