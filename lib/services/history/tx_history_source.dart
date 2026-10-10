import 'package:ibiti_guardian/models/on_chain_tx.dart';

/// One page of wallet history plus the cursor for the next (older) page.
class HistoryPage {
  final List<OnChainTx> transactions;
  final String? nextCursor;
  const HistoryPage(this.transactions, this.nextCursor);
}

/// A history source could not answer. The message is short, human-readable and
/// never contains an API key. The history screen shows it with a retry button
/// instead of pretending that the wallet has no transactions.
class TxHistoryUnavailable implements Exception {
  final String message;
  const TxHistoryUnavailable(this.message);

  @override
  String toString() => message;
}

/// A service that can list a wallet's transactions (Ankr, Moralis, ...).
abstract class TxHistorySource {
  /// Short stable id, also used as the cursor prefix.
  String get name;

  bool supports(String chainKey);

  /// False when the source has no usable key: the next source is tried.
  Future<bool> isConfigured();

  /// Throws [TxHistoryUnavailable] when the source cannot answer.
  Future<HistoryPage> fetch({
    required String address,
    required String chainKey,
    String? cursor,
  });
}
