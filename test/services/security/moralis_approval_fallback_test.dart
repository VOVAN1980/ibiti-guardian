import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ibiti_guardian/services/ankr/ankr_config_service.dart';
import 'package:ibiti_guardian/services/moralis/moralis_config_service.dart';
import 'package:ibiti_guardian/services/security/approval_scan_service.dart';

const _owner = '0x1111111111111111111111111111111111111111';
const _token = '0x2222222222222222222222222222222222222222';
const _spender = '0x3333333333333333333333333333333333333333';
Map<String, dynamic> _row(String spender) => {
      'token': {
        'address': _token,
        'name': 'Token',
        'symbol': 'TOK',
        'decimals': 6
      },
      'spender': {'address': spender},
      'value': '7'
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
      if (utf8.decode(message!.buffer.asUint8List()) !=
          'secrets/moralis.json') {
        return null;
      }
      return ByteData.sublistView(
          Uint8List.fromList(utf8.encode('{"MORALIS_API_KEY":"synthetic"}')));
    });
    await MoralisConfigService.instance.init();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });
  setUp(() {
    AnkrConfigService.instance.setKeyForTest('');
    ApprovalScanService.sourceOverride = null;
    ApprovalScanService.lastRiskScore = 17;
    ApprovalScanService.lastScanTime = DateTime.utc(2026, 10, 9);
  });
  tearDown(() {
    ApprovalScanService.moralisClientFactory = null;
    ApprovalScanService.lastRiskScore = null;
    ApprovalScanService.lastScanTime = null;
    ApprovalScanService.hasRiskyApprovals = false;
    ApprovalScanService.lastScannedApprovals = [];
  });
  test('reserve Moralis source walks all cursors without dropping approvals',
      () async {
    var calls = 0;
    ApprovalScanService.moralisClientFactory =
        () => MockClient((request) async {
              calls++;
              expect(request.headers['X-API-Key'], 'synthetic');
              expect(request.url.queryParameters['cursor'],
                  calls == 1 ? null : 'next');
              return http.Response(
                  jsonEncode({
                    'result': [_row(calls == 1 ? _spender : _owner)],
                    'cursor': calls == 1 ? 'next' : null
                  }),
                  200);
            });
    final rows = await ApprovalScanService.scan(_owner, chainId: 56);
    expect(calls, 2);
    expect(rows, hasLength(2));
    expect(rows.every((a) => a.walletAddress == _owner), true);
  });
  test('401 is not retried and does not erase last score', () async {
    var calls = 0;
    ApprovalScanService.moralisClientFactory = () => MockClient((_) async {
          calls++;
          return http.Response('private raw key', 401);
        });
    await expectLater(ApprovalScanService.scan(_owner),
        throwsA(isNot(contains('private raw key'))));
    expect(calls, 1);
    expect(ApprovalScanService.lastRiskScore, 17);
  });
  test('failure after page 1 rejects entire reserve scan', () async {
    var calls = 0;
    ApprovalScanService.moralisClientFactory = () => MockClient((_) async {
          calls++;
          return calls == 1
              ? http.Response(
                  jsonEncode({
                    'result': [_row(_spender)],
                    'cursor': 'next'
                  }),
                  200)
              : http.Response('paused', 401);
        });
    await expectLater(ApprovalScanService.scan(_owner), throwsA(anything));
    expect(calls, 2);
    expect(ApprovalScanService.lastRiskScore, 17);
  });
  test('missing result is not interpreted as safe empty', () async {
    ApprovalScanService.moralisClientFactory =
        () => MockClient((_) async => http.Response('{}', 200));
    await expectLater(ApprovalScanService.scan(_owner), throwsA(anything));
    expect(ApprovalScanService.lastRiskScore, 17);
  });
  test('malformed allowance/address row cannot be silently skipped', () async {
    ApprovalScanService.moralisClientFactory =
        () => MockClient((_) async => http.Response(
            jsonEncode({
              'result': [
                {
                  ..._row(_spender),
                  'value': 'bad',
                  'token': {'address': 'bad'}
                }
              ]
            }),
            200));
    await expectLater(ApprovalScanService.scan(_owner), throwsA(anything));
  });
  test('repeated reserve cursor fails instead of looping', () async {
    var calls = 0;
    ApprovalScanService.moralisClientFactory = () => MockClient((_) async {
          calls++;
          return http.Response(
              jsonEncode({
                'result': [_row(_spender)],
                'cursor': 'cycle'
              }),
              200);
        });
    await expectLater(ApprovalScanService.scan(_owner), throwsA(anything));
    expect(calls, 2);
  });
}
