import 'package:ibiti_guardian/models/intent_data.dart';

/// Turns an intent parsed from LLM output into one the app may act on.
///
/// The model's JSON is untrusted: a web page, search result or token name it
/// read can steer it. So only the user-level meaning survives — operation
/// type, token symbols, amount, slippage. Everything that decides what is
/// actually signed (atomic amount, token contracts, decimals, origin,
/// automation trigger, the Buy / Sell window marker
/// [IntentData.userTradeWindow], the swap amount mode) is dropped and
/// re-derived by the app from its own registries, and a recipient address is
/// kept only when the user typed it or it is already in their address book.
///
/// A swap amount is always what the user PAYS (exact input): the swap step,
/// its approve and every USD check — the swap limit, the daily trading
/// limit, «AI Мандат» max position, the AI card — value that amount at the
/// paying coin's price. The model's `exactOut` would make its amount the
/// coin to RECEIVE, valued at the wrong coin's price (a 0.5 ETH buy counted
/// as 0.5 BNB). So the model never sets the amount mode, and a swap amount
/// it marked `exactOut` is dropped: the user gives the amount to pay.
class LlmIntentGuard {
  LlmIntentGuard._();

  /// Minimum length for an address to count as "typed by the user" —
  /// shorter strings could match by accident.
  static const _minAddressLength = 26;

  /// Returns null when the intent must not be acted on: either there was none,
  /// or it asks for an execution after the model read untrusted content.
  static IntentData? sanitize(
    IntentData? intent, {
    required String userText,
    required bool untrustedContext,
    Iterable<String> knownAddresses = const [],
  }) {
    if (intent == null) return null;
    if (untrustedContext && intent.isExecutionIntent) return null;

    // An amount the model marked as the coin to receive is not an amount to
    // pay: never valued, quoted or signed as one (see the class doc).
    final receiveAmount = intent.type == IntentType.swapAsset &&
        intent.amountMode == AmountMode.exactOut;

    return IntentData(
      type: intent.type,
      rawInput: userText,
      tokenSymbol: intent.tokenSymbol,
      toAddress: _verifiedRecipient(intent.toAddress, userText, knownAddresses),
      amount: receiveAmount ? null : intent.amount,
      sourceTokenSymbol: intent.sourceTokenSymbol,
      targetTokenSymbol: intent.targetTokenSymbol,
      // No amountMode (always exact input), no origin (market), no
      // sourceTrigger (not automation) and never the Buy / Sell window.
      slippageBps: intent.slippageBps,
      isQuantity: intent.isQuantity,
      userTradeWindow: false,
    );
  }

  /// Whether [address] was typed by the user or is in their address book.
  static bool isVerifiedRecipient(
    String? address, {
    required String userText,
    Iterable<String> knownAddresses = const [],
  }) =>
      _verifiedRecipient(address, userText, knownAddresses) != null;

  static String? _verifiedRecipient(
    String? address,
    String userText,
    Iterable<String> knownAddresses,
  ) {
    final candidate = address?.trim();
    if (candidate == null || candidate.length < _minAddressLength) return null;

    final lower = candidate.toLowerCase();
    if (userText.toLowerCase().contains(lower)) return candidate;
    for (final known in knownAddresses) {
      if (known.trim().toLowerCase() == lower) return known.trim();
    }
    return null;
  }
}
