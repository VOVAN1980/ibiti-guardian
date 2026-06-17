// TODO(refactor): GOD WIDGET — 2446 lines. Decompose into:
//   • _WalletHeader (balance display + chain switcher)
//   • _WalletActionRow (Send/Receive/Swap/Buy buttons)
//   • _WalletAssetList (per-asset cards)
//   • _WalletHistorySection (recent transactions)
//   • _WalletSettingsSheet (settings overflow)
// Priority: HIGH — complexity makes bug isolation extremely difficult.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/screens/vault/vault_onboarding_screen.dart';
import 'package:ibiti_guardian/screens/wallet/components/wallet_receive_modal.dart';
import 'package:ibiti_guardian/screens/wallet/components/wallet_send_modal.dart';
import 'package:ibiti_guardian/screens/wallet/components/wallet_swap_modal.dart';
import 'package:ibiti_guardian/screens/wallet/components/network_create_modal.dart';
import 'package:ibiti_guardian/screens/wallet/components/token_management_sheet.dart';
import 'package:ibiti_guardian/screens/wallet/wallet_card_detail_screen.dart';
import 'package:ibiti_guardian/screens/wallet/all_wallets_screen.dart';
import 'package:ibiti_guardian/screens/wallet/wallet_transaction_history_screen.dart';
import 'package:ibiti_guardian/screens/assistant/components/assistant_chat_screen.dart';
import 'package:ibiti_guardian/models/app_intent.dart';
import 'package:ibiti_guardian/services/execution/tx_registry.dart';
import 'package:ibiti_guardian/models/tx_status.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/audit_log_service.dart';
import 'package:ibiti_guardian/screens/wallet/components/wallet_add_card_modal.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/services/wallet/token_manager_service.dart';
import 'package:ibiti_guardian/services/wallet/wallet_settings_service.dart';
import 'package:ibiti_guardian/screens/wallet/token_detail_screen.dart';

/// Maps a chainId to a short human-readable network name.
String _chainName(int chainId, {String chainKey = ''}) {
  // Prefer chainKey for non-EVM chains
  if (chainKey == 'solana') return 'SOL';
  if (chainKey == 'tron') return 'TRX';
  const map = {
    1: 'ETH',
    56: 'BNB',
    137: 'Polygon',
    42161: 'Arbitrum',
    10: 'Optimism',
    8453: 'Base',
    43114: 'Avalanche',
    250: 'Fantom',
  };
  return map[chainId] ?? 'Chain $chainId';
}

/// Unique identity key for a WalletAsset across all chains.
/// Uses chainKey when available (non-EVM), falls back to chainId.
String _assetIdentity(WalletAsset asset) {
  final chain = asset.chainKey.isNotEmpty ? asset.chainKey : '${asset.chainId}';
  return '$chain:${asset.address}'.toLowerCase();
}

class WalletSpaceScreen extends StatefulWidget {
  const WalletSpaceScreen({super.key});

  @override
  State<WalletSpaceScreen> createState() => _WalletSpaceScreenState();
}

class _WalletSpaceScreenState extends State<WalletSpaceScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _headerFade;
  final PageController _pageController = PageController(viewportFraction: 0.95);
  int _currentCardIndex = 0;
  List<WalletCardModel> _activeWallets = [];

  static const List<CardAccent> _cardAccentOrder = [
    CardAccent.black,
    CardAccent.silver,
    CardAccent.gold,
    CardAccent.platinum,
  ];

  void _syncWalletCards(IBITIVaultService vault) {
    final chainKey = vault.chainKey;
    final nextWallets = <WalletCardModel>[];

    if (chainKey == 'tron') {
      // ── Tron: single Black card ──────────────────────────────────────
      final addr = vault.tronAddress;
      if (addr != null && addr.isNotEmpty) {
        nextWallets.add(WalletCardModel(
          id: 'tron_black',
          name: 'Card Black',
          fullAddress: addr,
          isPrimary: true,
          accent: CardAccent.black,
          chainKey: 'tron',
        ));
      }
    } else if (chainKey == 'solana') {
      // ── Solana: single Black card ────────────────────────────────────
      final addr = vault.solanaAddress;
      if (addr != null && addr.isNotEmpty) {
        nextWallets.add(WalletCardModel(
          id: 'solana_black',
          name: 'Card Black',
          fullAddress: addr,
          isPrimary: true,
          accent: CardAccent.black,
          chainKey: 'solana',
        ));
      }
    } else {
      // ── EVM: card per address (Black only for now) ───────────────────
      final addresses = vault.evmCardAddresses.isNotEmpty
          ? vault.evmCardAddresses
          : [vault.activeAddress].where((e) => e.isNotEmpty).toList();
      for (var i = 0;
          i < addresses.length && i < _cardAccentOrder.length;
          i++) {
        final accent = _cardAccentOrder[i];
        nextWallets.add(WalletCardModel(
          id: 'evm_card_$i',
          name: switch (accent) {
            CardAccent.black => 'Card Black',
            CardAccent.silver => 'Card Silver',
            CardAccent.gold => 'Card Gold',
            CardAccent.platinum => 'Card Platinum',
          },
          fullAddress: addresses[i],
          isPrimary: i == 0,
          accent: accent,
          chainKey: chainKey,
        ));
      }
    }

    _activeWallets = nextWallets;
    final activeIndex = _activeWallets.indexWhere(
      (wallet) =>
          wallet.fullAddress.toLowerCase() == vault.activeAddress.toLowerCase(),
    );
    _currentCardIndex = activeIndex >= 0 ? activeIndex : 0;
  }

  Future<void> _addNewCard(CardAccent accent) async {
    final vault = IBITIVaultService.instance;
    // Card creation only available for EVM networks
    if (vault.chainKey == 'tron' || vault.chainKey == 'solana') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Card creation for this network is in development.'),
          behavior: SnackBarBehavior.floating,
        ));
      }
      return;
    }
    final accentIndex = _cardAccentOrder.indexOf(accent);
    if (accentIndex <= 0) return;

    final createdAddress = await vault.createAdditionalEvmCard();
    if (!mounted || createdAddress == null) return;

    setState(() {
      _syncWalletCards(vault);
      _currentCardIndex = _activeWallets.indexWhere(
        (wallet) =>
            wallet.fullAddress.toLowerCase() == createdAddress.toLowerCase(),
      );
      if (_currentCardIndex < 0) {
        _currentCardIndex = _activeWallets.length - 1;
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_pageController.hasClients || _currentCardIndex < 0) return;
      _pageController.animateToPage(
        _currentCardIndex,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
      );
    });
  }

  List<CardAccent> _availableAddCardAccents() {
    final usedAccents = _activeWallets.map((wallet) => wallet.accent).toSet();
    return _cardAccentOrder
        .where((accent) =>
            accent != CardAccent.black && !usedAccents.contains(accent))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _headerFade = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500));
    _headerFade.forward();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // WalletSettingsService._load() is async — if settings are not yet loaded
      // (isLoaded == false), the defaultNetwork getter returns the hardcoded
      // 'Ethereum' default, which overwrites the user's persisted choice.
      // We must wait until the service finishes loading before applying.
      final settings = WalletSettingsService.instance;
      if (settings.isLoaded) {
        _applyDefaultNetwork(settings.defaultNetwork);
      } else {
        // One-shot listener: fires when _load() completes and calls notifyListeners.
        void onLoaded() {
          if (!mounted) return;
          if (settings.isLoaded) {
            settings.removeListener(onLoaded);
            _applyDefaultNetwork(settings.defaultNetwork);
          }
        }

        settings.addListener(onLoaded);
      }
    });
  }

  /// Switches to the user's preferred default network if it differs from the
  /// current active chain. No-op if the vault has no address for the chain.
  Future<void> _applyDefaultNetwork(String displayName) async {
    if (!mounted) return;
    final chain = PrivyChainRegistry.supportedChains.cast<dynamic>().firstWhere(
          (c) => c?.displayName == displayName,
          orElse: () => null,
        );
    if (chain != null &&
        IBITIVaultService.instance.hasAddressForChain(chain.chainKey) &&
        IBITIVaultService.instance.chainKey != chain.chainKey) {
      await IBITIVaultService.instance.setActiveChain(chain.chainKey);
    }
  }

  @override
  void dispose() {
    _headerFade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vault = IBITIVaultService.instance;

    return Scaffold(
      backgroundColor: GuardianColors.background,
      body: ListenableBuilder(
        listenable: vault,
        builder: (context, _) {
          if (!vault.isVaultCreated) {
            return _buildConnectPrompt(context);
          }

          _syncWalletCards(vault);
          final wallets = _activeWallets;

          return ListenableBuilder(
            listenable: Listenable.merge([
              VaultPortfolioListener.instance,
              TokenManagerService.instance,
              WalletSettingsService.instance,
            ]),
            builder: (context, _) {
              final portfolio = VaultPortfolioListener.instance;
              final walletSettings = WalletSettingsService.instance;
              final summary = portfolio.summary;
              final isLoading = portfolio.isLoading;
              final isStale = portfolio.isStale;
              final lastUpdatedAt = portfolio.lastUpdatedAt;
              final loadError = portfolio.lastError;

              // Always use current chain summary
              final totalUsd = summary?.totalBalanceUsd ?? 0.0;
              final assets = summary?.allAssets ?? [];
              final filtered = _sortAndFilterAssets(assets);

              final currentAccent =
                  wallets.isNotEmpty && _currentCardIndex < wallets.length
                      ? wallets[_currentCardIndex].accent
                      : CardAccent.black;

              return _BankBackground(
                currentAccent: currentAccent,
                child: SafeArea(
                  child: CustomScrollView(
                    physics: const BouncingScrollPhysics(),
                    slivers: [
                      SliverToBoxAdapter(
                        child: FadeTransition(
                          opacity: _headerFade,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // ── TOTAL BALANCE & TOP ICONS ───────────────────────────
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _TotalBalanceBlock(
                                      totalUsd: totalUsd,
                                      isLoading: isLoading,
                                      isStale: isStale,
                                      lastUpdatedAt: lastUpdatedAt,
                                      isVisible: walletSettings.balanceVisible,
                                      totalChangeUsd:
                                          summary?.totalChangeUsd ?? 0,
                                      totalChangePct:
                                          summary?.totalChangePct ?? 0,
                                      hasPerformanceData:
                                          summary?.hasPerformanceData ?? false,
                                      hasUnpricedAssets:
                                          summary?.hasUnpricedAssets ?? false,
                                    ),
                                    const Spacer(),
                                    _GlassBtn(
                                      icon: Icons.qr_code_scanner_rounded,
                                      onTap: () =>
                                          WalletReceiveModal.show(context),
                                    ),
                                    const SizedBox(width: 10),
                                    _GlassBtn(
                                      icon: Icons.refresh_rounded,
                                      onTap: () => VaultPortfolioListener
                                          .instance
                                          .refresh(),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 22),

                                // ── PRIMARY CARD CAROUSEL ────────────────────────────
                                SizedBox(
                                  height: 196,
                                  child: PageView.builder(
                                    controller: _pageController,
                                    physics: const BouncingScrollPhysics(),
                                    itemCount: wallets.length,
                                    onPageChanged: (index) async {
                                      setState(() => _currentCardIndex = index);
                                      if (index >= 0 &&
                                          index < wallets.length) {
                                        final card = wallets[index];
                                        // Within EVM — switch card address
                                        if (card.chainKey != 'tron' &&
                                            card.chainKey != 'solana') {
                                          await vault.setActiveEvmCard(
                                            card.fullAddress,
                                          );
                                        }
                                      }
                                    },
                                    itemBuilder: (context, index) {
                                      final wallet = wallets[index];
                                      final isActive =
                                          index == _currentCardIndex;
                                      return AnimatedScale(
                                        scale: isActive ? 1.0 : 0.93,
                                        duration:
                                            const Duration(milliseconds: 360),
                                        curve: Curves.easeOutCubic,
                                        child: AnimatedOpacity(
                                          opacity: isActive ? 1.0 : 0.6,
                                          duration:
                                              const Duration(milliseconds: 360),
                                          child: _PrimaryCard(
                                            wallet: wallet,
                                            displayAddress: wallet.fullAddress,
                                            onTap: () => _openCardDetail(
                                                context, wallet),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                                const SizedBox(height: 14),

                                // ── ALL WALLETS pill ────────────────────────
                                _AllWalletsPill(
                                  count: wallets.length,
                                  onTap: () =>
                                      _openAllWallets(context, wallets),
                                ),
                                const SizedBox(height: 24),

                                // ── QUICK ACTIONS ───────────────────────────
                                _QuickActionsRow(
                                  onSend: () => WalletSendModal.show(context),
                                  onReceive: () =>
                                      WalletReceiveModal.show(context),
                                  onSwap: () => WalletSwapModal.show(context),
                                  onScan: () => _openAiIntent(
                                      context,
                                      const AppIntent.scan(
                                          origin: 'wallet_button')),
                                ),
                                const SizedBox(height: 28),

                                // Network selector — always visible
                                _NetworkSelectorCarousel(
                                  selectedChainKey: vault.chainKey,
                                  onSelected: (key) {
                                    _handleChainSelected(context, key);
                                  },
                                ),
                                const SizedBox(height: 18),

                                // ── ASSETS ──────────────────────────────────
                                _AssetsBlock(
                                  assets: filtered,
                                  isLoading: isLoading,
                                  isSupported: summary?.isSupported ?? true,
                                  isStale: isStale,
                                  loadError: loadError,
                                  onRetry: () =>
                                      VaultPortfolioListener.instance.refresh(),
                                  onAssetTap: (asset) =>
                                      _showAssetActions(context, asset),
                                  onAssetLongPress: (asset) =>
                                      _showTokenManagementSheet(context, asset),
                                ),
                                const SizedBox(height: 20),

                                // ── SYSTEM STATUS ───────────────────────────
                                const _SystemStatusCard(),
                                const SizedBox(height: 16),

                                // ── RECENT ACTIONS ──────────────────────────
                                _RecentActionsBlock(
                                  onOpenHistory: () =>
                                      _openTransactionHistory(context),
                                ),
                                const SizedBox(height: 32),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _openCardDetail(BuildContext context, WalletCardModel wallet) {
    HapticFeedback.mediumImpact();
    Navigator.of(context).push(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 440),
      reverseTransitionDuration: const Duration(milliseconds: 360),
      pageBuilder: (_, animation, __) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: WalletCardDetailScreen(
          wallet: wallet,
          onAddCard: () {
            // Trigger the add card modal
            Navigator.of(context).pop(); // Exit detail screen
            WalletAddCardModal.show(
              context,
              availableAccents: _availableAddCardAccents(),
              onSelect: (color) {
                _addNewCard(color);
              },
            );
          },
        ),
      ),
    ));
  }

  void _openAllWallets(BuildContext context, List<WalletCardModel> wallets) {
    HapticFeedback.lightImpact();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AllWalletsScreen(wallets: wallets),
    ));
  }

  /// Opens [AssistantChatScreen] pre-seeded with a Swap [AppIntent].
  ///
  /// [sourceToken] is set when user taps Swap from a specific asset row
  /// (e.g. USDT) — the AI receives "I want to swap USDT" directly.
  void _openAiSwap(BuildContext context, {String? sourceToken}) {
    HapticFeedback.mediumImpact();
    _openAiIntent(
      context,
      AppIntent.swap(
        sourceToken: sourceToken,
        network:
            PrivyChainRegistry.getChain(IBITIVaultService.instance.chainKey)
                .displayName,
        origin: 'wallet_button',
      ),
    );
  }

  void _openAiIntent(BuildContext context, AppIntent intent) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AssistantChatScreen(
        onOpenVoice: () {},
        initialIntent: intent,
      ),
    ));
  }

  /// Asset-row tap → full-screen token detail page (MetaMask-style).
  void _showAssetActions(BuildContext context, WalletAsset asset) {
    HapticFeedback.mediumImpact();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TokenDetailScreen(asset: asset),
      ),
    );
  }

  /// Handles a network tap in the carousel.
  ///
  /// If the vault already has an address for [chainKey] → switch immediately.
  /// If not → show NetworkCreateModal; switch only after successful creation.
  Future<void> _handleChainSelected(
      BuildContext context, String chainKey) async {
    final vault = IBITIVaultService.instance;
    final fromNetwork = PrivyChainRegistry.getChain(vault.chainKey).displayName;
    final toNetwork = PrivyChainRegistry.getChain(chainKey).displayName;
    if (vault.hasAddressForChain(chainKey)) {
      await vault.setActiveChain(chainKey);
      AuditLogService.instance.recordNetworkSwitch(
        fromNetwork: fromNetwork,
        toNetwork: toNetwork,
        success: true,
      );
    } else {
      final created = await NetworkCreateModal.show(context, chainKey);
      if (created && context.mounted) {
        await vault.setActiveChain(chainKey);
        AuditLogService.instance.recordNetworkSwitch(
          fromNetwork: fromNetwork,
          toNetwork: toNetwork,
          success: true,
        );
      } else {
        AuditLogService.instance.recordNetworkSwitch(
          fromNetwork: fromNetwork,
          toNetwork: toNetwork,
          success: false,
          message: 'Network profile creation was cancelled or failed.',
        );
      }
    }
  }

  void _showComingSoon(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$feature coming soon.'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  /// Symbols that are exempt from the value-based spam filter.
  /// These are core assets that should always be visible when balance > 0.
  static const _safeSymbols = {
    'BNB',
    'ETH',
    'MATIC',
    'POL',
    'IBITI',
    'USDT',
    'USDC',
    'SOL',
    'TRX'
  };

  List<WalletAsset> _sortAndFilterAssets(List<WalletAsset> assets) {
    final tokenManager = TokenManagerService.instance;
    final settings = WalletSettingsService.instance;
    final chain =
        PrivyChainRegistry.getChain(IBITIVaultService.instance.chainKey);

    // ── Per-chain scoping ────────────────────────────────────────────────
    // Discard assets from other chains.
    final activeChainKey = IBITIVaultService.instance.chainKey;
    final scoped = assets.where((a) {
      // Match by chainKey first (most reliable)
      if (a.chainKey.isNotEmpty) {
        return a.chainKey == activeChainKey;
      }
      // Fallback: match by chainId for EVM assets
      if (chain.evmChainId != null) {
        return a.chainId == chain.evmChainId;
      }
      return true; // unknown chain metadata — keep
    }).toList();

    final merged = chain.evmChainId != null
        ? tokenManager.mergeCustomTokens(scoped, chain.evmChainId!)
        : scoped;

    // ── Dedup by address within final list ─────────────────────────────
    final seenAddrs = <String>{};
    final deduped = merged.where((a) {
      final key = _assetIdentity(a);
      if (seenAddrs.contains(key)) return false;
      seenAddrs.add(key);
      return true;
    }).toList();

    final visible = deduped.where((asset) {
      final tokenId = _assetIdentity(asset);
      if (tokenManager.isHidden(tokenId)) return false;
      // Native tokens always visible (even at zero balance)
      if (asset.isNative) return true;
      if (settings.hideZeroBalance && asset.balance <= 0) return false;
      // Spam filter: exempt native tokens and known safe symbols
      if (settings.spamFilter && asset.valueUsd < 0.01) {
        if (asset.isNative) return true;
        if (_safeSymbols.contains(asset.symbol.toUpperCase())) return true;
        return false;
      }
      return true;
    }).toList();

    visible.sort((a, b) {
      final aId = _assetIdentity(a);
      final bId = _assetIdentity(b);
      final aPinned = tokenManager.isPinned(aId);
      final bPinned = tokenManager.isPinned(bId);
      if (aPinned != bPinned) {
        return aPinned ? -1 : 1;
      }
      return b.valueUsd.compareTo(a.valueUsd);
    });

    return visible;
  }

  void _showTokenManagementSheet(BuildContext context, WalletAsset asset) {
    HapticFeedback.selectionClick();
    TokenManagementSheet.show(context, asset: asset);
  }

  void _openTransactionHistory(BuildContext context) {
    final activeAddress = IBITIVaultService.instance.activeAddress;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WalletTransactionHistoryScreen(
          walletAddress: activeAddress,
        ),
      ),
    );
  }

  Widget _buildConnectPrompt(BuildContext context) {
    return _BankBackground(
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: GuardianColors.glassBackground,
                    shape: BoxShape.circle,
                    border: Border.all(color: GuardianColors.glassBorder),
                  ),
                  child: const Icon(Icons.account_balance_wallet_outlined,
                      size: 36, color: GuardianColors.accent),
                ),
                const SizedBox(height: 24),
                Text(LocalizationService.instance.t('brandName'),
                    style: GuardianTextStyles.display.copyWith(fontSize: 28)),
                const SizedBox(height: 8),
                const Text(
                  'Connect your wallet to get started',
                  textAlign: TextAlign.center,
                  style: GuardianTextStyles.bodySecondary,
                ),
                const SizedBox(height: 36),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: GuardianColors.background,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999)),
                    ),
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const VaultOnboardingScreen())),
                    child: Text(
                        LocalizationService.instance.t('walletConnectBtn'),
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 17)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Background gradient ───────────────────────────────────────────────────────

class _BankBackground extends StatelessWidget {
  final Widget child;
  final CardAccent currentAccent;

  const _BankBackground({
    required this.child,
    this.currentAccent = CardAccent.black,
  });

  @override
  Widget build(BuildContext context) {
    // Generate base color for gradient based on accent
    final Color topColor = switch (currentAccent) {
      CardAccent.black => const Color(0xFF060A14),
      CardAccent.silver => const Color(0xFF161A20),
      CardAccent.gold => const Color(0xFF1E170A),
      CardAccent.platinum => const Color(0xFF141217),
    };

    final Color midColor = switch (currentAccent) {
      CardAccent.black => const Color(0xFF0A1020),
      CardAccent.silver => const Color(0xFF262A32),
      CardAccent.gold => const Color(0xFF33270F),
      CardAccent.platinum => const Color(0xFF201D28),
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [topColor, midColor, const Color(0xFF000000)],
          stops: const [0.0, 0.5, 1.0],
        ),
      ),
      child: child,
    );
  }
}

// ── Header ────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final VoidCallback onScanTap;
  const _Header({required this.onScanTap});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(LocalizationService.instance.t('brandName'),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5)),
            const SizedBox(height: 4),
            // ── Live TxRegistry status pill ──────────────────────────────
            ListenableBuilder(
              listenable: TxRegistry.instance,
              builder: (_, __) {
                // Active (non-terminal) tx has priority over latest
                final display =
                    TxRegistry.instance.activeTx ?? TxRegistry.instance.latest;
                if (display == null) {
                  return Text(
                      LocalizationService.instance.t('walletVaultSnapshot'),
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 13,
                          fontWeight: FontWeight.w500));
                }
                return _TxPill(event: display);
              },
            ),
          ],
        ),
        const Spacer(),
        _GlassBtn(icon: Icons.qr_code_scanner_rounded, onTap: onScanTap),
      ],
    );
  }
}

/// Compact status pill that shows latest tx state.
class _TxPill extends StatelessWidget {
  final TxStatusEvent event;
  const _TxPill({required this.event});

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (event.status) {
      TxStatus.submitted => (const Color(0xFFFFBB33), Icons.send_rounded),
      TxStatus.pending => (
          const Color(0xFFFFBB33),
          Icons.hourglass_top_rounded
        ),
      TxStatus.confirmed => (
          const Color(0xFF00FF9D),
          Icons.check_circle_outline_rounded
        ),
      TxStatus.failed => (const Color(0xFFFF3B30), Icons.error_outline_rounded),
      TxStatus.timeout => (const Color(0xFFFF9500), Icons.timer_off_outlined),
    };
    // statusLabel includes operationLabel when set
    final label = event.statusLabel;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      child: Row(
        key: ValueKey('${event.txHash}_${event.status}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 13),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2)),
        ],
      ),
    );
  }
}

// ── Total balance ─────────────────────────────────────────────────────────────

class _TotalBalanceBlock extends StatelessWidget {
  final double totalUsd;
  final bool isLoading;
  final bool isStale;
  final DateTime? lastUpdatedAt;
  final bool isVisible;
  final double totalChangeUsd;
  final double totalChangePct;
  final bool hasPerformanceData;
  final bool hasUnpricedAssets;
  const _TotalBalanceBlock({
    required this.totalUsd,
    required this.isLoading,
    required this.isStale,
    this.lastUpdatedAt,
    required this.isVisible,
    this.totalChangeUsd = 0,
    this.totalChangePct = 0,
    this.hasPerformanceData = false,
    this.hasUnpricedAssets = false,
  });

  @override
  Widget build(BuildContext context) {
    final isPositive = totalChangeUsd >= 0;
    final changeColor = isPositive
        ? const Color(0xFF4ADE80) // green-400
        : const Color(0xFFEF4444); // red-500

    return Column(
      children: [
        Text(LocalizationProvider.of(context).t('walletTotalAssets'),
            style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 14,
                fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        if (isLoading)
          const _ShimmerBlock(width: 200, height: 52)
        else
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(
                        begin: const Offset(0, 0.15), end: Offset.zero)
                    .animate(
                        CurvedAnimation(parent: anim, curve: Curves.easeOut)),
                child: child,
              ),
            ),
            child: Text(
              key: ValueKey(totalUsd.toStringAsFixed(2)),
              isVisible ? '\$${totalUsd.toStringAsFixed(2)}' : '••••••',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 46,
                fontWeight: FontWeight.w900,
                letterSpacing: -2,
              ),
            ),
          ),
        // --- Performance delta line with cloud icon ---
        if (hasPerformanceData && !isLoading) ...[
          const SizedBox(height: 4),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            child: isVisible
                ? Row(
                    key: ValueKey('perf_${totalChangeUsd.toStringAsFixed(2)}'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isStale
                            ? Icons.cloud_off_rounded
                            : Icons.cloud_done_rounded,
                        color: isStale ? GuardianColors.warning : changeColor,
                        size: 14,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        totalChangeUsd.abs() >= 0.01
                            ? '${isPositive ? '+' : ''}\$${totalChangeUsd.abs().toStringAsFixed(2)} '
                                '(${isPositive ? '+' : ''}${totalChangePct.toStringAsFixed(2)}%)'
                            : '${isPositive ? '+' : ''}${totalChangePct.toStringAsFixed(2)}%',
                        style: TextStyle(
                          color: changeColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ],
    );
  }

  String _formatFreshness(DateTime? lastUpdatedAt) {
    if (lastUpdatedAt == null) return 'Live snapshot';
    final diff = DateTime.now().difference(lastUpdatedAt);
    if (diff.inSeconds < 60) return 'Updated just now';
    if (diff.inMinutes < 60) return 'Updated ${diff.inMinutes}m ago';
    return 'Updated ${diff.inHours}h ago';
  }
}

// Shimmer skeleton — used during portfolio loading
class _ShimmerBlock extends StatefulWidget {
  final double width;
  final double height;
  const _ShimmerBlock({required this.width, required this.height});

  @override
  State<_ShimmerBlock> createState() => _ShimmerBlockState();
}

class _ShimmerBlockState extends State<_ShimmerBlock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat();
    _anim = CurvedAnimation(parent: _c, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            begin: Alignment(-1.5 + _anim.value * 3, 0),
            end: Alignment(1.5 + _anim.value * 3, 0),
            colors: [
              Colors.white.withOpacity(0.04),
              Colors.white.withOpacity(0.12),
              Colors.white.withOpacity(0.04),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Primary wallet card ───────────────────────────────────────────────────────

class _PrimaryCard extends StatefulWidget {
  final WalletCardModel wallet;

  /// Raw on-chain address line (for primary = live vault; for virtual cards = placeholder model).
  final String displayAddress;
  final VoidCallback onTap;
  const _PrimaryCard({
    required this.wallet,
    required this.displayAddress,
    required this.onTap,
  });

  @override
  State<_PrimaryCard> createState() => _PrimaryCardState();
}

class _PrimaryCardState extends State<_PrimaryCard> {
  bool _pressed = false;
  double _tiltX = 0;
  double _tiltY = 0;
  @override
  Widget build(BuildContext context) {
    final matrix = Matrix4.identity()
      ..setEntry(3, 2, 0.001)
      ..rotateX(_tiltX * 0.14)
      ..rotateY(_tiltY * 0.14);

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() {
          _pressed = false;
          _tiltX = 0;
          _tiltY = 0;
        });
        widget.onTap();
      },
      onTapCancel: () => setState(() {
        _pressed = false;
        _tiltX = 0;
        _tiltY = 0;
      }),
      child: AnimatedScale(
        scale: _pressed ? 0.975 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          transform: matrix,
          transformAlignment: Alignment.center,
          child: Hero(
            tag: 'wallet_card_${widget.wallet.id}',
            child: Material(
              color: Colors.transparent,
              child: Container(
                height: 210,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                      color: _shadowColor(widget.wallet.accent),
                      blurRadius: 40,
                      offset: const Offset(0, 20),
                    ),
                  ],
                  gradient: cardBorderGradient(widget.wallet.accent),
                ),
                padding: const EdgeInsets.all(0.95),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(29),
                    gradient: cardGradient(widget.wallet.accent),
                    border: Border.all(
                      color: cardInnerStrokeColor(widget.wallet.accent),
                      width: 0.7,
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('IBITI',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: -0.3)),
                              const SizedBox(height: 2),
                              Text('Guardian Wallet',
                                  style: TextStyle(
                                      color: Colors.white.withOpacity(0.5),
                                      fontSize: 10,
                                      letterSpacing: 0.6)),
                            ],
                          ),
                          const Spacer(),
                          // Glow dot
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: GuardianColors.success,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color:
                                      GuardianColors.success.withOpacity(0.5),
                                  blurRadius: 8,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      Center(
                        child: SizedBox(
                          width: double.infinity,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              WalletCardModel.maskForDisplay(
                                  widget.displayAddress),
                              maxLines: 1,
                              softWrap: false,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 3.0,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const Spacer(),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(widget.wallet.name,
                                  style: TextStyle(
                                      color: Colors.white.withOpacity(0.55),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                          const Spacer(),
                          const Text('IBITI',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 2)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ), // Hero
        ), // AnimatedContainer
      ), // AnimatedScale
    );
  }

  Color _shadowColor(CardAccent accent) {
    switch (accent) {
      case CardAccent.silver:
        return const Color(0x4488A0B9);
      case CardAccent.gold:
        return const Color(0x44A46A16);
      case CardAccent.platinum:
        return const Color(0x446C88B4);
      case CardAccent.black:
        return const Color(0x447A1E14);
    }
  }
}

// ── All wallets pill ──────────────────────────────────────────────────────────

class _AllWalletsPill extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _AllWalletsPill({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    return Center(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(999),
              border:
                  Border.all(color: Colors.white.withOpacity(0.12), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wallet_rounded, color: Colors.white, size: 15),
                const SizedBox(width: 8),
                Text(
                    t.t('walletAllWallets', {
                      'count': count.toString(),
                      'default': 'All wallets · {count}'
                    }),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700)),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right_rounded,
                    color: Colors.white.withOpacity(0.5), size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _QAShape { circle, roundedSquare, hexagon, diamond, pentagon }

class _QuickActionsRow extends StatelessWidget {
  final VoidCallback onSend, onReceive, onSwap, onScan;
  const _QuickActionsRow({
    required this.onSend,
    required this.onReceive,
    required this.onSwap,
    required this.onScan,
  });

  @override
  Widget build(BuildContext context) {
    final loc = LocalizationProvider.of(context);
    final items = [
      _QA(loc.t('walletActionSend'), Icons.arrow_upward_rounded, onSend,
          _QAShape.circle),
      _QA(loc.t('walletActionReceive'), Icons.south_rounded, onReceive,
          _QAShape.roundedSquare),
      _QA(loc.t('walletActionSwap'), Icons.sync_alt_rounded, onSwap,
          _QAShape.hexagon),
      _QA(loc.t('cmdScan'), Icons.radar_rounded, onScan, _QAShape.diamond),
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: items
          .map((q) => Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: _QuickActionBtn(item: q),
                ),
              ))
          .toList(),
    );
  }
}

class _QA {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final _QAShape shape;
  _QA(this.label, this.icon, this.onTap, this.shape);
}

class _QuickActionBtn extends StatefulWidget {
  final _QA item;
  const _QuickActionBtn({required this.item});

  @override
  State<_QuickActionBtn> createState() => _QuickActionBtnState();
}

class _QuickActionBtnState extends State<_QuickActionBtn> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        HapticFeedback.lightImpact();
        widget.item.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.88 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Column(
          children: [
            _QAShapeWidget(
                shape: widget.item.shape,
                icon: widget.item.icon,
                pressed: _pressed),
            const SizedBox(height: 9),
            Text(widget.item.label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

class _QAShapeWidget extends StatelessWidget {
  final _QAShape shape;
  final IconData icon;
  final bool pressed;
  const _QAShapeWidget(
      {required this.shape, required this.icon, required this.pressed});

  @override
  Widget build(BuildContext context) {
    const size = 60.0;
    final fill = Colors.white.withOpacity(0.08);
    final border = Colors.white.withOpacity(0.14);
    final shadow = pressed
        ? <BoxShadow>[]
        : [
            BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 12,
                offset: const Offset(0, 4))
          ];
    final child = Icon(icon, color: Colors.white, size: 24);

    switch (shape) {
      case _QAShape.circle:
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fill,
              border: Border.all(color: border),
              boxShadow: shadow),
          child: Center(child: child),
        );
      case _QAShape.roundedSquare:
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: fill,
              border: Border.all(color: border),
              boxShadow: shadow),
          child: Center(child: child),
        );
      case _QAShape.hexagon:
        return SizedBox(
          width: size,
          height: size,
          child: ClipPath(
            clipper: _HexClipper(),
            child: Container(color: fill, child: Center(child: child)),
          ),
        );
      case _QAShape.diamond:
        return SizedBox(
          width: size,
          height: size,
          child: Center(
            child: Transform.rotate(
              angle: math.pi / 4,
              child: Container(
                width: size * 0.72,
                height: size * 0.72,
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: fill,
                    border: Border.all(color: border),
                    boxShadow: shadow),
                child: Transform.rotate(
                  angle: -math.pi / 4,
                  child: Center(child: child),
                ),
              ),
            ),
          ),
        );
      case _QAShape.pentagon:
        return SizedBox(
          width: size,
          height: size,
          child: ClipPath(
            clipper: _PentagonClipper(),
            child: Container(color: fill, child: Center(child: child)),
          ),
        );
    }
  }
}

class _HexClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size s) {
    final path = Path()
      ..moveTo(s.width * 0.5, 0)
      ..lineTo(s.width, s.height * 0.25)
      ..lineTo(s.width, s.height * 0.75)
      ..lineTo(s.width * 0.5, s.height)
      ..lineTo(0, s.height * 0.75)
      ..lineTo(0, s.height * 0.25)
      ..close();
    return path;
  }

  @override
  bool shouldReclip(_) => false;
}

class _PentagonClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size s) {
    final cx = s.width / 2, cy = s.height / 2, r = s.width * 0.5;
    final path = Path();
    for (int i = 0; i < 5; i++) {
      final a = -math.pi / 2 + (2 * math.pi / 5) * i;
      final x = cx + r * math.cos(a), y = cy + r * math.sin(a);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    return path..close();
  }

  @override
  bool shouldReclip(_) => false;
}

// ── Network chips ─────────────────────────────────────────────────────────────

class _NetworkSelectorCarousel extends StatefulWidget {
  final String selectedChainKey;
  final ValueChanged<String> onSelected;

  const _NetworkSelectorCarousel({
    required this.selectedChainKey,
    required this.onSelected,
  });

  @override
  State<_NetworkSelectorCarousel> createState() =>
      _NetworkSelectorCarouselState();
}

class _NetworkSelectorCarouselState extends State<_NetworkSelectorCarousel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    const allChains = PrivyChainRegistry.supportedChains;

    // The pinned chain is the currently active one
    final pinnedChain = PrivyChainRegistry.getChain(widget.selectedChainKey);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.t('walletNetworksTitle', {'default': 'Networks'}),
            style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w900)),
        const SizedBox(height: 12),
        SizedBox(
          height: 40,
          child: Row(
            children: [
              // `[ All ]` Trigger Button — now toggles unified portfolio view
              GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  setState(() => _expanded = !_expanded);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                  decoration: BoxDecoration(
                    color: _expanded
                        ? Colors.white.withOpacity(0.15)
                        : Colors.white.withOpacity(0.07),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: _expanded
                          ? Colors.white.withOpacity(0.25)
                          : Colors.white.withOpacity(0.12),
                    ),
                  ),
                  child: Text(
                    'All',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),

              // Expanding Carousel
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) {
                    return SizeTransition(
                      sizeFactor: animation,
                      axis: Axis.horizontal,
                      axisAlignment: -1.0,
                      child: child,
                    );
                  },
                  child: _expanded
                      ? ListView.separated(
                          key: const ValueKey('expanded_list'),
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          itemCount: allChains.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (_, i) {
                            final chain = allChains[i];
                            final active =
                                chain.chainKey == widget.selectedChainKey;
                            return _buildChip(chain, active, true);
                          },
                        )
                      : Align(
                          key: const ValueKey('collapsed_single'),
                          alignment: Alignment.centerLeft,
                          child: _buildChip(pinnedChain, true, false),
                        ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildChip(PrivyChain chain, bool active, bool tapAllowed) {
    return GestureDetector(
      onTap: () {
        if (!tapAllowed) return;
        HapticFeedback.selectionClick();
        widget.onSelected(chain.chainKey);
        setState(() => _expanded = false); // Collapse on select
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        decoration: BoxDecoration(
          color: active ? Colors.white : Colors.white.withOpacity(0.07),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: active ? Colors.white : Colors.white.withOpacity(0.12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              chain.displayName,
              style: TextStyle(
                color: active ? Colors.black : Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Assets block ──────────────────────────────────────────────────────────────

class _AssetsBlock extends StatefulWidget {
  final List<WalletAsset> assets;
  final bool isLoading;
  final bool isSupported;
  final bool isStale;
  final String? loadError;
  final VoidCallback? onRetry;
  final void Function(WalletAsset)? onAssetTap;
  final void Function(WalletAsset)? onAssetLongPress;
  const _AssetsBlock(
      {required this.assets,
      required this.isLoading,
      this.isSupported = true,
      this.isStale = false,
      this.loadError,
      this.onRetry,
      this.onAssetTap,
      this.onAssetLongPress});

  @override
  State<_AssetsBlock> createState() => _AssetsBlockState();
}

class _AssetsBlockState extends State<_AssetsBlock> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    final visibleAssets = _showAll || widget.assets.length <= 5
        ? widget.assets
        : widget.assets.take(5).toList();
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(t.t('walletAssetsTitle', {'default': 'Assets'}),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w900)),
              const Spacer(),
              if (widget.assets.length > 5)
                TextButton(
                  onPressed: widget.isLoading
                      ? null
                      : () => setState(() => _showAll = !_showAll),
                  child: Text(
                    _showAll ? 'Show less' : 'Show all',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.65),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              TextButton(
                onPressed: widget.isLoading ? null : widget.onRetry,
                child: Text(widget.isStale ? 'Retry' : 'Refresh',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.5), fontSize: 13)),
              ),
            ],
          ),
          if (!widget.isLoading && (widget.loadError?.isNotEmpty ?? false))
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: GuardianColors.warning.withOpacity(0.10),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: GuardianColors.warning.withOpacity(0.28),
                ),
              ),
              child: const Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    color: GuardianColors.warning,
                    size: 16,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Portfolio update failed. Showing last snapshot.',
                      style: TextStyle(
                        color: GuardianColors.warning,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          if (widget.isLoading)
            Column(
              children: List.generate(
                  3,
                  (_) => const Padding(
                        padding: EdgeInsets.only(bottom: 14),
                        child:
                            _ShimmerBlock(width: double.infinity, height: 46),
                      )),
            )
          else if (!widget.isSupported)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  t.t('walletPortfolioNotSupported', {
                    'default':
                        'Network supported, portfolio loading not available yet'
                  }),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.4),
                    fontSize: 14,
                  ),
                ),
              ),
            )
          else if (widget.assets.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                    t.t('walletAssetsEmpty',
                        {'default': 'No assets on this network'}),
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.4), fontSize: 14)),
              ),
            )
          else
            ...visibleAssets.map((a) => _AssetRow(
                  asset: a,
                  onTap: widget.onAssetTap != null
                      ? () => widget.onAssetTap!(a)
                      : null,
                  onLongPress: widget.onAssetLongPress != null
                      ? () => widget.onAssetLongPress!(a)
                      : null,
                )),
        ],
      ),
    );
  }
}

class _AssetRow extends StatelessWidget {
  final WalletAsset asset;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  const _AssetRow({required this.asset, this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(14),
      splashColor: Colors.white.withOpacity(0.06),
      highlightColor: Colors.white.withOpacity(0.03),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.07),
                borderRadius: BorderRadius.circular(15),
              ),
              child: asset.logoUrl != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(15),
                      child: Image.network(asset.logoUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              _SymbolIcon(symbol: asset.symbol)))
                  : _SymbolIcon(symbol: asset.symbol),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(asset.symbol,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(
                    _chainName(asset.chainId, chainKey: asset.chainKey),
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.45), fontSize: 12),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  asset.balance.toStringAsFixed(4),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                // USD value — show "—" if price is unavailable
                Text(
                  asset.priceAvailable
                      ? '\$${asset.valueUsd.toStringAsFixed(2)}'
                      : '\u2014',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.45), fontSize: 12),
                ),
                // 24h change badge
                if (asset.priceChange24hPct != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    '${asset.priceChange24hPct! >= 0 ? '+' : ''}${asset.priceChange24hPct!.toStringAsFixed(2)}%',
                    style: TextStyle(
                      color: asset.priceChange24hPct! >= 0
                          ? const Color(0xFF4ADE80)
                          : const Color(0xFFEF4444),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded,
                color: Colors.white.withOpacity(0.2), size: 18),
          ],
        ),
      ),
    );
  }
}

class _SymbolIcon extends StatelessWidget {
  final String symbol;
  const _SymbolIcon({required this.symbol});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        symbol.length > 1 ? symbol.substring(0, 1) : symbol,
        style: const TextStyle(
            color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900),
      ),
    );
  }
}

// ── System status card ─────────────────────────────────────────────────────────

class _SystemStatusCard extends StatefulWidget {
  const _SystemStatusCard();

  @override
  State<_SystemStatusCard> createState() => _SystemStatusCardState();
}

class _SystemStatusCardState extends State<_SystemStatusCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breathe;
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    _breathe = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
    _glow = CurvedAnimation(parent: _breathe, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: TxRegistry.instance,
      builder: (_, __) {
        final t = LocalizationProvider.of(context);
        // Priority: active tx state > security clean state
        final activeTx = TxRegistry.instance.activeTx;
        final latest = TxRegistry.instance.latest;

        // Determine visual mode
        final bool isPending = activeTx != null;
        final bool isConfirmed =
            !isPending && latest?.status == TxStatus.confirmed;
        final bool isFailed = !isPending && latest?.status == TxStatus.failed;

        final Color statusColor = isPending
            ? const Color(0xFFFFBB33)
            : isFailed
                ? GuardianColors.danger
                : GuardianColors.success;

        final IconData statusIcon = isPending
            ? Icons.hourglass_top_rounded
            : isFailed
                ? Icons.error_outline_rounded
                : Icons.verified_user_rounded;

        final String title = isPending
            ? t.t('walletSysStatusActive',
                {'default': 'System status · TX active'})
            : isFailed
                ? t.t('walletSysStatusFailed',
                    {'default': 'System status · TX failed'})
                : isConfirmed
                    ? t.t('walletSysStatusConfirmed',
                        {'default': 'System status · Confirmed'})
                    : t.t('walletSysStatusSafe', {'default': 'System status'});

        // Show operation context from TxRegistry when available
        final activeLabel = (activeTx ?? latest)?.operationLabel;

        final String subtitle = isPending
            ? (activeLabel != null
                ? '$activeLabel…'
                : 'Processing transaction…')
            : isFailed
                ? (activeLabel != null
                    ? '$activeLabel failed'
                    : 'Last transaction failed')
                : isConfirmed
                    ? (activeLabel != null
                        ? '$activeLabel completed ✓'
                        : 'Transaction confirmed ✓')
                    : 'Protected · No threats detected';

        final String badge = isPending
            ? t.t('walletSysStateActive', {'default': 'Active'})
            : isFailed
                ? t.t('walletSysStateFailed', {'default': 'Failed'})
                : t.t('walletSysStateSafe', {'default': 'Safe'});

        return AnimatedBuilder(
          animation: _glow,
          builder: (_, __) => Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              gradient: LinearGradient(
                colors: [
                  statusColor.withOpacity(0.06 + _glow.value * 0.06),
                  (isPending ? const Color(0xFFFF8C00) : GuardianColors.accent)
                      .withOpacity(0.04 + _glow.value * 0.04),
                ],
              ),
              border: Border.all(
                color: statusColor.withOpacity(0.14 + _glow.value * 0.18),
              ),
              boxShadow: [
                BoxShadow(
                  color: statusColor.withOpacity(0.06 + _glow.value * 0.10),
                  blurRadius: 18 + _glow.value * 12,
                  spreadRadius: _glow.value * 2,
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.10 + _glow.value * 0.10),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color:
                            statusColor.withOpacity(0.2 + _glow.value * 0.25),
                        blurRadius: 12 + _glow.value * 8,
                      )
                    ],
                  ),
                  child: Icon(statusIcon, color: statusColor, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: Text(
                            key: ValueKey(title),
                            title,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w800)),
                      ),
                      const SizedBox(height: 3),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: Text(
                            key: ValueKey(subtitle),
                            subtitle,
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 12)),
                      ),
                    ],
                  ),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                      key: ValueKey(badge),
                      badge,
                      style: TextStyle(
                        color: statusColor,
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                      )),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ── Glass button ──────────────────────────────────────────────────────────────

class _GlassBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _GlassBtn({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

// ── Shared models ─────────────────────────────────────────────────────────────

enum CardAccent { black, silver, gold, platinum }

class WalletCardModel {
  final String id;
  final String name;
  final String fullAddress;
  final CardAccent accent;
  final bool isPrimary;
  final String chainKey;

  const WalletCardModel({
    required this.id,
    required this.name,
    required this.fullAddress,
    required this.accent,
    this.isPrimary = false,
    this.chainKey = 'bsc',
  });

  /// Masked line shown on cards / QR context — must stay in sync with [maskForDisplay].
  String get maskedAddress => WalletCardModel.maskForDisplay(fullAddress);

  static String maskForDisplay(String fullAddress) {
    if (fullAddress.contains('*')) return fullAddress;
    if (fullAddress.length < 8) return fullAddress;

    // For EVM addresses, preserve 0x prefix formatting
    if (fullAddress.startsWith('0x')) {
      final hex = fullAddress.substring(2);
      if (hex.length < 8) return fullAddress;
      return '0x${hex.substring(0, 4)}  ••••  ••••  ${hex.substring(hex.length - 4)}';
    }

    // For Tier 2 & Non-EVM (Solana/Tron) format naturally
    return '${fullAddress.substring(0, 4)}  ••••  ••••  ${fullAddress.substring(fullAddress.length - 4)}';
  }

  String get shortTail => WalletCardModel.shortTailFrom(fullAddress);

  static String shortTailFrom(String fullAddress) {
    if (fullAddress.length < 4) return fullAddress;
    return '•${fullAddress.substring(fullAddress.length - 4)}';
  }
}

// ── Recent actions block ──────────────────────────────────────────────────────

class _RecentActionsBlock extends StatelessWidget {
  final VoidCallback onOpenHistory;

  const _RecentActionsBlock({required this.onOpenHistory});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: TxRegistry.instance,
      builder: (_, __) {
        // Show only terminal txs, newest first, max 3
        final recent = TxRegistry.instance.history
            .where((e) => e.isTerminal)
            .toList()
            .reversed
            .take(3)
            .toList();

        if (recent.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12),
              child: Row(
                children: [
                  Text(LocalizationService.instance.t('walletRecent'),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w900)),
                  const Spacer(),
                  TextButton(
                    onPressed: onOpenHistory,
                    child:
                        Text(LocalizationService.instance.t('walletViewAll')),
                  ),
                ],
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withOpacity(0.07)),
              ),
              child: Column(
                children: recent
                    .asMap()
                    .entries
                    .map((entry) => _RecentRow(
                          event: entry.value,
                          isLast: entry.key == recent.length - 1,
                        ))
                    .toList(),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RecentRow extends StatelessWidget {
  final TxStatusEvent event;
  final bool isLast;
  const _RecentRow({required this.event, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (event.status) {
      TxStatus.confirmed => (GuardianColors.success, Icons.check_rounded),
      TxStatus.failed => (GuardianColors.danger, Icons.close_rounded),
      TxStatus.timeout => (GuardianColors.warning, Icons.timer_off_rounded),
      _ => (Colors.white54, Icons.radio_button_unchecked),
    };

    final label = event.operationLabel ?? event.statusLabel;
    final age = _timeAgo(event.timestamp);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(bottom: BorderSide(color: Colors.white.withOpacity(0.06))),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 16),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          Text(age,
              style: TextStyle(
                  color: Colors.white.withOpacity(0.4), fontSize: 12)),
        ],
      ),
    );
  }

  String _timeAgo(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

/// Card gradient per accent type
LinearGradient cardGradient(CardAccent accent) {
  switch (accent) {
    case CardAccent.black:
      return const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF1A1A1A), Color(0xFF0E0E0E), Color(0xFF141414)],
      );
    case CardAccent.silver:
      return const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF4A4E53), Color(0xFF2A2E33), Color(0xFF1F2226)],
      );
    case CardAccent.gold:
      return const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF5B4A1D), Color(0xFF33270B), Color(0xFF1F1705)],
      );
    case CardAccent.platinum:
      return const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF3A3E50), Color(0xFF222633), Color(0xFF171A21)],
      );
  }
}

LinearGradient cardBorderGradient(CardAccent accent) {
  switch (accent) {
    case CardAccent.black:
      return const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFF5C0D14),
          Color(0xFF9E2D1E),
          Color(0xFFD8AF63),
          Color(0xFF40100C),
        ],
        stops: [0.0, 0.26, 0.7, 1.0],
      );
    case CardAccent.silver:
      return const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFFF2F5FA),
          Color(0xFF9AA7B9),
          Color(0xFFD9E1EC),
          Color(0xFF707B8C),
        ],
        stops: [0.0, 0.3, 0.7, 1.0],
      );
    case CardAccent.gold:
      return const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFFFFE7A1),
          Color(0xFFD6A043),
          Color(0xFFF4D27A),
          Color(0xFF845511),
        ],
        stops: [0.0, 0.28, 0.68, 1.0],
      );
    case CardAccent.platinum:
      return const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFFF1F7FF),
          Color(0xFFA1B6D6),
          Color(0xFFD7E4F7),
          Color(0xFF6A7FA0),
        ],
        stops: [0.0, 0.32, 0.7, 1.0],
      );
  }
}

Color cardInnerStrokeColor(CardAccent accent) {
  switch (accent) {
    case CardAccent.black:
      return const Color(0x55E2BC77);
    case CardAccent.silver:
      return const Color(0x66F7FAFF);
    case CardAccent.gold:
      return const Color(0x66FFE3A4);
    case CardAccent.platinum:
      return const Color(0x66EAF2FF);
  }
}

// ── Asset actions bottom sheet ────────────────────────────────────────────────

class _AssetActionsSheet extends StatelessWidget {
  final WalletAsset asset;
  final VoidCallback onSend;
  final VoidCallback onReceive;
  final VoidCallback onSwap;
  final bool canSend;
  final bool canSwap;

  const _AssetActionsSheet({
    required this.asset,
    required this.onSend,
    required this.onReceive,
    required this.onSwap,
    required this.canSend,
    required this.canSwap,
  });

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final t = LocalizationProvider.of(context);
    return Container(
      margin: EdgeInsets.fromLTRB(12, 0, 12, 20 + bottomPadding),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1523),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
        boxShadow: const [
          BoxShadow(
              color: Color(0x55000000), blurRadius: 40, offset: Offset(0, -8)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.15),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
          // Asset header
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Center(
                  child: Text(
                      asset.symbol.substring(
                          0, asset.symbol.length > 3 ? 3 : asset.symbol.length),
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 13)),
                ),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(asset.symbol,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w900)),
                  Text(asset.name,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.45), fontSize: 12)),
                ],
              ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('\$${asset.valueUsd.toStringAsFixed(2)}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 16)),
                  Text(asset.balance.toStringAsFixed(4),
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.45), fontSize: 12)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 24),
          // Action buttons row
          Row(
            children: [
              _SheetAction(
                  icon: Icons.arrow_upward_rounded,
                  label: t.t('walletActionSend', {'default': 'Send'}),
                  onTap: onSend,
                  isEnabled: canSend),
              const SizedBox(width: 12),
              _SheetAction(
                  icon: Icons.arrow_downward_rounded,
                  label: t.t('walletActionReceive', {'default': 'Receive'}),
                  onTap: onReceive,
                  isEnabled: true),
              const SizedBox(width: 12),
              _SheetAction(
                  icon: Icons.sync_alt_rounded,
                  label: t.t('walletActionSwap', {'default': 'Swap'}),
                  onTap: onSwap,
                  highlight: true,
                  isEnabled: canSwap),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _SheetAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool highlight;
  final bool isEnabled;

  const _SheetAction(
      {required this.icon,
      required this.label,
      required this.onTap,
      this.highlight = false,
      this.isEnabled = true});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: () {
          if (!isEnabled) return;
          HapticFeedback.lightImpact();
          onTap();
        },
        child: Opacity(
          opacity: isEnabled ? 1.0 : 0.35,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: highlight
                  ? Colors.white.withOpacity(0.12)
                  : Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: highlight
                      ? Colors.white.withOpacity(0.2)
                      : Colors.white.withOpacity(0.08)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 22),
                const SizedBox(height: 6),
                Text(label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
