import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/swap/swap_provider.dart';

/// Describes a complete SWAP execution plan — either one or two steps.
///
/// Step 1 (optional): ERC-20 approve — required when the source token is not
///   the native gas token and the router hasn't been granted sufficient allowance.
///
/// Step 2 (mandatory): The swap itself — built from the resolved [QuoteResponse].
///
/// Both steps always go through the full execution pipeline independently.
/// A bundled single call is explicitly forbidden (security invariant #7).
class SwapExecutionPlan {
  /// The quote that was resolved by [SwapProvider.getQuote].
  final QuoteResponse quote;

  /// Step 1 — null when approval is not needed (native token / allowance sufficient).
  final TransactionRequest? approveStep;

  /// Step 2 — always present.
  final TransactionRequest swapStep;

  /// Whether this plan requires a preliminary ERC-20 approval.
  bool get requiresApproval => approveStep != null;

  /// Total number of on-chain steps the user must confirm.
  int get totalSteps => requiresApproval ? 2 : 1;

  const SwapExecutionPlan({
    required this.quote,
    required this.swapStep,
    this.approveStep,
  });

  /// Human-readable summary for UI headers.
  /// e.g.  "Swap 100 USDT → BNB  (2 steps)"
  String get displaySummary {
    final base = swapStep.displaySummary;
    return totalSteps > 1 ? '$base  ($totalSteps steps)' : base;
  }
}
