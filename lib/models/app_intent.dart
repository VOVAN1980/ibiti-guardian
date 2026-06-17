/// Unified intent model — all user-initiated actions flow through this.
///
/// One [AppIntent] describes WHAT the user wants to do,
/// regardless of WHERE it was triggered (wallet button / voice / chat).
library app_intent;

enum AppIntentType {
  send,
  receive,
  swap,
  buy,
  sell,
  analyzeMarket,
  scan,
  showBalance,
  showAddress,
  revoke,
  unknown,
}

class AppIntent {
  final AppIntentType type;

  /// Token ticker the user wants to send / swap FROM (e.g. 'USDT').
  final String? sourceToken;

  /// Token ticker the user wants to swap TO (e.g. 'ETH').
  final String? targetToken;

  /// Human-readable amount string (e.g. '10', '0.5').
  final String? amountText;

  /// Destination address for `send`.
  final String? toAddress;

  /// Network identifier (e.g. 'BNB', 'ETH', 'Polygon').
  final String? network;

  /// Where the intent originated — for analytics / voice personalisation.
  /// Values: 'wallet_button' | 'ai_chat' | 'voice' | 'deep_link'
  final String? origin;

  const AppIntent({
    required this.type,
    this.sourceToken,
    this.targetToken,
    this.amountText,
    this.toAddress,
    this.network,
    this.origin,
  });

  // ── Convenience constructors ──────────────────────────────────────────────

  const AppIntent.swap({
    String? sourceToken,
    String? targetToken,
    String? amountText,
    String? network,
    String origin = 'wallet_button',
  }) : this(
          type: AppIntentType.swap,
          sourceToken: sourceToken,
          targetToken: targetToken,
          amountText: amountText,
          network: network,
          origin: origin,
        );

  const AppIntent.send({
    String? sourceToken,
    String? toAddress,
    String? amountText,
    String? network,
    String origin = 'wallet_button',
  }) : this(
          type: AppIntentType.send,
          sourceToken: sourceToken,
          toAddress: toAddress,
          amountText: amountText,
          network: network,
          origin: origin,
        );

  const AppIntent.receive({String? network, String origin = 'wallet_button'})
      : this(type: AppIntentType.receive, network: network, origin: origin);

  const AppIntent.scan({String origin = 'wallet_button'})
      : this(type: AppIntentType.scan, origin: origin);
}
