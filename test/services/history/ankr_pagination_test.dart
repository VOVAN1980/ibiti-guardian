import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ibiti_guardian/models/on_chain_tx.dart';
import 'package:ibiti_guardian/services/ankr/ankr_config_service.dart';
import 'package:ibiti_guardian/services/ankr/ankr_tx_history_service.dart';
import 'package:ibiti_guardian/services/history/tx_history_merge.dart';
import 'package:ibiti_guardian/services/history/tx_history_source.dart';

const _wallet = '0x1111111111111111111111111111111111111111';
const _contract = '0x2222222222222222222222222222222222222222';
const _key = 'SYNTHETIC-SECRET';
const _time = 1728127000;

Map<String, dynamic> _transaction(String hash, {int time = _time}) => {
      'hash': hash,
      'from': _wallet,
      'to': _contract,
      'timestamp': time,
      'value': '0',
      'status': '1',
      'input': '0x',
      'gasUsed': '21000',
      'gasPrice': '1000000000',
    };

Map<String, dynamic> _transfer(String hash, {int time = _time}) => {
      'transactionHash': hash,
      'fromAddress': _contract,
      'toAddress': _wallet,
      'timestamp': time,
      'tokenSymbol': 'TEST',
      'contractAddress': _contract,
      'value': '0.5',
      'tokenDecimals': 18,
    };

http.Response _response(String field, List<Map<String, dynamic>> rows,
        {String? next}) =>
    http.Response(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {field: rows, if (next != null) 'nextPageToken': next},
      }),
      200,
    );

void main() {
  late AnkrConfigService config;
  setUp(() => config = AnkrConfigService.instance..setKeyForTest(_key));
  tearDown(() => config.setKeyForTest(''));

  AnkrTxHistoryService source(
          Future<http.Response> Function(http.Request) callback) =>
      AnkrTxHistoryService(client: MockClient(callback), config: config);

  test('independent native cursors keep all rows at a shared timestamp',
      () async {
    final calls = <String, List<Object?>>{};
    final service = source((request) async {
      final body = jsonDecode(request.body) as Map;
      final method = body['method'] as String;
      final params = body['params'] as Map;
      expect(params, isNot(contains('toTimestamp')));
      (calls[method] ??= []).add(params['pageToken']);
      final first = params['pageToken'] == null;
      if (method == 'ankr_getTransactionsByAddress') {
        expect(params['address'], _wallet);
        return _response(
            'transactions',
            [
              for (var i = first ? 0 : 25; i < (first ? 25 : 37); i++)
                _transaction('tx$i'),
            ],
            next: first ? 'native-next' : null);
      }
      expect(params['address'], [_wallet]);
      return _response(
          'transfers',
          [
            for (var i = first ? 0 : 25; i < (first ? 25 : 31); i++)
              _transfer('token$i'),
          ],
          next: first ? 'token-next' : null);
    });
    final first = await service.fetch(address: _wallet, chainKey: 'bsc');
    expect(first.transactions, hasLength(50), reason: 'no union truncation');
    expect(first.nextCursor, isNotNull);
    expect(first.nextCursor, isNot(contains(_key)));
    expect(first.nextCursor, isNot(contains('native-next')));
    final last = await service.fetch(
        address: _wallet, chainKey: 'bsc', cursor: first.nextCursor);
    final all = mergeHistoryPages(first.transactions, last.transactions);
    expect(all, hasLength(68));
    expect(all.map((tx) => tx.hash).toSet(), hasLength(68));
    expect(last.nextCursor, isNull);
    expect(calls['ankr_getTransactionsByAddress'], [null, 'native-next']);
    expect(calls['ankr_getTokenTransfers'], [null, 'token-next']);
  });

  test('a finished stream is not restarted and late transfers retain gas',
      () async {
    var transactionCalls = 0;
    var transferCalls = 0;
    final service = source((request) async {
      final body = jsonDecode(request.body) as Map;
      if (body['method'] == 'ankr_getTransactionsByAddress') {
        transactionCalls++;
        return _response('transactions', [_transaction('same')]);
      }
      transferCalls++;
      if (transferCalls == 1) {
        return _response('transfers', [_transfer('newer', time: _time + 1)],
            next: 'older-token-page');
      }
      expect((body['params'] as Map)['pageToken'], 'older-token-page');
      return _response('transfers', [_transfer('same')]);
    });
    final first = await service.fetch(address: _wallet, chainKey: 'bsc');
    final before = first.transactions.singleWhere((tx) => tx.hash == 'same');
    expect(before.type, OnChainTxType.other);
    final last = await service.fetch(
        address: _wallet, chainKey: 'bsc', cursor: first.nextCursor);
    final after = last.transactions.single;
    expect(after.type, OnChainTxType.receive);
    expect(after.value, 0.5);
    expect(after.feeNative, closeTo(0.000021, 1e-12));
    expect(after.gasUsed, '21000');
    final merged = mergeHistoryPages(first.transactions, last.transactions);
    expect(merged, hasLength(2));
    expect(merged.last, same(after));
    expect(transactionCalls, 1);
    expect(transferCalls, 2);
    expect(last.nextCursor, isNull);
  });

  test('late transaction details enrich an already shown token transfer',
      () async {
    var transactionCalls = 0;
    var transferCalls = 0;
    final service = source((request) async {
      final body = jsonDecode(request.body) as Map;
      if (body['method'] == 'ankr_getTokenTransfers') {
        transferCalls++;
        return _response('transfers', [_transfer('same')]);
      }
      transactionCalls++;
      return transactionCalls == 1
          ? _response('transactions', [_transaction('newer', time: _time + 2)],
              next: 'native-next')
          : _response('transactions', [_transaction('same')]);
    });
    final first = await service.fetch(address: _wallet, chainKey: 'bsc');
    final last = await service.fetch(
        address: _wallet, chainKey: 'bsc', cursor: first.nextCursor);
    expect(last.transactions.single.type, OnChainTxType.receive);
    expect(last.transactions.single.tokenSymbol, 'TEST');
    expect(last.transactions.single.feeNative, isNotNull);
    expect(transferCalls, 1);
    expect(transactionCalls, 2);
  });

  test('a transfer with legs split across pages is enriched to a swap',
      () async {
    var transferCalls = 0;
    final service = source((request) async {
      final body = jsonDecode(request.body) as Map;
      if (body['method'] == 'ankr_getTransactionsByAddress') {
        return _response('transactions', [_transaction('swap')]);
      }
      transferCalls++;
      if (transferCalls == 1) {
        return _response('transfers', [_transfer('swap')], next: 'next-leg');
      }
      return _response('transfers', [
        _transfer('swap')
          ..['fromAddress'] = _wallet
          ..['toAddress'] = _contract
          ..['contractAddress'] = '0x3333333333333333333333333333333333333333'
          ..['tokenSymbol'] = 'OTHER'
          ..['value'] = '2',
      ]);
    });
    final first = await service.fetch(address: _wallet, chainKey: 'bsc');
    final last = await service.fetch(
        address: _wallet, chainKey: 'bsc', cursor: first.nextCursor);
    expect(last.transactions.single.type, OnChainTxType.swap);
    expect(last.transactions.single.sellValue, 2);
    expect(last.transactions.single.buyValue, 0.5);
    expect(
        mergeHistoryPages(first.transactions, last.transactions), hasLength(1));
  });

  test('a transient page failure leaves its continuation retryable', () async {
    var transferCalls = 0;
    final tokens = <Object?>[];
    final service = source((request) async {
      final body = jsonDecode(request.body) as Map;
      if (body['method'] == 'ankr_getTransactionsByAddress') {
        return _response('transactions', []);
      }
      tokens.add((body['params'] as Map)['pageToken']);
      transferCalls++;
      if (transferCalls == 1) {
        return _response('transfers', [_transfer('one')], next: 'retry-token');
      }
      if (transferCalls == 2) return http.Response('', 503);
      return _response('transfers', [_transfer('two')]);
    });
    final first = await service.fetch(address: _wallet, chainKey: 'bsc');
    await expectLater(
      service.fetch(
          address: _wallet, chainKey: 'bsc', cursor: first.nextCursor),
      throwsA(isA<TxHistoryUnavailable>()),
    );
    final retried = await service.fetch(
        address: _wallet, chainKey: 'bsc', cursor: first.nextCursor);
    expect(retried.transactions.single.hash, 'two');
    expect(tokens, [null, 'retry-token', 'retry-token']);
  });

  test('wrong-wallet, wrong-chain and unknown cursors fail before network',
      () async {
    var calls = 0;
    final service = source((request) async {
      calls++;
      final body = jsonDecode(request.body) as Map;
      return body['method'] == 'ankr_getTransactionsByAddress'
          ? _response('transactions', [], next: 'next')
          : _response('transfers', []);
    });
    final first = await service.fetch(address: _wallet, chainKey: 'bsc');
    for (final (address, chain, cursor) in [
      (_contract, 'bsc', first.nextCursor),
      (_wallet, 'eth', first.nextCursor),
      (_wallet, 'bsc', 'unknown'),
      (_wallet, 'bsc', 'ts:100'),
    ]) {
      await expectLater(
        service.fetch(address: address, chainKey: chain, cursor: cursor),
        throwsA(isA<TxHistoryUnavailable>()),
      );
    }
    expect(calls, 2);
  });

  test('a provider repeating its page token fails instead of looping',
      () async {
    final service = source((request) async {
      final body = jsonDecode(request.body) as Map;
      return body['method'] == 'ankr_getTransactionsByAddress'
          ? _response('transactions', [_transaction('one')], next: 'same-token')
          : _response('transfers', []);
    });
    final first = await service.fetch(address: _wallet, chainKey: 'bsc');
    await expectLater(
      service.fetch(
          address: _wallet, chainKey: 'bsc', cursor: first.nextCursor),
      throwsA(isA<TxHistoryUnavailable>().having(
          (e) => e.message, 'message', 'history cursor did not advance')),
    );
  });

  test('malformed provider rows are not presented as an empty history',
      () async {
    final service = source((_) async => http.Response(
        jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': {}}), 200));
    await expectLater(
      service.fetch(address: _wallet, chainKey: 'bsc'),
      throwsA(isA<TxHistoryUnavailable>()),
    );
  });

  test('raw provider errors cannot expose a key-bearing endpoint', () async {
    final service = source((_) async => http.Response(
          jsonEncode({
            'error': {
              'code': -32000,
              'message': 'https://rpc.ankr.com/multichain/$_key $_wallet',
            },
          }),
          200,
        ));
    await expectLater(
      service.fetch(address: _wallet, chainKey: 'bsc'),
      throwsA(isA<TxHistoryUnavailable>().having(
          (e) => e.toString(), 'safe diagnostic', 'JSON-RPC error (-32000)')),
    );
  });

  test('history upserts are case-insensitive and globally sorted', () {
    final initial = AnkrTxMapper.map(
      transactions: [
        _transaction('0xAA'),
        _transaction('older', time: _time - 2)
      ],
      transfers: [],
      wallet: _wallet,
      chainKey: 'bsc',
      nativeSymbol: 'BNB',
    );
    final later = AnkrTxMapper.map(
      transactions: [_transaction('0xaa')],
      transfers: [_transfer('0xaa'), _transfer('middle', time: _time - 1)],
      wallet: _wallet,
      chainKey: 'bsc',
      nativeSymbol: 'BNB',
    );
    final merged = mergeHistoryPages(initial, later);
    expect(merged.map((tx) => tx.hash), ['0xaa', 'middle', 'older']);
    expect(merged.first.type, OnChainTxType.receive);
    expect(merged.first.feeNative, isNotNull);
  });
}
