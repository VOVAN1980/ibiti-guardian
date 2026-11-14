import 'package:ibiti_guardian/models/on_chain_tx.dart';

/// Junk that anyone can push into a wallet's history without its consent:
/// - airdrops of worthless tokens nobody asked for, often named to lure the
///   owner to a scam site or into "selling" them through a malicious contract;
/// - zero-amount transfers from look-alike addresses ("address poisoning"),
///   planted so the owner later copies the wrong address from the history.
///
/// Used by the History screen while the wallet's spam filter is on.
class TxSpamFilter {
  const TxSpamFilter._();

  /// [isKnownToken] says whether a token contract is a real, recognised one
  /// (built-in list, the wallet's core tokens, tokens the user imported).
  /// [sentTokens] are contracts the user has sent from this wallet: a token
  /// the owner moves themselves is theirs, never spam.
  static bool isSpam(
    OnChainTx tx, {
    required bool Function(String contract) isKnownToken,
    Set<String> sentTokens = const {},
  }) {
    final moves =
        tx.type == OnChainTxType.receive || tx.type == OnChainTxType.send;
    if (!moves) return false;

    final contract = tx.contractAddress?.toLowerCase() ?? '';
    final isToken = contract.isNotEmpty;

    // Nothing moved, only an address was planted in the history.
    if (isToken && tx.value <= 0) return true;

    if (!isToken || tx.type != OnChainTxType.receive) return false;
    if (sentTokens.contains(contract)) return false;
    return !isKnownToken(contract);
  }
}
