import 'dart:typed_data';
import 'package:ibiti_guardian/models/intent_data.dart';

// ─── Domain Exceptions ────────────────────────────────────────────────────────

/// No route could be found for the given token pair on the requested chain.
class RouteNotFoundException implements Exception {
  final String message;
  const RouteNotFoundException(this.message);
  @override
  String toString() => 'RouteNotFoundException: $message';
}

/// The requested token is too illiquid for the provider to quote.
class IlliquidTokenException implements Exception {
  final String message;
  const IlliquidTokenException(this.message);
  @override
  String toString() => 'IlliquidTokenException: $message';
}

/// The connected chain is not supported by this provider.
class UnsupportedChainException implements Exception {
  final int chainId;
  const UnsupportedChainException(this.chainId);
  @override
  String toString() => 'UnsupportedChainException: chainId=$chainId';
}

/// Stale quote was attempted to be used past its TTL.
class StaleQuoteException implements Exception {
  const StaleQuoteException();
  @override
  String toString() => 'StaleQuoteException: Quote has expired (>5 min old).';
}

/// Wallet does not hold enough native token to cover estimated gas.
class InsufficientNativeGasException implements Exception {
  final BigInt required;
  final BigInt available;
  const InsufficientNativeGasException(
      {required this.required, required this.available});
  @override
  String toString() =>
      'InsufficientNativeGasException: need ${required}wei, have ${available}wei';
}

// ─── Quote Request ─────────────────────────────────────────────────────────────

/// Request payload for fetching a swap quote from any [SwapProvider].
class QuoteRequest {
  final String sourceTokenAddress;
  final String targetTokenAddress;

  /// The amount specified by the user (in Wei / smallest unit of the source token).
  final BigInt amount;

  /// Whether [amount] refers to the input token (exactIn) or output token (exactOut).
  final AmountMode amountMode;

  /// Maximum accepted slippage in basis points. Default = 50 (0.5%).
  /// Enforced cap: 200 (2.0%) — see [SwapSlippagePolicy].
  final int slippageBps;

  final int chainId;
  final String userAddress;

  const QuoteRequest({
    required this.sourceTokenAddress,
    required this.targetTokenAddress,
    required this.amount,
    required this.amountMode,
    this.slippageBps = 50,
    required this.chainId,
    required this.userAddress,
  });
}

// ─── Quote Response ────────────────────────────────────────────────────────────

/// A fully resolved swap route returned by a [SwapProvider].
///
/// All fields required for the execution layer and the Preview UI are present.
/// Never construct this manually outside of a [SwapProvider] implementation.
class QuoteResponse {
  // ── Output amounts ──────────────────────────────────────────────────────────

  /// The gross expected output amount (before slippage deduction), in Wei.
  final BigInt expectedOutputAmount;

  /// The minimum guaranteed output amount after slippage tolerance, in Wei.
  /// = expectedOutputAmount * (1 - slippageBps/10000)
  final BigInt minOutputAmount;

  // ── Routing ─────────────────────────────────────────────────────────────────

  /// The contract to call to execute the swap (e.g. 0x ExchangeProxy).
  final String routerAddress;

  /// The contract that needs ERC-20 approval to spend source tokens.
  /// For 0x AllowanceHolder flow, this is the AllowanceHolder contract address.
  /// Distinct from [routerAddress] — do NOT mix these up.
  final String allowanceTarget;

  /// ABI-encoded calldata for the swap call.
  final Uint8List calldata;

  /// Native token value in Wei to attach to the tx (ETH/BNB/MATIC).
  /// Non-zero only when selling native gas tokens.
  final BigInt nativeValue;

  // ── Fees & Impact ───────────────────────────────────────────────────────────

  /// Estimated price impact in percent (e.g. 0.15 = 0.15%).
  final double priceImpactPct;

  /// Estimated gas cost in Wei (native token units).
  final BigInt gasEstimate;

  // ── Metadata ────────────────────────────────────────────────────────────────

  /// Whether the user needs to call ERC-20 `approve(allowanceTarget, amount)` first.
  final bool approvalNeeded;

  /// Human-readable provider name for the UI (e.g. "0x", "1inch", "MockAggregator").
  final String providerName;

  /// UTC timestamp when this quote was fetched.
  /// Used to enforce the 5-minute staleness check.
  final DateTime quoteTimestamp;

  /// Human-readable route summary for the Preview UI (e.g. "ETH → USDC via Uniswap V3").
  final String routeSummary;

  /// Optional extra data (provider-specific, used for debugging/logging).
  final Map<String, dynamic> extraSummary;

  const QuoteResponse({
    required this.expectedOutputAmount,
    required this.minOutputAmount,
    required this.routerAddress,
    required this.allowanceTarget,
    required this.calldata,
    required this.nativeValue,
    required this.priceImpactPct,
    required this.gasEstimate,
    required this.approvalNeeded,
    required this.providerName,
    required this.quoteTimestamp,
    required this.routeSummary,
    this.extraSummary = const {},
  });

  /// Returns true if this quote is older than 5 minutes and must NOT be executed.
  bool get isStale =>
      DateTime.now().toUtc().difference(quoteTimestamp).inMinutes >= 5;

  /// Convenience: network fee alias (used in quoteSummary for legacy display).
  BigInt get networkFeeWei => gasEstimate;
}

// ─── Slippage Policy ──────────────────────────────────────────────────────────

/// Centralised slippage constants enforced by [GuardianPolicyEngine].
///
/// AI cannot override these — they are compile-time constants.
class SwapSlippagePolicy {
  SwapSlippagePolicy._();

  /// Default slippage sent to providers when the user/AI hasn't specified one.
  static const int defaultBps = 50; // 0.5%

  /// Absolute hard cap. Any quote request above this is rejected by the policy engine
  /// before even reaching the provider.
  static const int maxBps = 200; // 2.0%
}

// ─── Abstract Provider Interface ──────────────────────────────────────────────

/// Abstract base for all swap quote providers.
///
/// Concrete implementations: [ZeroXSwapProvider], [MockSwapProvider].
/// [GuardianExecutionController] depends only on this interface —
/// never on a concrete class directly.
abstract class SwapProvider {
  /// Fetch a swap route for [request].
  ///
  /// Throws [RouteNotFoundException] if no route exists.
  /// Throws [IlliquidTokenException] if the source/target token is too illiquid.
  /// Throws [UnsupportedChainException] if the chain is not supported.
  Future<QuoteResponse> getQuote(QuoteRequest request);
}
