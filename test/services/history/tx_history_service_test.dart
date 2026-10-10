import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ibiti_guardian/models/on_chain_tx.dart';
import 'package:ibiti_guardian/services/ankr/ankr_config_service.dart';
import 'package:ibiti_guardian/services/ankr/ankr_tx_history_service.dart';
import 'package:ibiti_guardian/services/history/tx_history_service.dart';
import 'package:ibiti_guardian/services/history/tx_history_source.dart';

class _FakeSource implements TxHistorySource {
  _FakeSource(
    this.name, {
    this.configured = true,
    this.failure,
    this.next,
    this.chains = const {'bsc'},
  });

  @override
  final String name;
  final bool configured;
  final String? failure;
  final String? next;
  final Set<String> chains;
  final List<String?> cursors = [];

  @override
  bool supports(String chainKey) => chains.contains(chainKey);

  @override
  Future<bool> isConfigured() async => configured;

  @override
  Future<HistoryPage> fetch({
    required String address,
    required String chainKey,
    String? cursor,
  }) async {
    cursors.add(cursor);
    if (failure != null) throw TxHistoryUnavailable(failure!);
    return HistoryPage([_tx(name)], next);
  }
}

OnChainTx _tx(String hash) => OnChainTx(
      hash: hash,
      type: OnChainTxType.receive,
      from: '0xa',
      to: '0xb',
      value: 1,
      blockTimestamp: DateTime.utc(2026, 10, 10),
      isSuccess: true,
      chainKey: 'bsc',
    );

void main() {
  tearDown(() {
    TxHistoryService.sources = [];
  });

  test('the first source that answers wins, even when an earlier one failed',
      () async {
    final broken = _FakeSource('a', failure: 'HTTP 401');
    final good = _FakeSource('b', next: 'c1');
    TxHistoryService.sources = [broken, good];
    final page = await TxHistoryService.fetch(address: '0x1', chainKey: 'bsc');
    expect(page.transactions.single.hash, 'b');
    expect(page.nextCursor, 'b|c1', reason: 'a cursor belongs to its source');
  });

  test('an unconfigured or unsupporting source is skipped without an error',
      () async {
    final unconfigured = _FakeSource('a', configured: false);
    final wrongChain = _FakeSource('b', chains: {'eth'});
    final good = _FakeSource('c');
    TxHistoryService.sources = [unconfigured, wrongChain, good];
    final page = await TxHistoryService.fetch(address: '0x1', chainKey: 'bsc');
    expect(page.transactions.single.hash, 'c');
    expect(unconfigured.cursors, isEmpty);
    expect(wrongChain.cursors, isEmpty);
  });

  test('a next page goes only to the source that produced its cursor',
      () async {
    final a = _FakeSource('a');
    final b = _FakeSource('b');
    TxHistoryService.sources = [a, b];
    await TxHistoryService.fetch(
        address: '0x1', chainKey: 'bsc', cursor: 'b|ts:99');
    expect(a.cursors, isEmpty);
    expect(b.cursors, ['ts:99']);
  });

  test(
      'when every source fails the reasons are reported, never an empty history',
      () async {
    TxHistoryService.sources = [
      _FakeSource('a', failure: 'HTTP 403'),
      _FakeSource('b', failure: 'HTTP 401'),
    ];
    await expectLater(
      TxHistoryService.fetch(address: '0x1', chainKey: 'bsc'),
      throwsA(isA<TxHistoryUnavailable>().having(
        (e) => e.message,
        'message',
        'a: HTTP 403; b: HTTP 401',
      )),
    );
  });

  test('with nothing configured the screen gets an error, not an empty list',
      () async {
    TxHistoryService.sources = [_FakeSource('a', configured: false)];
    await expectLater(
      TxHistoryService.fetch(address: '0x1', chainKey: 'bsc'),
      throwsA(isA<TxHistoryUnavailable>()),
    );
  });

  group('Ankr source', () {
    const key = 'SECRET-KEY-123';
    late AnkrConfigService config;

    setUp(() {
      config = AnkrConfigService.instance..setKeyForTest(key);
    });
    tearDown(() => config.setKeyForTest(''));

    AnkrTxHistoryService service(http.Client client) =>
        AnkrTxHistoryService(client: client, config: config);

    test(
        'asks for transactions and token transfers, newest first, and merges them',
        () async {
      final seen = <String, Map<String, dynamic>>{};
      final client = MockClient((request) async {
        expect(request.url.toString(), 'https://rpc.ankr.com/multichain/$key');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final method = body['method'] as String;
        seen[method] = body['params'] as Map<String, dynamic>;
        if (method == 'ankr_getTransactionsByAddress') {
          return http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'result': {
                'transactions': [
                  {
                    'hash': '0xaa',
                    'from': '0x1010101010101010101010101010101010101010',
                    'to': '0x7c1ba66011c65603caa7f892069e9b330406ac39',
                    'value': '0x0',
                    'status': '0x1',
                    'input': '0x',
                    'gasUsed': '0x5208',
                    'gasPrice': '0x3b9aca00',
                    'timestamp': '0x6700a000',
                  }
                ],
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'result': {
              'transfers': [
                {
                  'transactionHash': '0xaa',
                  'fromAddress': '0x7c1ba66011c65603caa7f892069e9b330406ac39',
                  'toAddress': '0x1010101010101010101010101010101010101010',
                  'tokenSymbol': 'USDT',
                  'tokenName': 'Tether USD',
                  'tokenDecimals': 18,
                  'contractAddress':
                      '0x55d398326f99059ff775485246999027b3197955',
                  'value': '0.5',
                  'timestamp': 1728127000,
                }
              ],
            },
          }),
          200,
        );
      });

      final page = await service(client).fetch(
        address: '0x1010101010101010101010101010101010101010',
        chainKey: 'bsc',
      );
      expect(page.transactions, hasLength(1));
      expect(page.transactions.single.tokenSymbol, 'USDT');
      expect(page.nextCursor, isNull, reason: 'fewer entries than a full page');
      expect(seen['ankr_getTransactionsByAddress']!['blockchain'], ['bsc']);
      expect(seen['ankr_getTokenTransfers']!['descOrder'], isTrue);
      expect(seen['ankr_getTokenTransfers']!['address'], isA<List>());
      expect(seen['ankr_getTransactionsByAddress']!['address'], isA<String>());
    });

    test('a refusal is an error that never contains the key', () async {
      final client =
          MockClient((_) async => http.Response('{"error":"nope"}', 403));
      Object? caught;
      try {
        await service(client).fetch(address: '0x1', chainKey: 'bsc');
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<TxHistoryUnavailable>());
      expect(caught.toString(), 'HTTP 403');
      expect(caught.toString(), isNot(contains(key)));
    });

    test('a JSON-RPC error is reported without its raw message', () async {
      final client = MockClient((_) async => http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'error': {'code': -32000, 'message': 'rate limit'},
            }),
            200,
          ));
      await expectLater(
        service(client).fetch(address: '0x1', chainKey: 'bsc'),
        throwsA(isA<TxHistoryUnavailable>()
            .having((e) => e.message, 'message', 'JSON-RPC error (-32000)')),
      );
    });

    test('a full final page does not invent a timestamp cursor', () async {
      List<Map<String, dynamic>> txs(int n) => [
            for (var i = 0; i < n; i++)
              {
                'hash': '0x${i.toRadixString(16).padLeft(4, '0')}',
                'from': '0x1010101010101010101010101010101010101010',
                'to': '0x7c1ba66011c65603caa7f892069e9b330406ac39',
                'value': '0x1',
                'status': '0x1',
                'input': '0x',
                'gasUsed': '0x5208',
                'gasPrice': '0x1',
                'timestamp': '0x${(0x6700a000 - i).toRadixString(16)}',
              }
          ];
      final client = MockClient((request) async {
        final method = (jsonDecode(request.body) as Map)['method'];
        final result = method == 'ankr_getTransactionsByAddress'
            ? {'transactions': txs(AnkrTxHistoryService.pageSize)}
            : {'transfers': <Map<String, dynamic>>[]};
        return http.Response(
            jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': result}), 200);
      });
      final page = await service(client).fetch(
        address: '0x1010101010101010101010101010101010101010',
        chainKey: 'bsc',
      );
      expect(page.transactions, hasLength(AnkrTxHistoryService.pageSize));
      expect(page.nextCursor, isNull);
    });
  });
}
