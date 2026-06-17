import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/models/dispatch_item.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/market/token_registry_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';

// ─── Result types ──────────────────────────────────────────────────────────────

sealed class AutomationIntentResult {}

/// Intent built — ready for execution handoff.
class AutomationIntentReady extends AutomationIntentResult {
  final IntentData intent;
  AutomationIntentReady(this.intent);
}

/// Cannot build intent — execution must be blocked with this reason.
class AutomationIntentBlocked extends AutomationIntentResult {
  final String reason;
  AutomationIntentBlocked(this.reason);
}

// ─── AutomationIntentBuilder ───────────────────────────────────────────────────

/// Constructs a swap [IntentData] from a [DispatchItem] for handoff to
/// [GuardianExecutionController.orchestrate].
///
/// ## Resolution order for source token
/// 1. Stablecoin on **same chain** as target (first-class rule — Phase 5d).
/// 2. Any stablecoin (any chain).
/// 3. Any non-target asset (sorted by USD value).
///
/// ## Resolution order for target token address
/// 1. Wallet holdings.
/// 2. Built-in [TokenRegistryService] vetted table.
/// 3. Block with a clear reason.
///
/// ## Safety
/// - Unknown chainId → blocked (no silent eth fallback — Phase 5d fix).
/// - Mandate network check performed on the resolved target chain.
/// - rawInput tagged with address source for audit trail.
class AutomationIntentBuilder {
  AutomationIntentBuilder._();

  static const _log = GuardianLogger('IntentBuilder');

  static const Set<String> _stablecoins = {
    'USDT',
    'USDC',
    'DAI',
    'FDUSD',
    'BUSD',
    'USDE',
    'PYUSD',
  };

  /// Build an [IntentData] for a BUY: swap stablecoin → target asset.
  static AutomationIntentResult buildBuy(DispatchItem item) {
    final portfolio = VaultPortfolioListener.instance.summary;
    if (portfolio == null) {
      return AutomationIntentBlocked(
        'Portfolio not loaded — cannot resolve token addresses.',
      );
    }

    final settings = AiControlService.instance.settings;
    final mandate = settings.mandate;
    final perTxLimit = settings.perTxLimit;

    // ─ 1. Early-resolve target chain for same-chain source preference ─────────
    // If user already holds the target, use that chain as the preferred source
    // chain. If not yet held, fall back to active chain.
    final targetHoldingChainId = _bestChainIdForSymbol(
      item.assetSymbol,
      portfolio.allAssets,
    );
    final preferredSourceChainKey =
        _chainKeyFromChainId(targetHoldingChainId) ?? 'eth';

    // ─ 2. Source token: same-chain stablecoin preferred (Phase 5d) ───────────
    final sourceWallet = _bestSourceToken(
      portfolio.allAssets,
      excludeSymbol: item.assetSymbol,
      preferredChainKey: preferredSourceChainKey,
    );

    if (sourceWallet == null) {
      return AutomationIntentBlocked(
        'No suitable source token found in wallet to fund '
        '${item.assetSymbol} purchase.',
      );
    }

    // ─ 3. Derive source chain key — block if unknown (Phase 5d) ──────────────
    final sourceChainKey = _chainKeyFromChainId(sourceWallet.chainId);
    if (sourceChainKey == null) {
      return AutomationIntentBlocked(
        'Source token ${sourceWallet.symbol} is on an unrecognised chain '
        '(chainId ${sourceWallet.chainId}). '
        'Cannot resolve target address safely — blocked.',
      );
    }

    // ─ 4. Target token address: holdings → registry ───────────────────────────
    final targetResolution = _resolveTargetAddress(
      symbol: item.assetSymbol,
      sourceChainKey: sourceChainKey,
    );

    if (!targetResolution.found) {
      return AutomationIntentBlocked(
        '${item.assetSymbol} address not found in wallet holdings or '
        'built-in registry for chain ${targetResolution.chainKey}. '
        '${targetResolution.note}',
      );
    }

    // ─ 5. Mandate network check on resolved target chain ─────────────────────
    if (!mandate.allowsNetwork(targetResolution.chainKey)) {
      return AutomationIntentBlocked(
        'Target token chain "${targetResolution.chainKey}" is not in the '
        'active mandate allowed networks. '
        'Update the mandate in AI Control → Mandate to include this network.',
      );
    }

    // ─ Audit/debug log — Phase 5d: show source of address resolution ─────────
    _log.d('${item.assetSymbol} resolved via ${targetResolution.source.name} '
        'on ${targetResolution.chainKey} | source=${sourceWallet.symbol}');

    // ─ 6. Size calculation ────────────────────────────────────────────────────
    final double exposureRemaining = mandate.maxPositionUsd > 0
        ? _exposureRemaining(
            item.assetSymbol, mandate.maxPositionUsd, portfolio.allAssets)
        : double.infinity;

    final double buyUsd = [
      perTxLimit > 0 ? perTxLimit : double.infinity,
      exposureRemaining,
      sourceWallet.valueUsd,
    ].reduce((a, b) => a < b ? a : b);

    if (buyUsd <= 0) {
      return AutomationIntentBlocked(
        'Trade size resolved to zero or below. '
        'Exposure may be at mandate cap or source balance empty.',
      );
    }

    final double amountInSourceTokens =
        sourceWallet.priceUsd > 0 ? buyUsd / sourceWallet.priceUsd : 0;

    if (amountInSourceTokens <= 0) {
      return AutomationIntentBlocked(
        'Source token ${sourceWallet.symbol} price is zero — '
        'cannot compute trade amount.',
      );
    }

    // ─ 7. Build IntentData ────────────────────────────────────────────────────
    // rawInput tagged with resolution source for audit trail.
    // sourceTrigger marks this automated → ExecutionController uses automation path.
    return AutomationIntentReady(
      IntentData(
        type: IntentType.swapAsset,
        rawInput: '[automation:${targetResolution.source.name}] '
            '${item.trigger.label}: ${item.reason}',
        sourceTokenSymbol: sourceWallet.symbol,
        sourceTokenAddress: sourceWallet.address,
        targetTokenSymbol: item.assetSymbol,
        targetTokenAddress: targetResolution.address,
        amount: amountInSourceTokens,
        amountMode: AmountMode.exactIn,
        slippageBps:
            50, // 0.5% — policy engine caps at SwapSlippagePolicy.maxBps
        sourceTokenDecimals: sourceWallet.decimals,
        targetTokenDecimals: targetResolution.decimals,
        sourceTrigger: item.trigger.id,
      ),
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  /// Resolve target address: same chain first, then active chain, then fallback.
  static TokenResolution _resolveTargetAddress({
    required String symbol,
    required String sourceChainKey,
  }) {
    final registry = TokenRegistryService.instance;
    final onSource = registry.resolve(symbol: symbol, chainKey: sourceChainKey);
    if (onSource.found) return onSource;
    final onActive = registry.resolveOnActiveChain(symbol);
    if (onActive.found) return onActive;
    return registry.resolveWithFallback(
      symbol: symbol,
      preferredChainKeys: ['eth', 'bsc', 'base', 'arbitrum', 'polygon'],
    );
  }

  /// Source token with same-chain stablecoin as first priority (Phase 5d).
  ///
  /// Priority order:
  ///   1. Stablecoin on [preferredChainKey]
  ///   2. Any stablecoin (any chain)
  ///   3. Any non-target asset (highest USD value)
  static WalletAsset? _bestSourceToken(
    List<WalletAsset> assets, {
    required String excludeSymbol,
    required String preferredChainKey,
  }) {
    final preferredChainId = _chainIdFromKey(preferredChainKey);
    final candidates = assets.where(
      (a) =>
          a.symbol.toUpperCase() != excludeSymbol.toUpperCase() &&
          a.valueUsd > 0,
    );

    // 1. Same-chain stablecoin.
    if (preferredChainId != null) {
      final sameChain = candidates
          .where((a) =>
              _stablecoins.contains(a.symbol.toUpperCase()) &&
              a.chainId == preferredChainId)
          .toList();
      if (sameChain.isNotEmpty) {
        return sameChain.reduce((a, b) => a.valueUsd >= b.valueUsd ? a : b);
      }
    }

    // 2. Any stablecoin.
    final anyStable = candidates
        .where((a) => _stablecoins.contains(a.symbol.toUpperCase()))
        .toList();
    if (anyStable.isNotEmpty) {
      return anyStable.reduce((a, b) => a.valueUsd >= b.valueUsd ? a : b);
    }

    // 3. Largest non-target position.
    final sorted = candidates.toList()
      ..sort((a, b) => b.valueUsd.compareTo(a.valueUsd));
    return sorted.isEmpty ? null : sorted.first;
  }

  /// Returns the chainId of the highest-value holding for [symbol].
  /// Used only for same-chain source preference heuristic — not for blocking.
  static int _bestChainIdForSymbol(String symbol, List<WalletAsset> assets) {
    WalletAsset? best;
    for (final a in assets) {
      if (a.symbol.toUpperCase() == symbol.toUpperCase()) {
        if (best == null || a.valueUsd > best.valueUsd) best = a;
      }
    }
    return best?.chainId ??
        1; // 1=ETH only for source preference, not for blocking
  }

  static double _exposureRemaining(
    String symbol,
    double maxPositionUsd,
    List<WalletAsset> assets,
  ) {
    double currentUsd = 0;
    for (final a in assets) {
      if (a.symbol.toUpperCase() == symbol.toUpperCase())
        currentUsd += a.valueUsd;
    }
    return (maxPositionUsd - currentUsd).clamp(0.0, double.infinity);
  }

  /// Returns null for unrecognised chainIds — caller must handle, not silently default.
  static String? _chainKeyFromChainId(int chainId) => switch (chainId) {
        1 => 'eth',
        56 => 'bsc',
        8453 => 'base',
        42161 => 'arbitrum',
        137 => 'polygon',
        _ => null, // unknown chain — do NOT silently default to eth
      };

  /// Reverse of [_chainKeyFromChainId]. Returns null for unknown keys.
  static int? _chainIdFromKey(String key) => switch (key) {
        'eth' => 1,
        'bsc' => 56,
        'base' => 8453,
        'arbitrum' => 42161,
        'polygon' => 137,
        _ => null,
      };
}
