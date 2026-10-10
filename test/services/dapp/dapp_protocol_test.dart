import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/dapp/dapp_protocol.dart';

const account = '0x1111111111111111111111111111111111111111';
const target = '0x2222222222222222222222222222222222222222';
void main() {
  group('HTTPS origin boundary', () {
    test('canonical origin excludes path/query and normalizes standard port',
        () {
      expect(DappOrigin.canonical('https://EXAMPLE.com:443/a?q=1'),
          'https://example.com');
      expect(DappOrigin.canonical('https://example.com:8443/a'),
          'https://example.com:8443');
    });
    for (final url in [
      'http://site.com',
      'file:///data/secrets',
      'javascript:alert(1)',
      'content://secret',
      'data:text/html,x',
      'https://user:pass@site.com',
      'https://',
      'https://sіte.com',
      'https://s%D1%96te.com',
      'https://site.com/\n'
    ]) {
      test(
          'rejects $url',
          () => expect(
              () => DappOrigin.httpsUrl(url), throwsA(isA<DappError>())));
    }
    test('browser link accepts only its own route and HTTPS URL', () {
      expect(
          DappOrigin.browserLink(Uri.parse(
              'ibitiguard://browser?url=https%3A%2F%2Fexample.com%2Fx')),
          Uri.parse('https://example.com/x'));
      for (final value in [
        'ibitiguardian://browser?url=https://example.com',
        'ibitiguard://wc?url=https://example.com',
        'ibitiguard://browser?url=http://example.com',
        'ibitiguard://browser?url=https://a.com&url=https://b.com'
      ]) {
        expect(DappOrigin.browserLink(Uri.parse(value)), isNull);
      }
    });
  });
  group('Exact transaction payload', () {
    test('inconsistent fee fields rejected before RPC', () {
      for (final fields in [
        {'maxPriorityFeePerGas': '0x1'},
        {'type': '0x0', 'maxFeePerGas': '0xa'},
        {'type': '0x2', 'gasPrice': '0xa'},
      ]) {
        expect(
            () => DappTransaction.parse(
                {'from': account, 'to': target, ...fields}, account, 56),
            throwsA(isA<DappError>()));
      }
    });
    Map<String, dynamic> payload() =>
        {'from': account, 'to': target, 'value': '0x1', 'data': '0xabcd'};
    test('preserves calldata, amount, sender and chain exactly', () {
      final tx = DappTransaction.parse(payload(), account, 56);
      expect(tx.params, {...payload(), 'chainId': '0x38'});
      expect(tx.value, BigInt.one);
      expect(() => tx.params['value'] = '0x2', throwsUnsupportedError);
    });
    test('input alias does not change bytes', () {
      final p = payload()
        ..remove('data')
        ..['input'] = '0xabcd';
      expect(DappTransaction.parse(p, account, 56).data, '0xabcd');
    });
    final mutations = <String, Map<String, dynamic>>{
      'different account': {'from': target},
      'different chain': {'chainId': '0x1'},
      'zero target': {'to': '0x${'0' * 40}'},
      'deployment': {'to': null},
      'negative amount': {'value': '-1'},
      'decimal amount': {'value': '10'},
      'odd bytes': {'data': '0xabc'},
      'conflicting input': {'input': '0xff'},
      'unknown extension': {'authorizationList': []},
      'unknown tx type': {'type': '0x4'},
      'mixed gas': {'gasPrice': '0x1', 'maxFeePerGas': '0x2'},
    };
    for (final entry in mutations.entries) {
      test(
          'rejects ${entry.key}',
          () => expect(
              () => DappTransaction.parse(
                  {...payload(), ...entry.value}, account, 56),
              throwsA(isA<DappError>())));
    }
    test('approve decodes exact spender, amount, unlimited flag', () {
      final data =
          '0x095ea7b3${target.substring(2).padLeft(64, '0')}${'f' * 64}';
      final tx = DappTransaction.parse(
          {...payload(), 'value': '0x0', 'data': data}, account, 56);
      expect(tx.isApproval, isTrue);
      expect(tx.tokenRecipient, target);
      expect(tx.tokenAmount, (BigInt.one << 256) - BigInt.one);
      expect(tx.isUnlimitedApproval, isTrue);
    });
  });
  group('Request and typed data contract', () {
    test('rejects invalid JSON and non-array params without exposing content',
        () {
      expect(() => DappRpcRequest.decode('secret'), throwsA(isA<DappError>()));
      expect(
          () => DappRpcRequest.decode(
              '{"id":1,"method":"personal_sign","params":{}}'),
          throwsA(isA<DappError>()));
      expect(const DappError(-32700, 'Invalid JSON.').toString(),
          isNot(contains('secret')));
    });
    Map<String, dynamic> typed() => {
          'types': {
            'Message': [
              {'name': 'text', 'type': 'string'}
            ]
          },
          'primaryType': 'Message',
          'domain': {'chainId': 56},
          'message': {'text': 'Привет'}
        };
    test('typed data keeps UTF8 and snapshots original payload', () {
      final data = typed();
      final copy = validateTypedData(jsonEncode(data), account, 56);
      (data['message'] as Map)['text'] = 'Changed';
      expect(copy['message']['text'], 'Привет');
    });
    test('rejects typed data chain/account mismatch', () {
      final data = typed();
      (data['domain'] as Map)['chainId'] = 1;
      expect(() => validateTypedData(data, account, 56),
          throwsA(isA<DappError>()));
      data['domain'] = {'chainId': 56};
      data['message'] = {'owner': target};
      expect(() => validateTypedData(data, account, 56),
          throwsA(isA<DappError>()));
    });
  });
}
