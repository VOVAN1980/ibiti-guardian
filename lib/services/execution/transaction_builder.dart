import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';

/// Converts [IntentData] into a normalized [TransactionRequest].
///
/// Rules:
/// - No network calls, no guessing, no AI fallback
/// - If required fields are missing → return null (caller handles error)
/// - fromAddress always comes from WalletAdapter — never from user input
class TransactionBuilder {
  TransactionBuilder._();

  /// Build a [TransactionRequest] from [intent].
  /// Returns null if the intent cannot be safely converted (missing critical fields).
  static TransactionRequest? build(IntentData intent) {
    final wallet = WalletAdapter.instance;

    if (!wallet.isConnected) return null;

    switch (intent.type) {
      case IntentType.sendAsset:
        return _buildSend(intent, wallet);
      case IntentType.revokeApproval:
        return _buildRevoke(intent, wallet);
      case IntentType.swapAsset:
        // SWAP goes through SwapIntentBuilder (requires a QuoteResponse first).
        // The ExecutionController fetches the quote and calls SwapIntentBuilder directly.
        // Returning null here signals the controller to route SWAP separately.
        return null;
      case IntentType.scanApprovals:
        // Scan doesn't produce a transaction
        return null;
      default:
        return null;
    }
  }

  // ——— Send ——————————————————————————————————————————————————————

  static TransactionRequest? _buildSend(
      IntentData intent, WalletAdapter wallet) {
    // Strict validation — no guessing
    final toAddress = intent.toAddress;
    if (toAddress == null || toAddress.isEmpty) return null;
    if (intent.amount == null) return null;
    if (intent.tokenSymbol == null) return null;

    return TransactionRequest(
      type: TransactionType.send,
      fromAddress: wallet.address,
      toAddress: toAddress,
      tokenSymbol: intent.tokenSymbol,
      amount: intent.amount,
      rawAmount: intent.rawAmount,
      chainId: wallet.chainId,
      chainKey: wallet.chainKey,
      sourceIntent: intent,
    );
  }

  // ——— Revoke ————————————————————————————————————————————————————

  static TransactionRequest? _buildRevoke(
      IntentData intent, WalletAdapter wallet) {
    // In Phase 4, revoke-by-command targets are resolved from the last scan.
    // Without a specific approval selected, we return a generic revoke request
    // targeting the wallet itself (Phase 5 will resolve specific approvals).
    return TransactionRequest(
      type: TransactionType.revoke,
      fromAddress: wallet.address,
      toAddress: wallet.address, // placeholder — real target set in Phase 5
      chainId: wallet.chainId,
      chainKey: wallet.chainKey,
      sourceIntent: intent,
    );
  }
}
