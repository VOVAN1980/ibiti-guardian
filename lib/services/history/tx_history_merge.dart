import 'package:ibiti_guardian/models/on_chain_tx.dart';

/// New pages can add transfer details to a transaction loaded earlier. Keep the
/// complete updated row, one per hash, in chronological order across streams.
List<OnChainTx> mergeHistoryPages(
  List<OnChainTx> existing,
  List<OnChainTx> incoming,
) {
  final byHash = {
    for (final tx in [...existing, ...incoming]) tx.hash.toLowerCase(): tx,
  };
  return byHash.values.toList()
    ..sort((a, b) {
      final timeOrder = b.blockTimestamp.compareTo(a.blockTimestamp);
      return timeOrder != 0 ? timeOrder : a.hash.compareTo(b.hash);
    });
}
