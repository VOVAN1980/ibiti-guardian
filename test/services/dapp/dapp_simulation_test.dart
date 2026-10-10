import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/dapp/dapp_protocol.dart';
import 'package:ibiti_guardian/services/dapp/dapp_simulation.dart';

const account = '0x1111111111111111111111111111111111111111';
const target = '0x2222222222222222222222222222222222222222';
void main() {
  late DappTransaction tx;
  late List<String> methods;
  late Map<String, dynamic> results;
  Future<dynamic> rpc(int chain, String method, List<dynamic> params) async {
    expect(chain, 56);
    methods.add(method);
    expect(method, isNot('eth_sendTransaction'));
    if (method == 'eth_call' || method == 'eth_estimateGas') {
      final payload = params.first as Map;
      expect(payload['from'], account);
      expect(payload['to'], target);
      expect(payload['data'], tx.data);
      expect(payload['value'], '0x7');
      expect(payload['chainId'], isNull);
    }
    return results[method];
  }

  setUp(() {
    tx = DappTransaction.parse({
      'from': account,
      'to': target,
      'data': '0xabcdef01',
      'value': '0x7',
      'nonce': '0x5'
    }, account, 56);
    methods = [];
    results = {
      'eth_call': '0x',
      'eth_estimateGas': '0x5208',
      'eth_gasPrice': '0xa',
      'eth_getBalance': '0xf4240'
    };
  });
  test('production preflight simulates exact payload and bounds fees; no write',
      () async {
    final plan = await simulateDappTransaction(tx, rpc);
    expect(methods,
        ['eth_call', 'eth_estimateGas', 'eth_gasPrice', 'eth_getBalance']);
    expect(plan.payload['data'], '0xabcdef01');
    expect(plan.payload['value'], '0x7');
    expect(plan.payload['nonce'], '0x5');
    expect(plan.payload['gas'], '0x6270');
    expect(plan.payload['gasPrice'], '0xa');
    expect(plan.maxFee, BigInt.from(252000));
    expect(() => plan.payload['value'] = '0x0', throwsUnsupportedError);
  });
  test('recheck cannot silently change any approved transaction field',
      () async {
    final plan = await simulateDappTransaction(tx, rpc);
    results['eth_gasPrice'] = '0x9';
    expect(await simulateDappTransaction(tx, rpc, approved: plan), same(plan));
  });
  test('increased network fee requires a new approval', () async {
    final plan = await simulateDappTransaction(tx, rpc);
    results['eth_gasPrice'] = '0xb';
    await expectLater(simulateDappTransaction(tx, rpc, approved: plan),
        throwsA(isA<DappError>().having((e) => e.code, 'code', 4001)));
  });
  test('lower gas price does not hide gas usage exceeding approved limit',
      () async {
    final plan = await simulateDappTransaction(tx, rpc);
    results['eth_estimateGas'] = '0x7530';
    results['eth_gasPrice'] = '0x1';
    await expectLater(simulateDappTransaction(tx, rpc, approved: plan),
        throwsA(isA<DappError>()));
  });
  test('recheck uses approved fee, not a cheaper newly estimated fee',
      () async {
    final plan = await simulateDappTransaction(tx, rpc);
    results['eth_gasPrice'] = '0x1';
    results['eth_getBalance'] = '0xc350';
    await expectLater(simulateDappTransaction(tx, rpc, approved: plan),
        throwsA(isA<DappError>()));
  });
  test('insufficient native coin for fee fails before signing', () async {
    results['eth_getBalance'] = '0x7';
    await expectLater(
        simulateDappTransaction(tx, rpc), throwsA(isA<DappError>()));
  });
  test('zero/malformed gas estimate fails closed', () async {
    for (final estimate in ['0x0', 'garbage']) {
      results['eth_estimateGas'] = estimate;
      await expectLater(
          simulateDappTransaction(tx, rpc), throwsA(isA<DappError>()));
    }
  });
  test('website gas limit below actual estimate is rejected', () async {
    tx = DappTransaction.parse({...tx.params, 'gas': '0x1'}, account, 56);
    await expectLater(
        simulateDappTransaction(tx, rpc), throwsA(isA<DappError>()));
  });
  test('EIP-1559 fee fields preserved, no legacy gasPrice injected', () async {
    tx = DappTransaction.parse({
      ...tx.params,
      'maxFeePerGas': '0xa',
      'maxPriorityFeePerGas': '0x2',
      'type': '0x2'
    }, account, 56);
    final plan = await simulateDappTransaction(tx, rpc);
    expect(plan.payload['gasPrice'], isNull);
    expect(plan.payload['maxFeePerGas'], '0xa');
    expect(plan.payload['maxPriorityFeePerGas'], '0x2');
    expect(methods, isNot(contains('eth_gasPrice')));
  });
  test('simulation revert stops before estimate, auth and write', () async {
    var count = 0;
    await expectLater(
        simulateDappTransaction(tx, (_, method, __) async {
          count++;
          expect(method, 'eth_call');
          throw const DappError(-32000, 'Simulation reverted.');
        }),
        throwsA(isA<DappError>()));
    expect(count, 1);
  });
}
