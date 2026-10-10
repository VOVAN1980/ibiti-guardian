import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/dapp/dapp_permissions.dart';
import 'package:ibiti_guardian/services/dapp/dapp_protocol.dart';

const account = '0x1111111111111111111111111111111111111111';
const key = 'guardian_dapp_permissions_v1';

class FaultyStorage extends FlutterSecureStorage {
  String? value;
  bool failRead = false;
  bool ignoreWrite = false;
  int writes = 0;

  @override
  Future<String?> read(
      {required String key,
      IOSOptions? iOptions,
      AndroidOptions? aOptions,
      LinuxOptions? lOptions,
      WebOptions? webOptions,
      MacOsOptions? mOptions,
      WindowsOptions? wOptions}) async {
    if (failRead) throw StateError('synthetic storage failure');
    return value;
  }

  @override
  Future<void> write(
      {required String key,
      required String? value,
      IOSOptions? iOptions,
      AndroidOptions? aOptions,
      LinuxOptions? lOptions,
      WebOptions? webOptions,
      MacOsOptions? mOptions,
      WindowsOptions? wOptions}) async {
    writes++;
    if (!ignoreWrite) this.value = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DateTime now;
  late SecureDappPermissions store;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    now = DateTime.utc(2026, 10, 8);
    store = SecureDappPermissions(now: () => now);
  });
  test('Android storage mode matches existing Vault and never resets on error',
      () {
    expect(
        store.storage.aOptions.toMap()['encryptedSharedPreferences'], 'true');
    expect(store.storage.aOptions.toMap()['resetOnError'], 'false');
  });
  test('consent round-trip is per origin/account and never stores signatures',
      () async {
    await store.grant('https://dapp.example/page', account);
    expect(await store.has('https://dapp.example/other', account), isTrue);
    expect(await store.origins(), ['https://dapp.example']);
    expect(await store.has('https://other.example', account), isFalse);
    expect(await store.has('https://dapp.example', '0x${'2' * 40}'), isFalse);
    final content =
        jsonDecode((await const FlutterSecureStorage().read(key: key))!);
    expect((content['https://dapp.example'] as Map).keys.toSet(),
        {'account', 'expiresAt'});
  });
  test('permission expires exactly at 30 days', () async {
    await store.grant('https://dapp.example', account);
    now = now.add(const Duration(days: 30));
    expect(await store.has('https://dapp.example', account), isFalse);
    expect(await store.origins(), isEmpty);
  });
  test('revocation is persistent and idempotent', () async {
    await store.grant('https://dapp.example', account);
    await store.revoke('https://dapp.example');
    await store.revoke('https://dapp.example');
    expect(
        await SecureDappPermissions(now: () => now)
            .has('https://dapp.example', account),
        isFalse);
  });
  for (final corrupt in ['not json', '[]', '{"https://dapp.example":true}']) {
    test('corrupt storage fails closed: $corrupt', () async {
      FlutterSecureStorage.setMockInitialValues({key: corrupt});
      expect(await store.has('https://dapp.example', account), isFalse);
      expect(await store.origins(), isEmpty);
    });
  }
  test('parallel updates across instances do not lose permissions', () async {
    final other = SecureDappPermissions(now: () => now);
    await Future.wait([
      store.grant('https://a.example', account),
      other.grant('https://b.example', account)
    ]);
    expect(await store.origins(), ['https://a.example', 'https://b.example']);
    await Future.wait([
      store.revoke('https://a.example'),
      other.grant('https://c.example', account)
    ]);
    expect(await store.origins(), ['https://b.example', 'https://c.example']);
  });
  test('invalid accounts and HTTP origins cannot be saved', () async {
    await expectLater(
        store.grant('http://dapp.example', account), throwsA(isA<DappError>()));
    await expectLater(store.grant('https://dapp.example', 'invalid'),
        throwsA(isA<DappError>()));
    expect(await store.origins(), isEmpty);
  });
  test('storage read failure denies access and never overwrites permissions',
      () async {
    final broken = FaultyStorage()..failRead = true;
    final permissions = SecureDappPermissions(storage: broken, now: () => now);
    expect(await permissions.has('https://dapp.example', account), isFalse);
    await expectLater(permissions.grant('https://dapp.example', account),
        throwsA(isA<DappError>()));
    await expectLater(
        permissions.revoke('https://dapp.example'), throwsA(isA<DappError>()));
    expect(broken.writes, 0);
  });
  test('unpersisted grant is not reported as successful', () async {
    final broken = FaultyStorage()..ignoreWrite = true;
    final permissions = SecureDappPermissions(storage: broken, now: () => now);
    await expectLater(permissions.grant('https://dapp.example', account),
        throwsA(isA<DappError>()));
    expect(await permissions.has('https://dapp.example', account), isFalse);
  });
  test('unpersisted revoke is not reported as successful', () async {
    final broken = FaultyStorage();
    final permissions = SecureDappPermissions(storage: broken, now: () => now);
    await permissions.grant('https://dapp.example', account);
    broken.ignoreWrite = true;
    await expectLater(
        permissions.revoke('https://dapp.example'), throwsA(isA<DappError>()));
    expect(await permissions.has('https://dapp.example', account), isTrue);
  });
}
