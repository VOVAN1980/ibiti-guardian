import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/models/dispatch_item.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';
import 'package:ibiti_guardian/services/market/token_registry_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/swap/zerox_swap_provider.dart';

// ─── Result types ──────────────────────────────────────────────────────────────

sealed class AutomationIntentResult {}

/// Intent built — ready for execution handoff.
class AutomationIntentReady extends AutomationIntentResult {
  final IntentData intent;

  /// Network both tokens were resolved on. The swap may only be quoted and
  /// signed there (C8): callers block when it is not the active network.
  final String? chainKey;

  /// The wallet asset that pays (FROM token), for prefilling a swap window.
  final WalletAsset? sourceAsset;

  /// Trade size in USD.
  final double? valueUsd;

  AutomationIntentReady(
    this.intent, {
    this.chainKey,
    this.sourceAsset,
    this.valueUsd,
  });
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
    return buildBuyForSymbol(
      item.assetSymbol,
      label: item.trigger.label,
      reason: item.reason,
      sourceTrigger: item.trigger.id,
    );
  }

  /// [buildBuy] for a bare symbol: sizing = min(max position, remaining
  /// exposure, source balance). Also used to prefill the swap window when
  /// «Ручной» prepares a delegated buy (amount on the FROM token, C14).
  static AutomationIntentResult buildBuyForSymbol(
    String symbol, {
    String? label,
    String? reason,
    String? sourceTrigger,
  }) {
    final portfolio = VaultPortfolioListener.instance.summary;
    if (portfolio == null) {
      return AutomationIntentBlocked(
        'Portfolio not loaded — cannot resolve token addresses.',
      );
    }

    final settings = AiControlService.instance.settings;
    final mandate = settings.mandate;
    final perTxLimit = mandate.maxPositionUsd;

    // ─ 1. Preferred chain for the source ─────────────────────────────────────
    // The swap is quoted and signed on the ACTIVE network only (C8), so a
    // stablecoin there comes first. Without an active chain: the chain the
    // user already holds the target on.
    final activeChainKey = WalletAdapter.instance.chainKey;
    final targetHoldingChainId = _bestChainIdForSymbol(
      symbol,
      portfolio.allAssets,
    );
    final preferredSourceChainKey = _chainIdFromKey(activeChainKey) != null
        ? activeChainKey
        : (_chainKeyFromChainId(targetHoldingChainId) ?? 'eth');

    // ─ 2. Source token: same-chain stablecoin preferred (Phase 5d) ───────────
    final sourceWallet = _bestSourceToken(
      portfolio.allAssets,
      excludeSymbol: symbol,
      preferredChainKey: preferredSourceChainKey,
    );

    if (sourceWallet == null) {
      return AutomationIntentBlocked(
        'No suitable source token found in wallet to fund '
        '$symbol purchase.',
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
      symbol: symbol,
      sourceChainKey: sourceChainKey,
    );

    if (!targetResolution.found) {
      return AutomationIntentBlocked(
        '$symbol address not found in wallet holdings or '
        'built-in registry for chain ${targetResolution.chainKey}. '
        '${targetResolution.note}',
      );
    }

    // C8: both tokens must live on one network — a target address from
    // another chain would be quoted against the wrong token.
    if (targetResolution.chainKey != sourceChainKey) {
      return AutomationIntentBlocked(
        '$symbol was found on ${targetResolution.chainKey}, but the paying '
        'token ${sourceWallet.symbol} is on $sourceChainKey. '
        'Cross-network trades are not done automatically.',
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
    _log.d('$symbol resolved via ${targetResolution.source.name} '
        'on ${targetResolution.chainKey} | source=${sourceWallet.symbol}');

    // ─ 6. Size calculation ────────────────────────────────────────────────────
    final double exposureRemaining = mandate.maxPositionUsd > 0
        ? _exposureRemaining(
            symbol, mandate.maxPositionUsd, portfolio.allAssets)
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

    // A native coin as the source goes by the provider's native reference.
    final sourceRaw = sourceWallet.address.trim().toLowerCase();
    final sourceAddress =
        sourceWallet.isNative || sourceRaw.isEmpty || sourceRaw == 'native'
            ? _nativeRef(sourceChainKey, sourceWallet.symbol)
            : sourceWallet.address;

    // ─ 7. Build IntentData ────────────────────────────────────────────────────
    // rawInput tagged with resolution source for audit trail.
    // sourceTrigger marks this automated → ExecutionController uses automation path.
    return AutomationIntentReady(
      IntentData(
        type: IntentType.swapAsset,
        rawInput: '[automation:${targetResolution.source.name}] '
            '${label ?? 'Buy $symbol'}: ${reason ?? ''}',
        sourceTokenSymbol: sourceWallet.symbol,
        sourceTokenAddress: sourceAddress,
        targetTokenSymbol: symbol,
        targetTokenAddress: targetResolution.address,
        amount: amountInSourceTokens,
        amountMode: AmountMode.exactIn,
        slippageBps:
            50, // 0.5% — policy engine caps at SwapSlippagePolicy.maxBps
        sourceTokenDecimals: sourceWallet.decimals,
        targetTokenDecimals: targetResolution.decimals,
        sourceTrigger: sourceTrigger,
      ),
      chainKey: sourceChainKey,
      sourceAsset: sourceWallet,
      valueUsd: buyUsd,
    );
  }

  /// Build a swap [IntentData] for an AI buy or sell of [symbol] on the
  /// ACTIVE network only (C8): buy = stablecoin → [symbol], sell = [symbol]
  /// → stablecoin. Size by [amountUsd] (dollars) or [quantity] (coins of
  /// [symbol]). [priceUsd] is the coin's price when the caller knows it
  /// (needed to size by quantity on a buy when the wallet holds none).
  ///
  /// Never sizes from a guessed price: with no real price, or a token that
  /// cannot be resolved on the active network, it returns
  /// [AutomationIntentBlocked] and the caller opens the prefilled window
  /// instead (D17). "Sell all / half" (negative amounts) is not built here:
  /// those keep the window (C13). Limits and «AI Мандат» are not applied
  /// here — the gate and the controller refuse over-limit trades with a
  /// reason, never shrink them silently.
  static AutomationIntentResult buildTrade({
    required String symbol,
    required bool isBuy,
    double? amountUsd,
    double? quantity,
    double? priceUsd,
    String? sourceTrigger,
  }) {
    final upper = symbol.trim().toUpperCase();
    if (upper.isEmpty) return AutomationIntentBlocked('No token given.');
    final hasUsd = amountUsd != null && amountUsd > 0;
    final hasQty = quantity != null && quantity > 0;
    if (!hasUsd && !hasQty) {
      return AutomationIntentBlocked(
        'No positive amount for $upper — the window is opened instead.',
      );
    }

    final portfolio = VaultPortfolioListener.instance.summary;
    if (portfolio == null) {
      return AutomationIntentBlocked(
        'Portfolio not loaded — cannot resolve token addresses.',
      );
    }

    final chainKey = WalletAdapter.instance.chainKey;
    final chain = PrivyChainRegistry.getChain(chainKey);
    if (chain.chainKey != chainKey) {
      return AutomationIntentBlocked('Unknown active network "$chainKey".');
    }
    final mandate = AiControlService.instance.settings.mandate;
    if (!mandate.allowsNetwork(chainKey)) {
      return AutomationIntentBlocked(
        'Network "$chainKey" is not in the active mandate allowed networks.',
      );
    }

    final onChain = portfolio.allAssets
        .where((a) => _isOnChain(a, chainKey))
        .toList();

    // The coin being bought or sold.
    final coin = _resolveOnChain(upper, chainKey, onChain);
    if (coin == null) {
      return AutomationIntentBlocked(
        '$upper cannot be resolved reliably on ${chain.displayName}.',
      );
    }
    final coinPrice = (coin.priceUsd != null && coin.priceUsd! > 0)
        ? coin.priceUsd!
        : ((priceUsd != null && priceUsd > 0) ? priceUsd : null);

    // The stablecoin side.
    final stable = isBuy
        ? _largestStable(onChain, excludeSymbol: upper)
        : (_largestStable(onChain, excludeSymbol: upper, requireBalance: false) ??
            _registryStable(chainKey));
    if (stable == null) {
      return AutomationIntentBlocked(
        isBuy
            ? 'No stablecoin on ${chain.displayName} to pay for $upper.'
            : 'No stablecoin to receive on ${chain.displayName}.',
      );
    }

    final source = isBuy ? stable : coin;
    final target = isBuy ? coin : stable;

    // Size in source tokens, from real prices only.
    final double sourceAmount;
    final double usd;
    if (isBuy) {
      final stablePrice = stable.priceUsd != null && stable.priceUsd! > 0
          ? stable.priceUsd!
          : 1.0; // a stablecoin is pegged to the dollar
      if (hasUsd) {
        usd = amountUsd;
      } else {
        if (coinPrice == null) {
          return AutomationIntentBlocked(
            'No price for $upper — cannot size a buy of $quantity $upper.',
          );
        }
        usd = quantity! * coinPrice;
      }
      sourceAmount = usd / stablePrice;
    } else {
      if (hasQty) {
        sourceAmount = quantity;
        usd = coinPrice == null ? 0.0 : quantity * coinPrice;
      } else {
        if (coinPrice == null) {
          return AutomationIntentBlocked(
            'No price for $upper — cannot size a sale worth \$$amountUsd.',
          );
        }
        usd = amountUsd!;
        sourceAmount = usd / coinPrice;
      }
    }

    if (sourceAmount <= 0 || !sourceAmount.isFinite) {
      return AutomationIntentBlocked('Trade size for $upper resolved to zero.');
    }
    final balance = source.balance;
    if (balance != null && sourceAmount > balance) {
      return AutomationIntentBlocked(
        'Not enough ${source.symbol}: need $sourceAmount, have $balance.',
      );
    }

    return AutomationIntentReady(
      IntentData(
        type: IntentType.swapAsset,
        rawInput: '[ai-trade:${isBuy ? 'buy' : 'sell'}] $upper',
        sourceTokenSymbol: source.symbol,
        sourceTokenAddress: source.address,
        targetTokenSymbol: target.symbol,
        targetTokenAddress: target.address,
        amount: sourceAmount,
        amountMode: AmountMode.exactIn,
        slippageBps: 50,
        sourceTokenDecimals: source.decimals,
        targetTokenDecimals: target.decimals,
        sourceTrigger: sourceTrigger,
      ),
      chainKey: chainKey,
      sourceAsset: source.asset,
      valueUsd: usd > 0 ? usd : null,
    );
  }

  /// A token on [chainKey] usable as a swap side: held (non-native) asset,
  /// the network's native coin, or the built-in registry.
  static _TradeToken? _resolveOnChain(
    String symbol,
    String chainKey,
    List<WalletAsset> onChain,
  ) {
    final chain = PrivyChainRegistry.getChain(chainKey);
    final native = (chain.nativeSymbol ?? '').toUpperCase();
    WalletAsset? held;
    for (final a in onChain) {
      if (a.symbol.toUpperCase() != symbol) continue;
      if (held == null || a.valueUsd > held.valueUsd) held = a;
    }
    final heldPrice = held != null && held.priceAvailable && held.priceUsd > 0
        ? held.priceUsd
        : null;

    if (symbol == native) {
      return _TradeToken(
        symbol: symbol,
        address: _nativeRef(chainKey, symbol),
        decimals: _nativeDecimals(chainKey),
        balance: held?.balance ?? 0,
        priceUsd: heldPrice,
        asset: held,
      );
    }
    if (held != null &&
        held.address.isNotEmpty &&
        held.address.toLowerCase() != 'native' &&
        !held.isNative) {
      return _TradeToken(
        symbol: held.symbol.toUpperCase(),
        address: held.address,
        decimals: held.decimals,
        balance: held.balance,
        priceUsd: heldPrice,
        asset: held,
      );
    }
    final entry = TokenRegistryService.instance
        .resolveFromRegistry(symbol: symbol, chainKey: chainKey);
    final address = entry?.address;
    if (entry == null || address == null || address.isEmpty) return null;
    return _TradeToken(
      symbol: symbol,
      address: address,
      decimals: entry.decimals,
      balance: 0,
      priceUsd: null,
      asset: null,
    );
  }

  static _TradeToken? _largestStable(
    List<WalletAsset> onChain, {
    required String excludeSymbol,
    bool requireBalance = true,
  }) {
    WalletAsset? best;
    for (final a in onChain) {
      final s = a.symbol.toUpperCase();
      if (s == excludeSymbol || !_stablecoins.contains(s)) continue;
      if (a.address.isEmpty || a.address.toLowerCase() == 'native') continue;
      if (requireBalance && a.valueUsd <= 0) continue;
      if (best == null || a.valueUsd > best.valueUsd) best = a;
    }
    if (best == null) return null;
    return _TradeToken(
      symbol: best.symbol.toUpperCase(),
      address: best.address,
      decimals: best.decimals,
      balance: best.balance,
      priceUsd: best.priceAvailable && best.priceUsd > 0 ? best.priceUsd : null,
      asset: best,
    );
  }

  static _TradeToken? _registryStable(String chainKey) {
    for (final symbol in const ['USDT', 'USDC']) {
      final entry = TokenRegistryService.instance
          .resolveFromRegistry(symbol: symbol, chainKey: chainKey);
      final address = entry?.address;
      if (entry != null && address != null && address.isNotEmpty) {
        return _TradeToken(
          symbol: symbol,
          address: address,
          decimals: entry.decimals,
          balance: 0,
          priceUsd: null,
          asset: null,
        );
      }
    }
    return null;
  }

  static bool _isOnChain(WalletAsset a, String chainKey) {
    if (a.chainKey.isNotEmpty) return a.chainKey == chainKey;
    final evmId = PrivyChainRegistry.getChain(chainKey).evmChainId;
    return evmId != null && a.chainId == evmId;
  }

  /// How the swap providers name a network's native coin (same as the swap
  /// window): 0x needs its sentinel, Jupiter the wSOL mint, SunSwap "TRX".
  static String _nativeRef(String chainKey, String symbol) => switch (chainKey) {
        'solana' => 'So11111111111111111111111111111111111111112',
        'tron' => symbol,
        _ => ZeroXSwapProvider.nativeTokenSentinel,
      };

  static int _nativeDecimals(String chainKey) => switch (chainKey) {
        'solana' => 9,
        'tron' => 6,
        _ => 18,
      };

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

/// One side of an AI trade on the active network.
class _TradeToken {
  final String symbol;

  /// Contract address, or the provider's native-coin reference.
  final String address;
  final int decimals;

  /// Held quantity; 0 when not held.
  final double? balance;

  /// Real price in USD, or null when unknown.
  final double? priceUsd;

  /// The wallet asset, when held.
  final WalletAsset? asset;

  const _TradeToken({
    required this.symbol,
    required this.address,
    required this.decimals,
    required this.balance,
    required this.priceUsd,
    required this.asset,
  });
}
