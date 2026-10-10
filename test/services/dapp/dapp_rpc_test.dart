import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/services/dapp/dapp_protocol.dart';
import 'package:ibiti_guardian/services/dapp/dapp_wallet_backend.dart';

void main() {
  test('RPC uses the pinned registry, never a website-supplied endpoint',
      () async {
    final params = <dynamic>[
      {
        'from': '0x${'1' * 40}',
        'to': '0x${'2' * 40}',
        'data': '0xabcdef01',
        'value': '0x7'
      },
      'latest'
    ];
    final rpc = DappRpc(
        createClient: () => MockClient((request) async {
              expect(request.url.toString(),
                  PrivyChainRegistry.getEvmChain(56)!.rpcUrl);
              final body = jsonDecode(request.body) as Map;
              expect(body['method'], 'eth_call');
              expect(body['params'], params);
              return http.Response(
                  '{"jsonrpc":"2.0","id":1,"result":"0x"}', 200);
            }));
    expect(await rpc.call(56, 'eth_call', params), '0x');
  });
  test('unsupported network is rejected before transport', () async {
    var calls = 0;
    final rpc = DappRpc(createClient: () {
      calls++;
      return MockClient((_) async => http.Response('{}', 200));
    });
    await expectLater(
        rpc.call(97, 'eth_chainId', []), throwsA(isA<DappError>()));
    expect(calls, 0);
  });
  for (final response in [
    http.Response('sensitive upstream content', 500),
    http.Response('{"error":{"message":"private request details"}}', 200),
    http.Response('invalid json with secret', 200)
  ]) {
    test(
        'upstream error is redacted (${response.statusCode}, ${response.body.length})',
        () async {
      final rpc =
          DappRpc(createClient: () => MockClient((_) async => response));
      try {
        await rpc.call(56, 'eth_call', []);
        fail('must reject');
      } on DappError catch (error) {
        expect(error.toString(), isNot(contains('private')));
        expect(error.toString(), isNot(contains('secret')));
        expect(error.toString(), isNot(contains('sensitive')));
      }
    });
  }
}
