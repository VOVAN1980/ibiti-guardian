import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';
import 'package:ibiti_guardian/services/execution/native_transaction_builder.dart';
import 'package:ibiti_guardian/services/market/token_registry_service.dart';
import 'package:ibiti_guardian/utils/token_symbol_normalizer.dart';

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
    final toAddress = intent.toAddress?.trim();
    if (toAddress == null || toAddress.isEmpty) return null;
    // A short "0x1234" used to be zero-padded into a different, real address.
    if (!isValidRecipient(toAddress, wallet.chainKey)) return null;
    final amount = intent.amount;
    if (amount == null || amount <= 0) return null;
    final rawSymbol = intent.tokenSymbol?.trim();
    if (rawSymbol == null || rawSymbol.isEmpty) return null;
    final symbol = TokenSymbolNormalizer.normalize(rawSymbol); // "эфира" → ETH

    // The token is resolved here, on the active chain. A contract, decimals or
    // atomic amount carried by the intent is never used: an intent showing
    // "1 USDT" with rawAmount 3e18 and no contract used to sign 3 BNB.
    final chainKey = wallet.chainKey;
    final chain = PrivyChainRegistry.getChain(chainKey);
    final nativeSymbol = chain.nativeSymbol?.toUpperCase();
    String? tokenContract;
    final int decimals;
    if (symbol == nativeSymbol) {
      decimals = _nativeDecimals(chainKey);
    } else {
      // Registry first: a look-alike "USDT" in holdings must not win.
      final token = TokenRegistryService.instance
              .resolveFromRegistry(symbol: symbol, chainKey: chainKey) ??
          TokenRegistryService.instance
              .resolve(symbol: symbol, chainKey: chainKey);
      final address = token.address;
      if (!token.found || address == null || address.isEmpty) return null;
      tokenContract = address;
      decimals = token.decimals;
    }

    return TransactionRequest(
      type: TransactionType.send,
      fromAddress: wallet.address,
      toAddress: toAddress,
      tokenSymbol: symbol,
      tokenContract: tokenContract,
      tokenDecimals: decimals,
      amount: amount,
      rawAmount:
          NativeTransactionBuilder.toWeiFromDouble(amount, decimals: decimals),
      // wallet.chainId throws on Solana/Tron; non-EVM requests carry 0.
      chainId: chain.evmChainId ?? 0,
      chainKey: chainKey,
      sourceIntent: intent,
    );
  }

  static final _evmAddress = RegExp(r'^0x[0-9a-fA-F]{40}$');
  static final _solanaAddress = RegExp(r'^[1-9A-HJ-NP-Za-km-z]{32,44}$');
  static final _tronAddress = RegExp(r'^T[1-9A-HJ-NP-Za-km-z]{33}$');

  /// Address shape check for the chain (length and alphabet).
  static bool isValidRecipient(String address, String chainKey) {
    switch (chainKey) {
      case 'solana':
        return _solanaAddress.hasMatch(address);
      case 'tron':
        return _tronAddress.hasMatch(address);
      default:
        return _evmAddress.hasMatch(address);
    }
  }

  static int _nativeDecimals(String chainKey) {
    switch (chainKey) {
      case 'solana':
        return 9;
      case 'tron':
        return 6;
      default:
        return 18;
    }
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
