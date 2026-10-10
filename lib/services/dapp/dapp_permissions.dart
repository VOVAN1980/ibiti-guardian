import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dapp_protocol.dart';

abstract class DappPermissions {
  Future<bool> has(String origin, String account);
  Future<void> grant(String origin, String account);
  Future<void> revoke(String origin);
  Future<List<String>> origins();
}

/// Stores only per-origin account consent, never signatures or payloads.
class SecureDappPermissions implements DappPermissions {
  final FlutterSecureStorage storage;
  static const _key = 'guardian_dapp_permissions_v1';
  final DateTime Function() now;
  // Serialize updates across browser instances, not only within one page.
  static Future<void> _writes = Future<void>.value();
  SecureDappPermissions(
      {this.storage = const FlutterSecureStorage(
          // Match Vault/CEX: the Android plugin migrates default-mode entries
          // whenever an encrypted-mode reader runs. Mixing modes loses reads.
          aOptions: AndroidOptions(encryptedSharedPreferences: true)),
      DateTime Function()? now})
      : now = now ?? DateTime.now;

  Future<Map<String, dynamic>> _read({bool requireSuccess = false}) async {
    try {
      final value = await storage.read(key: _key);
      final entries = value == null
          ? <String, dynamic>{}
          : jsonDecode(value) as Map<String, dynamic>;
      if (kDebugMode) {
        debugPrint('[DappPermissions] read entries=${entries.length}');
      }
      return entries;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[DappPermissions] read rejected type=${error.runtimeType}');
      }
      if (requireSuccess) {
        throw const DappError(-32000, 'Website permissions could not be read.');
      }
      // Storage corruption/error never grants account access.
      return {};
    }
  }

  @override
  Future<bool> has(String origin, String account) async {
    await _writes;
    final entry = (await _read())[DappOrigin.canonical(origin)];
    if (entry is! Map || entry['account'] != account.toLowerCase()) {
      return false;
    }
    final expiry = DateTime.tryParse('${entry['expiresAt']}');
    return expiry != null && now().isBefore(expiry);
  }

  @override
  Future<void> grant(String origin, String account) async {
    if (!isEvmAddress(account)) {
      throw const DappError(-32602, 'Invalid account.');
    }
    final canonical = DappOrigin.canonical(origin);
    await _update((entries) {
      entries[canonical] = {
        'account': account.toLowerCase(),
        'expiresAt':
            now().add(const Duration(days: 30)).toUtc().toIso8601String()
      };
    });
    if (!await has(canonical, account)) {
      throw const DappError(
          -32000, 'Website permission could not be verified.');
    }
  }

  @override
  Future<void> revoke(String origin) async {
    final canonical = DappOrigin.canonical(origin);
    await _update((entries) {
      entries.remove(canonical);
    });
    if ((await _read(requireSuccess: true)).containsKey(canonical)) {
      throw const DappError(-32000, 'Website permission could not be revoked.');
    }
  }

  Future<void> _update(void Function(Map<String, dynamic>) update) async {
    final previous = _writes;
    final settled = Completer<void>();
    _writes = settled.future;
    try {
      await previous;
      final entries = await _read(requireSuccess: true);
      update(entries);
      await storage.write(key: _key, value: jsonEncode(entries));
    } catch (_) {
      throw const DappError(-32000, 'Website permission could not be saved.');
    } finally {
      settled.complete();
    }
  }

  @override
  Future<List<String>> origins() async {
    await _writes;
    final entries = await _read();
    final result = <String>[];
    for (final entry in entries.entries) {
      try {
        final value = entry.value;
        final accountValid = value is Map && isEvmAddress(value['account']);
        final active = value is Map &&
            DateTime.tryParse('${value['expiresAt']}')?.isAfter(now()) == true;
        if (kDebugMode) {
          debugPrint(
              '[DappPermissions] listing accountValid=$accountValid active=$active');
        }
        if (accountValid && active) {
          result.add(DappOrigin.canonical(entry.key));
        }
      } on DappError {
        if (kDebugMode) {
          debugPrint('[DappPermissions] listing invalidOrigin=true');
        }
      }
    }
    return result..sort();
  }
}
