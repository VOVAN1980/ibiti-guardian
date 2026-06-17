import 'dart:math' as math;

import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/services/swap/swap_provider.dart';
import 'package:ibiti_guardian/services/swap/zerox_swap_provider.dart';
import 'package:ibiti_guardian/services/execution/native_transaction_builder.dart';

// ─── Result Types ──────────────────────────────────────────────────────────────

/// Result of a market-layer quote fetch.
///
/// This is distinct from [QuoteResponse] (which is execution-level).
/// [MarketQuoteResult] is for display and planning — it strips out
/// execution calldata and focuses on what the market UI needs:
/// price, slippage, gas estimate, and viability against mandate.
class MarketQuoteResult {
  /// Expected output in **target token units** (not in USD).
  /// Null if quote failed.
  final double? expectedOutput;

  /// Quote: how many USD the output is worth (approximated from market price).
  /// Null if quote failed or price unavailable.
  final double? expectedOutputUsd;

  /// Minimum guaranteed output after slippage.
  final double? guaranteedOutput;

  /// Actual slippage percent from the quote (not heuristic).
  /// Null if quote failed.
  final double? actualSlippagePct;

  /// Real estimated gas cost in USD.
  /// Null if quote failed.
  final double? gasEstimateUsd;

  /// Route summary from the provider (e.g. "ETH → USDC via Uniswap V3").
  final String routeSummary;

  /// Provider that answered this quote.
  final String providerName;

  /// Whether the trade is gas-viable: gasEstimateUsd < mandate.maxGasUsd.
  final bool gasViable;

  /// Whether the trade passed all mandate checks.
  final bool viable;

  /// Why the trade is not viable, or null if viable.
  final String? blockReason;

  /// Whether this result is a live quote or a graceful fallback.
  final bool isLive;

  const MarketQuoteResult({
    this.expectedOutput,
    this.expectedOutputUsd,
    this.guaranteedOutput,
    this.actualSlippagePct,
    this.gasEstimateUsd,
    required this.routeSummary,
    required this.providerName,
    required this.gasViable,
    required this.viable,
    this.blockReason,
    this.isLive = true,
  });

  /// A fallback result shown when live quote is unavailable.
  /// Clearly labeled so the UI can display the right disclaimer.
  factory MarketQuoteResult.unavailable(String reason) {
    return MarketQuoteResult(
      routeSummary: 'Live quote unavailable',
      providerName: 'N/A',
      gasViable: false,
      viable: false,
      blockReason: reason,
      isLive: false,
    );
  }

  /// One-line status for display in the modal header.
  String get statusLine {
    if (!isLive) return 'Live quote unavailable — showing heuristic estimate';
    if (!viable) return 'Blocked: ${blockReason ?? "mandate check failed"}';
    return 'Live quote · $providerName · '
        '${actualSlippagePct?.toStringAsFixed(2) ?? "?"}% slippage';
  }
}

// ─── QuoteEngine ───────────────────────────────────────────────────────────────

/// Market-layer quote engine.
///
/// Provides live pre-execution quotes for the TradingPlan modal and
/// Command Panel — without requiring a full IntentData or wallet context.
///
/// Architecture notes:
/// - Uses [ZeroXSwapProvider] (same as [GuardianExecutionController]).
/// - Does NOT build calldata / execution plans — that is the controller's job.
/// - Falls back gracefully when offline or chain not supported.
/// - All mandate checks are re-run here before returning `viable = true`.
class QuoteEngine {
  QuoteEngine._();
  static final QuoteEngine instance = QuoteEngine._();

  // Inject mock in tests via [overrideProvider].
  SwapProvider _provider = ZeroXSwapProvider.instance;
  void overrideProvider(SwapProvider p) => _provider = p;

  /// Minimum gas price (Gwei) used for USD gas estimation when wallet is not connected.
  static const double _fallbackGasPriceGwei = 5.0;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Fetch a live quote for the market planning modal.
  ///
  /// [tokenInAddress] / [tokenOutAddress]: EVM token addresses.
  ///   Use the sentinel "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE" for
  ///   native gas tokens (ETH, BNB) — matches 0x API convention.
  ///
  /// [amountUsd]: desired trade size in USD (from [TradingSizeCalculator]).
  /// [tokenInPriceUsd]: current price of the input token (from cached market data).
  /// [tokenOutPriceUsd]: current price of the output token.
  /// [chainId]: EVM chain (1=Eth, 56=BSC, 137=Polygon, 42161=Arbitrum).
  /// [mandate]: used to enforce gas and slippage limits on the result.
  ///
  /// Returns [MarketQuoteResult.unavailable] on any network or provider error
  /// — callers should always handle both `isLive = true` and `isLive = false`.
  Future<MarketQuoteResult> fetchQuote({
    required String tokenInAddress,
    required String tokenOutAddress,
    required double amountUsd,
    required double tokenInPriceUsd,
    required double tokenOutPriceUsd,
    required int chainId,
    required AutonomyMandate mandate,
    int tokenInDecimals = 18,
    int tokenOutDecimals = 18,

    /// Price of the chain's native gas token (BNB/ETH/MATIC) in USD.
    /// Required for accurate gas cost calculation. If null, falls back to
    /// a conservative $600 estimate (safe for BSC, slightly low for ETH).
    double? gasTokenPriceUsd,
    int? slippageOverrideBps,
  }) async {
    if (tokenInPriceUsd <= 0) {
      return MarketQuoteResult.unavailable(
          'Input token price unavailable — cannot size the trade.');
    }

    // ── Convert USD amount → raw atomic units (respecting token decimals) ────
    final tokenInAmount = amountUsd / tokenInPriceUsd;
    final rawAmount = NativeTransactionBuilder.toWeiFromDouble(tokenInAmount,
        decimals: tokenInDecimals);

    // ── Slippage: respect mandate.maxSlippageBps as ceiling ─────────────────
    final slippageBps = (slippageOverrideBps ?? SwapSlippagePolicy.defaultBps)
        .clamp(0,
            math.min(mandate.maxSlippageBps.round(), SwapSlippagePolicy.maxBps))
        .toInt();

    final request = QuoteRequest(
      sourceTokenAddress: tokenInAddress,
      targetTokenAddress: tokenOutAddress,
      amount: rawAmount,
      amountMode: AmountMode.exactIn,
      slippageBps: slippageBps,
      chainId: chainId,
      userAddress: '0x0000000000000000000000000000000000000000', // read-only
    );

    // ── Fetch quote ──────────────────────────────────────────────────────────
    QuoteResponse quote;
    try {
      quote = await _provider.getQuote(request);
    } on UnsupportedChainException {
      return MarketQuoteResult.unavailable(
          'Chain $chainId is not supported by the quote provider.');
    } on RouteNotFoundException {
      return MarketQuoteResult.unavailable(
          'No route found for this token pair on chain $chainId.');
    } on IlliquidTokenException {
      return MarketQuoteResult.unavailable(
          'One of the tokens is too illiquid for a live quote.');
    } catch (e) {
      return MarketQuoteResult.unavailable(
          'Quote provider error: ${e.runtimeType}. Live quote unavailable.');
    }

    if (quote.isStale) {
      return MarketQuoteResult.unavailable(
          'Quote expired before it could be displayed. Refresh to try again.');
    }

    // ── Derive human-readable values ─────────────────────────────────────────
    final outputDivisor = BigInt.from(10).pow(tokenOutDecimals);
    final outputTokens =
        quote.expectedOutputAmount.toDouble() / outputDivisor.toDouble();
    final outputUsd = outputTokens * tokenOutPriceUsd;
    final guaranteedTokens =
        quote.minOutputAmount.toDouble() / outputDivisor.toDouble();

    // Gas cost in USD: gasUnits * gasPriceGwei * 1e9 / 1e18 * nativeTokenPriceUsd.
    // Gas is ALWAYS paid in native token (BNB/ETH/MATIC), not the input token.
    final gasPrice = gasTokenPriceUsd ?? 600.0; // conservative fallback
    final gasWei = quote.gasEstimate.toDouble();
    const gasPriceGwei = _fallbackGasPriceGwei;
    final gasUsd = (gasWei * gasPriceGwei * 1e9) / 1e18 * gasPrice;

    final actualSlippage = outputUsd > 0
        ? ((amountUsd - outputUsd) / amountUsd * 100).clamp(0.0, 100.0)
        : 0.0;

    // ── Mandate checks ───────────────────────────────────────────────────────
    String? blockReason;
    bool gasViable = true;

    if (gasUsd > mandate.maxGasUsd) {
      gasViable = false;
      blockReason =
          'Gas (\$${gasUsd.toStringAsFixed(2)}) exceeds mandate maxGasUsd '
          '(\$${mandate.maxGasUsd.toStringAsFixed(0)}).';
    } else if (actualSlippage > mandate.maxSlippageBps / 100) {
      blockReason =
          'Slippage ${actualSlippage.toStringAsFixed(2)}% exceeds mandate '
          'max ${(mandate.maxSlippageBps / 100).toStringAsFixed(2)}%.';
    }

    return MarketQuoteResult(
      expectedOutput: outputTokens,
      expectedOutputUsd: outputUsd,
      guaranteedOutput: guaranteedTokens,
      actualSlippagePct: actualSlippage,
      gasEstimateUsd: gasUsd,
      routeSummary: quote.routeSummary,
      providerName: quote.providerName,
      gasViable: gasViable,
      viable: blockReason == null,
      blockReason: blockReason,
      isLive: true,
    );
  }
}
