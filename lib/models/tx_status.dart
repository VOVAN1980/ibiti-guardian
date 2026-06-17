/// Transaction status states for the Phase 10 execution feedback pipeline.
enum TxStatus {
  /// Hash received from Privy — tx submitted to network.
  submitted,

  /// Receipt call returned null — tx visible but not yet mined.
  pending,

  /// receipt.status == true — included in a block successfully.
  confirmed,

  /// receipt.status == false — included but reverted on-chain.
  failed,

  /// Polling exceeded the maximum wait period (60 s).
  timeout,
}

/// Immutable snapshot of a transaction status at a point in time.
class TxStatusEvent {
  final TxStatus status;
  final String txHash;
  final String? walletAddress;

  /// Block number where the tx was included (only set on [TxStatus.confirmed]/[TxStatus.failed]).
  final int? blockNumber;

  /// Human-readable failure reason (only set on [TxStatus.failed]/[TxStatus.timeout]).
  final String? errorReason;

  final DateTime timestamp;

  /// Short human-readable description of what this tx does.
  /// Examples: "Swapping USDT → ETH", "Sending BNB", "Revoking approval"
  /// Displayed in status card and recent history.
  final String? operationLabel;

  /// Human-readable amount received (e.g. "0.45 ETH").
  final String? assetLabel;

  const TxStatusEvent({
    required this.status,
    required this.txHash,
    this.walletAddress,
    this.blockNumber,
    this.errorReason,
    required this.timestamp,
    this.operationLabel,
    this.assetLabel,
  });

  /// Creates a copy of this event with updated status fields,
  /// preserving [operationLabel], [assetLabel] and [txHash].
  TxStatusEvent copyWith({
    required TxStatus status,
    int? blockNumber,
    String? errorReason,
  }) =>
      TxStatusEvent(
        status: status,
        txHash: txHash,
        walletAddress: walletAddress,
        blockNumber: blockNumber ?? this.blockNumber,
        errorReason: errorReason ?? this.errorReason,
        timestamp: DateTime.now(),
        operationLabel: operationLabel,
        assetLabel: assetLabel,
      );

  bool get isTerminal =>
      status == TxStatus.confirmed ||
      status == TxStatus.failed ||
      status == TxStatus.timeout;

  /// Short human-readable label for the UI.
  String get statusLabel {
    final op = operationLabel;
    switch (status) {
      case TxStatus.submitted:
        return op != null ? '$op…' : 'Transaction sent';
      case TxStatus.pending:
        return op != null ? '$op…' : 'Awaiting confirmation…';
      case TxStatus.confirmed:
        return op != null ? '$op ✓' : 'Confirmed ✓';
      case TxStatus.failed:
        return op != null ? '$op failed' : 'Transaction failed';
      case TxStatus.timeout:
        return 'Confirmation timeout';
    }
  }

  /// Short phrase for the voice assistant to read aloud.
  String voicePhrase({String? assetLabel}) {
    final op = operationLabel;
    switch (status) {
      case TxStatus.submitted:
        return op != null
            ? '$op. Waiting for confirmation.'
            : 'Transaction sent. Waiting for confirmation.';
      case TxStatus.pending:
        return 'Waiting for confirmation.';
      case TxStatus.confirmed:
        if (op != null) return '$op completed.';
        return assetLabel != null
            ? 'Done. You received $assetLabel.'
            : 'Transaction confirmed.';
      case TxStatus.failed:
        return op != null ? '$op failed.' : 'Transaction failed.';
      case TxStatus.timeout:
        return 'Confirmation timeout. Check the explorer.';
    }
  }
}
