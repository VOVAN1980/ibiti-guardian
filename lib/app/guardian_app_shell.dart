import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/screens/assistant/assistant_home_screen.dart';
import 'package:ibiti_guardian/screens/assistant/components/assistant_chat_screen.dart';
import 'package:ibiti_guardian/screens/security/guardian_control_screen.dart';
import 'package:ibiti_guardian/screens/security/security_center_screen.dart';
import 'package:ibiti_guardian/screens/security/ai_control_screen.dart'
    show AIControlScreen;
import 'package:ibiti_guardian/screens/settings/settings_screen.dart';
import 'package:ibiti_guardian/screens/market_command/market_command_screen.dart';
import 'package:ibiti_guardian/models/trading_plan.dart';
import 'package:ibiti_guardian/screens/wallet/components/wallet_receive_modal.dart';
import 'package:ibiti_guardian/screens/wallet/components/wallet_send_modal.dart';
import 'package:ibiti_guardian/screens/wallet/components/wallet_swap_modal.dart';
import 'package:ibiti_guardian/screens/wallet/components/wallet_trade_modal.dart';
import 'package:ibiti_guardian/screens/wallet/wallet_address_book_screen.dart';
import 'package:ibiti_guardian/screens/wallet/wallet_settings_screen.dart';
import 'package:ibiti_guardian/screens/wallet/wallet_space_screen.dart';
import 'package:ibiti_guardian/screens/wallet/wallet_transaction_history_screen.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_bus.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/market/automation_dispatch_service.dart';
import 'package:ibiti_guardian/services/market/automation_engine.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_registry.dart';
import 'package:ibiti_guardian/services/voice/voice_turn_controller.dart';
import 'package:ibiti_guardian/services/assistant/assistant_session_context.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';
import 'package:ibiti_guardian/widgets/floating_mic_bubble.dart';
import 'package:ibiti_guardian/screens/market_command/widgets/cex_spot_trade_modal.dart';
import 'package:ibiti_guardian/services/wallet/wallet_topup_detector.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';

class GuardianAppShell extends StatefulWidget {
  final int initialIndex;
  const GuardianAppShell({super.key, this.initialIndex = 0});
  @override
  State<GuardianAppShell> createState() => _GuardianAppShellState();
}

class _GuardianAppShellState extends State<GuardianAppShell>
    with WidgetsBindingObserver {
  late int _currentIndex;
  StreamSubscription<UICommand>? _cmdSub;
  final _marketKey = GlobalKey<MarketCommandScreenState>();
  final _voice = VoiceTurnController.instance;
  OverlayEntry? _bubbleOverlay;

  // ValueNotifier so the OverlayEntry builder always reads fresh state.
  final _bubbleVisible = ValueNotifier<bool>(false);

  late final List<Widget> _screens = [
    const AssistantHomeScreen(),
    AssistantChatScreen(onOpenVoice: () {}),
    const SecurityCenterScreen(),
    const WalletSpaceScreen(),
    MarketCommandScreen(key: _marketKey),
    const SettingsScreen(),
  ];

  // Navigation tab index by target string.
  static const _tabIndex = <String, int>{
    'ai': 0,
    'chat': 1,
    'security_center': 2,
    'wallet': 3,
    'market': 4,
    'settings': 5,
  };

  // Index → screen name for ScreenContextService.
  static const _screenNames = [
    'ai',
    'chat',
    'security',
    'wallet',
    'market',
    'settings'
  ];

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, _screens.length - 1);
    ScreenContextService.instance.setScreen(_screenNames[_currentIndex]);
    AutomationEngine.instance.start();
    AutomationDispatchService.instance.start();
    WidgetsBinding.instance.addObserver(this);

    // ── UICommandBus consumer ─────────────────────────────────────────────────
    // This is the ONLY place that converts voice/chat UICommands into actual
    // navigation and modal actions. Without this subscription, all commands
    // dispatched by GuardianAssistantService go to void.
    _cmdSub = UICommandBus.instance.commands.listen(_handleUICommand);

    // ── Floating mic bubble ───────────────────────────────────────────────────
    // OverlayEntry is created ONCE after the first frame and never removed.
    // Visibility is controlled via Opacity + IgnorePointer inside the bubble.
    _voice.sessionNotifier.addListener(_onSessionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _bubbleOverlay = OverlayEntry(
        // Wrap in Stack so Positioned works correctly inside Overlay.
        builder: (_) => Stack(
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: _bubbleVisible,
              builder: (_, visible, __) => ValueListenableBuilder<Offset?>(
                valueListenable: ScreenContextService.instance.bubblePosition,
                builder: (_, initPos, __) => FloatingMicBubble(
                  isVisible: visible,
                  initialPosition: initPos,
                ),
              ),
            ),
          ],
        ),
      );
      Overlay.of(context, rootOverlay: true).insert(_bubbleOverlay!);
    });
  }

  @override
  void dispose() {
    _cmdSub?.cancel();
    _bubbleOverlay?.remove();
    _bubbleVisible.dispose();
    _voice.sessionNotifier.removeListener(_onSessionChanged);
    WidgetsBinding.instance.removeObserver(this);
    AutomationEngine.instance.stop();
    AutomationDispatchService.instance.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // End voice session when app goes to background.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (_voice.isSessionActive) {
        _voice.endSession();
        AssistantSessionContext.instance.resetSession();
      }
    }

    // When app returns from background — reconnect exchanges and force
    // an immediate price alert check so notifications fire instantly,
    // not only after navigating to the market tab.
    if (state == AppLifecycleState.resumed) {
      final registry = ExchangeRegistry.instance;
      for (final id in registry.availableExchanges) {
        final svc = registry.serviceFor(id);
        if (!svc.isConnected) {
          svc.connect();
        }
      }
      // Trigger an immediate balance check across all networks/wallets
      WalletTopUpDetector.instance.checkAllBalances();
    }
  }

  /// Called when session state changes — updates the ValueNotifier
  /// which drives the bubble's isVisible parameter reactively.
  void _onSessionChanged() {
    _updateBubbleVisibility();
  }

  /// Compute and push bubble visibility to the ValueNotifier.
  /// Bubble is visible only when session is active AND we are NOT on the
  /// AI Voice tab (index 0) — which has its own PTT button.
  void _updateBubbleVisibility() {
    final visible = _voice.isSessionActive && _currentIndex != 0;
    if (_bubbleVisible.value != visible) {
      _bubbleVisible.value = visible;
    }
  }

  /// Handles a single UICommand from the assistant pipeline.
  ///
  /// Runs after the current frame so that `context` is always valid,
  /// even if the command arrives while the widget tree is still building.
  void _handleUICommand(UICommand cmd) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (cmd.type) {
        case UICommandType.navigate:
          if (cmd.target == 'showTradingPlan') {
            _handleShowPlan(cmd);
          } else {
            final idx = _tabIndex[cmd.target];
            if (idx != null && idx != _currentIndex) {
              setState(() => _currentIndex = idx);
              _updateBubbleVisibility();
            }
          }

        case UICommandType.openModal:
          _openModal(cmd.target ?? '');
          _updateBubbleVisibility();

        case UICommandType.dismiss:
          _dismissTop();
          AssistantSessionContext.instance.setOpenModal(null);

        case UICommandType.showTradingPlan:
          _handleShowPlan(cmd);

        // fillField / selectToken / executeAction are consumed by the
        // individual modal widgets (e.g. wallet_send_modal.dart) that already
        // listen to UICommandBus internally.
        default:
          break;
      }
    });
  }

  /// Closes the topmost route (modal, bottom sheet, dialog, pushed screen).
  /// For tab screens (IndexedStack) that are NOT pushed routes, falls back
  /// to the AI home tab (index 0) so the user is never left on a random screen.
  void _dismissTop() {
    if (!mounted) return;
    final nav = Navigator.of(context, rootNavigator: true);
    nav.maybePop().then((popped) {
      // maybePop returns true only if something was actually dismissed.
      // If nothing was popped (e.g. wallet is a tab, not a route),
      // return to the AI home tab.
      if (!popped && mounted && _currentIndex != 0) {
        setState(() => _currentIndex = 0);
        _updateBubbleVisibility();
      }
    });
  }

  /// Handles `showTradingPlan` command: switches to market tab and optionally shows a plan if provided.
  void _handleShowPlan(UICommand cmd) {
    if (!mounted) return;
    // Switch to market tab (index 4)
    if (_currentIndex != 4) {
      setState(() => _currentIndex = 4);
    }

    // If there is no specific plan payload, just navigating to the market tab is enough.
    if (cmd.payload == null || cmd.payload!['plan'] == null) return;

    // Delay slightly so MarketCommandScreen is built and ready
    Future.delayed(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      final plan = cmd.payload!['plan'];
      if (plan is TradingPlan) {
        _marketKey.currentState?.showPlan(plan);
      }
    });
  }

  /// Opens the correct modal / screen for the given [target] string.
  ///
  /// Uses `useRootNavigator: true` so the sheet always appears on top of the
  /// current tab, regardless of which screen is active.
  void _openModal(String target) {
    if (!mounted) return;
    final ctx = context;

    // Track open modal for voice session follow-up context.
    AssistantSessionContext.instance.setOpenModal(target);

    switch (target) {
      case 'safe':
        GuardianControlScreen.showAiModal(ctx, mode: 'safe');

      case 'panic':
        GuardianControlScreen.showAiModal(ctx, mode: 'panic');

      case 'wallet_receive':
        // Navigate to wallet tab first, then open receive modal.
        if (_currentIndex != 3) setState(() => _currentIndex = 3);
        // Delay slightly so WalletSpaceScreen is mounted and listening.
        Future.delayed(const Duration(milliseconds: 220), () {
          if (mounted) WalletReceiveModal.show(ctx);
        });

      case 'wallet_send':
        if (_currentIndex != 3) setState(() => _currentIndex = 3);
        Future.delayed(const Duration(milliseconds: 220), () {
          if (mounted) WalletSendModal.show(ctx);
        });

      case 'wallet_swap':
        if (_currentIndex != 3) setState(() => _currentIndex = 3);
        Future.delayed(const Duration(milliseconds: 220), () {
          if (mounted) WalletSwapModal.show(ctx);
        });

      case 'cex_trade':
        final payload = UICommandBus.instance.latestPayload('cex_trade');
        if (payload != null) {
          final symbol = payload['symbol']?.toString().toUpperCase() ?? 'SOL';
          final isBuy = payload['isBuy'] as bool? ?? true;
          final exchangeId = payload['exchangeId']?.toString().toLowerCase() ?? 'mexc';
          final initialAmount = (payload['initialAmount'] as num?)?.toDouble();
          final price = (payload['price'] as num?)?.toDouble() ?? 0.0;
          final quoteAsset = payload['quoteAsset']?.toString() ?? 'USDT';

          final asset = MarketAsset(
            id: symbol.toLowerCase(),
            symbol: symbol,
            name: symbol,
            price: price,
            imageUrl: '',
            change24h: 0,
            marketCap: 0,
            volume: 0,
            rank: 0,
            sparkline: const [],
            high24h: 0,
            low24h: 0,
            change7d: 0,
            change30d: 0,
            networkGroup: '',
            sourceId: exchangeId,
            sourcePair: '$symbol-$quoteAsset',
          );

          final isSuccess = payload['isSuccess'] as bool? ?? false;
          final orderId = payload['orderId']?.toString();
          final executedQty = (payload['executedQty'] as num?)?.toDouble();
          final executedPrice = (payload['executedPrice'] as num?)?.toDouble();

          CexSpotTradeModal.show(
            ctx,
            asset: asset,
            isBuy: isBuy,
            initialAmount: initialAmount,
            isSuccess: isSuccess,
            orderId: orderId,
            executedQty: executedQty,
            executedPrice: executedPrice,
          );
        }

      case 'wallet_buy':
        if (_currentIndex != 3) setState(() => _currentIndex = 3);
        Future.delayed(const Duration(milliseconds: 220), () {
          if (mounted) WalletTradeModal.show(ctx, isBuy: true);
        });

      case 'wallet_sell':
        if (_currentIndex != 3) setState(() => _currentIndex = 3);
        Future.delayed(const Duration(milliseconds: 220), () {
          if (mounted) WalletTradeModal.show(ctx, isBuy: false);
        });

      case 'wallet_history':
        if (_currentIndex != 3) setState(() => _currentIndex = 3);
        Future.delayed(const Duration(milliseconds: 120), () {
          if (mounted) {
            Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute(
                builder: (_) => const WalletTransactionHistoryScreen(),
              ),
            );
          }
        });

      case 'wallet_address_book':
        if (_currentIndex != 3) setState(() => _currentIndex = 3);
        Future.delayed(const Duration(milliseconds: 120), () {
          if (mounted) {
            Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute(
                builder: (_) => const WalletAddressBookScreen(),
              ),
            );
          }
        });

      case 'wallet_settings':
        if (_currentIndex != 3) setState(() => _currentIndex = 3);
        Future.delayed(const Duration(milliseconds: 120), () {
          if (mounted) {
            Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute(
                builder: (_) => const WalletSettingsScreen(),
              ),
            );
          }
        });

      case 'ai_control':
        Navigator.of(ctx, rootNavigator: true).push(
          MaterialPageRoute(builder: (_) => const AIControlScreen()),
        );

      case 'policy_limits':
        if (_currentIndex != 2) setState(() => _currentIndex = 2);

      case 'epk_control':
        if (_currentIndex != 2) setState(() => _currentIndex = 2);

      case 'audit_history':
        if (_currentIndex != 2) setState(() => _currentIndex = 2);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          if (index == _currentIndex) return;
          setState(() => _currentIndex = index);
          ScreenContextService.instance.setScreen(_screenNames[index]);
          _updateBubbleVisibility();
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.auto_awesome_outlined),
            selectedIcon: const Icon(Icons.auto_awesome),
            label: LocalizationProvider.of(context).t('navAi'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.chat_bubble_outline),
            selectedIcon: const Icon(Icons.chat_bubble),
            label: LocalizationProvider.of(context).t('navChat'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.shield_outlined),
            selectedIcon: const Icon(Icons.shield),
            label: LocalizationProvider.of(context).t('navSecurity'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.account_balance_wallet_outlined),
            selectedIcon: const Icon(Icons.account_balance_wallet),
            label: LocalizationProvider.of(context).t('navWallet'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.show_chart_outlined),
            selectedIcon: const Icon(Icons.show_chart),
            label: LocalizationProvider.of(context).t('navMarket'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: LocalizationProvider.of(context).t('navSettings'),
          ),
        ],
      ),
    );
  }
}
