import 'dart:convert';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/models/on_chain_tx.dart';
import 'package:ibiti_guardian/services/history/tx_history_source.dart';
import 'package:ibiti_guardian/services/moralis/moralis_config_service.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';

export 'package:ibiti_guardian/services/history/tx_history_source.dart'
    show HistoryPage;

/// Fetches on-chain transaction history from Moralis /wallets/{address}/history.
/// Supports pagination via cursor.
class MoralisTxHistoryService {
  static const _baseUrl = 'https://deep-index.moralis.io/api/v2.2';
  static const _pageSize = 25;

  /// Fetch a page of on-chain transactions.
  ///
  /// [cursor] is returned from the previous page; pass null for the first page.
  /// Returns ({transactions, nextCursor}).
  static Future<HistoryPage> fetch({
    required String address,
    required String chainKey,
    String? cursor,
  }) async {
    final apiKey = MoralisConfigService.key;
    if (apiKey.isEmpty) return const HistoryPage([], null);

    final chain = PrivyChainRegistry.getChain(chainKey);
    final moralisChain = chain.moralisSlug;
    if (moralisChain == null) return const HistoryPage([], null);

    try {
      final params = {
        'chain': moralisChain,
        'limit': '$_pageSize',
        'include_internal_transactions': 'false',
        if (cursor != null) 'cursor': cursor,
      };
      final uri = Uri.parse('$_baseUrl/wallets/$address/history')
          .replace(queryParameters: params);
      final resp = await http.get(uri, headers: {'X-API-Key': apiKey}).timeout(
        const Duration(seconds: 20),
      );

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final rawList = (data['result'] as List?) ?? [];
        final nextCursor = data['cursor']?.toString();
        final txns = rawList
            .map((e) => OnChainTx.fromMoralisEntry(
                  e as Map<String, dynamic>,
                  address,
                  chainKey,
                ))
            .toList();
        return HistoryPage(txns, nextCursor);
      }
    } catch (e) {
      const log = GuardianLogger('MoralisTxHistory');
      log.e('fetch error', e);
    }
    return const HistoryPage([], null);
  }

  /// Like [fetch], but a refusal or failure is reported instead of being shown
  /// as an empty history (for example "Free usage is paused", HTTP 401).
  static Future<HistoryPage> fetchOrThrow({
    required String address,
    required String chainKey,
    String? cursor,
  }) async {
    final apiKey = MoralisConfigService.key;
    if (apiKey.isEmpty) {
      throw const TxHistoryUnavailable('key is not configured');
    }
    final moralisChain = PrivyChainRegistry.getChain(chainKey).moralisSlug;
    if (moralisChain == null) {
      throw TxHistoryUnavailable('does not serve $chainKey');
    }
    final http.Response resp;
    try {
      final params = {
        'chain': moralisChain,
        'limit': '$_pageSize',
        'include_internal_transactions': 'false',
        if (cursor != null) 'cursor': cursor,
      };
      final uri = Uri.parse('$_baseUrl/wallets/$address/history')
          .replace(queryParameters: params);
      resp = await http.get(uri, headers: {'X-API-Key': apiKey}).timeout(
        const Duration(seconds: 20),
      );
    } catch (e) {
      throw TxHistoryUnavailable('request failed (${e.runtimeType})');
    }
    if (resp.statusCode != 200) {
      throw TxHistoryUnavailable('HTTP ${resp.statusCode}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final rawList = (data['result'] as List?) ?? [];
    final txns = rawList
        .map((e) => OnChainTx.fromMoralisEntry(
              e as Map<String, dynamic>,
              address,
              chainKey,
            ))
        .toList();
    return HistoryPage(txns, data['cursor']?.toString());
  }
}
