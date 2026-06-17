import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/models/swap_execution_plan.dart';
import 'package:ibiti_guardian/services/swap/swap_provider.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';

/// Builds a [SwapExecutionPlan] from a [swapAsset] [IntentData].
///
/// Rules (same invariants as [TransactionBuilder]):
/// - No network calls inside build() — quote is injected externally.
/// - fromAddress always comes from [WalletAdapter], never user input.
/// - Returns null on any missing critical field.
class SwapIntentBuilder {
  SwapIntentBuilder._();

  /// Constructs a [SwapExecutionPlan] from a resolved [QuoteResponse].
  ///
  /// [intent] must be of type [IntentType.swapAsset].
  /// [quote]  is the already-fetched route from [SwapProvider.getQuote].
  static SwapExecutionPlan? build({
    required IntentData intent,
    required QuoteResponse quote,
    String? overrideChainKey,
    String? overrideFromAddress,
  }) {
    if (intent.type != IntentType.swapAsset) return null;

    final wallet = WalletAdapter.instance;
    if (!wallet.isConnected) return null;

    // Use the override chain if provided (cross-chain swap modal),
    // otherwise fall back to the wallet's current chain.
    final effectiveChainKey = overrideChainKey ?? wallet.chainKey;
    final effectiveChainId =
        PrivyChainRegistry.getChain(effectiveChainKey).evmChainId ??
            wallet.chainId;
    final effectiveFromAddress = overrideFromAddress ?? wallet.address;

    // ── Validate required swap fields ─────────────────────────────────────
    final srcSymbol = intent.sourceTokenSymbol;
    final dstSymbol = intent.targetTokenSymbol;
    final srcAddress = intent.sourceTokenAddress;
    final amount = intent.amount;

    if (srcSymbol == null || dstSymbol == null) return null;
    if (srcAddress == null || srcAddress.isEmpty) return null;
    if (amount == null || amount <= 0) return null;

    // Swap MUST have rawAmount + sourceTokenDecimals resolved upstream.
    // If missing, block — never silently assume 18 decimals.
    final srcDecimals = intent.sourceTokenDecimals;
    if (intent.rawAmount == null || srcDecimals == null) return null;

    // ── Step 1 (optional): ERC-20 Approve ────────────────────────────────
    // Target the AllowanceHolder contract (not the router) — this is the 0x v2 flow.
    TransactionRequest? approveStep;
    if (quote.approvalNeeded && quote.allowanceTarget.isNotEmpty) {
      approveStep = TransactionRequest(
        type: TransactionType.approve,
        fromAddress: effectiveFromAddress,
        toAddress: srcAddress, // token contract being approved
        tokenSymbol: srcSymbol,
        tokenContract: srcAddress,
        amount: amount, // approve exactly the swap amount (never unlimited)
        rawAmount: intent.rawAmount, // atomic approve amount
        tokenDecimals: srcDecimals,
        chainId: effectiveChainId,
        chainKey: effectiveChainKey,
        spenderAddress:
            quote.allowanceTarget, // ← AllowanceHolder, NOT the router
        isUnlimitedApproval: false,
        sourceIntent: intent,
      );
    }

    // ── Step 2 (mandatory): Swap Transaction ─────────────────────────────
    final swapStep = TransactionRequest(
      type: TransactionType.swap,
      fromAddress: effectiveFromAddress,
      toAddress: quote.routerAddress,
      tokenSymbol: srcSymbol,
      tokenContract: srcAddress,
      targetTokenSymbol: dstSymbol,
      targetTokenAddress: intent.targetTokenAddress,
      amount: amount,
      rawAmount: intent.rawAmount, // atomic swap amount
      tokenDecimals: srcDecimals,
      chainId: effectiveChainId,
      chainKey: effectiveChainKey,
      calldata: quote.calldata,
      routerAddress: quote.routerAddress,
      approvalNeeded: quote.approvalNeeded,
      quoteSummary: {
        'expectedOut': quote.expectedOutputAmount.toString(),
        'minOut': quote.minOutputAmount.toString(),
        'priceImpactPct': quote.priceImpactPct,
        'gasEstimateWei': quote.gasEstimate.toString(),
        'nativeValue': quote.nativeValue.toString(),
        'allowanceTarget': quote.allowanceTarget,
        'routeSummary': quote.routeSummary,
        'provider': quote.providerName,
        'quoteTimestamp': quote.quoteTimestamp.toIso8601String(),
        'targetDecimals': intent.targetTokenDecimals,
        ...quote.extraSummary,
      },
      sourceIntent: intent,
    );

    return SwapExecutionPlan(
      quote: quote,
      approveStep: approveStep,
      swapStep: swapStep,
    );
  }
}
