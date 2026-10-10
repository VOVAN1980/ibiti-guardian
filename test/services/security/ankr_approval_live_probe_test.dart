import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:ibiti_guardian/services/ankr/ankr_approval_source.dart';
import 'package:ibiti_guardian/services/ankr/ankr_config_service.dart';
import 'package:ibiti_guardian/services/security/approval_scan_service.dart';
import 'package:ibiti_guardian/services/security/approval_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'opt-in complete BSC approval scan through production facade (read only)',
      () async {
    final config = AnkrConfigService.instance;
    final originalSource = ApprovalScanService.sourceOverride;
    final clients = <_MetadataClient>[];
    http.Client createClient() {
      final client = HttpOverrides.runWithHttpOverrides(
          () => _MetadataClient(IOClient(HttpClient())), _NetworkOverrides());
      clients.add(client);
      return client;
    }

    List<int> statuses() => [for (final client in clients) ...client.statuses];
    List<String> methods() => [for (final client in clients) ...client.methods];
    final watch = Stopwatch()..start();
    var count = 0;
    String status = 'failed';
    try {
      final local = jsonDecode(File('secrets/ankr.json').readAsStringSync());
      final key = local['ANKR_API_KEY'];
      if (key is! String || key.trim().isEmpty) {
        throw const ApprovalSourceException('missing_key');
      }
      config.setKeyForTest(key.trim());
      // Explicit operator input only; never commit or print a user's wallet.
      final address = Platform.environment['ANKR_PROBE_WALLET_ADDRESS'];
      if (address == null ||
          !RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(address)) {
        throw const ApprovalSourceException('missing_probe_wallet');
      }
      ApprovalScanService.sourceOverride =
          AnkrApprovalSource(clientFactory: createClient);
      final approvals = await ApprovalScanService.scan(address,
          chainId: 56, publishResult: false);
      count = approvals.length;
      expect(
          approvals.every((a) =>
              a.chainId == 56 && a.walletAddress == address.toLowerCase()),
          true);
      expect(approvals.every((a) => a.allowance > BigInt.zero), true);
      expect(statuses().last, 200);
      expect(methods().contains('ankr_getLogs'), true);
      expect(methods().contains('eth_getLogs'), true);
      expect(methods().where((m) => m == 'eth_getBlockByNumber').length,
          greaterThanOrEqualTo(2));
      expect(clients.every((client) => client.closed), true);
      status = 'success';
    } catch (e) {
      fail(
          'Approval probe failed (${e is ApprovalSourceException ? e.code : e.runtimeType})');
    } finally {
      watch.stop();
      // Metadata only: no addresses, allowance values, raw bodies or keys.
      // ignore: avoid_print
      print(jsonEncode({
        'source': 'ankr+rpc',
        'chain': 'bsc',
        'status': status,
        'activeApprovalCount': count,
        'httpCalls': methods().length,
        'httpStatuses': statuses(),
        'methods': methods(),
        'latencyMs': watch.elapsedMilliseconds,
        'readOnly': true
      }));
      for (final client in clients) {
        client.close();
      }
      config.setKeyForTest('');
      ApprovalScanService.sourceOverride = originalSource;
    }
  },
      skip: Platform.environment['RUN_ANKR_APPROVAL_PROBE'] != 'true',
      timeout: const Timeout(Duration(minutes: 2)));
}

class _NetworkOverrides extends HttpOverrides {}

class _MetadataClient extends http.BaseClient {
  _MetadataClient(this.inner);
  final http.Client inner;
  final statuses = <int>[];
  final methods = <String>[];
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request) {
      methods.add((jsonDecode(request.body) as Map)['method'] as String);
    }
    final response = await inner.send(request);
    statuses.add(response.statusCode);
    return response;
  }

  @override
  void close() {
    closed = true;
    inner.close();
  }
}
