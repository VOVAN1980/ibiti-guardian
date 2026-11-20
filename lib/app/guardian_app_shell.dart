import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/screens/assistant/assistant_home_screen.dart';
import 'package:ibiti_guardian/screens/assistant/components/assistant_chat_screen.dart';
import 'package:ibiti_guardian/screens/security/guardian_control_screen.dart';
import 'package:ibiti_guardian/screens/security/security_center_screen.dart';
import 'package:ibiti_guardian/screens/security/trusted_addresses_screen.dart';
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
import 'package:ibiti_guardian/services/security/ai_action_gate.dart';
import 'package:ibiti_guardian/services/voice/voice_turn_controller.dart';
import 'package:ibiti_guardian/services/assistant/assistant_session_context.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';
import 'package:ibiti_guardian/widgets/floating_mic_bubble.dart';
import 'package:ibiti_guardian/screens/market_command/widgets/cex_spot_trade_modal.dart';
import 'package:ibiti_guardian/services/wallet/wallet_topup_detector.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/dapp/dapp_link_service.dart';
import 'package:ibiti_guardian/screens/dapp/dapp_browser_screen.dart';

/// Where the floating mic bubble is ([GuardianAppShell.micBubblePlace]).
enum MicBubblePlace {
  /// Not shown.
  hidden,

  /// At its usual spot (bottom right, or where the user dragged it).
  usual,

  /// In the strip at the top of the screen, above an open AI confirmation
  /// card ([GuardianAppShell.aboveAiCard]).
  aboveAiCard,
}

class GuardianAppShell extends StatefulWidget {
  final int initialIndex;
  const GuardianAppShell({super.key, this.initialIndex = 0});

  /// How many main screens are mounted (normally one). Notification taps
  /// wait for it, so they never open anything over the unlock screen.
  static int _mountedCount = 0;
  static bool get isMounted => debugIsMountedOverride ?? _mountedCount > 0;

  /// Tests: stands for "the main screen is mounted" (null = the real count),
  /// so notification routing can be tested without the whole main screen.
  @visibleForTesting
  static bool? debugIsMountedOverride;

  /// Where the floating mic bubble is. Normally only during a voice session
  /// and off the AI Voice tab (index 0, which has its own mic button), at
  /// its usual spot. While an AI confirmation card is open it shows on EVERY
  /// tab, with or without a session: the card is a root modal sheet whose
  /// barrier covers every tab's own mic button (the AI Voice tab's too), and
  /// it tells the user they can answer «да» / «нет» by voice (D5). The
  /// bubble is drawn above all routes, so it stays reachable — and so it
  /// then goes to the strip at the top of the screen, above the card
  /// ([aboveAiCard]): at its usual spot (bottom right) it would cover the
  /// card's note, its «да» / «нет» hint or even «Подтвердить».
  @visibleForTesting
  static MicBubblePlace micBubblePlace({
    required bool sessionActive,
    required int tabIndex,
    required bool aiCardOpen,
  }) {
    if (aiCardOpen) return MicBubblePlace.aboveAiCard;
    if (sessionActive && tabIndex != 0) return MicBubblePlace.usual;
    return MicBubblePlace.hidden;
  }

  /// Whether the floating mic bubble shows at all ([micBubblePlace]).
  @visibleForTesting
  static bool micBubbleVisible({
    required bool sessionActive,
    required int tabIndex,
    required bool aiCardOpen,
  }) =>
      micBubblePlace(
        sessionActive: sessionActive,
        tabIndex: tabIndex,
        aiCardOpen: aiCardOpen,
      ) !=
      MicBubblePlace.hidden;

  /// AiActionConfirmSheet: the card is at most this share of the screen
  /// high, with [_aiCardBottomGap] and the bottom safe area below it.
  static const double _aiCardMaxHeightFactor = 0.85;
  static const double _aiCardBottomGap = 12;

  /// FloatingMicBubble: 72 px high, kept at least 4 px below the top inset
  /// and 8 px above the bottom of the screen it is given.
  static const double _bubbleFootprint = 4 + 72 + 8;

  /// Height of the strip at the top of the screen the mic bubble keeps to
  /// while an AI card is open: everything above the tallest card the sheet
  /// can show, and never less than the bubble needs below the status bar.
  /// Only a card taller than ~80 % of the screen can reach the strip, and
  /// then only its title row: the bubble never sits on the card's rows,
  /// note, hint or buttons.
  @visibleForTesting
  static double aboveAiCardStripHeight(MediaQueryData mq) {
    final aboveTallestCard = mq.size.height * (1 - _aiCardMaxHeightFactor) -
        _aiCardBottomGap -
        mq.padding.bottom;
    return math.max(aboveTallestCard, mq.padding.top + _bubbleFootprint);
  }

  /// [bubble] (a [FloatingMicBubble], which places and clamps itself in the
  /// screen its MediaQuery describes) kept to the strip above the AI card:
  /// it is given a screen that ends at the strip's bottom, with no bottom
  /// inset and no keyboard, so its default spot (then the top right, just
  /// below the status bar) and every drag stay inside the strip.
  @visibleForTesting
  static Widget aboveAiCard(BuildContext context, Widget bubble) {
    final mq = MediaQuery.of(context);
    final height = aboveAiCardStripHeight(mq);
    return Positioned(
      left: 0,
      top: 0,
      right: 0,
      height: height,
      child: MediaQuery(
        data: mq.copyWith(
          size: Size(mq.size.width, height),
          padding: mq.padding.copyWith(bottom: 0),
          viewPadding: mq.viewPadding.copyWith(bottom: 0),
          viewInsets: EdgeInsets.zero,
        ),
        child: Stack(clipBehavior: Clip.none, children: [bubble]),
      ),
    );
  }

  /// Whether an AI confirmation card is open ([AiActionGate.hasOpenCard]),
  /// as seen after the last frame. The card is a root modal sheet, so a
  /// frame always runs when it opens or closes (its slide animation): a
  /// check after each frame catches both, with no timer polling. Persistent
  /// frame callbacks cannot be removed, so the watch is installed once, on
  /// the first call, and lives as long as the app.
  static ValueListenable<bool> aiCardOpenWatch() {
    if (!_aiCardWatchInstalled) {
      _aiCardWatchInstalled = true;
      WidgetsBinding.instance.addPersistentFrameCallback((_) {
        if (_aiCardOpen.value == AiActionGate.instance.hasOpenCard) return;
        // Mid-frame: the listeners rebuild widgets, so tell them right
        // after this frame.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _aiCardOpen.value = AiActionGate.instance.hasOpenCard;
        });
      });
    }
    return _aiCardOpen;
  }

  static final ValueNotifier<bool> _aiCardOpen = ValueNotifier<bool>(false);
  static bool _aiCardWatchInstalled = false;

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
  final _bubblePlace = ValueNotifier<MicBubblePlace>(MicBubblePlace.hidden);

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
    GuardianAppShell._mountedCount++;
    _currentIndex = widget.initialIndex.clamp(0, _screens.length - 1);
    ScreenContextService.instance.setScreen(_screenNames[_currentIndex]);
    AutomationEngine.instance.start();
    AutomationDispatchService.instance.start();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      DappLinkService.instance.attach((url) {
        if (!mounted) return;
        Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => DappBrowserScreen(initialUrl: url),
        ));
      });
    });

    // ── UICommandBus consumer ─────────────────────────────────────────────────
    // This is the ONLY place that converts voice/chat UICommands into actual
    // navigation and modal actions. Without this subscription, all commands
    // dispatched by GuardianAssistantService go to void.
    _cmdSub = UICommandBus.instance.commands.listen(_handleUICommand);

    // ── Floating mic bubble ───────────────────────────────────────────────────
    // OverlayEntry is created ONCE after the first frame and never removed.
    // Visibility is controlled via Opacity + IgnorePointer inside the bubble.
    _voice.sessionNotifier.addListener(_onSessionChanged);
    // An AI confirmation card opening / closing shows / hides the bubble.
    GuardianAppShell.aiCardOpenWatch().addListener(_updateBubbleVisibility);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _bubbleOverlay = OverlayEntry(
        // Wrap in Stack so Positioned works correctly inside Overlay.
        builder: (_) => ValueListenableBuilder<MicBubblePlace>(
          valueListenable: _bubblePlace,
          builder: (_, place, __) => Stack(
            children: [
              // The usual bubble: it keeps its own (dragged) spot while it
              // is hidden, also while an AI card is open.
              ValueListenableBuilder<Offset?>(
                valueListenable: ScreenContextService.instance.bubblePosition,
                builder: (_, initPos, __) => FloatingMicBubble(
                  isVisible: place == MicBubblePlace.usual,
                  initialPosition: initPos,
                ),
              ),
              // An AI card is open: a bubble of its own, only while the
              // card is, in the strip above the card — it never covers the
              // card, and «да» / «нет» by voice stays one tap away (D5).
              if (place == MicBubblePlace.aboveAiCard)
                Builder(
                  builder: (stripContext) => GuardianAppShell.aboveAiCard(
                    stripContext,
                    const FloatingMicBubble(
                      key: ValueKey('aiCardMicBubble'),
                      isVisible: true,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
      Overlay.of(context, rootOverlay: true).insert(_bubbleOverlay!);
    });
  }

  @override
  void dispose() {
    GuardianAppShell._mountedCount--;
    GuardianAppShell.aiCardOpenWatch()
        .removeListener(_updateBubbleVisibility);
    DappLinkService.instance.detach();
    _cmdSub?.cancel();
    _bubbleOverlay?.remove();
    _bubblePlace.dispose();
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

  /// Compute and push the bubble's place to the ValueNotifier: during a
  /// voice session off the AI Voice tab (index 0 has its own PTT button) at
  /// its usual spot, and on every tab, above the card, while an AI
  /// confirmation card is open ([GuardianAppShell.micBubblePlace]).
  void _updateBubbleVisibility() {
    final place = GuardianAppShell.micBubblePlace(
      sessionActive: _voice.isSessionActive,
      tabIndex: _currentIndex,
      aiCardOpen: AiActionGate.instance.hasOpenCard,
    );
    if (_bubblePlace.value != place) {
      _bubblePlace.value = place;
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
          _openModal(cmd.target ?? '', cmdPayload: cmd.payload);
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
  /// [cmdPayload] is the payload of THIS command (not the latest one on the
  /// bus, which another command may already have replaced).
  ///
  /// Uses `useRootNavigator: true` so the sheet always appears on top of the
  /// current tab, regardless of which screen is active.
  void _openModal(String target, {Map<String, dynamic>? cmdPayload}) {
    if (!mounted) return;
    final ctx = context;

    // Track open modal for voice session follow-up context.
    AssistantSessionContext.instance.setOpenModal(target);

    switch (target) {
      // A window opened by the user's own macro is the user's window; the
      // model can't set 'byUserMacro' (stripped from its commands).
      case 'safe':
      case 'panic':
        if (cmdPayload?['byUserMacro'] == true) {
          GuardianControlScreen.showUserModal(ctx, mode: target);
        } else {
          GuardianControlScreen.showAiModal(ctx, mode: target);
        }

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
        // The command's own payload: commands run after the frame, so two
        // cex_trade commands in one frame (e.g. a gated order's result and
        // another order window) used to both open with the last payload.
        final payload =
            cmdPayload ?? UICommandBus.instance.latestPayload('cex_trade');
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

      case 'ai_action':
        // Tap on «ИИ выполнил: …»: every AI operation (exchange orders too)
        // is in the transaction history. cmdPayload['historyId'] names the
        // entry (an exchange order id or a tx hash); the history opens it.
        final historyId = cmdPayload?['historyId']?.toString();
        if (_currentIndex != 3) setState(() => _currentIndex = 3);
        Future.delayed(const Duration(milliseconds: 120), () {
          if (mounted) {
            Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute(
                builder: (_) =>
                    WalletTransactionHistoryScreen(focusId: historyId),
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

      case 'trusted_addresses':
        // Asked again while it is open: it is already on screen.
        if (TrustedAddressesScreen.openCount > 0) break;
        if (_currentIndex != 2) setState(() => _currentIndex = 2);
        Future.delayed(const Duration(milliseconds: 120), () {
          if (mounted && TrustedAddressesScreen.openCount == 0) {
            Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute(
                builder: (_) => const TrustedAddressesScreen(),
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
