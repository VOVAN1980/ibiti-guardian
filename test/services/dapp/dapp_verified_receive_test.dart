import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/policy/validators/composite_validator.dart';
import 'package:ibiti_guardian/services/policy/validators/target_selector_guard.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/dapp/dapp_policy.dart';
import 'package:ibiti_guardian/services/dapp/dapp_protocol.dart';
import 'package:ibiti_guardian/services/dapp/dapp_simulation.dart';
import 'package:ibiti_guardian/services/dapp/dapp_verified_receive.dart';

const account = '0x1111111111111111111111111111111111111111';
const target = '0x2222222222222222222222222222222222222222';
const implementation = '0x3333333333333333333333333333333333333333';
const book = '0x4444444444444444444444444444444444444444';
const forwarder = '0x5555555555555555555555555555555555555555';
const token = '0x55d398326f99059ff775485246999027b3197955';
const transferTopic =
    '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
const withdrawnTopic =
    '0xa6786aab7dbbc48b4b0387488b407bd81448030ab207b50bea7dbb5fbc1cd9eb';
final now = DateTime.now();
String word(BigInt number) => number.toRadixString(16).padLeft(64, '0');
String addressWord(String address) => address.substring(2).padLeft(64, '0');

String withdrawalData({String recipient = account, int sourceCount = 0}) {
  final head = [
    addressWord(token),
    addressWord(recipient),
    word(BigInt.from(500)),
    'a' * 64,
    word(BigInt.from(now.millisecondsSinceEpoch ~/ 1000 + 600)),
    word(BigInt.from(224)),
    word(BigInt.from(544))
  ].join();
  final certificate = word(BigInt.from(258)) + 'b' * 516 + '0' * 60;
  return '0x4093ae3e$head$certificate${word(BigInt.from(sourceCount))}${'c' * 64 * sourceCount}';
}

class ReceiveRpc {
  final Map<String, dynamic> fixture;
  List<String> methods = [];
  String? failMethod;
  String? tamperCode;
  bool wrongClone = false;
  String destination = target;
  String? wrongStorage;
  dynamic simulation;
  final DappTransaction tx;
  ReceiveRpc(this.fixture, this.tx) {
    simulation = [
      {
        'calls': [
          {
            'status': '0x1',
            'returnData': '0x${word(BigInt.from(1000))}',
            'logs': []
          },
          {'status': '0x1', 'returnData': '0x', 'logs': logs()},
          {
            'status': '0x1',
            'returnData': '0x${word(BigInt.from(1500))}',
            'logs': []
          }
        ]
      }
    ];
  }
  List<Map<String, dynamic>> logs() => [
        {
          'address': token,
          'topics': [
            transferTopic,
            '0x${addressWord(target)}',
            '0x${addressWord(account)}'
          ],
          'data': '0x${word(BigInt.from(500))}'
        },
        {
          'address': target,
          'topics': [
            withdrawnTopic,
            '0x${'a' * 64}',
            '0x${addressWord(token)}',
            '0x${addressWord(account)}'
          ],
          'data': '0x${word(BigInt.from(500))}'
        }
      ];
  String withImmutable(String code, List<int> offsets, String address) {
    for (final offset in offsets) {
      final index = 2 + offset * 2;
      code = code.replaceRange(index, index + 64, addressWord(address));
    }
    return code;
  }

  Future<dynamic> call(int chain, String method, List<dynamic> params) async {
    expect(chain, 56);
    methods.add(method);
    expect(
        method,
        isNot(anyOf('eth_sendTransaction', 'eth_sendRawTransaction',
            'personal_sign', 'eth_signTypedData_v4')));
    if (failMethod == method) {
      throw const DappError(-32000, 'Read unavailable.');
    }
    switch (method) {
      case 'eth_blockNumber':
        return '0x100';
      case 'eth_getStorageAt':
        expect(params[0], target);
        expect(params[2], '0x100');
        return wrongStorage ?? '0x${addressWord(implementation)}';
      case 'eth_getCode':
        expect(params[1], '0x100');
        var code = switch (params[0]) {
          target => fixture['LvsVaultProxy'] as String,
          implementation => fixture['LvsAuthorizedVaultV4'] as String,
          book => withImmutable(fixture['LvsDepositAddressBook'] as String,
              [304, 1283], forwarder),
          forwarder => withImmutable(
              fixture['LvsBookForwarder'] as String, [61, 161], book),
          _ => wrongClone ? '0xabcd' : '0x'
        };
        if (tamperCode == params[0]) code = code.replaceRange(2, 4, 'ff');
        return code;
      case 'eth_call':
        expect(params[1], '0x100');
        final payload = params[0] as Map;
        return switch (payload['data']) {
          '0x05a8da72' => '0x${addressWord(book)}',
          '0xf645d4f9' => '0x${addressWord(forwarder)}',
          '0xb269681d' => '0x${addressWord(destination)}',
          _ => throw StateError('Unexpected read')
        };
      case 'eth_simulateV1':
        expect(params[1], '0x100');
        final payload = params[0] as Map;
        expect(payload['validation'], false);
        expect(payload['traceTransfers'], true);
        expect(payload.containsKey('stateOverrides'), false);
        final blocks = payload['blockStateCalls'] as List;
        expect(blocks.length, 1);
        expect(blocks.single.containsKey('stateOverrides'), false);
        final calls = blocks.single['calls'] as List;
        expect(calls.length, 3);
        expect(calls[0]['to'], token);
        expect(calls[0]['data'], '0x70a08231${addressWord(account)}');
        expect(calls[0], calls[2]);
        expect(calls[0]['from'], isNot(account));
        expect(calls[1]['from'], account);
        expect(calls[1]['to'], target);
        expect(calls[1]['data'], tx.data);
        expect(calls[1]['value'], '0x0');
        expect(calls[1]['gas'], '0xf4240');
        expect(calls[1]['gasPrice'], '0x1');
        expect(calls[1].containsKey('chainId'), false);
        return simulation;
      default:
        throw StateError('Unexpected RPC: $method');
    }
  }
}

void main() {
  late DappTransaction tx;
  late ReceiveRpc rpc;
  late DappReceiverRegistry registry;
  late DappGasPlan gas;
  Future<DappReceiveEvidence> run({bool verifiedToken = true}) =>
      simulateVerifiedReceive(tx, gas, registry, rpc.call,
          isVerifiedToken: (_) => verifiedToken, now: now);

  setUp(() {
    tx = DappTransaction.parse({
      'from': account,
      'to': target,
      'value': '0x0',
      'data': withdrawalData()
    }, account, 56);
    gas = DappGasPlan({...tx.params, 'gas': '0xf4240', 'gasPrice': '0x1'},
        BigInt.from(1000000));
    registry = DappReceiverRegistry.fromJson(
        File('assets/dapp/verified_receivers.json').readAsStringSync());
    rpc = ReceiveRpc(
        jsonDecode(
            File('test/services/dapp/fixtures/reviewed_receiver_bytecode.json')
                .readAsStringSync()) as Map<String, dynamic>,
        tx);
  });

  test('reviewed receive uses exact code and real balance change, zero writes',
      () async {
    final evidence = await run();
    expect(evidence.call.amount, BigInt.from(500));
    expect(evidence.call.recipient, account);
    expect(evidence.call.token, token);
    expect(evidence.block, '0x100');
    expect(evidence.matches(tx, now: now), true);
    expect(rpc.methods.where((m) => m == 'eth_simulateV1').length, 1);
  });

  TransactionRequest context({String? to, int chain = 56, BigInt? value,
      String? data, TransactionType type = TransactionType.unknown}) => TransactionRequest(
      type: type, fromAddress: account, toAddress: to ?? target,
      chainId: chain, chainKey: 'bsc', sourceIntent: IntentData.empty(), amount: 0,
      rawAmount: value ?? BigInt.zero,
      calldata: Uint8List.fromList([for (var i = 2; i < (data ?? tx.data).length; i += 2)
        int.parse((data ?? tx.data).substring(i, i + 2), radix: 16)]));

  test('proved receive reaches consent in default Safe mode without persistent trust', () async {
    final evidence = await run();
    final profile = PolicyProfileStore.instance.current;
    expect(profile.mode, PolicyMode.safe);
    expect(profile.trustedContracts, isEmpty);
    DappPolicy.check(tx: tx, profile: profile, epk: const EpkState(),
        spendUsd: 0, unknownSpend: false, contractCall: true,
        verifiedReceive: evidence, now: now);
    expect((await CompositeValidator(verifiedReceive: evidence)
        .validate(context(), const EpkState())).isValid, true);
    expect((await CompositeValidator()
        .validate(context(), const EpkState())).isValid, false);
    expect(identical(profile, PolicyProfileStore.instance.current), true);
    expect(profile.trustedContracts, isEmpty);
    expect(profile.allowUnknownContracts, false);
  });

  test('receive evidence cannot authorize other payloads, fees or targets', () async {
    final evidence = await run();
    expect(evidence.matchesPayload(gas.payload, now: now), true);
    for (final fields in [
      {'gasPrice': '0x2'}, {'gas': '0xf4241'}, {'nonce': '0x2'},
      {'from': implementation}, {'to': implementation}, {'value': '0x1'},
      {'chainId': '0x1'}, {'data': '0x095ea7b3'},
    ]) {
      expect(evidence.matchesPayload({...gas.payload, ...fields}, now: now), false);
    }
    expect(evidence.matchesPayload(gas.payload, now: now.add(const Duration(seconds: 31))), false);
    for (final altered in [context(to: implementation), context(chain: 1),
      context(value: BigInt.one), context(data: '0x1234'), context(type: TransactionType.send)]) {
      expect(evidence.matchesContext(altered, now: now), false);
      expect((await TargetSelectorGuard(verifiedReceive: evidence)
          .validate(altered, const EpkState())).isValid, false);
    }
  });

  test('one-time receive never overrides pause, expiry or invalid spending limits', () async {
    final evidence = await run();
    void check({PolicyProfile? profile, EpkState epk = const EpkState(), DateTime? instant}) =>
      DappPolicy.check(tx: tx, profile: profile ?? PolicyProfile.safe(), epk: epk,
        spendUsd: 0, unknownSpend: false, contractCall: true, verifiedReceive: evidence,
        now: instant ?? now);
    expect(() => check(epk: const EpkState(isActive: false)), throwsA(isA<DappError>()));
    expect(() => check(profile: PolicyProfile.safe().copyWith(actionExpiries: {'SWAP': now})), throwsA(isA<DappError>()));
    expect(() => check(epk: const EpkState(perTxLimit: -1)), throwsA(isA<DappError>()));
    expect(() => check(instant: now.add(const Duration(seconds: 31))), throwsA(isA<DappError>()));
  });

  test('certificate, sources and recipient are decoded canonically', () {
    final call = DappReceiveCall.parse(DappTransaction.parse(
        {...tx.params, 'data': withdrawalData(sourceCount: 2)}, account, 56));
    expect(call.sources.length, 2);
    expect(call.sources.first, '0x${'c' * 64}');
    expect(() => call.sources.add('bad'), throwsUnsupportedError);
  });

  for (final changed in [target, implementation, book, forwarder]) {
    test('changed runtime code at $changed cannot bypass EPK', () async {
      if ([book, forwarder].contains(changed)) {
        tx = DappTransaction.parse(
            {...tx.params, 'data': withdrawalData(sourceCount: 1)},
            account,
            56);
        gas = DappGasPlan({...tx.params, 'gas': '0xf4240', 'gasPrice': '0x1'},
            BigInt.from(1000000));
        rpc = ReceiveRpc(rpc.fixture, tx);
      }
      rpc.tamperCode = changed;
      await expectLater(run(), throwsA(isA<DappError>()));
      expect(rpc.methods, isNot(contains('eth_simulateV1')));
    });
  }

  test(
      'book forwarder bindings and undecployed deterministic sources are verified',
      () async {
    tx = DappTransaction.parse(
        {...tx.params, 'data': withdrawalData(sourceCount: 2)}, account, 56);
    gas = DappGasPlan({...tx.params, 'gas': '0xf4240', 'gasPrice': '0x1'},
        BigInt.from(1000000));
    rpc = ReceiveRpc(rpc.fixture, tx);
    await run();
    expect(rpc.methods.where((m) => m == 'eth_getCode').length, 5);
  });

  test('wrong destination and existing malicious clone fail before simulation',
      () async {
    tx = DappTransaction.parse(
        {...tx.params, 'data': withdrawalData(sourceCount: 1)}, account, 56);
    gas = DappGasPlan({...tx.params, 'gas': '0xf4240', 'gasPrice': '0x1'},
        BigInt.from(1000000));
    rpc = ReceiveRpc(rpc.fixture, tx)..destination = implementation;
    await expectLater(run(), throwsA(isA<DappError>()));
    rpc.destination = target;
    rpc.wrongClone = true;
    await expectLater(run(), throwsA(isA<DappError>()));
    expect(rpc.methods, isNot(contains('eth_simulateV1')));
  });

  test(
      'unknown token, expired quote, native value, changed recipient fail closed',
      () async {
    await expectLater(run(verifiedToken: false), throwsA(isA<DappError>()));
    expect(rpc.methods, isEmpty);
    for (final fields in [
      {'data': withdrawalData(recipient: implementation)},
      {'value': '0x1'},
      {'data': tx.data.replaceRange(10 + 4 * 64, 10 + 5 * 64, word(BigInt.one))}
    ]) {
      tx = DappTransaction.parse({...tx.params, ...fields}, account, 56);
      await expectLater(run(), throwsA(isA<DappError>()));
    }
    expect(rpc.methods, isEmpty);
  });

  test(
      'overlong sources, offsets, certificate padding and trailing bytes rejected',
      () {
    final data = tx.data;
    for (final changed in [
      withdrawalData(sourceCount: 33),
      data.replaceRange(10 + 5 * 64, 10 + 6 * 64, word(BigInt.zero)),
      data.replaceRange(10 + 7 * 64, 10 + 8 * 64, word(BigInt.from(65))),
      data.replaceRange(10 + 16 * 64 + 4, 10 + 17 * 64, '1' * 60),
      '$data${'0' * 64}',
      '0x4093ae3e'
    ]) {
      final invalid =
          DappTransaction.parse({...tx.params, 'data': changed}, account, 56);
      expect(() => DappReceiveCall.parse(invalid), throwsA(isA<DappError>()));
    }
  });

  for (final method in ['eth_getCode', 'eth_getStorageAt', 'eth_simulateV1']) {
    test('$method unavailable means no permission and no simulation downgrade',
        () async {
      rpc.failMethod = method;
      await expectLater(run(), throwsA(isA<DappError>()));
      expect(rpc.methods.where((m) => m == 'eth_simulateV1').length,
          lessThanOrEqualTo(1));
    });
  }

  test('fake proxy storage word rejected', () async {
    rpc.wrongStorage = '0x${'a' * 64}';
    await expectLater(run(), throwsA(isA<DappError>()));
    expect(rpc.methods, isNot(contains('eth_simulateV1')));
  });

  for (final mutation in [
    'noResult',
    'missingCall',
    'reverted',
    'missingBalance',
    'partialCredit',
    'missingEvent',
    'wrongRecipient',
    'outgoing',
    'approval',
    'nativeSpend'
  ]) {
    test('simulation $mutation cannot be represented as safe zero spend',
        () async {
      final calls = rpc.simulation[0]['calls'] as List;
      switch (mutation) {
        case 'noResult':
          rpc.simulation = [];
          break;
        case 'missingCall':
          calls.removeLast();
          break;
        case 'reverted':
          calls[1]['status'] = '0x0';
          break;
        case 'missingBalance':
          calls[2]['returnData'] = '0x';
          break;
        case 'partialCredit':
          calls[2]['returnData'] = '0x${word(BigInt.from(1499))}';
          break;
        case 'missingEvent':
          calls[1]['logs'].removeLast();
          break;
        case 'wrongRecipient':
          calls[1]['logs'][1]['topics'][3] = '0x${addressWord(implementation)}';
          break;
        default:
          calls[1]['logs'].add({
            'address': mutation == 'nativeSpend'
                ? '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
                : token,
            'topics': [
              mutation == 'approval' ? '0x${'f' * 64}' : transferTopic,
              '0x${addressWord(account)}',
              '0x${addressWord(implementation)}'
            ],
            'data': '0x${word(BigInt.one)}'
          });
      }
      await expectLater(run(), throwsA(isA<DappError>()));
    });
  }

  test(
      'evidence is exact-request-bound and expires; cannot reuse for other calls',
      () async {
    final evidence = await run();
    expect(
        evidence.matches(tx, now: now.add(const Duration(seconds: 31))), false);
    expect(evidence.matches(tx, now: now.subtract(const Duration(seconds: 1))),
        false);
    for (final fields in [
      {'to': implementation},
      {'nonce': '0x1'},
      {'value': '0x1'},
      {'data': withdrawalData(sourceCount: 1)}
    ]) {
      expect(
          evidence.matches(
              DappTransaction.parse({...tx.params, ...fields}, account, 56),
              now: now),
          false);
    }
  });

  test(
      'verified receive remains subject to trusted targets, mode and active EPK',
      () async {
    final evidence = await run();
    expect(evidence.matches(tx, now: now), true);
    void check(PolicyProfile profile, EpkState epk) => DappPolicy.check(
        tx: tx,
        profile: profile,
        epk: epk,
        spendUsd: 0,
        unknownSpend: false,
        contractCall: true,
        now: now);
    check(PolicyProfile.defi(), const EpkState());
    expect(() => check(PolicyProfile.safe(), const EpkState()),
        throwsA(isA<DappError>()));
    check(PolicyProfile.safe().copyWith(trustedContracts: [target]),
        const EpkState());
    expect(() => check(PolicyProfile.defi(), const EpkState(isActive: false)),
        throwsA(isA<DappError>()));
    expect(
        () => DappPolicy.check(
            tx: tx,
            profile: PolicyProfile.defi(),
            epk: const EpkState(),
            spendUsd: 0,
            unknownSpend: true),
        throwsA(isA<DappError>()));
  });

  test(
      'verified claim keeps contract-action limits instead of masquerading as SEND',
      () {
    expect(
        () => DappPolicy.check(
            tx: tx,
            profile:
                PolicyProfile.defi().copyWith(actionExpiries: {'SWAP': now}),
            epk: const EpkState(),
            spendUsd: 0,
            unknownSpend: false,
            contractCall: true,
            now: now),
        throwsA(isA<DappError>()));
  });

  test(
      'receipt must prove exact payout; a transaction hash or status alone does not',
      () async {
    final evidence = await run();
    final receipt = {'from': account, 'to': target, 'logs': rpc.logs()};
    expect(evidence.confirmsReceipt(receipt, tx), true);
    expect(evidence.confirmsReceipt({...receipt, 'logs': []}, tx), false);
    expect(evidence.confirmsReceipt({...receipt, 'to': implementation}, tx),
        false);
    (receipt['logs'] as List)[0]['data'] = '0x${word(BigInt.one)}';
    expect(evidence.confirmsReceipt(receipt, tx), false);
  });
}
