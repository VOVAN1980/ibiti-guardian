import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ibiti_guardian/services/ankr/ankr_approval_source.dart';
import 'package:ibiti_guardian/services/ankr/ankr_config_service.dart';
import 'package:ibiti_guardian/services/security/approval_source.dart';
import 'package:ibiti_guardian/services/token_metadata_cache.dart';

const _owner = '0x1111111111111111111111111111111111111111';
const _token = '0x2222222222222222222222222222222222222222';
const _spender = '0x3333333333333333333333333333333333333333';
final _now = DateTime.utc(2026, 10, 10, 12);
String _word(int n) => '0x${n.toRadixString(16).padLeft(64, '0')}';
String _topic(String address) => '0x${address.substring(2).padLeft(64, '0')}';
Map<String, dynamic> _log(
        {String token = _token,
        String spender = _spender,
        int block = 10,
        String owner = _owner}) =>
    {
      'blockchain': 'bsc',
      'address': token,
      'removed': false,
      'blockNumber': '0x${block.toRadixString(16)}',
      'topics': [
        AnkrApprovalSource.approvalTopic,
        _topic(owner),
        _topic(spender)
      ],
      'data': _word(100),
    };

class _Fixture {
  final requests = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> indexed = [_log()];
  List<Map<String, dynamic>> tail = [];
  int indexTip = 990;
  bool reorg = false;
  bool stale = false;
  bool missingLogs = false;
  bool cycle = false;
  bool neverEnding = false;
  bool failSecondPage = false;
  bool twoPages = false;
  bool symbolReverts = false;
  bool symbolHttpFails = false;
  bool missingSync = false;
  String syncState = 'synced';
  DateTime? syncTime;
  bool timeout = false;
  int allowance = 7;
  int decimals = 6;
  String? malformedAllowance;
  String? badSymbol;
  int chainId = 56;
  String chain = 'bsc';
  int page = 0;
  String? transientMethod;
  int transientFailures = 0;
  int transientStatus = 503;
  int? transientRpcCode;
  bool transientTimeout = false;
  bool transientConnectionError = false;
  final clients = <_TrackedClient>[];
  _TrackedClient get client => clients.last;
  http.Client createClient() {
    final next = _TrackedClient(MockClient(respond));
    clients.add(next);
    return next;
  }

  Future<http.Response> respond(http.Request request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    requests.add(body);
    final method = body['method'];
    final params = body['params'];
    if (method == transientMethod && transientFailures-- > 0) {
      if (transientTimeout) throw TimeoutException('private endpoint and key');
      if (transientConnectionError) {
        throw http.ClientException('private endpoint and key', request.url);
      }
      if (transientRpcCode == null) {
        return http.Response('private provider body', transientStatus);
      }
      return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': body['id'],
            'error': {
              'code': transientRpcCode,
              'message': 'private provider body'
            },
          }),
          200);
    }
    dynamic result;
    dynamic error;
    switch (method) {
      case 'eth_chainId':
        result = '0x${chainId.toRadixString(16)}';
      case 'eth_getBlockByNumber':
        expect(params[1], false);
        final timestamp = _now
                .subtract(Duration(minutes: stale ? 3 : 0))
                .millisecondsSinceEpoch ~/
            1000;
        result = {
          'number': '0x3e8',
          'hash': _word(reorg && params[0] != 'latest' ? 2 : 1),
          'timestamp': '0x${timestamp.toRadixString(16)}'
        };
      case 'ankr_getLogs':
        page++;
        expect(params['fromBlock'], 0);
        expect(params['toBlock'], 1000);
        expect(params['blockchain'], [chain]);
        expect(params['topics'], [
          [AnkrApprovalSource.approvalTopic],
          [_topic(_owner)]
        ]);
        result = {
          if (!missingSync)
            'syncStatus': {
              'status': syncState,
              'blockNumber': indexTip,
              'timestamp': (syncTime ?? _now).millisecondsSinceEpoch ~/ 1000
            },
          if (!missingLogs) 'logs': page == 1 ? indexed : [_log()],
          if (cycle || neverEnding || (twoPages && page == 1))
            'nextPageToken': neverEnding ? 'page-$page' : 'next'
        };
        if (twoPages && page == 2) expect(params['pageToken'], 'next');
        if (failSecondPage && page == 2) {
          error = {'code': -1, 'message': 'secret raw response'};
        }
      case 'eth_getLogs':
        expect(params[0]['toBlock'], '0x3e8');
        expect(params[0]['topics'],
            [AnkrApprovalSource.approvalTopic, _topic(_owner)]);
        result = tail;
      case 'eth_call':
        expect(params[1], '0x3e8',
            reason: 'All reads must use the captured block');
        final data = params[0]['data'] as String;
        if (data.startsWith('0xdd62ed3e')) {
          expect(data.substring(10, 74), _owner.substring(2).padLeft(64, '0'));
          if (timeout) {
            throw TimeoutException('key and wallet must never escape');
          }
          result = malformedAllowance ?? _word(allowance);
        } else if (data == '0x313ce567') {
          result = _word(decimals);
        } else if (data == '0x95d89b41') {
          if (symbolHttpFails) return http.Response('secret key body', 429);
          if (symbolReverts) {
            error = {'code': 3, 'message': 'execution reverted private body'};
          }
          result = badSymbol ?? '0x${'544f4b'.padRight(64, '0')}';
        } else {
          throw StateError('Unexpected method');
        }
      default:
        throw StateError('Unexpected RPC $method');
    }
    return http.Response(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': body['id'],
          if (error != null) 'error': error else 'result': result
        }),
        200);
  }

  AnkrApprovalSource get source => AnkrApprovalSource(
      clientFactory: createClient, now: () => _now, retryDelay: Duration.zero);
  Future<dynamic> scan({String? target}) =>
      source.fetch(_owner, chainId: 56, targetTokenAddress: target);
}

class _TrackedClient extends http.BaseClient {
  _TrackedClient(this.inner);
  final http.Client inner;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      inner.send(request);
  @override
  void close() {
    closed = true;
    inner.close();
  }
}

Matcher _failure(String code) =>
    throwsA(isA<ApprovalSourceException>().having((e) => e.code, 'code', code));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    AnkrConfigService.instance.setKeyForTest('synthetic-key');
    TokenMetadataCache().clear();
  });
  tearDown(() {
    AnkrConfigService.instance.setKeyForTest('');
    TokenMetadataCache().clear();
  });

  test(
      'walks every page, deduplicates pairs and uses current allowance not event value',
      () async {
    final f = _Fixture()..twoPages = true;
    final approvals = await f.scan();
    expect(f.page, 2);
    expect(approvals, hasLength(1));
    expect(approvals.single.allowance, BigInt.from(7));
    expect(approvals.single.decimals, 6);
    expect(approvals.single.tokenSymbol, 'TOK');
    expect(approvals.single.walletAddress, _owner);
    expect(approvals.single.isVerified, false);
    expect(f.client.closed, true);
    expect(
        f.requests.every((r) => {
              'eth_chainId',
              'eth_getBlockByNumber',
              'ankr_getLogs',
              'eth_getLogs',
              'eth_call'
            }.contains(r['method'])),
        true);
  });
  test('old and latest revoked/consumed allowances are excluded', () async {
    final f = _Fixture()..allowance = 0;
    expect(await f.scan(), isEmpty);
    expect(f.requests.where((r) => r['method'] == 'eth_call').length, 1);
  });
  test('RPC tail discovers fresh approval not yet indexed', () async {
    final f = _Fixture()
      ..indexed = []
      ..tail = [_log(block: 999)];
    expect(await f.scan(), hasLength(1));
  });
  test('empty complete scan still verifies fresh block and RPC tail', () async {
    final f = _Fixture()..indexed = [];
    expect(await f.scan(), isEmpty);
    expect(f.requests.last['method'], 'eth_getBlockByNumber');
    expect(f.requests.any((r) => r['method'] == 'eth_getLogs'), true);
  });
  test('token-only scans constrain both index and RPC by exact contract',
      () async {
    final f = _Fixture();
    expect(await f.scan(target: _token), hasLength(1));
    expect(
        f.requests.firstWhere((r) => r['method'] == 'ankr_getLogs')['params']
            ['address'],
        [_token]);
    expect(
        f.requests.firstWhere((r) => r['method'] == 'eth_getLogs')['params'][0]
            ['address'],
        _token);
  });
  test('does not mistake ERC-721 Approval for ERC-20 allowance', () async {
    final nft = _log();
    (nft['topics'] as List).add(_word(99));
    nft['data'] = '0x';
    final f = _Fixture()..indexed = [nft];
    expect(await f.scan(), isEmpty);
    expect(f.requests.any((r) => r['method'] == 'eth_call'), false);
  });
  test('second page error rejects the whole scan and closes client', () async {
    final f = _Fixture()
      ..twoPages = true
      ..failSecondPage = true;
    await expectLater(f.scan(), _failure('rpc_error'));
    expect(f.client.closed, true);
    expect(f.requests.any((r) => r['method'] == 'eth_call'), false);
  });
  test('missing logs is failure, never an empty safe list', () async {
    final f = _Fixture()..missingLogs = true;
    await expectLater(f.scan(), _failure('invalid_logs'));
  });
  test('repeated cursor is rejected without loop', () async {
    final f = _Fixture()..cycle = true;
    await expectLater(f.scan(), _failure('cursor_cycle'));
    expect(f.page, 2);
  });
  test('bounded pagination never accepts incomplete result', () async {
    final f = _Fixture()..neverEnding = true;
    await expectLater(f.scan(), _failure('page_limit'));
    expect(f.page, 40);
  });
  test('wrong owner or wrong chain logs fail closed', () async {
    final f = _Fixture()..indexed = [_log(owner: _spender)];
    await expectLater(f.scan(), _failure('log_filter_mismatch'));
    final other = _Fixture()
      ..indexed = [
        {..._log(), 'blockchain': 'eth'}
      ];
    await expectLater(other.scan(), _failure('invalid_log'));
  });
  test('removed logs and out-of-range logs fail closed', () async {
    final f = _Fixture()
      ..indexed = [
        {..._log(), 'removed': true}
      ];
    await expectLater(f.scan(), _failure('invalid_log'));
    final other = _Fixture()..indexed = [_log(block: 1001)];
    await expectLater(other.scan(), _failure('log_range_mismatch'));
  });
  test('wrong token in targeted scan fails closed', () async {
    await expectLater(
        _Fixture().scan(target: _spender), _failure('log_token_mismatch'));
  });
  test('wrong chain, stale index and stale RPC cannot give green result',
      () async {
    await expectLater(
        (_Fixture()..chainId = 1).scan(), _failure('chain_mismatch'));
    await expectLater(
        (_Fixture()..indexTip = 400).scan(), _failure('indexer_stale'));
    await expectLater((_Fixture()..stale = true).scan(), _failure('rpc_stale'));
  });
  test('reorg rejects previously collected allowances', () async {
    await expectLater(
        (_Fixture()..reorg = true).scan(), _failure('block_changed'));
  });
  test('missing, unsynced or stale synchronization evidence is rejected',
      () async {
    await expectLater((_Fixture()..missingSync = true).scan(),
        _failure('invalid_index_status'));
    await expectLater((_Fixture()..syncState = 'lagging').scan(),
        _failure('invalid_index_status'));
    await expectLater(
        (_Fixture()..syncTime = _now.subtract(const Duration(minutes: 3)))
            .scan(),
        _failure('rpc_stale'));
  });
  test('pair limit fails before any current allowance can be published',
      () async {
    final f = _Fixture()
      ..indexed = [
        for (var i = 1; i <= 257; i++)
          _log(spender: '0x${i.toRadixString(16).padLeft(40, '0')}')
      ];
    await expectLater(f.scan(), _failure('pair_limit'));
    expect(f.requests.any((r) => r['method'] == 'eth_call'), false);
  });
  test('failed or malformed allowance cannot be treated as revoked', () async {
    await expectLater((_Fixture()..malformedAllowance = '0x').scan(),
        _failure('invalid_call_result'));
    await expectLater(
        (_Fixture()..timeout = true).scan(), _failure('scan_timeout'));
  });
  test('invalid decimals are never guessed', () async {
    await expectLater(
        (_Fixture()..decimals = 256).scan(), _failure('invalid_decimals'));
  });
  test('optional reverting or malicious symbol does not grant trusted identity',
      () async {
    final first = await (_Fixture()..symbolReverts = true).scan();
    expect(first.single.tokenSymbol, isNot('TOK'));
    final second =
        await (_Fixture()..badSymbol = '0x${'0a'.padRight(64, '0')}').scan();
    expect(second.single.tokenSymbol, isNot(contains('\n')));
    expect(second.single.isVerified, false);
  });
  test('network error on optional metadata is not swallowed', () async {
    await expectLater(
        (_Fixture()..symbolHttpFails = true).scan(), _failure('http_429'));
  });
  test('invalid address and unsupported chain do not call network', () async {
    final f = _Fixture();
    await expectLater(
        f.source.fetch('bad', chainId: 56), _failure('invalid_address'));
    await expectLater(
        f.source.fetch(_owner, chainId: 999), _failure('unsupported_chain'));
    expect(f.requests, isEmpty);
  });
  test('provider exception content never escapes', () async {
    final source = AnkrApprovalSource(
        clientFactory: () => MockClient((_) async {
              throw StateError(
                  'https://rpc.ankr.com/bsc/synthetic-key $_owner raw data');
            }));
    try {
      await source.fetch(_owner, chainId: 56);
      fail('Must reject');
    } on ApprovalSourceException catch (e) {
      expect(e.code, 'network_error');
      expect(e.toString(), isNot(contains('synthetic-key')));
      expect(e.toString(), isNot(contains(_owner)));
      expect(e.toString(), isNot(contains('https://')));
    }
  });
  test('supports existing monitoring chains without cross-chain fallback',
      () async {
    for (final entry in {
      1: 'eth',
      56: 'bsc',
      137: 'polygon',
      42161: 'arbitrum',
      10: 'optimism',
      8453: 'base',
      100: 'gnosis'
    }.entries) {
      final f = _Fixture()
        ..chain = entry.value
        ..chainId = entry.key
        ..indexed = [];
      expect(await f.source.fetch(_owner, chainId: entry.key), isEmpty);
      expect(f.requests.first['method'], 'eth_chainId');
    }
  });

  test('temporary timeouts restart only the failed read with a fresh client',
      () async {
    final f = _Fixture()
      ..transientMethod = 'ankr_getLogs'
      ..transientFailures = 1
      ..transientTimeout = true;
    expect(await f.scan(), hasLength(1));
    expect(
        f.requests.where((r) => r['method'] == 'ankr_getLogs'), hasLength(2));
    expect(f.requests.where((r) => r['method'] == 'eth_chainId'), hasLength(1));
    expect(f.clients, hasLength(2));
    expect(f.clients.every((c) => c.closed), true);
    final pages =
        f.requests.where((r) => r['method'] == 'ankr_getLogs').toList();
    expect(pages[0]['params'], pages[1]['params']);
    expect(pages[0]['id'], isNot(pages[1]['id']));
  });

  test('temporary network failures, HTTP 429/503 and gateway timeout recover',
      () async {
    for (final kind in ['connection', '429', '503', 'rpc']) {
      final f = _Fixture()
        ..transientMethod = 'ankr_getLogs'
        ..transientFailures = 1
        ..transientConnectionError = kind == 'connection'
        ..transientStatus = kind == '429' ? 429 : 503
        ..transientRpcCode = kind == 'rpc' ? -32071 : null;
      expect(await f.scan(), hasLength(1));
      expect(
          f.requests.where((r) => r['method'] == 'ankr_getLogs'), hasLength(2));
      expect(f.clients.every((c) => c.closed), true);
    }
  });

  test('persistent transient failure is bounded to three attempts, not green',
      () async {
    final f = _Fixture()
      ..transientMethod = 'ankr_getLogs'
      ..transientFailures = 10;
    await expectLater(f.scan(), _failure('http_503'));
    expect(
        f.requests.where((r) => r['method'] == 'ankr_getLogs'), hasLength(3));
    expect(f.requests.any((r) => r['method'] == 'eth_getLogs'), false);
    expect(f.clients.every((c) => c.closed), true);
  });

  test('auth, invalid JSON, contract failures and bad schema are never retried',
      () async {
    for (final status in [400, 401, 403, 404]) {
      final f = _Fixture()
        ..transientMethod = 'ankr_getLogs'
        ..transientFailures = 10
        ..transientStatus = status;
      await expectLater(f.scan(), _failure('http_$status'));
      expect(
          f.requests.where((r) => r['method'] == 'ankr_getLogs'), hasLength(1));
    }
    for (final code in [-32602, -32050, -32075, 3]) {
      final f = _Fixture()
        ..transientMethod = 'ankr_getLogs'
        ..transientFailures = 10
        ..transientRpcCode = code;
      await expectLater(f.scan(), _failure('rpc_error'));
      expect(
          f.requests.where((r) => r['method'] == 'ankr_getLogs'), hasLength(1));
    }
    final revertedAllowance = _Fixture()
      ..transientMethod = 'eth_call'
      ..transientFailures = 10
      ..transientRpcCode = 3;
    await expectLater(revertedAllowance.scan(), _failure('contract_reverted'));
    expect(revertedAllowance.requests.where((r) => r['method'] == 'eth_call'),
        hasLength(1));
    var calls = 0;
    final source = AnkrApprovalSource(
        clientFactory: () => MockClient((_) async {
              calls++;
              return http.Response('invalid private JSON', 200);
            }));
    await expectLater(
        source.fetch(_owner, chainId: 56), _failure('invalid_json'));
    expect(calls, 1);
    final malformed = _Fixture()..missingLogs = true;
    await expectLater(malformed.scan(), _failure('invalid_logs'));
    expect(malformed.page, 1);
  });

  test('a timed-out response is discarded, its client closes before retry',
      () async {
    final f = _Fixture()..indexed = [];
    final lateResponse = Completer<http.Response>();
    final clients = <_TrackedClient>[];
    var calls = 0;
    final source = AnkrApprovalSource(
      now: () => _now,
      requestTimeout: const Duration(milliseconds: 20),
      retryDelay: Duration.zero,
      clientFactory: () {
        if (clients.isNotEmpty) expect(clients.last.closed, true);
        final client = _TrackedClient(MockClient((request) async {
          if (++calls == 1) return lateResponse.future;
          return f.respond(request);
        }));
        clients.add(client);
        return client;
      },
    );
    expect(await source.fetch(_owner, chainId: 56), isEmpty);
    expect(clients, hasLength(2));
    expect(clients.every((c) => c.closed), true);
    final count = calls;
    lateResponse.complete(http.Response('private late invalid response', 200));
    await Future<void>.delayed(Duration.zero);
    expect(calls, count);
  });

  test('total deadline closes a hung request without starting later stages',
      () async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final client = _TrackedClient(MockClient((request) async {
      calls++;
      return pending.future;
    }));
    final source = AnkrApprovalSource(
      clientFactory: () => client,
      requestTimeout: const Duration(seconds: 20),
      scanBudget: const Duration(milliseconds: 20),
      retryDelay: Duration.zero,
    );
    await expectLater(
        source.fetch(_owner, chainId: 56), _failure('scan_timeout'));
    expect(calls, 1);
    expect(client.closed, true);
    pending.complete(http.Response('late body', 200));
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
  });

  test('Retry-After cannot extend the total scan deadline', () async {
    var calls = 0;
    final source = AnkrApprovalSource(
        scanBudget: const Duration(seconds: 1),
        clientFactory: () => MockClient((_) async {
              calls++;
              return http.Response('private rate-limit body', 429,
                  headers: {'retry-after': '120'});
            }));
    await expectLater(
        source.fetch(_owner, chainId: 56), _failure('scan_timeout'));
    expect(calls, 1);
  });

  test('retry diagnostics contain only methods/codes/counts, never secrets',
      () async {
    final original = debugPrint;
    final lines = <String>[];
    debugPrint = (String? line, {int? wrapWidth}) => lines.add(line ?? '');
    try {
      final f = _Fixture()
        ..transientMethod = 'eth_chainId'
        ..transientFailures = 1
        ..transientConnectionError = true;
      await f.scan();
      expect(lines.join(), contains('method=eth_chainId'));
      for (final value in [
        'synthetic-key',
        _owner,
        _token,
        _spender,
        'private',
        'https://',
        'params',
        'body'
      ]) {
        expect(lines.join(), isNot(contains(value)));
      }
    } finally {
      debugPrint = original;
    }
  });
}
