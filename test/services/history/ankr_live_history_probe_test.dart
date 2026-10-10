import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:ibiti_guardian/models/on_chain_tx.dart';
import 'package:ibiti_guardian/services/ankr/ankr_config_service.dart';
import 'package:ibiti_guardian/services/ankr/ankr_tx_history_service.dart';
import 'package:ibiti_guardian/services/history/tx_history_merge.dart';
import 'package:ibiti_guardian/services/history/tx_history_service.dart';

// Explicitly opt-in: ordinary tests must never consume provider quotas or keys.
void main() {
  test('live Ankr history walks native page tokens through the app facade',
      () async {
    final config = AnkrConfigService.instance;
    final savedSources = TxHistoryService.sources;
    final client = HttpOverrides.runWithHttpOverrides(
        () => _CountingClient(IOClient(HttpClient())), _LiveHttpOverrides());
    var pages = 0;
    var history = <OnChainTx>[];
    String? cursor;
    var complete = false;
    try {
      final local = jsonDecode(File('secrets/ankr.json').readAsStringSync())
          as Map<String, dynamic>;
      final key = local['ANKR_API_KEY'];
      if (key is! String || key.trim().isEmpty) {
        throw const FormatException('Local key is not configured');
      }
      config.setKeyForTest(key.trim());
      // Explicit operator input only; never commit or print a user's wallet.
      final address = Platform.environment['ANKR_PROBE_WALLET_ADDRESS'];
      if (address == null ||
          !RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(address)) {
        throw const FormatException('Probe wallet address is not configured');
      }
      TxHistoryService.sources = [
        AnkrTxHistoryService(client: client, config: config),
      ];
      do {
        final page = await TxHistoryService.fetch(
          address: address,
          chainKey: 'bsc',
          cursor: cursor,
        );
        pages++;
        history = mergeHistoryPages(history, page.transactions);
        cursor = page.nextCursor;
      } while (cursor != null && pages < 20);
      complete = cursor == null;
      expect(complete, isTrue,
          reason: 'Bounded walk must reach the final page');
      expect(pages, greaterThan(1),
          reason: 'Check actual continuation, not page 1');
      expect(history, isNotEmpty);
      expect(history.every((tx) => tx.hash.isNotEmpty), isTrue);
      expect(client.statuses.every((status) => status == 200), isTrue);
      expect(history.map((tx) => tx.hash.toLowerCase()).toSet().length,
          history.length);
    } catch (error) {
      // Never surface raw provider objects, URLs, keys or exception content.
      fail('Live history probe failed (${error.runtimeType})');
    } finally {
      // Metadata only; raw transactions, addresses and amounts are not logged.
      // ignore: avoid_print
      print(jsonEncode({
        'source': 'ankr',
        'chain': 'bsc',
        'pages': pages,
        'httpCalls': client.statuses.length,
        'httpStatuses': client.statuses,
        'uniqueOperations': history.length,
        'receivedOperations':
            history.where((tx) => tx.type == OnChainTxType.receive).length,
        'operationsWithKnownFee':
            history.where((tx) => tx.feeNative != null).length,
        'complete': complete,
        'readOnly': true,
      }));
      client.close();
      config.setKeyForTest('');
      TxHistoryService.sources = savedSources;
    }
  },
      skip: Platform.environment['RUN_ANKR_HISTORY_PROBE'] != 'true',
      timeout: const Timeout(Duration(minutes: 2)));
}

class _LiveHttpOverrides extends HttpOverrides {}

class _CountingClient extends http.BaseClient {
  _CountingClient(this._inner);
  final http.Client _inner;
  final statuses = <int>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    statuses.add(response.statusCode);
    return response;
  }

  @override
  void close() => _inner.close();
}
