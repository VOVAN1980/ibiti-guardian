import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/services/ankr/ankr_tx_history_service.dart';
import 'package:ibiti_guardian/services/history/tx_history_source.dart';
import 'package:ibiti_guardian/services/moralis/moralis_config_service.dart';
import 'package:ibiti_guardian/services/moralis/moralis_tx_history_service.dart';

export 'package:ibiti_guardian/services/history/tx_history_source.dart'
    show HistoryPage, TxHistoryUnavailable;

/// Wallet history for the whole app. Sources are tried in order; the first one
/// that answers wins, even with an empty list. If none can answer, the error
/// is thrown, so the screen shows a retry instead of "no transactions".
class TxHistoryService {
  TxHistoryService._();

  /// Replaceable in tests.
  static List<TxHistorySource> sources = [
    AnkrTxHistoryService(),
    MoralisTxHistorySource(),
  ];

  static Future<HistoryPage> fetch({
    required String address,
    required String chainKey,
    String? cursor,
  }) async {
    // A cursor belongs to the source that produced it: "<source>|<cursor>".
    String? only;
    var raw = cursor;
    if (cursor != null) {
      final bar = cursor.indexOf('|');
      if (bar > 0) {
        only = cursor.substring(0, bar);
        raw = cursor.substring(bar + 1);
      }
    }

    final failures = <String>[];
    for (final source in sources) {
      if (only != null && source.name != only) continue;
      if (!source.supports(chainKey)) continue;
      if (!await source.isConfigured()) continue;
      try {
        final page = await source.fetch(
          address: address,
          chainKey: chainKey,
          cursor: raw,
        );
        final next = page.nextCursor == null
            ? null
            : '${source.name}|${page.nextCursor}';
        return HistoryPage(page.transactions, next);
      } on TxHistoryUnavailable catch (e) {
        failures.add('${source.name}: ${e.message}');
      } catch (e) {
        failures.add('${source.name}: ${e.runtimeType}');
      }
    }
    if (failures.isEmpty) {
      throw const TxHistoryUnavailable(
          'No history source is configured for this network');
    }
    throw TxHistoryUnavailable(failures.join('; '));
  }
}

/// [MoralisTxHistoryService] as a [TxHistorySource].
class MoralisTxHistorySource implements TxHistorySource {
  @override
  String get name => 'moralis';

  @override
  bool supports(String chainKey) =>
      PrivyChainRegistry.getChain(chainKey).moralisSlug != null;

  @override
  Future<bool> isConfigured() async {
    await MoralisConfigService.instance.init();
    return MoralisConfigService.key.isNotEmpty;
  }

  @override
  Future<HistoryPage> fetch({
    required String address,
    required String chainKey,
    String? cursor,
  }) =>
      MoralisTxHistoryService.fetchOrThrow(
        address: address,
        chainKey: chainKey,
        cursor: cursor,
      );
}
