import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/dapp/dapp_permissions.dart';
import 'package:ibiti_guardian/services/dapp/dapp_protocol.dart';
import 'package:ibiti_guardian/services/dapp/dapp_session.dart';
import 'package:ibiti_guardian/services/dapp/dapp_transaction_consent.dart';

const account = '0x1111111111111111111111111111111111111111';
const target = '0x2222222222222222222222222222222222222222';
const origin = 'https://dapp.example';
Matcher code(int value) =>
    isA<DappError>().having((e) => e.code, 'code', value);

class Permissions implements DappPermissions {
  final entries = <String, String>{};
  @override
  Future<bool> has(String origin, String account) async =>
      entries[origin] == account;
  @override
  Future<void> grant(String origin, String account) async {
    entries[origin] = account;
  }

  @override
  Future<void> revoke(String origin) async {
    entries.remove(origin);
  }

  @override
  Future<List<String>> origins() async => entries.keys.toList();
}

class Wallet implements DappWalletBackend {
  @override
  String account = '0x1111111111111111111111111111111111111111';
  @override
  bool available = true;
  @override
  Set<int> supportedChains = {56, 1, 137, 42161, 8453};
  int sends = 0, signs = 0, typedSigns = 0, reads = 0, checks = 0, prepares = 0;
  bool blocked = false;
  final consents = <DappTransaction, DappTransactionConsent>{};
  int confirmations = 0, discards = 0;
  String? signedHex;
  DappTransaction? sent;
  Completer<void>? transport;
  @override
  Future<void> checkSigningAllowed(int chainId) async {
    checks++;
    if (blocked) throw const DappError(4100, 'Blocked');
  }

  @override
  Future<DappApproval> prepareTransaction(
      String origin, DappTransaction tx) async {
    prepares++;
    final preview = DappApproval(
        origin: origin,
        method: 'eth_sendTransaction',
        account: account,
        chainId: tx.chainId,
        content: tx.data);
    consents.putIfAbsent(tx, () => DappTransactionConsent(tx, preview));
    return preview;
  }

  @override
  void confirmTransaction(DappTransaction tx, DappApproval shown) {
    consents[tx]!.confirm(tx, shown);
    confirmations++;
  }

  @override
  void discardTransaction(DappTransaction tx) {
    consents.remove(tx);
    discards++;
  }

  @override
  Future<void> checkTypedData(Map<String, dynamic> data, int chainId) async {
    if (blocked) throw const DappError(4100, 'Blocked');
  }

  @override
  Future<String> sendTransaction(DappTransaction tx,
      {required bool Function() isCurrent}) async {
    if (transport != null) await transport!.future;
    if (!isCurrent()) throw const DappError(4001, 'Cancelled');
    consents[tx]!.consume(tx);
    sends++;
    sent = tx;
    return '0x${'a' * 64}';
  }

  @override
  Future<String> signMessage(String hex, String expectedAccount,
      {required bool Function() isCurrent}) async {
    if (transport != null) await transport!.future;
    if (!isCurrent()) throw const DappError(4001, 'Cancelled');
    signs++;
    signedHex = hex;
    return 'signature';
  }

  @override
  Future<String> signTypedData(
      Map<String, dynamic> data, String expectedAccount,
      {required int chainId, required bool Function() isCurrent}) async {
    if (!isCurrent()) throw const DappError(4001, 'Cancelled');
    typedSigns++;
    return 'typed-signature';
  }

  @override
  Future<dynamic> readRpc(
      int chainId, String method, List<dynamic> params) async {
    reads++;
    return '0x1';
  }
}

void main() {
  late Wallet wallet;
  late Permissions permissions;
  late DappSession session;
  late List<DappApproval> approvals;
  late int authCount;
  late bool accepted, authAccepted;
  Future<dynamic> call(String method, [List<dynamic> params = const []]) =>
      session.handle(DappRpcRequest(1, method, params),
          sourceOrigin: origin, isMainFrame: true);
  Future<void> connect() async {
    await call('eth_requestAccounts');
  }

  String hex(String text) =>
      '0x${utf8.encode(text).map((c) => c.toRadixString(16).padLeft(2, '0')).join()}';
  setUp(() {
    wallet = Wallet();
    permissions = Permissions();
    approvals = [];
    authCount = 0;
    accepted = true;
    authAccepted = true;
    session = DappSession(
        wallet: wallet,
        permissions: permissions,
        approve: (value) async {
          approvals.add(value);
          return accepted;
        },
        authenticate: () async {
          authCount++;
          return authAccepted;
        });
    session.navigate('$origin/page');
  });
  test('page load never leaks account or prompts a connection', () async {
    expect(await call('eth_accounts'), isEmpty);
    expect(await call('eth_chainId'), '0x38');
    expect(approvals, isEmpty);
    expect(authCount, 0);
  });
  test('account consent is scoped to native origin and exact account',
      () async {
    await connect();
    expect(await call('eth_accounts'), [account]);
    expect(approvals.single.origin, origin);
    expect(authCount, 0);
    wallet.account = target;
    expect(await call('eth_accounts'), isEmpty);
  });
  test('connection rejection leaves no permission', () async {
    accepted = false;
    await expectLater(connect(), throwsA(code(4001)));
    expect(permissions.entries, isEmpty);
    expect(wallet.signs, 0);
  });
  for (final method in [
    'eth_sign',
    'eth_signTransaction',
    'eth_sendRawTransaction',
    'wallet_sendCalls',
    'wallet_watchAsset',
    'unknown'
  ]) {
    test('$method cannot bypass signing route', () async {
      await expectLater(call(method), throwsA(code(4200)));
      expect(wallet.sends + wallet.signs + wallet.typedSigns, 0);
      expect(approvals, isEmpty);
    });
  }
  test('cross-origin and same-origin iframe are both rejected', () async {
    await connect();
    for (final source in ['https://attacker.example', origin]) {
      await expectLater(
          session.handle(const DappRpcRequest(2, 'eth_accounts', []),
              sourceOrigin: source, isMainFrame: false),
          throwsA(code(4100)));
    }
    await expectLater(
        session.handle(const DappRpcRequest(2, 'eth_accounts', []),
            sourceOrigin: 'https://attacker.example', isMainFrame: true),
        throwsA(code(4100)));
  });
  test('signing requires site connection before approval/auth', () async {
    await expectLater(
        call('personal_sign', [hex('hello'), account]), throwsA(code(4100)));
    expect(approvals, isEmpty);
    expect(authCount, 0);
    expect(wallet.signs, 0);
  });
  test('personal_sign presents full Unicode and signs exact source bytes once',
      () async {
    await connect();
    const message = 'Привет, Guardian! € 😀';
    await call('personal_sign', [hex(message), account]);
    expect(approvals.last.content, message);
    expect(wallet.signedHex, hex(message));
    expect(wallet.signs, 1);
    expect(authCount, 1);
    expect(wallet.checks, 2);
  });
  test('wrong signature account rejected', () async {
    await connect();
    await expectLater(
        call('personal_sign', [hex('hello'), target]), throwsA(code(4100)));
    expect(wallet.signs, 0);
  });
  test('opaque and hidden messages rejected before UI', () async {
    await connect();
    for (final value in [
      '0xfffe',
      hex('Hello\u202eevil'),
      hex('\u0000secret')
    ]) {
      await expectLater(
          call('personal_sign', [value, account]), throwsA(isA<DappError>()));
    }
    expect(approvals.length, 1);
    expect(wallet.signs, 0);
  });
  test('SIWE cannot impersonate a different origin', () async {
    await connect();
    await expectLater(
        call('personal_sign', [
          hex('evil.example wants you to sign in with your Ethereum account:\n$account'),
          account
        ]),
        throwsA(code(4100)));
    expect(wallet.signs, 0);
  });
  test('tx simulation, consent, auth, revalidation then one write', () async {
    await connect();
    await call('eth_sendTransaction', [
      {'from': account, 'to': target, 'value': '0x0', 'data': '0x12345678'}
    ]);
    expect(wallet.sent!.data, '0x12345678');
    expect(wallet.sends, 1);
    expect(wallet.prepares, 2);
    expect(authCount, 1);
  });
  test('reject/auth cancellation/policy pause produces no signature', () async {
    await connect();
    accepted = false;
    await expectLater(
        call('personal_sign', [hex('hello'), account]), throwsA(code(4001)));
    accepted = true;
    authAccepted = false;
    await expectLater(
        call('personal_sign', [hex('hello'), account]), throwsA(code(4001)));
    authAccepted = true;
    wallet.blocked = true;
    await expectLater(
        call('personal_sign', [hex('hello'), account]), throwsA(code(4100)));
    expect(wallet.signs, 0);
    expect(wallet.sends, 0);
  });
  test('network switches browser context only after approval', () async {
    await connect();
    await call('wallet_switchEthereumChain', [
      {'chainId': '0x1'}
    ]);
    expect(session.chainId, 1);
    expect(wallet.sends + wallet.signs, 0);
    await expectLater(
        call('wallet_switchEthereumChain', [
          {'chainId': '0x61'}
        ]),
        throwsA(code(4902)));
    expect(session.chainId, 1);
  });
  test('add network does not adopt website RPC URL or switch network',
      () async {
    await connect();
    await call('wallet_addEthereumChain', [
      {
        'chainId': '0x1',
        'rpcUrls': ['https://evil.example']
      }
    ]);
    expect(session.chainId, 56);
    expect(wallet.reads, 0);
  });
  test('permission revocation removes account access immediately', () async {
    await connect();
    await call('wallet_revokePermissions', [
      {'eth_accounts': {}}
    ]);
    expect(await call('eth_accounts'), isEmpty);
    await expectLater(
        call('personal_sign', [hex('hello'), account]), throwsA(code(4100)));
  });
  test('typed data is presented in full and signed once', () async {
    await connect();
    final data = {
      'types': {'Message': []},
      'domain': {'chainId': 56},
      'primaryType': 'Message',
      'message': {'text': 'hello'}
    };
    await call('eth_signTypedData_v4', [account, jsonEncode(data)]);
    expect(approvals.last.content, contains('hello'));
    expect(wallet.typedSigns, 1);
  });
  for (final event in ['navigation', 'close', 'account', 'pause']) {
    test('$event during approval cancels without any write', () async {
      await connect();
      final approval = Completer<bool>();
      session = DappSession(
          wallet: wallet,
          permissions: permissions,
          approve: (_) => approval.future,
          authenticate: () async => true)
        ..navigate(origin);
      final pending = call('personal_sign', [hex('hello'), account]);
      await Future<void>.delayed(Duration.zero);
      final assertion = expectLater(pending, throwsA(code(4001)));
      if (event == 'navigation') session.navigate('$origin/another-document');
      if (event == 'close') session.close();
      if (event == 'account') wallet.account = target;
      if (event == 'pause') session.invalidate();
      approval.complete(true);
      await assertion;
      expect(wallet.signs, 0);
      expect(wallet.sends, 0);
    });
  }
  test('parallel interactive requests cannot spawn second approval', () async {
    await connect();
    final approval = Completer<bool>();
    int dialogs = 0;
    session = DappSession(
        wallet: wallet,
        permissions: permissions,
        approve: (_) {
          dialogs++;
          return approval.future;
        },
        authenticate: () async => true)
      ..navigate(origin);
    final first = call('personal_sign', [hex('hello'), account]);
    await Future<void>.delayed(Duration.zero);
    await expectLater(call('personal_sign', [hex('another'), account]),
        throwsA(code(-32002)));
    approval.complete(false);
    await expectLater(first, throwsA(code(4001)));
    expect(dialogs, 1);
    expect(wallet.signs, 0);
  });
  test('cancellation at SDK await is rechecked immediately before write',
      () async {
    await connect();
    wallet.transport = Completer<void>();
    final pending = call('personal_sign', [hex('hello'), account]);
    await Future<void>.delayed(Duration.zero);
    final assertion = expectLater(pending, throwsA(code(4001)));
    session.close();
    wallet.transport!.complete();
    await assertion;
    expect(wallet.signs, 0);
  });
  test('permission revoke during SDK await cancels the final signing guard',
      () async {
    await connect();
    wallet.transport = Completer<void>();
    final pending = call('personal_sign', [hex('hello'), account]);
    await Future<void>.delayed(Duration.zero);
    final assertion = expectLater(pending, throwsA(code(4001)));
    await call('wallet_revokePermissions', [
      {'eth_accounts': {}}
    ]);
    wallet.transport!.complete();
    await assertion;
    expect(wallet.signs, 0);
  });
  test('SIWE pins account in address line, URI origin and network', () async {
    await connect();
    String login(String address, String uri, int chain) =>
        'dapp.example wants you to sign in with your Ethereum account:\n\n$address\n\nStatement mentions $account\n\nURI: $uri\nVersion: 1\nChain ID: $chain\nNonce: 12345678\nIssued At: 2026-10-08T12:00:00Z';
    for (final message in [
      login(target, origin, 56),
      login(account, 'https://evil.example', 56),
      login(account, origin, 1)
    ]) {
      await expectLater(
          call('personal_sign', [hex(message), account]), throwsA(code(4100)));
    }
    expect(wallet.signs, 0);
    await call('personal_sign', [hex(login(account, origin, 56)), account]);
    expect(wallet.signs, 1);
  });
  test('cancelled native transaction leaves no reusable consent', () async {
    await connect();
    accepted = false;
    await expectLater(call('eth_sendTransaction', [{'from': account, 'to': target}]), throwsA(code(4001)));
    expect(wallet.confirmations, 0);
    expect(wallet.sends, 0);
    expect(wallet.consents, isEmpty);
    expect(wallet.discards, 1);
    expect(authCount, 0);
    expect(wallet.prepares, 1);
  });
  test('failed local authentication leaves no reusable consent', () async {
    await connect();
    authAccepted = false;
    await expectLater(call('eth_sendTransaction', [{'from': account, 'to': target}]), throwsA(code(4001)));
    expect(wallet.confirmations, 0);
    expect(wallet.sends, 0);
    expect(wallet.consents, isEmpty);
  });
  test('native consent is issued after fresh recheck and consumed once', () async {
    await connect();
    await call('eth_sendTransaction', [{'from': account, 'to': target}]);
    expect(wallet.prepares, 2);
    expect(wallet.confirmations, 1);
    expect(wallet.sends, 1);
    expect(wallet.consents, isEmpty);
    expect(authCount, 1);
  });


  for (final accepted in [false, true]) {
    test('duplicate transaction request cannot bypass pending decision $accepted', () async {
      await connect();
      final approval = Completer<bool>();
      var dialogs = 0;
      session = DappSession(
        wallet: wallet,
        permissions: permissions,
        approve: (_) { dialogs++; return approval.future; },
        authenticate: () async { authCount++; return true; },
      )..navigate(origin);
      final params = [{'from': account, 'to': target, 'value': '0x0', 'data': '0x12345678'}];
      final pending = call('eth_sendTransaction', params);
      final outcome = accepted
          ? expectLater(pending, completion('0x${'a' * 64}'))
          : expectLater(pending, throwsA(code(4001)));
      await Future<void>.delayed(Duration.zero);
      await expectLater(call('eth_sendTransaction', params), throwsA(code(-32002)));
      expect(wallet.sends, 0);
      expect(authCount, 0);
      approval.complete(accepted);
      await outcome;
      expect(dialogs, 1);
      expect(wallet.confirmations, accepted ? 1 : 0);
      expect(wallet.sends, accepted ? 1 : 0);
      expect(authCount, accepted ? 1 : 0);
      expect(wallet.consents, isEmpty);
    });
  }
}
