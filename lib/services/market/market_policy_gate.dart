import 'package:ibiti_guardian/models/audit_log_entry.dart';
import 'package:ibiti_guardian/models/execution_result.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/services/audit_log_service.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';

// ─── Gate Result ───────────────────────────────────────────────────────────────

enum MarketGateVerdict {
  /// Trade flow can open — all checks passed.
  allowed,

  /// Mode blocks this flow. Show AI explanation, not swap UI.
  blockedByMode,

  /// Asset or network is outside mandate scope.
  blockedByMandate,

  /// Wallet not connected — cannot proceed to execution.
  noWallet,
}

/// Result of a market-layer pre-execution policy check.
class MarketGateResult {
  final MarketGateVerdict verdict;

  /// Human-readable reason for the block. Null if [verdict] is [allowed].
  final String? reason;

  /// Suggested prompt to open in the AI assistant when blocked.
  /// Provides context on why the user was blocked and what to do next.
  final String? aiExplanationPrompt;

  const MarketGateResult._({
    required this.verdict,
    this.reason,
    this.aiExplanationPrompt,
  });

  bool get isAllowed => verdict == MarketGateVerdict.allowed;
  bool get isBlocked => !isAllowed;

  factory MarketGateResult.allowed() =>
      const MarketGateResult._(verdict: MarketGateVerdict.allowed);

  factory MarketGateResult.blockedByMode({
    required String reason,
    required String aiPrompt,
  }) =>
      MarketGateResult._(
        verdict: MarketGateVerdict.blockedByMode,
        reason: reason,
        aiExplanationPrompt: aiPrompt,
      );

  factory MarketGateResult.blockedByMandate({
    required String reason,
    required String aiPrompt,
  }) =>
      MarketGateResult._(
        verdict: MarketGateVerdict.blockedByMandate,
        reason: reason,
        aiExplanationPrompt: aiPrompt,
      );

  factory MarketGateResult.noWallet() => const MarketGateResult._(
        verdict: MarketGateVerdict.noWallet,
        reason: 'No wallet connected. Connect a wallet before trading.',
        aiExplanationPrompt:
            'The user wants to trade but no wallet is connected. '
            'Explain how to connect a wallet in Guardian.',
      );
}

// ─── MarketPolicyGate ──────────────────────────────────────────────────────────

/// Pre-execution policy gate for all Market → Execution flows.
///
/// Called BEFORE opening [WalletSwapModal] or any trade execution UI.
/// Ensures the Market screen cannot bypass Mode / Mandate / Wallet checks.
///
/// Contract:
/// - Manual mode → always blocked (AI explains, no execution UI opens)
/// - Guarded / Full Autonomy → mandate checks run
/// - If mandate doesn't cover asset/network → blocked with AI explanation
/// - All blocks AND passes recorded to [AuditLogService] with [ExecutionSource.market]
///
/// This is a PLANNING-LAYER gate — it does not replace [GuardianPolicyEngine.checkV3].
/// [GuardianPolicyEngine] is still the final, non-bypassable execution gate.
class MarketPolicyGate {
  MarketPolicyGate._();
  static final MarketPolicyGate instance = MarketPolicyGate._();

  /// Check whether a market-originated swap/trade is allowed to proceed.
  ///
  /// [asset]: the market asset the user wants to trade.
  /// Returns [MarketGateResult.allowed] if the swap UI can open.
  /// Returns a blocked result if not — caller must show AI explanation instead.
  MarketGateResult checkSwap(MarketAsset asset) {
    final settings = AiControlService.instance.settings;
    final mode = settings.mode;
    final mandate = settings.mandate;
    final wallet = WalletAdapter.instance;
    final priceStr = asset.price >= 1
        ? '\$${asset.price.toStringAsFixed(2)}'
        : '\$${asset.price.toStringAsFixed(4)}';

    // ── 1. Wallet connected ───────────────────────────────────────────────────
    if (!wallet.isConnected) {
      const reason = 'No wallet connected. Connect a wallet before trading.';
      _logBlock(asset, reason);
      return MarketGateResult.noWallet();
    }

    // ── 2. Mode check: Manual → always blocked ────────────────────────────────
    if (mode == AiMode.manual) {
      const reason = 'Manual mode is active — live swap form is not available. '
          'The AI will explain the opportunity instead.';
      _logBlock(asset, reason);
      return MarketGateResult.blockedByMode(
        reason: reason,
        aiPrompt:
            'Current AI mode is Manual. Do NOT execute or prepare a trade. '
            'The user wants to trade ${asset.symbol} (${asset.networkGroup}, '
            'price $priceStr). Explain what this trade would involve, '
            'what the current market context is, what risks exist, '
            'and what the user needs to do to enable execution '
            '(switch to Guarded or Full Autonomy in AI Control).',
      );
    }

    // ── 3. Mandate: asset allowed ─────────────────────────────────────────────
    if (!mandate.allowsAsset(asset.symbol)) {
      final allowed = mandate.allowedAssets.isEmpty
          ? 'all assets'
          : mandate.allowedAssets.join(', ');
      final reason = 'Asset ${asset.symbol} is outside your AI mandate. '
          'Allowed: $allowed.';
      _logBlock(asset, reason);
      return MarketGateResult.blockedByMandate(
        reason: reason,
        aiPrompt:
            'The user wants to trade ${asset.symbol} but this asset is not '
            'in the active AI mandate (allowed: $allowed). '
            'Explain the mandate restriction and how to update it in '
            'AI Control → Mandate settings.',
      );
    }

    // ── 4. Mandate: network allowed ───────────────────────────────────────────
    final chainKey = wallet.chainKey;
    if (chainKey.isNotEmpty && !mandate.allowsNetwork(chainKey)) {
      final allowed = mandate.allowedNetworks.isEmpty
          ? 'all networks'
          : mandate.allowedNetworks.join(', ');
      final reason = 'Network "$chainKey" is outside your AI mandate. '
          'Allowed: $allowed.';
      _logBlock(asset, reason);
      return MarketGateResult.blockedByMandate(
        reason: reason,
        aiPrompt:
            'The user wants to trade on "$chainKey" but this network is not '
            'in the active AI mandate (allowed: $allowed). '
            'Explain the restriction and how to enable this network in the mandate.',
      );
    }

    // ── All checks passed ─────────────────────────────────────────────────────
    _logPass(asset, mode, wallet.chainKey);
    return MarketGateResult.allowed();
  }

  // ─── Private helpers ────────────────────────────────────────────────────────

  void _logBlock(MarketAsset asset, String reason) {
    AuditLogService.instance.recordMarketPolicyBlock(
      assetSymbol: asset.symbol,
      reason: reason,
    );
  }

  void _logPass(MarketAsset asset, AiMode mode, String chainKey) {
    AuditLogService.instance.record(
      intentType: IntentType.swapAsset,
      actionLabel: 'MARKET_SWAP_ALLOWED',
      summary: 'Market swap for ${asset.symbol} passed pre-check '
          '(mode: ${mode.name}, network: $chainKey).',
      executionSource: ExecutionSource.market,
      result: ExecutionResult.success(
        txHash: '',
        pathLabel: 'market_gate',
        message: 'Market policy gate passed.',
      ),
    );
  }
}
