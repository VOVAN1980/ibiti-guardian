import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';
import 'package:ibiti_guardian/models/trading_plan.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/services/intents/intent_parser.dart';
import 'package:ibiti_guardian/services/intents/intent_router.dart';
import 'package:ibiti_guardian/services/execution/guardian_execution_controller.dart';
import 'package:ibiti_guardian/services/assistant/openai_chat_service.dart';
import 'package:ibiti_guardian/services/assistant/assistant_session_context.dart';
import 'package:ibiti_guardian/services/assistant/language_detector.dart';
import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_bus.dart';
import 'package:ibiti_guardian/services/assistant/voice_greeting_service.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/market/market_scout_service.dart';
import 'package:ibiti_guardian/services/market/trading_plan_builder.dart';
import 'package:ibiti_guardian/services/market/wallet_exposure_service.dart';
import 'package:ibiti_guardian/services/market/automation_engine.dart';
import 'package:ibiti_guardian/services/market/watchlist_service.dart';
import 'package:ibiti_guardian/models/automation_trigger.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_registry.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_interface.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/services/wallet/address_book_service.dart';
import 'package:ibiti_guardian/services/assistant/user_memory_service.dart';
import 'package:ibiti_guardian/models/user_memory.dart';
import 'package:ibiti_guardian/utils/token_symbol_normalizer.dart';
import 'package:ibiti_guardian/services/assistant/swap_voice_orchestrator.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/services/market/market_live_engine.dart';
import 'package:ibiti_guardian/services/market/market_memory_service.dart';
import 'package:ibiti_guardian/services/ibiti/ibiti_loop.dart';
import 'package:ibiti_guardian/services/market/market_intent_normalizer.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_order_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_account_store.dart';
import 'package:ibiti_guardian/services/exchanges/okx_exchange_service.dart';
import 'package:ibiti_guardian/services/market/market_multi_action_parser.dart';
import 'package:ibiti_guardian/services/wallet/market_price_alert_service.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/services/assistant/market_voice_brain.dart';


enum AssistantInputSource { voice, marketChat, generalChat, automated }

enum AssistantToneMode { companion, analyst, operator }

/// The single entry point for UI → Assistant interaction.
///
/// Re-architected for Phase 9: Fully decoupled Voice-OS architecture.
///
class GuardianAssistantService {
  GuardianAssistantService._();
  static final instance = GuardianAssistantService._();

  final _controller = GuardianExecutionController.instance;
  final _openai = OpenAIChatService.instance;

  /// Resets all session-scoped state.
  ///
  /// Call this on logout or account switch to prevent stale chat history,
  /// cached context, or cross-session data leaks.
  void reset() {
    _openai.clearHistory();
  }

  bool _isModeStatusQuestion(String input) {
    final lower = input.toLowerCase();
    return lower.contains('какой режим') ||
        lower.contains('текущий режим') ||
        lower.contains('what mode') ||
        lower.contains('current mode') ||
        (lower.contains('что ты можешь') && lower.contains('режим'));
  }

  bool _isLimitsStatusQuestion(String input) {
    final lower = input.toLowerCase();
    if (lower.contains('отправ') ||
        lower.contains('переведи') ||
        lower.contains('купи') ||
        lower.contains('продай') ||
        lower.contains('обменяй') ||
        lower.contains('свап') ||
        lower.contains('send') ||
        lower.contains('buy') ||
        lower.contains('sell') ||
        lower.contains('swap')) {
      return false;
    }
    return lower.contains('лимит') ||
        lower.contains('limits') ||
        lower.contains('что тебе можно') ||
        lower.contains('what are your limits') ||
        lower.contains('allowed actions') ||
        lower.contains('разрешен');
  }

  AssistantResponse _modeContractResponse(String languageCode) {
    final mode = AiControlService.instance.settings.mode;
    if (languageCode == 'ru') {
      switch (mode) {
        case AiMode.manual:
          return AssistantResponse.info(
            'Сейчас активен режим Manual. Я могу подсказывать, показывать баланс, активы, рынок, историю и риски, но не готовлю боевые send/swap действия. Для подготовки операций нужен Guarded, для самостоятельного исполнения Full Autonomy.',
          );
        case AiMode.guarded:
          return AssistantResponse.info(
            'Сейчас активен режим Guarded. Я могу открыть окна, заполнить формы, собрать preview и маршрут, но финальная подпись и подтверждение остаются за вами.',
          );
        case AiMode.fullAutonomy:
          return AssistantResponse.info(
            'Сейчас активен режим Full Autonomy. Я могу сама готовить и выполнять действия по голосу, чату или расписанию, но только в рамках лимитов, mandate, policy и EPK.',
          );
      }
    }
    switch (mode) {
      case AiMode.manual:
        return AssistantResponse.info(
          'Manual mode is active. I can explain and show balances, assets, market, history and risks, but I do not prepare live send or swap actions. Use Guarded for prepared actions or Full Autonomy for self-execution.',
        );
      case AiMode.guarded:
        return AssistantResponse.info(
          'Guarded mode is active. I can open screens, fill forms, build previews and routes, but final signing stays with you.',
        );
      case AiMode.fullAutonomy:
        return AssistantResponse.info(
          'Full Autonomy is active. I can prepare and execute actions by voice, chat or schedule, but only inside your limits, mandate, policy and EPK protection.',
        );
    }
  }

  AssistantResponse _limitsStatusResponse(String languageCode) {
    final s = AiControlService.instance.settings;
    final actions = s.allowedActions.map((e) => e.name).join(', ');
    final assets = s.mandate.allowedAssets.isEmpty
        ? 'any'
        : s.mandate.allowedAssets.join(', ');
    final networks = s.mandate.allowedNetworks.isEmpty
        ? 'any'
        : s.mandate.allowedNetworks.join(', ');
    final venues = s.mandate.allowedVenues.isEmpty
        ? 'any'
        : s.mandate.allowedVenues.join(', ');
    if (languageCode == 'ru') {
      return AssistantResponse.info(
        'Текущий режим: ${s.mode.name}. '
        'Лимит на одну операцию: \$${s.perTxLimit.toStringAsFixed(0)}. '
        'Дневной лимит: \$${s.dailyLimit.toStringAsFixed(0)}. '
        'Лимит на получателя: \$${s.perRecipientLimit.toStringAsFixed(0)}. '
        'Лимит на контракт: \$${s.perContractLimit.toStringAsFixed(0)}. '
        'Разрешённые действия: $actions. '
        'Разрешённые активы: $assets. '
        'Разрешённые сети: $networks. '
        'Разрешённые площадки: $venues. '
        'Макс. дневной лимит: \$${s.mandate.maxPositionUsd.toStringAsFixed(0)}. '
        'Максимальная дневная просадка: ${s.mandate.maxDrawdownPct.toStringAsFixed(1)}%.',
      );
    }
    return AssistantResponse.info(
      'Current mode: ${s.mode.name}. '
      'Per transaction limit: \$${s.perTxLimit.toStringAsFixed(0)}. '
      'Daily limit: \$${s.dailyLimit.toStringAsFixed(0)}. '
      'Per recipient limit: \$${s.perRecipientLimit.toStringAsFixed(0)}. '
      'Per contract limit: \$${s.perContractLimit.toStringAsFixed(0)}. '
      'Allowed actions: $actions. '
      'Allowed assets: $assets. '
      'Allowed networks: $networks. '
      'Allowed venues: $venues. '
      'Max daily trading limit: \$${s.mandate.maxPositionUsd.toStringAsFixed(0)}. '
      'Max daily drawdown: ${s.mandate.maxDrawdownPct.toStringAsFixed(1)}%.',
    );
  }

  // Manual mode contract: verbal explanation only, zero UI navigation.
  // The navigate:security_center that used to live here has been removed —
  // it bypassed _applyWindowPermissions and created an inconsistent special path.
  // In Manual mode the AI simply explains and the user acts themselves.
  AssistantResponse _manualExecutionBlockedResponse(String languageCode) {
    return AssistantResponse(
      message: languageCode == 'ru'
          ? 'Сейчас у вас режим Manual. Я могу объяснить действие и показать, что для него нужно, '
              'но не буду открывать боевой перевод или обмен. '
              'Для этого включите Guarded или Full Autonomy.'
          : 'Manual mode is active. I can explain the action and tell you what is needed, '
              'but I will not open a live send or swap flow. '
              'Enable Guarded or Full Autonomy for that.',
      speechText: languageCode == 'ru'
          ? 'Режим Manual. Для действий нужен Guarded или Full Autonomy.'
          : 'Manual mode. Enable Guarded or Full Autonomy for actions.',
      type: ResponseType.info,
    );
  }

  String _executionOpenMessage(String languageCode, String actionLabel) {
    final mode = AiControlService.instance.settings.mode;
    if (languageCode == 'ru') {
      switch (mode) {
        case AiMode.manual:
          return 'Сейчас режим Manual. Для боевых действий нужен Guarded или Full Autonomy.';
        case AiMode.guarded:
          return '$actionLabel подготовлю, но финальная подпись будет за вами.';
        case AiMode.fullAutonomy:
          return '$actionLabel открываю. В Full Autonomy я могу провести действие сама в рамках лимитов.';
      }
    }
    switch (mode) {
      case AiMode.manual:
        return 'Manual mode is active. Guarded or Full Autonomy is required for live actions.';
      case AiMode.guarded:
        return 'I will prepare $actionLabel, but final signing stays with you.';
      case AiMode.fullAutonomy:
        return 'Opening $actionLabel. In Full Autonomy I can execute it myself within your limits.';
    }
  }

  /// Full descriptive message for UI/chat display.
  String _surfaceOpenMessage(
    String languageCode, {
    required String surfaceRu,
    required String surfaceEn,
  }) {
    final mode = AiControlService.instance.settings.mode;
    if (languageCode == 'ru') {
      switch (mode) {
        case AiMode.manual:
          return 'Открыла $surfaceRu.';
        case AiMode.guarded:
          return 'Открыла $surfaceRu.';
        case AiMode.fullAutonomy:
          return 'Открыла $surfaceRu.';
      }
    }
    switch (mode) {
      case AiMode.manual:
        return 'Opened $surfaceEn.';
      case AiMode.guarded:
        return 'Opened $surfaceEn.';
      case AiMode.fullAutonomy:
        return 'Opened $surfaceEn.';
    }
  }

  List<UICommand> _commandsAllowedForMode(
    IntentData? intent,
    List<UICommand> commands,
  ) {
    if (intent == null || !intent.isExecutionIntent) return commands;
    if (AiControlService.instance.settings.mode == AiMode.manual) {
      return const [];
    }
    return commands;
  }

  /// Filters navigate/openModal/dismiss commands based on openWindows/closeWindows
  /// permissions. Applied to LLM-path dispatches to match the fast-path info()
  /// closure behaviour. Without this, Manual mode could still open windows via LLM.
  List<UICommand> _applyWindowPermissions(List<UICommand> commands) {
    final allowed = AiControlService.instance.settings.allowedActions;
    final canOpen = allowed.contains(AiAction.openWindows);
    final canClose = allowed.contains(AiAction.closeWindows);
    return commands.where((c) {
      if ((c.type == UICommandType.navigate ||
              c.type == UICommandType.openModal) &&
          !canOpen) {
        return false;
      }
      if (c.type == UICommandType.dismiss && !canClose) return false;
      return true;
    }).toList();
  }

  IntentData _resolveAddressBookRecipient(IntentData intent) {
    if (intent.type != IntentType.sendAsset || intent.toAddress != null) {
      return intent;
    }

    final input = intent.rawInput.toLowerCase();
    for (final entry in AddressBookService.instance.entries) {
      final label = entry.label.trim().toLowerCase();
      if (label.isNotEmpty && input.contains(label)) {
        return IntentData(
          type: intent.type,
          rawInput: intent.rawInput,
          tokenSymbol: intent.tokenSymbol,
          toAddress: entry.address,
          amount: intent.amount,
          rawAmount: intent.rawAmount,
          sourceTokenSymbol: intent.sourceTokenSymbol,
          sourceTokenAddress: intent.sourceTokenAddress,
          targetTokenSymbol: intent.targetTokenSymbol,
          targetTokenAddress: intent.targetTokenAddress,
          amountMode: intent.amountMode,
          slippageBps: intent.slippageBps,
          sourceTokenDecimals: intent.sourceTokenDecimals,
          targetTokenDecimals: intent.targetTokenDecimals,
          sourceTrigger: intent.sourceTrigger,
        );
      }
    }

    return intent;
  }

  // ── Known slang / alias map for asset matching ────────────────────────────
  static const _assetAliases = <String, String>{
    // RU slang
    'биток': 'BTC',
    'биткоин': 'BTC',
    'bitcoin': 'BTC',
    'эфир': 'ETH',
    'эфириум': 'ETH',
    'ethereum': 'ETH',
    'бнб': 'BNB',
    'солана': 'SOL',
    'solana': 'SOL',
    'usdt': 'USDT',
    'тезер': 'USDT',
    'tether': 'USDT',
    'usdc': 'USDC',
    'юсдк': 'USDC',
    'busd': 'BUSD',
    'wbnb': 'WBNB',
  };

  /// Extracts a canonical token symbol (e.g. 'ETH') if the input mentions
  /// a known asset by symbol, name, or alias. Returns null if nothing matched.
  String? _extractAssetSymbol(String lower) {
    for (final entry in _assetAliases.entries) {
      if (lower.contains(entry.key)) return entry.value;
    }
    // Direct symbol match for shorter tickers not in alias map
    for (final sym in [
      'btc',
      'eth',
      'bnb',
      'sol',
      'ada',
      'dot',
      'matic',
      'arb'
    ]) {
      if (lower.contains(sym)) return sym.toUpperCase();
    }
    return null;
  }

  // ── Modal Open Fast-Path ──────────────────────────────────────────────────
  // Runs BEFORE IntentParser. Intercepts explicit "open send/swap" commands
  // and dispatches UICommands directly. Without this, IntentParser would
  // match 'отправ' → sendAsset (empty) → orchestrate → "не удалось создать".
  AssistantResponse? _modalOpenFastPath(String input, String lang) {
    final lower = input.toLowerCase();

    final hasOpenVerb = lower.contains('открой') ||
        lower.contains('открою') ||
        lower.contains('открыть') ||
        lower.contains('открыва') ||
        lower.contains('покажи') ||
        lower.contains('показать') ||
        lower.contains('запусти') ||
        lower.contains('запустить') ||
        lower.contains('open') ||
        lower.contains('show') ||
        lower.contains('launch');

    if (!hasOpenVerb) return null;

    // Manual mode cannot open execution modals
    if (AiControlService.instance.settings.mode == AiMode.manual) {
      return _manualExecutionBlockedResponse(lang);
    }

    // Window-open permission gate: respect the openWindows toggle.
    final canOpen = AiControlService.instance.settings.allowedActions
        .contains(AiAction.openWindows);
    if (!canOpen) {
      final isRu = lang.startsWith('ru');
      final msg = isRu
          ? 'Открытие окон сейчас заблокировано в настройках AI Control. '
              'Включите разрешение «Открытие окон» чтобы я могла это сделать.'
          : 'Opening windows is currently blocked in AI Control settings. '
              'Enable the "Open windows" permission to allow this.';
      return AssistantResponse.info(msg, speechText: msg);
    }

    final isRu = lang.startsWith('ru');

    if (lower.contains('отправ') ||
        lower.contains('перевод') ||
        lower.contains('send') ||
        lower.contains('transfer')) {
      const modalCmd =
          UICommand(type: UICommandType.openModal, target: 'wallet_send');

      // AppShell._openModal handles tab switch + 220ms delay internally
      UICommandBus.instance.dispatch(modalCmd);

      // Short confirmation only — full tutorial is spoken by WalletSendModal._startGuideOnce()
      final sendMsg = isRu ? 'Открываю отправку.' : 'Opening send.';
      return AssistantResponse.info(
        sendMsg,
        speechText: sendMsg,
        commands: const [modalCmd],
      );
    }

    if (lower.contains('обмен') ||
        lower.contains('свап') ||
        lower.contains('своп') ||
        lower.contains('swap') ||
        lower.contains('поменя')) {
      const modalCmd =
          UICommand(type: UICommandType.openModal, target: 'wallet_swap');

      UICommandBus.instance.dispatch(modalCmd);

      // Short confirmation only — full tutorial is spoken by WalletSwapModal._startGuideOnce()
      final swapMsg = isRu ? 'Открываю обмен.' : 'Opening swap.';
      return AssistantResponse.info(
        swapMsg,
        speechText: swapMsg,
        commands: const [modalCmd],
      );
    }

    return null;
  }

  /// Resolve current price for a symbol from cache or live tickers.
  /// Returns null if symbol is not found anywhere.
  double? _findPriceForSymbol(String symbol) {
    final upper = symbol.toUpperCase();
    // 1. Try CoinGecko cache
    final markets = MarketDataService.instance.cachedMarkets;
    for (final a in markets) {
      if (a.symbol.toUpperCase() == upper && a.price > 0) return a.price;
    }
    // 2. Try live exchange tickers
    final live = MarketLiveEngine.instance;
    for (final exId in ExchangeRegistry.instance.availableExchanges) {
      final key = MarketLiveEngine.key(exId.name, '${upper}USDT');
      final ticker = live.latestByKey(key);
      if (ticker != null && ticker.lastPrice > 0) return ticker.lastPrice;
    }
    return null;
  }

  Future<AssistantResponse?> _fastPathCommand(
    String input,
    String detectedLang,
    AssistantInputSource source,
  ) async {
    final lower = input.toLowerCase();

    // Language lock — resolved first so EVERY branch uses the correct language.
    // ru* → 'ru', everything else → 'en'. App only has ru/en content.
    // Transcript detection is unreliable for language choice — use app setting.
    final appLang =
        SettingsService.instance.settings.languageCode.trim().toLowerCase();
    final effectiveLang = appLang.startsWith('ru') ? 'ru' : 'en';

    // Permission flags — read once; fresh on every call.
    final allowedActions = AiControlService.instance.settings.allowedActions;
    final currentMode = AiControlService.instance.settings.mode;
    final canOpenWindows = allowedActions.contains(AiAction.openWindows);
    final canCloseWindows = allowedActions.contains(AiAction.closeWindows);

    // Manual + execution-intent early exit — now uses locked effectiveLang.
    if (currentMode == AiMode.manual &&
        (lower.contains('send') ||
            lower.contains('swap') ||
            lower.contains('отправ') ||
            lower.contains('обмен'))) {
      return _manualExecutionBlockedResponse(effectiveLang);
    }

    AssistantResponse info(
      String message,
      List<UICommand> commands, {
      String? speech,
    }) {
      final effectiveCommands = commands.where((c) {
        if ((c.type == UICommandType.navigate ||
                c.type == UICommandType.openModal) &&
            !canOpenWindows) {
          return false;
        }
        if (c.type == UICommandType.dismiss && !canCloseWindows) return false;
        return true;
      }).toList();
      if (effectiveCommands.isNotEmpty) {
        UICommandBus.instance.dispatchAll(effectiveCommands);
      }
      return AssistantResponse.info(
        message,
        speechText: speech ?? message,
        commands: effectiveCommands,
      );
    }

    // ── Dismiss / close / go back ────────────────────────────────────────────
    // Guard 1: "убери 2 USDT" or "убери сумму" is a correction, not dismiss.
    // Guard 2: "убери TP" / "убери алерт" = market action — NEVER dismiss.
    final norm = MarketIntentNormalizer.instance;
    final hasUberi = lower.contains('убери') || lower.contains('убрать');
    final uberiIsDismiss = hasUberi &&
        !RegExp(r'[0-9]').hasMatch(lower) &&
        !lower.contains('сумм') &&
        !lower.contains('поставь') &&
        !lower.contains('замени') &&
        !_containsKnownToken(lower) &&
        !norm.isMarketCommand(lower); // ← 10B fix: market commands skip dismiss

    final isCloseIntent = lower.contains('закрой') ||
        lower.contains('закрыть') ||
        lower.contains('скрой') ||
        uberiIsDismiss ||
        lower.contains('спрячь') ||
        lower.contains('выйди') ||
        lower.contains('выйти') ||
        (lower.contains('назад') && lower.length < 25) ||
        lower.contains('close') ||
        lower.contains('dismiss') ||
        lower.contains('go back') ||
        lower.contains('hide');
    if (isCloseIntent && !norm.isMarketCommand(lower)) {
      if (!canCloseWindows) {
        final msg = effectiveLang == 'ru'
            ? 'Закрытие окон не разрешено в режиме Manual.'
            : 'Closing windows is not permitted in Manual mode.';
        return info(
          msg,
          const [],
          speech: msg,
        );
      }
      final msg = effectiveLang == 'ru' ? 'Закрыл.' : 'Closed.';
      return info(
        msg,
        const [UICommand(type: UICommandType.dismiss)],
      );
    }

    // ── App capabilities: what can you do ───────────────────────────────────
    if (lower.contains('что ты умеешь') ||
        lower.contains('что умеешь') ||
        lower.contains('what can you do') ||
        lower.contains('what can you') ||
        lower.contains('твои возможности') ||
        lower.contains('какие команды') ||
        lower.contains('список команд') ||
        lower.contains('help me') ||
        (lower.contains('помог') && lower.contains('команд'))) {
      final mode = AiControlService.instance.settings.mode;
      final String capText;
      if (effectiveLang == 'ru') {
        switch (mode) {
          case AiMode.manual:
            // Accurate: Manual has window permissions BLOCKED by _applyWindowPermissions.
            // AI can only describe, explain and read data — it cannot open any screen.
            capText = 'Я в режиме Manual. '
                'Могу рассказать ваш баланс, активы, адрес, историю, рынок и лимиты. '
                'Не могу открывать окна, модалки или переходить на экраны — управление интерфейсом заблокировано. '
                'Выполнять транзакции также не могу. '
                'Переключитесь в Guarded или Full Autonomy чтобы я начала действовать.';
            break;
          case AiMode.guarded:
            capText = 'Я в режиме Guarded. '
                'Знаю ваш баланс, активы, лимиты, рынок. '
                'Могу открыть и заполнить форму отправки, обмена, получения. '
                'Могу открыть Safe, Panic, EPK, AI центр, политики. '
                'Финальное подтверждение всегда остаётся за вами.';
            break;
          case AiMode.fullAutonomy:
            final s = AiControlService.instance.settings;
            capText = 'Я в режиме Full Autonomy. '
                'Могу подготовить и исполнить транзакции '
                'в рамках лимитов: \$${s.perTxLimit.toStringAsFixed(0)} на операцию, '
                '\$${s.dailyLimit.toStringAsFixed(0)} в день. '
                'Знаю баланс, активы, рынок. Могу открыть любой экран или модальное окно.';
            break;
        }
      } else {
        switch (mode) {
          case AiMode.manual:
            // Accurate: in Manual mode window permissions are blocked.
            capText = 'I am in Manual mode. '
                'I can tell you your balance, assets, address, history, market data and limits verbally. '
                'I cannot open any windows, modals or navigate to screens — UI control is locked. '
                'I also cannot execute transactions. '
                'Switch to Guarded or Full Autonomy to unlock those capabilities.';
            break;
          case AiMode.guarded:
            capText = 'I am in Guarded mode. '
                'I know your balance, assets, limits and market. '
                'I can open and fill send, swap, receive forms. '
                'I can open Safe, Panic, EPK, AI center, policy limits. '
                'Final confirmation always stays with you.';
            break;
          case AiMode.fullAutonomy:
            final s = AiControlService.instance.settings;
            capText = 'I am in Full Autonomy mode. '
                'I can prepare and execute transactions '
                'within limits: \$${s.perTxLimit.toStringAsFixed(0)} per tx, '
                '\$${s.dailyLimit.toStringAsFixed(0)} per day. '
                'I know your balance, assets and market. I can open any screen or modal.';
            break;
        }
      }
      return info(capText, const []);
    }

    // ── Exchange / биржи fast path ──────────────────────────────────────────
    if (lower.contains('бирж') ||
        lower.contains('exchange') ||
        lower.contains('какие бирж') ||
        lower.contains('сколько бирж') ||
        lower.contains('which exchange') ||
        lower.contains('how many exchange') ||
        lower.contains('подключен')) {
      final reg = ExchangeRegistry.instance;
      final connected = <String>[];
      for (final id in reg.availableExchanges) {
        final svc = reg.serviceFor(id);
        if (svc.isConnected) connected.add(id.displayName);
      }
      final live = MarketLiveEngine.instance;
      final pairCount = live.pairCount;

      final String text;
      if (effectiveLang == 'ru') {
        text = 'Подключены ${connected.length} биржи: ${connected.join(", ")}. '
            'MarketLiveEngine отслеживает $pairCount торговых пар.';
      } else {
        text =
            '${connected.length} exchanges connected: ${connected.join(", ")}. '
            'MarketLiveEngine tracking $pairCount pairs.';
      }
      return info(text, const []);
    }

    // ── IBITI status fast path ─────────────────────────────────────────────
    if (lower.contains('jarvis') ||
        lower.contains('джарвис') ||
        lower.contains('ibiti') ||
        lower.contains('ибити') ||
        lower.contains('автономн') ||
        lower.contains('autonomous') ||
        lower.contains('торгует') ||
        lower.contains('can he trade') ||
        lower.contains('может торговать') ||
        lower.contains('observe')) {
      final loop = IbitiLoop.instance;
      final mode = loop.executionMode;
      final isRunning = loop.isRunning;
      final ticks = loop.tickCount;
      final events = loop.totalEvents;

      final String text;
      if (effectiveLang == 'ru') {
        if (!isRunning) {
          text = 'IBITI сейчас не запущен. Когнитивный цикл неактивен.';
        } else {
          text = 'IBITI активен в режиме ${mode.name}. '
              '${mode.name == 'observeOnly' ? 'Он только наблюдает, деньги не трогает. ' : 'Внимание: режим ${mode.name}. '}'
              'Циклов: $ticks. Событий обработано: $events.';
        }
      } else {
        if (!isRunning) {
          text = 'IBITI is not running. Cognitive loop is inactive.';
        } else {
          text = 'IBITI is active in ${mode.name} mode. '
              '${mode.name == 'observeOnly' ? 'Observing only, no money touched. ' : 'Attention: ${mode.name} mode active. '}'
              'Ticks: $ticks. Events processed: $events.';
        }
      }
      return info(text, const []);
    }

    // ── Market price query: from cache only, honest fallback ─────────────────
    final isPriceQuery = lower.contains('курс') ||
        lower.contains('цена') ||
        lower.contains('price') ||
        lower.contains('стоит') ||
        lower.contains('сколько стоит') ||
        lower.contains('how much is') ||
        lower.contains('what is the price');
    if (isPriceQuery) {
      final sym = _extractAssetSymbol(lower);
      final cachedMarkets = MarketDataService.instance.cachedMarkets;
      if (cachedMarkets.isNotEmpty && sym != null) {
        // Try exact symbol match first, then name match.
        // Never fall back to a random token — let 'not found' handle it.
        final bySymbol =
            cachedMarkets.where((a) => a.symbol.toUpperCase() == sym).toList();
        final matches = bySymbol.isNotEmpty
            ? bySymbol
            : cachedMarkets
                .where((a) => lower.contains(a.name.toLowerCase()))
                .toList();
        if (matches.isNotEmpty) {
          final asset = matches.first;
          final sign = asset.change24h >= 0 ? '+' : '';
          final priceStr = asset.price >= 1
              ? asset.price.toStringAsFixed(2)
              : asset.price.toStringAsFixed(4);
          final text = effectiveLang == 'ru'
              ? '${asset.symbol}: \$$priceStr. За сутки: $sign${asset.change24h.toStringAsFixed(2)}%. '
                  'За 7 дней: ${asset.change7d >= 0 ? '+' : ''}${asset.change7d.toStringAsFixed(2)}%. '
                  'Статус: ${_marketStatusRu(asset.change24h)}.'
              : '${asset.symbol}: \$$priceStr. 24h: $sign${asset.change24h.toStringAsFixed(2)}%. '
                  '7d: ${asset.change7d >= 0 ? '+' : ''}${asset.change7d.toStringAsFixed(2)}%. '
                  'Status: ${asset.status}.';
          return info(
            text,
            const [],
            speech: text,
          );
        }
      }
      if (sym != null) {
        final noData = effectiveLang == 'ru'
            ? '$sym не найден в текущем кэше. Откройте рынок для актуальных данных.'
            : '$sym not found in current market cache. Open the market screen for live data.';
        return info(
          noData,
          const [],
          speech: noData,
        );
      }
    }

    // ── Specific asset balance ───────────────────────────────────────────────
    final isBalanceQuery = lower.contains('баланс') ||
        lower.contains('balance') ||
        lower.contains('сколько') ||
        lower.contains('мои актив') ||
        lower.contains('мои монет') ||
        lower.contains('how much');
    final specificSym = _extractAssetSymbol(lower);
    if (isBalanceQuery && specificSym != null && !lower.contains('истор')) {
      final portfolio = VaultPortfolioListener.instance.summary;
      if (portfolio != null && portfolio.allAssets.isNotEmpty) {
        // Sum balance across ALL entries with the same symbol (multi-chain support).
        // This avoids firstOrNull picking a zero-balance entry when another chain has funds.
        final matchingAssets = portfolio.allAssets
            .where((a) => a.symbol.toUpperCase() == specificSym)
            .toList();
        final String balText;
        if (matchingAssets.isNotEmpty) {
          final totalBal =
              matchingAssets.fold(0.0, (sum, a) => sum + a.balance);
          final totalUsd =
              matchingAssets.fold(0.0, (sum, a) => sum + a.valueUsd);
          final balStr = totalBal >= 1
              ? totalBal.toStringAsFixed(4)
              : totalBal.toStringAsFixed(6);
          final usdStr = totalUsd.toStringAsFixed(2);
          balText = effectiveLang == 'ru'
              ? 'У вас $specificSym: $balStr (≈\$$usdStr).'
              : 'You have $specificSym: $balStr (≈\$$usdStr).';
        } else {
          balText = effectiveLang == 'ru'
              ? '$specificSym не обнаружен в вашем кошельке.'
              : '$specificSym is not found in your wallet.';
        }
        // Voice-only: respond verbally without opening wallet.
        // Wallet opens only when the user explicitly says "open wallet" / "открой кошелёк".
        return info(
          balText,
          const [],
          speech: balText,
        );
      }
    }

    // ── Total balance (no specific asset mentioned) ──────────────────────────
    if (isBalanceQuery && specificSym == null && !lower.contains('истор')) {
      final portfolio = VaultPortfolioListener.instance.summary;
      final String balanceText;
      if (portfolio != null && portfolio.allAssets.isNotEmpty) {
        final total = portfolio.totalBalanceUsd;
        // Only include assets with non-zero balance in voice report.
        final nonZeroAssets = portfolio.allAssets
            .where((a) => a.balance > 0 && a.valueUsd > 0)
            .toList();
        if (effectiveLang == 'ru') {
          if (total <= 0 || nonZeroAssets.isEmpty) {
            balanceText = 'Общий баланс кошелька: \$0.00. '
                'Активов с положительным балансом не обнаружено.';
          } else {
            final topStr = nonZeroAssets.take(3).map((a) {
              final bal = a.balance >= 1
                  ? a.balance.toStringAsFixed(2)
                  : a.balance.toStringAsFixed(4);
              return '${a.symbol}\u00a0$bal';
            }).join(', ');
            balanceText =
                'Общий баланс кошелька: \$${total.toStringAsFixed(2)}. '
                'Активы: $topStr.';
          }
        } else {
          if (total <= 0 || nonZeroAssets.isEmpty) {
            balanceText =
                'Total wallet balance: \$0.00. No assets with positive balance found.';
          } else {
            final topStr = nonZeroAssets.take(3).map((a) {
              final bal = a.balance >= 1
                  ? a.balance.toStringAsFixed(2)
                  : a.balance.toStringAsFixed(4);
              return '${a.symbol}\u00a0$bal';
            }).join(', ');
            balanceText =
                'Total wallet balance: \$${total.toStringAsFixed(2)}. '
                'Assets: $topStr.';
          }
        }
        // Voice-only: respond verbally without opening wallet.
        // Wallet opens only when the user explicitly says "open wallet" / "открой кошелёк".
        return info(
          balanceText,
          const [],
          speech: balanceText,
        );
      }
    }

    // в•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђ
    // STRICT NAVIGATION GATE
    // Rule: AI opens screens/modals ONLY when the user explicitly says an open
    // or show verb PLUS a target screen name. Informational queries (balance,
    // history, prices, risks, market data) are answered verbally with NO UI
    // side-effects. This prevents ghost windows from appearing mid-conversation.
    // в•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђв•ђ

    // Explicit open verbs (RU + EN)
    final hasOpenVerb = lower.contains('открой') ||
        lower.contains('открыть') ||
        lower.contains('покажи') ||
        lower.contains('показать') ||
        lower.contains('перейди') ||
        lower.contains('перейти') ||
        lower.contains('запусти') ||
        lower.contains('запустить') ||
        lower.contains('open') ||
        lower.contains('show') ||
        lower.contains('go to') ||
        lower.contains('launch') ||
        lower.contains('navigate');

    // ── Wallet & sub-screens ─────────────────────────────────────────────────
    if (hasOpenVerb && (lower.contains('кошел') || lower.contains('wallet'))) {
      // History
      if (lower.contains('истори') || lower.contains('history')) {
        return info(
          _surfaceOpenMessage(effectiveLang,
              surfaceRu: 'историю операций', surfaceEn: 'transaction history'),
          const [
            UICommand(type: UICommandType.navigate, target: 'wallet'),
            UICommand(type: UICommandType.openModal, target: 'wallet_history'),
          ],
        );
      }
      // Address book
      if (lower.contains('адресн') ||
          lower.contains('address book') ||
          lower.contains('contacts') ||
          lower.contains('контакт')) {
        return info(
          _surfaceOpenMessage(effectiveLang,
              surfaceRu: 'адресную книгу', surfaceEn: 'address book'),
          const [
            UICommand(type: UICommandType.navigate, target: 'wallet'),
            UICommand(
                type: UICommandType.openModal, target: 'wallet_address_book'),
          ],
        );
      }
      // Wallet settings
      if (lower.contains('настройк') || lower.contains('settings')) {
        return info(
          _surfaceOpenMessage(effectiveLang,
              surfaceRu: 'настройки кошелька', surfaceEn: 'wallet settings'),
          const [
            UICommand(type: UICommandType.navigate, target: 'wallet'),
            UICommand(type: UICommandType.openModal, target: 'wallet_settings'),
          ],
        );
      }
      // Send modal
      if (lower.contains('отправ') ||
          lower.contains('send') ||
          lower.contains('перевод') ||
          lower.contains('transfer')) {
        return info(
          _surfaceOpenMessage(effectiveLang,
              surfaceRu: 'окно отправки', surfaceEn: 'send form'),
          const [
            UICommand(type: UICommandType.navigate, target: 'wallet'),
            UICommand(type: UICommandType.openModal, target: 'wallet_send'),
          ],
        );
      }
      // Swap modal
      if (lower.contains('обмен') ||
          lower.contains('swap') ||
          lower.contains('поменя') ||
          lower.contains('обменя')) {
        return info(
          _surfaceOpenMessage(effectiveLang,
              surfaceRu: 'окно обмена', surfaceEn: 'swap form'),
          const [
            UICommand(type: UICommandType.navigate, target: 'wallet'),
            UICommand(type: UICommandType.openModal, target: 'wallet_swap'),
          ],
        );
      }
      // Receive modal
      if (lower.contains('получ') ||
          lower.contains('receive') ||
          lower.contains('адрес') ||
          lower.contains('address')) {
        return info(
          _surfaceOpenMessage(effectiveLang,
              surfaceRu: 'адрес для получения', surfaceEn: 'receive address'),
          const [
            UICommand(type: UICommandType.navigate, target: 'wallet'),
            UICommand(type: UICommandType.openModal, target: 'wallet_receive'),
          ],
        );
      }
      // Plain wallet open
      return info(
        _surfaceOpenMessage(effectiveLang,
            surfaceRu: 'кошелёк', surfaceEn: 'wallet'),
        const [UICommand(type: UICommandType.navigate, target: 'wallet')],
      );
    }

    // ── History standalone (e.g. "покажи историю") ───────────────────────────
    if (hasOpenVerb &&
        (lower.contains('истори') || lower.contains('history'))) {
      return info(
        _surfaceOpenMessage(effectiveLang,
            surfaceRu: 'историю операций', surfaceEn: 'transaction history'),
        const [
          UICommand(type: UICommandType.navigate, target: 'wallet'),
          UICommand(type: UICommandType.openModal, target: 'wallet_history'),
        ],
      );
    }

    // ── Address book standalone ──────────────────────────────────────────────
    if (hasOpenVerb &&
        (lower.contains('адресн') || lower.contains('address book'))) {
      return info(
        _surfaceOpenMessage(effectiveLang,
            surfaceRu: 'адресную книгу', surfaceEn: 'address book'),
        const [
          UICommand(type: UICommandType.navigate, target: 'wallet'),
          UICommand(
              type: UICommandType.openModal, target: 'wallet_address_book'),
        ],
      );

      // ── Send standalone (e.g. «открой отправку», «открой send») ─────────────
    } else if (hasOpenVerb &&
        (lower.contains('отправ') ||
            lower.contains('send') ||
            lower.contains('перевод') ||
            lower.contains('transfer'))) {
      return info(
        _surfaceOpenMessage(effectiveLang,
            surfaceRu: 'окно отправки', surfaceEn: 'send form'),
        const [
          UICommand(type: UICommandType.navigate, target: 'wallet'),
          UICommand(type: UICommandType.openModal, target: 'wallet_send'),
        ],
      );

      // ── Swap standalone (e.g. «открой обмен», «открой swap») ────────────────
    } else if (hasOpenVerb &&
        (lower.contains('обмен') ||
            lower.contains('swap') ||
            lower.contains('поменя') ||
            lower.contains('обменя'))) {
      return info(
        _surfaceOpenMessage(effectiveLang,
            surfaceRu: 'окно обмена', surfaceEn: 'swap form'),
        const [
          UICommand(type: UICommandType.navigate, target: 'wallet'),
          UICommand(type: UICommandType.openModal, target: 'wallet_swap'),
        ],
      );

      // ── Receive standalone (e.g. «открой получение», «покажи мой адрес») ────
    } else if (hasOpenVerb &&
        (lower.contains('получен') ||
            lower.contains('receive') ||
            lower.contains('принят'))) {
      return info(
        _surfaceOpenMessage(effectiveLang,
            surfaceRu: 'адрес для получения', surfaceEn: 'receive address'),
        const [
          UICommand(type: UICommandType.navigate, target: 'wallet'),
          UICommand(type: UICommandType.openModal, target: 'wallet_receive'),
        ],
      );
    }

    // в”Ђв”Ђ Market в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
    if (hasOpenVerb && (lower.contains('рынок') || lower.contains('market'))) {
      return info(
        _surfaceOpenMessage(effectiveLang,
            surfaceRu: 'рынок', surfaceEn: 'market'),
        const [UICommand(type: UICommandType.navigate, target: 'market')],
      );
    }

    // ── Security center ──────────────────────────────────────────────────────
    if (hasOpenVerb &&
        (lower.contains('security') ||
            lower.contains('безопасност') ||
            lower.contains('центр безопасн'))) {
      return info(
        _surfaceOpenMessage(effectiveLang,
            surfaceRu: 'центр безопасности', surfaceEn: 'security center'),
        const [
          UICommand(type: UICommandType.navigate, target: 'security_center')
        ],
      );
    }

    // в”Ђв”Ђ Policy в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
    if (hasOpenVerb &&
        (lower.contains('политик') ||
            lower.contains('policy') ||
            lower.contains('лимит'))) {
      return info(
        _surfaceOpenMessage(effectiveLang,
            surfaceRu: 'политики', surfaceEn: 'policy'),
        const [
          UICommand(type: UICommandType.openModal, target: 'policy_limits')
        ],
      );
    }

    // в”Ђв”Ђ AI center в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
    if (hasOpenVerb &&
        (lower.contains('ai center') ||
            (lower.contains('центр') && lower.contains('ai')) ||
            lower.contains('ai контроль') ||
            lower.contains('ai control'))) {
      return info(
        _surfaceOpenMessage(effectiveLang,
            surfaceRu: 'AI центр', surfaceEn: 'AI center'),
        const [UICommand(type: UICommandType.openModal, target: 'ai_control')],
      );
    }

    // в”Ђв”Ђ EPK в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
    if (hasOpenVerb && lower.contains('epk')) {
      return info(
        _surfaceOpenMessage(effectiveLang,
            surfaceRu: 'EPK контроль', surfaceEn: 'EPK control'),
        const [UICommand(type: UICommandType.openModal, target: 'epk_control')],
      );
    }

    // в”Ђв”Ђ Audit в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
    if (hasOpenVerb && (lower.contains('аудит') || lower.contains('audit'))) {
      return info(
        _surfaceOpenMessage(effectiveLang,
            surfaceRu: 'аудит', surfaceEn: 'audit'),
        const [
          UICommand(type: UICommandType.openModal, target: 'audit_history')
        ],
      );
    }

    // ── MARKET INTELLIGENCE ────────────────────────────────────────────────────
    // "что на рынке", "какие сигналы", "что посоветуешь", "анализ рынка"
    // Pulls live data from MarketScoutService and formats a briefing.
    if (_isMarketQuery(lower) &&
        ScreenContextService.instance.activeModal == null) {
      final markets = MarketDataService.instance.cachedMarkets;
      if (markets.isEmpty) {
        return info(
          effectiveLang == 'ru'
              ? 'Рыночные данные ещё загружаются. Данные появятся через несколько секунд.'
              : 'Market data is still loading. Data will appear shortly.',
          const [],
          speech:
              effectiveLang == 'ru' ? 'Данные загружаются.' : 'Data loading.',
        );
      }
      final aiSettings = AiControlService.instance.settings;
      final signals = MarketScoutService.instance
          .findTopOpportunities(markets, settings: aiSettings, topN: 5);
      final fullBriefing =
          _buildMarketBriefing(signals, effectiveLang, short: false);
      final voiceBriefing =
          _buildMarketBriefing(signals, effectiveLang, short: true);
      return info(
        fullBriefing,
        const [],
        speech: voiceBriefing,
      );
    }

    // Screen context — needed for focusedSymbol fallback in trade and market commands
    final ctx = ScreenContextService.instance;

    // ── TRADING COMMAND (buy/sell/swap specific asset) ───────────────────────
    // "купи BTC на 50 долларов", "продай ETH", "поменяй USDT на SOL"
    // "купи эту монету на 10$" (uses focusedSymbol from ScreenContextService)
    //
    // Phase 5D: mode-aware execution
    //   Manual    → analysis only (TradingPlan text, no UI action)
    //   Guarded   → open swap modal with prefill, user confirms
    //   Full Auto → open swap modal with prefill (safe first)
    if (_isTradingCommand(lower)) {
      final explicitSymbol = _extractAssetSymbol(lower);
      // Fallback to focused token if user says "купи эту монету" / "buy this coin"
      final symbol = explicitSymbol ?? ctx.focusedSymbol?.toUpperCase();
      if (symbol == null) {
        // No specific asset and not on token detail → market briefing
        final markets = MarketDataService.instance.cachedMarkets;
        if (markets.isEmpty) {
          final noData = effectiveLang == 'ru'
              ? 'Рыночные данные ещё загружаются. Попробуйте через несколько секунд.'
              : 'Market data is still loading. Please try again shortly.';
          return info(noData, const [], speech: noData);
        }
        final aiSettings = AiControlService.instance.settings;
        final signals = MarketScoutService.instance
            .findTopOpportunities(markets, settings: aiSettings, topN: 5);
        return info(
          _buildMarketBriefing(signals, effectiveLang, short: false),
          const [],
          speech: _buildMarketBriefing(signals, effectiveLang, short: true),
        );
      } else {
        final markets = MarketDataService.instance.cachedMarkets;
        final asset = markets.cast<MarketAsset?>().firstWhere(
              (a) => a!.symbol.toUpperCase() == symbol,
              orElse: () => null,
            );
        if (asset != null) {
          final sourceId = asset.sourceId.toLowerCase();
          if (sourceId == 'mexc' || sourceId == 'binance' || sourceId == 'gateio' || sourceId == 'okx') {
            final parsedIntent = IntentParser.parse(input);
            final finalSymbol = parsedIntent.tokenSymbol ?? symbol;
            final finalAmount = parsedIntent.amount ?? _extractAmount(lower);
            final isQuantity = parsedIntent.isQuantity;
            final finalType = parsedIntent.type != IntentType.unknown
                ? parsedIntent.type
                : (_extractTradingDirection(lower) == TradingDirection.sell
                    ? IntentType.sellAsset
                    : IntentType.buyAsset);

            final intent = IntentData(
              type: finalType,
              tokenSymbol: finalSymbol,
              amount: finalAmount,
              isQuantity: isQuantity,
              rawInput: input,
            );
            return await _handleCexTradeIntent(intent, source, effectiveLang);
          }

          final aiSettings = AiControlService.instance.settings;
          final direction = _extractTradingDirection(lower);
          final plan = TradingPlanBuilder.build(
            asset: asset,
            direction: direction,
            settings: aiSettings,
          );
          final amount = _extractAmount(lower);

          final fullPlan =
              _buildTradingPlanBriefing(plan, effectiveLang, short: false);
          final voicePlan =
              _buildTradingPlanBriefing(plan, effectiveLang, short: true);

          if (currentMode == AiMode.manual) {
            final manualNote = effectiveLang == 'ru'
                ? '\n\n⚠️ Режим Manual. Это только анализ.'
                : '\n\n⚠️ Manual mode. Analysis only.';
            return info(fullPlan + manualNote, const [], speech: voicePlan);
          }

          // Guarded / Full Autonomy: show plan + open swap modal with prefill
          final commands = <UICommand>[
            UICommand(
              type: UICommandType.showTradingPlan,
              payload: {'plan': plan},
            ),
            UICommand(
              type: UICommandType.openModal,
              target: direction == TradingDirection.swap 
                  ? 'wallet_swap' 
                  : (direction == TradingDirection.sell ? 'wallet_sell' : 'wallet_buy'),
            ),
          ];

          // Prefill source/target tokens
          if (direction == TradingDirection.sell) {
            commands.add(UICommand(
              type: UICommandType.selectToken,
              target: 'swap_from_token',
              payload: {'symbol': symbol},
            ));
            commands.add(const UICommand(
              type: UICommandType.selectToken,
              target: 'swap_to_token',
              payload: {'symbol': 'USDT'},
            ));
          } else {
            commands.add(const UICommand(
              type: UICommandType.selectToken,
              target: 'swap_from_token',
              payload: {'symbol': 'USDT'},
            ));
            commands.add(UICommand(
              type: UICommandType.selectToken,
              target: 'swap_to_token',
              payload: {'symbol': symbol},
            ));
          }

          if (amount != null && amount > 0) {
            final amountStr = amount >= 1
                ? amount.toStringAsFixed(2)
                : amount.toStringAsFixed(4);
            commands.add(UICommand(
              type: UICommandType.fillField,
              target: 'swap_amount',
              payload: {'value': amountStr},
            ));
          }

          final dirLabel = direction == TradingDirection.sell
              ? (effectiveLang == 'ru' ? 'продажу' : 'sell')
              : (effectiveLang == 'ru' ? 'покупку' : 'buy');
          final amountNote = amount != null
              ? ' \$${amount.toStringAsFixed(0)}'
              : '';
          final modeEmoji = currentMode == AiMode.guarded ? '🛡️' : '⚡';
          final modeNote = effectiveLang == 'ru'
              ? '\n\n$modeEmoji Открываю форму. Подтвердите перед исполнением.'
              : '\n\n$modeEmoji Opening form. Confirm before execution.';
          final voiceSpeech = effectiveLang == 'ru'
              ? 'Готовлю $dirLabel $symbol$amountNote. Открываю форму.'
              : 'Preparing $dirLabel $symbol$amountNote. Opening form.';

          // Record buy/sell intent to market memory
          MarketMemoryService.instance.record(
            action: direction == TradingDirection.sell ? 'sell' : 'buy',
            symbol: symbol,
            source: 'voice',
            aiMode: currentMode.name,
            result: 'opened_form',
            amount: amount,
            priceThen: asset.price,
            rawInput: input,
          );
          return info(fullPlan + modeNote, commands, speech: voiceSpeech);
        } else {
          final notFound = effectiveLang == 'ru'
              ? '$symbol не найден в кэше.'
              : '$symbol not found in cache.';
          return info(notFound, const [], speech: notFound);
        }
      }
    }

    // ── PANIC / REVOKE ─────────────────────────────────────────────────────────
    // Guard: 'отправ'/'send' = send intent, NEVER panic (protects vs STT mis-transcription)
    final isPanicIntent = !lower.contains('отправ') &&
        !lower.contains('send') &&
        (lower.contains('panic') ||
            lower.contains('паник') ||
            lower.contains('revoke') ||
            // "отозв" now requires context — never a standalone trigger
            (lower.contains('отозв') &&
                (lower.contains('разрешен') ||
                    lower.contains('контракт') ||
                    lower.contains('апрув') ||
                    lower.contains('всё') ||
                    lower.contains('все') ||
                    lower.contains('все разрешения'))) ||
            lower.contains('экстренн') ||
            lower.contains('аварийн') ||
            (lower.contains('блокировк') &&
                (lower.contains('экстренн') ||
                    lower.contains('срочн') ||
                    lower.contains('аварийн'))) ||
            (lower.contains('срочно') &&
                (lower.contains('отозв') ||
                    lower.contains('разрешен') ||
                    lower.contains('всё') ||
                    lower.contains('все') ||
                    lower.contains('блокир'))));

    if (isPanicIntent) {
      if (!canOpenWindows) {
        return info(
          effectiveLang == 'ru'
              ? 'В режиме Manual я не могу запустить Panic сама — это исполнительное действие. '
                  'Переключитесь в Guarded или Full Autonomy.'
              : 'In Manual mode I cannot trigger Panic myself — it is an execution action. '
                  'Switch to Guarded or Full Autonomy.',
          const [],
          speech: effectiveLang == 'ru'
              ? 'Режим Manual: Panic запускается вручную. Переключитесь в Guarded.'
              : 'Manual mode: open Panic manually or switch to Guarded mode.',
        );
      }
      return info(
        _surfaceOpenMessage(effectiveLang,
            surfaceRu: 'Panic', surfaceEn: 'Panic'),
        const [UICommand(type: UICommandType.openModal, target: 'panic')],
      );
    }

    // ── SAFE / SCAN (scan approvals, check risks) ─────────────────────────────
    // Triggers: safe, сафе, scan, скан, сканирование, проверка разрешений/рисков
    // Does NOT include revoke/отозвать — those are Panic only.
    final isSafeIntent = lower.contains('скан') ||
        lower.contains('scan') ||
        lower.contains('сафе') ||
        (lower.contains('safe') &&
            !lower.contains('panic') &&
            !lower.contains('паник')) ||
        (lower.contains('провер') &&
            (lower.contains('разрешен') ||
                lower.contains('риск') ||
                lower.contains('контракт') ||
                lower.contains('апрув') ||
                lower.contains('безопас'))) ||
        (lower.contains('аудит') &&
            (lower.contains('безопас') ||
                lower.contains('разрешен') ||
                lower.contains('апрув')));

    if (isSafeIntent) {
      if (!canOpenWindows) {
        return info(
          effectiveLang == 'ru'
              ? 'В режиме Manual я могу рассказать о рисках, но не запускаю сканирование сама. '
                  'Включите Guarded или Full Autonomy чтобы я провела Safe-сканирование.'
              : 'In Manual mode I can explain risks but cannot run the scan myself. '
                  'Switch to Guarded or Full Autonomy to run Safe Review.',
          const [],
          speech: effectiveLang == 'ru'
              ? 'Режим Manual: сканирование не запускаю. Переключитесь в Guarded.'
              : 'Manual mode: I cannot run the scan. Switch to Guarded mode.',
        );
      }
      return info(
        _surfaceOpenMessage(effectiveLang,
            surfaceRu: 'Safe\u00a0Scan', surfaceEn: 'Safe\u00a0Scan'),
        const [UICommand(type: UICommandType.openModal, target: 'safe')],
      );
    }

    // ── MARKET COMMANDS: TP/SL, Watchlist, Alerts ─────────────────────────────
    // Deterministic fast-path for market-related voice/chat commands.
    // Uses ScreenContextService.focusedSymbol when user says "эту монету" / "this coin".
    // NEVER auto-trades. Always TriggerAction.notifyOnly.

    // --- Multi-action compound parser (10D) ---
    // "поставь TP 5%, SL 5%, алерт 10%" → all three in one go
    final multiActions = MarketMultiActionParser.instance.parse(lower);
    if (multiActions.length >= 2) {
      final symbol = _extractAssetSymbol(lower) ?? ctx.focusedSymbol?.toUpperCase();
      if (symbol == null) {
        final msg = effectiveLang == 'ru'
            ? 'Какую монету? Откройте карточку или скажите символ.'
            : 'Which coin? Open a token detail or say the symbol.';
        return info(msg, const [], speech: msg);
      }
      final price = ctx.focusedSymbol?.toUpperCase() == symbol
          ? ctx.focusedPrice
          : _findPriceForSymbol(symbol);
      if (price == null || price <= 0) {
        final msg = effectiveLang == 'ru'
            ? 'Не могу определить текущую цену $symbol.'
            : 'Cannot determine current price of $symbol.';
        return info(msg, const [], speech: msg);
      }

      final results = <String>[];
      for (final action in multiActions) {
        switch (action.type) {
          case MarketActionType.setTp:
            final pct = action.percent;
            if (pct != null && pct > 0 && pct <= 100) {
              AutomationEngine.instance.addTrigger(
                assetSymbol: symbol,
                type: TriggerType.takeProfit,
                requestedAction: TriggerAction.notifyOnly,
                thresholdPct: pct,
                entryPriceUsd: price,
                label: 'TP $symbol ${pct.toStringAsFixed(0)}% (voice)',
              );
              results.add('TP +${pct.toStringAsFixed(0)}%');
            }
            break;
          case MarketActionType.setSl:
            final pct = action.percent;
            if (pct != null && pct > 0 && pct <= 100) {
              AutomationEngine.instance.addTrigger(
                assetSymbol: symbol,
                type: TriggerType.stopLoss,
                requestedAction: TriggerAction.notifyOnly,
                thresholdPct: pct,
                entryPriceUsd: price,
                label: 'SL $symbol ${pct.toStringAsFixed(0)}% (voice)',
              );
              results.add('SL -${pct.toStringAsFixed(0)}%');
            }
            break;
          case MarketActionType.setAlert:
            final pct = action.percent;
            if (pct != null && pct > 0 && pct <= 100) {
              AutomationEngine.instance.addTrigger(
                assetSymbol: symbol,
                type: TriggerType.priceAbove,
                requestedAction: TriggerAction.notifyOnly,
                thresholdPct: pct,
                entryPriceUsd: price,
                label: 'Alert $symbol +${pct.toStringAsFixed(0)}% (voice)',
              );
              results.add('алерт +${pct.toStringAsFixed(0)}%');
            }
            break;
          case MarketActionType.addFavorite:
            final wl = WatchlistService.instance;
            wl.toggleSymbol(symbol);
            results.add('⭐ избранное');
            break;
          case MarketActionType.removeTp:
            AutomationEngine.instance.removeTriggersForSymbol(
                symbol, TriggerAction.notifyOnly,
                onlyType: TriggerType.takeProfit);
            results.add('TP снят');
            break;
          case MarketActionType.removeSl:
            AutomationEngine.instance.removeTriggersForSymbol(
                symbol, TriggerAction.notifyOnly,
                onlyType: TriggerType.stopLoss);
            results.add('SL снят');
            break;
          case MarketActionType.removeAlert:
            MarketPriceAlertService.instance.removeAllForSymbol(symbol);
            results.add('алерт снят');
            break;
          case MarketActionType.removeFavorite:
            final wl = WatchlistService.instance;
            if (wl.isFavoriteBySymbol(symbol)) wl.toggleSymbol(symbol);
            results.add('убран из избранного');
            break;
        }
      }
      if (results.isNotEmpty) {
        MarketMemoryService.instance.record(
          action: 'multi',
          symbol: symbol,
          source: 'voice',
          aiMode: currentMode.name,
          result: 'confirmed',
          priceThen: price,
          rawInput: input,
        );
        final joined = results.join(', ');
        final msg = effectiveLang == 'ru'
            ? 'Готово на $symbol: $joined.'
            : 'Done for $symbol: $joined.';
        return info(msg, const [], speech: msg);
      }
    }

    // --- TP/SL via voice/chat (10C: synonym dict + spoken numbers) ---
    // Understands: тейк / верхняя планка / take profit / stop loss / нижний предел
    // Numbers: "пять процентов" → 5.0 / "полтора" → 1.5
    final isTpSlCommand = norm.hasTpKeyword(lower) ||
        norm.hasSlKeyword(lower) ||
        // bare 'стоп' only counts as SL if paired with a number/percent
        (lower.contains('стоп') &&
            (lower.contains('%') || RegExp(r'\d').hasMatch(lower)));
    if (isTpSlCommand) {
      // Determine TP or SL
      final isTp = norm.hasTpKeyword(lower);

      // Extract percent — numeric OR spoken ("пять процентов" → 5.0, "полтора" → 1.5)
      final pct = norm.parsePercent(lower);
      if (pct == null) {
        final noPercent = effectiveLang == 'ru'
            ? 'Укажите процент. Например: "поставь тейк 10%" или "стоп лосс пять процентов".'
            : 'Specify a percentage. Example: "set take profit 10%" or "stop loss five percent".';
        return info(noPercent, const [], speech: noPercent);
      }
      if (pct <= 0 || pct > 100) {
        final badPct = effectiveLang == 'ru'
            ? 'Процент должен быть от 1 до 100.'
            : 'Percentage must be between 1 and 100.';
        return info(badPct, const [], speech: badPct);
      }

      // Resolve symbol — try explicit, then focused token
      final explicitSymbol = _extractAssetSymbol(lower);
      final symbol = explicitSymbol ?? ctx.focusedSymbol?.toUpperCase();
      if (symbol == null) {
        final noSymbol = effectiveLang == 'ru'
            ? 'Какую монету? Откройте карточку монеты или скажите символ. Например: "тейк BTC 10%".'
            : 'Which coin? Open a token detail or say the symbol. Example: "take profit BTC 10%".';
        return info(noSymbol, const [], speech: noSymbol);
      }

      // Get current price
      final price = ctx.focusedSymbol?.toUpperCase() == symbol
          ? ctx.focusedPrice
          : _findPriceForSymbol(symbol);
      if (price == null || price <= 0) {
        final noPrice = effectiveLang == 'ru'
            ? 'Не могу определить текущую цену $symbol. Откройте карточку монеты.'
            : 'Cannot determine current price of $symbol. Open the token detail.';
        return info(noPrice, const [], speech: noPrice);
      }

      // Create trigger via existing AutomationEngine
      final triggerType = isTp ? TriggerType.takeProfit : TriggerType.stopLoss;
      AutomationEngine.instance.addTrigger(
        assetSymbol: symbol,
        type: triggerType,
        requestedAction: TriggerAction.notifyOnly,
        thresholdPct: pct,
        entryPriceUsd: price,
        label: '${isTp ? "TP" : "SL"} $symbol ${pct.toStringAsFixed(0)}% (voice)',
      );

      final targetPrice = isTp
          ? price * (1 + pct / 100)
          : price * (1 - pct / 100);
      final fmtTarget = targetPrice < 1
          ? targetPrice.toStringAsFixed(6)
          : targetPrice.toStringAsFixed(2);

      final confirmMsg = effectiveLang == 'ru'
          ? '${isTp ? "✅ Тейк-профит" : "🛡 Стоп-лосс"} на $symbol: '
              '${isTp ? "+" : "-"}${pct.toStringAsFixed(0)}% → \$$fmtTarget. '
              'Уведомлю когда сработает.'
          : '${isTp ? "✅ Take Profit" : "🛡 Stop Loss"} on $symbol: '
              '${isTp ? "+" : "-"}${pct.toStringAsFixed(0)}% → \$$fmtTarget. '
              'Will notify when triggered.';
      // Record to market memory
      MarketMemoryService.instance.record(
        action: isTp ? 'tp' : 'sl',
        symbol: symbol,
        source: 'voice',
        aiMode: currentMode.name,
        result: 'confirmed',
        priceThen: price,
        rawInput: input,
      );
      return info(confirmMsg, const [], speech: confirmMsg);
    }

    // --- Watchlist via voice/chat (10C: synonym dict) ---
    // Understands: в избранное / звёздочку / добавь монету / следи за ней / add to watchlist etc.
    final isAddFav = norm.hasFavoriteKeyword(lower);
    final isRemoveFav = norm.hasRemoveFavoriteKeyword(lower);
    if (isAddFav || isRemoveFav) {
      final explicitSymbol = _extractAssetSymbol(lower);
      final symbol = explicitSymbol ?? ctx.focusedSymbol?.toUpperCase();
      if (symbol == null) {
        final noSymbol = effectiveLang == 'ru'
            ? 'Какую монету? Откройте карточку или скажите символ.'
            : 'Which coin? Open a token detail or say the symbol.';
        return info(noSymbol, const [], speech: noSymbol);
      }

      final wl = WatchlistService.instance;
      final alreadyFav = wl.isFavoriteBySymbol(symbol);

      if (isAddFav) {
        if (alreadyFav) {
          final already = effectiveLang == 'ru'
              ? '$symbol уже в избранном.'
              : '$symbol is already in watchlist.';
          return info(already, const [], speech: already);
        }
        wl.toggleSymbol(symbol);
        MarketMemoryService.instance.record(
          action: 'favorite',
          symbol: symbol,
          source: 'voice',
          aiMode: currentMode.name,
          result: 'confirmed',
          rawInput: input,
        );
        final added = effectiveLang == 'ru'
            ? '⭐ $symbol добавлен в избранное.'
            : '⭐ $symbol added to watchlist.';
        return info(added, const [], speech: added);
      } else {
        if (!alreadyFav) {
          final notThere = effectiveLang == 'ru'
              ? '$symbol нет в избранном.'
              : '$symbol is not in watchlist.';
          return info(notThere, const [], speech: notThere);
        }
        wl.toggleSymbol(symbol);
        MarketMemoryService.instance.record(
          action: 'favorite',
          symbol: symbol,
          source: 'voice',
          aiMode: currentMode.name,
          result: 'confirmed',
          rawInput: input,
        );
        final removed = effectiveLang == 'ru'
            ? '$symbol убран из избранного.'
            : '$symbol removed from watchlist.';
        return info(removed, const [], speech: removed);
      }
    }

    // --- Remove TP/SL via voice/chat (10F: modify/remove) ---
    if (norm.hasRemoveTpKeyword(lower)) {
      final symbol = _extractAssetSymbol(lower) ??
          ctx.focusedSymbol?.toUpperCase();
      if (symbol != null) {
        AutomationEngine.instance.removeTriggersForSymbol(
            symbol, TriggerAction.notifyOnly,
            onlyType: TriggerType.takeProfit);
        final msg = effectiveLang == 'ru'
            ? 'TP для $symbol снят.'
            : 'Take profit for $symbol removed.';
        return info(msg, const [], speech: msg);
      }
      final msg = effectiveLang == 'ru'
          ? 'Скажите для какой монеты убрать TP.'
          : 'Which coin\'s take profit should I remove?';
      return info(msg, const [], speech: msg);
    }

    if (norm.hasRemoveSlKeyword(lower)) {
      final symbol = _extractAssetSymbol(lower) ??
          ctx.focusedSymbol?.toUpperCase();
      if (symbol != null) {
        AutomationEngine.instance.removeTriggersForSymbol(
            symbol, TriggerAction.notifyOnly,
            onlyType: TriggerType.stopLoss);
        final msg = effectiveLang == 'ru'
            ? 'SL для $symbol снят.'
            : 'Stop loss for $symbol removed.';
        return info(msg, const [], speech: msg);
      }
      final msg = effectiveLang == 'ru'
          ? 'Скажите для какой монеты убрать SL.'
          : 'Which coin\'s stop loss should I remove?';
      return info(msg, const [], speech: msg);
    }

    // --- Price alert via voice/chat (10C: synonym dict + spoken numbers) ---
    // Understands: алерт / колокольчик / маякни / notify me / when it jumps / etc.

    // Remove alert first
    if (norm.hasRemoveAlertKeyword(lower)) {
      final symbol = _extractAssetSymbol(lower) ??
          ctx.focusedSymbol?.toUpperCase();
      if (symbol != null) {
        MarketPriceAlertService.instance.removeAllForSymbol(symbol);
        final msg = effectiveLang == 'ru'
            ? 'Алерт для $symbol снят.'
            : 'Alert for $symbol removed.';
        return info(msg, const [], speech: msg);
      }
      final msg = effectiveLang == 'ru'
          ? 'Скажите для какой монеты убрать алерт.'
          : 'Which coin\'s alert should I remove?';
      return info(msg, const [], speech: msg);
    }

    final isAlertCommand = norm.hasAlertKeyword(lower);
    if (isAlertCommand && !isTpSlCommand) {
      final explicitSymbol = _extractAssetSymbol(lower);
      final symbol = explicitSymbol ?? ctx.focusedSymbol?.toUpperCase();
      if (symbol == null) {
        final noSymbol = effectiveLang == 'ru'
            ? 'Какую монету? Откройте карточку или скажите символ.'
            : 'Which coin? Open a token detail or say the symbol.';
        return info(noSymbol, const [], speech: noSymbol);
      }

      // Extract % — numeric OR spoken ("десять процентов" → 10.0)
      final pct = norm.parsePercent(lower);
      if (pct != null && pct > 0 && pct <= 100) {
        final price = ctx.focusedSymbol?.toUpperCase() == symbol
            ? ctx.focusedPrice
            : _findPriceForSymbol(symbol);
        if (price != null && price > 0) {
          // Default: alert on rise (take profit style)
          AutomationEngine.instance.addTrigger(
            assetSymbol: symbol,
            type: TriggerType.priceAbove,
            requestedAction: TriggerAction.notifyOnly,
            thresholdPct: pct,
            entryPriceUsd: price,
            label: 'Alert $symbol +${pct.toStringAsFixed(0)}% (voice)',
          );
          final target = price * (1 + pct / 100);
          final fmtTarget = target < 1 ? target.toStringAsFixed(6) : target.toStringAsFixed(2);
          final msg = effectiveLang == 'ru'
              ? '🔔 Алерт: $symbol +${pct.toStringAsFixed(0)}% → \$$fmtTarget. Уведомлю.'
              : '🔔 Alert: $symbol +${pct.toStringAsFixed(0)}% → \$$fmtTarget. Will notify.';
          MarketMemoryService.instance.record(
            action: 'alert',
            symbol: symbol,
            source: 'voice',
            aiMode: currentMode.name,
            result: 'confirmed',
            priceThen: price,
            rawInput: input,
          );
          return info(msg, const [], speech: msg);
        }
      }

      // Try absolute price: "алерт BTC 70000"
      final priceMatch = RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(
          lower.replaceAll(RegExp(r'[a-zA-Z]+'), ' ').trim());
      if (priceMatch != null) {
        final targetPrice = double.tryParse(priceMatch.group(1)!.replaceAll(',', '.')) ?? 0;
        if (targetPrice > 0) {
          final currentPrice = ctx.focusedSymbol?.toUpperCase() == symbol
              ? ctx.focusedPrice
              : _findPriceForSymbol(symbol);
          final isAbove = currentPrice == null || targetPrice >= currentPrice;
          AutomationEngine.instance.addTrigger(
            assetSymbol: symbol,
            type: isAbove ? TriggerType.priceAbove : TriggerType.priceBelow,
            requestedAction: TriggerAction.notifyOnly,
            thresholdUsd: targetPrice,
            label: 'Alert $symbol ${isAbove ? "≥" : "≤"}\$${targetPrice.toStringAsFixed(2)} (voice)',
          );
          final msg = effectiveLang == 'ru'
              ? '🔔 Алерт: $symbol ${isAbove ? "≥" : "≤"} \$${targetPrice.toStringAsFixed(2)}. Уведомлю.'
              : '🔔 Alert: $symbol ${isAbove ? "≥" : "≤"} \$${targetPrice.toStringAsFixed(2)}. Will notify.';
          MarketMemoryService.instance.record(
            action: 'alert',
            symbol: symbol,
            source: 'voice',
            aiMode: currentMode.name,
            result: 'confirmed',
            priceThen: currentPrice,
            rawInput: input,
          );
          return info(msg, const [], speech: msg);
        }
      }

      // No valid target
      final hint = effectiveLang == 'ru'
          ? 'Укажите цену или процент. Например: "алерт +10%" или "алерт BTC 70000".'
          : 'Specify a price or percentage. Example: "alert +10%" or "alert BTC 70000".';
      return info(hint, const [], speech: hint);
    }

    // --- Show active alerts ---
    // "покажи мои алерты", "мои триггеры", "show my alerts"
    final isShowAlerts = lower.contains('мои алерт') ||
        lower.contains('мои тригг') ||
        lower.contains('покажи алерт') ||
        lower.contains('покажи тригг') ||
        lower.contains('show alert') ||
        lower.contains('show trigger') ||
        lower.contains('my alert') ||
        lower.contains('my trigger') ||
        lower.contains('list alert') ||
        lower.contains('list trigger');
    if (isShowAlerts) {
      final triggers = AutomationEngine.instance.triggers;
      if (triggers.isEmpty) {
        final empty = effectiveLang == 'ru'
            ? 'Активных алертов нет.'
            : 'No active alerts.';
        return info(empty, const [], speech: empty);
      }
      final buf = StringBuffer();
      buf.writeln(effectiveLang == 'ru'
          ? '📋 Активные алерты (${triggers.length}):'
          : '📋 Active alerts (${triggers.length}):');
      for (final t in triggers) {
        buf.writeln('• ${t.label} — ${t.conditionDescription}');
      }
      final voiceSummary = effectiveLang == 'ru'
          ? '${triggers.length} активных алертов.'
          : '${triggers.length} active alerts.';
      return info(buf.toString(), const [], speech: voiceSummary);
    }

    // --- Show market history ---
    // "что я делал", "мои действия", "покажи историю", "market history"
    final isShowHistory = lower.contains('что я делал') ||
        lower.contains('мои действ') ||
        lower.contains('покажи истори') ||
        lower.contains('рыночная истори') ||
        lower.contains('market history') ||
        lower.contains('my actions') ||
        lower.contains('what did i do') ||
        lower.contains('recent commands');
    if (isShowHistory) {
      final summary = await MarketMemoryService.instance.todaySummary(
        lang: effectiveLang,
      );
      final recent = await MarketMemoryService.instance.recent(limit: 10);
      if (recent.isEmpty) {
        return info(summary, const [], speech: summary);
      }
      final buf = StringBuffer();
      buf.writeln(summary);
      buf.writeln();
      for (final e in recent) {
        buf.writeln('• ${e.summary}');
      }
      return info(buf.toString(), const [], speech: summary);
    }

    return null;
  }

  // ── Market Intelligence Helpers ──────────────────────────────────────────────

  /// Returns true if the user is asking about the market state, signals,
  /// recommendations, or analysis — NOT a specific price query for a named asset.
  ///
  /// KEY RULE: "что купить / what to buy" without a specific asset symbol is a
  /// market RECOMMENDATION query (handled here by MarketScoutService).
  /// With a specific asset ("купи BTC") it is a trading COMMAND — handled by
  /// _isTradingCommand instead.
  static bool _isMarketQuery(String lower) {
    // Explicit market overview queries
    if (lower.contains('что на рынке') ||
        lower.contains('обзор рынк') ||
        lower.contains('market overview')) {
      return true;
    }

    // Signal / opportunity / recommendation queries
    if (lower.contains('сигнал') || lower.contains('signal')) {
      return true;
    }
    if (lower.contains('возможност') || lower.contains('opportunity')) {
      return true;
    }
    if (lower.contains('посоветуй') ||
        lower.contains('рекомендац') ||
        lower.contains('recommend') ||
        lower.contains('совет')) {
      return true;
    }

    // Analysis / strategy queries
    if (lower.contains('анализ рынк') || lower.contains('market analys')) {
      return true;
    }
    if (lower.contains('стратеги') || lower.contains('strategy')) return true;
    if (lower.contains('прогноз') || lower.contains('forecast')) return true;
    if (lower.contains('тренд') || lower.contains('trend')) return true;

    // "What should I buy/sell/invest" — only when no specific asset is named.
    // If the user says "what coin to buy" without naming one, it's a market briefing.
    // If they name an asset ("купи BTC"), _isTradingCommand will catch it first
    // because it is checked AFTER _isMarketQuery in _fastPathCommand.
    final hasBuySellKeyword = lower.contains('купить') ||
        lower.contains('buy') ||
        lower.contains('продать') ||
        lower.contains('sell') ||
        lower.contains('инвестировать') ||
        lower.contains('invest') ||
        lower.contains('вложить') ||
        lower.contains('вложить');
    final hasQuestionWord = lower.contains('что') ||
        lower.contains('какую') ||
        lower.contains('какой') ||
        lower.contains('what') ||
        lower.contains('which') ||
        lower.contains('какие') ||
        lower.contains('лучше') ||
        lower.contains('стоит') ||
        lower.contains('выгодно') ||
        lower.contains('сейчас');
    if (hasBuySellKeyword && hasQuestionWord) return true;

    return false;
  }

  /// Builds a market briefing from ranked signals.
  ///
  /// [short] = true: voice-friendly (~10 seconds speech).
  /// [short] = false: full chat message with prices, actions, thesis.
  static String _buildMarketBriefing(
    List<MarketOpportunity> signals,
    String lang, {
    bool short = false,
  }) {
    if (signals.isEmpty) {
      return lang == 'ru'
          ? 'Сейчас на рынке нет выраженных сигналов. Рекомендую подождать.'
          : 'No strong signals on the market right now. Recommend waiting.';
    }

    final buf = StringBuffer();

    if (short) {
      // Voice: compact, ~10 seconds
      if (lang == 'ru') {
        buf.write('Топ сигналы: ');
        for (int i = 0; i < signals.length; i++) {
          final s = signals[i];
          final sign = s.asset.change24h >= 0 ? '+' : '';
          buf.write(
              '${s.asset.symbol} $sign${s.asset.change24h.toStringAsFixed(1)}%. ');
        }
        final best = signals.first;
        buf.write(
            'Лучший: ${best.asset.symbol}, ${best.action.toLowerCase()}.');
      } else {
        buf.write('Top signals: ');
        for (int i = 0; i < signals.length; i++) {
          final s = signals[i];
          final sign = s.asset.change24h >= 0 ? '+' : '';
          buf.write(
              '${s.asset.symbol} $sign${s.asset.change24h.toStringAsFixed(1)}%. ');
        }
        final best = signals.first;
        buf.write('Best: ${best.asset.symbol}, ${best.action.toLowerCase()}.');
      }
    } else {
      // Chat: full detail
      if (lang == 'ru') {
        buf.writeln('📊 **Обзор рынка — топ ${signals.length} сигналов:**\n');
      } else {
        buf.writeln(
            '📊 **Market Overview — Top ${signals.length} Signals:**\n');
      }

      for (int i = 0; i < signals.length; i++) {
        final s = signals[i];
        final sign = s.asset.change24h >= 0 ? '+' : '';
        final price = s.asset.price >= 1
            ? '\$${s.asset.price.toStringAsFixed(2)}'
            : '\$${s.asset.price.toStringAsFixed(4)}';

        // Source label: 📡 = exchange (with name), 🌐 = CoinGecko
        final isExchangeOnly = s.asset.id.isEmpty || s.asset.rank == 0;
        final String sourceTag;
        if (isExchangeOnly) {
          final exchanges =
              ExchangeRegistry.instance.exchangesFor(s.asset.symbol);
          sourceTag =
              exchanges.isNotEmpty ? ' 📡 ${exchanges.join(", ")}' : ' 📡';
        } else {
          sourceTag = ' 🌐';
        }

        buf.writeln(
            '**${i + 1}. ${s.asset.symbol}**$sourceTag — $price ($sign${s.asset.change24h.toStringAsFixed(2)}% 24ч)');
        buf.writeln('   ${s.action}');
        buf.writeln('   ${s.thesis}');

        // Confidence + liquidity tier
        final confPct = (s.confidence * 100).toInt();
        final confBar = _confidenceBar(s.confidence);
        final liqLabel = switch (s.liquidityTier) {
          LiquidityTier.high => '🟢 High',
          LiquidityTier.medium => '🟡 Medium',
          LiquidityTier.low => '🔴 Low',
        };
        buf.writeln('   $confBar confidence $confPct% · liquidity: $liqLabel');

        if (!s.executableByAi && s.blockReason != null) {
          buf.writeln('   ⚠️ ${s.blockReason}');
        } else if (s.executableByAi) {
          buf.writeln(lang == 'ru'
              ? '   ✅ Готов к исполнению'
              : '   ✅ Ready to execute');
        }
        buf.writeln();
      }

      // Mode capability summary
      final capNote = MarketScoutService.instance
          .buildModeCapabilityNote(AiControlService.instance.settings);
      buf.writeln(lang == 'ru' ? '🤖 $capNote' : '🤖 $capNote');

      // Exchange connection context
      final reg = ExchangeRegistry.instance;
      final connectedExchanges = reg.availableExchanges
          .where((id) => reg.serviceFor(id).isConnected)
          .map((id) =>
              '${id.displayName} (${reg.serviceFor(id).totalPairs} пар)')
          .join(', ');
      if (connectedExchanges.isNotEmpty) {
        buf.writeln();
        buf.writeln(lang == 'ru'
            ? '📡 Данные: $connectedExchanges — реалтайм'
            : '📡 Data: $connectedExchanges — real-time');
      }

      // New listings
      final newListings = reg.recentNewListings;
      if (newListings.isNotEmpty) {
        final names = newListings
            .take(5)
            .map((e) => '${e.ticker.baseAsset} (${e.exchange})')
            .join(', ');
        buf.writeln(lang == 'ru'
            ? '🆕 Новые листинги: $names'
            : '🆕 New listings: $names');
      }
    }

    return buf.toString().trim();
  }

  // ── Trading Command Helpers ───────────────────────────────────────────────

  /// Renders a visual confidence bar: ████░░░░░░ (filled vs empty).
  static String _confidenceBar(double confidence) {
    const total = 5;
    final filled = (confidence * total).round().clamp(0, total);
    return '█' * filled + '░' * (total - filled);
  }

  /// Returns true if the user is giving a direct trading command
  /// (buy/sell/swap a specific asset), NOT a general market query.
  static bool _isTradingCommand(String lower) {
    // Direct buy commands
    if (lower.contains('купи') ||
        lower.contains('куплю') ||
        lower.contains('покупай') ||
        lower.contains('покупк')) {
      return true;
    }
    if (lower.contains('buy') || lower.contains('purchase')) return true;

    // Direct sell commands
    if (lower.contains('продай') ||
        lower.contains('продать') ||
        lower.contains('продаж')) {
      return true;
    }
    if (lower.contains('sell')) return true;

    // Swap / exchange commands (but not general "обмен" without asset)
    // These are already caught earlier in send/swap, but we handle them
    // more intelligently here with TradingPlan
    if (lower.contains('обменяй') || lower.contains('поменяй')) return true;

    // Investment commands
    if (lower.contains('вложи') || lower.contains('инвестир')) return true;
    if (lower.contains('invest')) return true;

    return false;
  }

  /// Derives the trading direction from user text.
  static TradingDirection _extractTradingDirection(String lower) {
    if (lower.contains('продай') ||
        lower.contains('продать') ||
        lower.contains('продаж') ||
        lower.contains('sell')) {
      return TradingDirection.sell;
    }
    if (lower.contains('обменяй') ||
        lower.contains('поменяй') ||
        lower.contains('swap') ||
        lower.contains('обмен')) {
      return TradingDirection.swap;
    }
    // Default to buy for "купи", "buy", "вложи", "invest"
    return TradingDirection.buy;
  }

  /// Extracts a USD amount from user text.
  /// Handles: "на 50 долларов", "$50", "50$", "100 usdt", "за 200"
  static double? _extractAmount(String lower) {
    return IntentParser.extractAmount(lower);
  }

  /// Builds a human-readable trading plan briefing.
  ///
  /// [short] = true: voice (~10s) — asset, direction, size, risk, execution status
  /// [short] = false: full chat with all plan details
  static String _buildTradingPlanBriefing(
    TradingPlan plan,
    String lang, {
    bool short = false,
  }) {
    final dirLabel = switch (plan.direction) {
      TradingDirection.buy => lang == 'ru' ? 'Покупка' : 'Buy',
      TradingDirection.sell => lang == 'ru' ? 'Продажа' : 'Sell',
      TradingDirection.swap => lang == 'ru' ? 'Обмен' : 'Swap',
      TradingDirection.swing => lang == 'ru' ? 'Свинг-трейд' : 'Swing Trade',
    };

    final priceStr = plan.entryPrice >= 1
        ? '\$${plan.entryPrice.toStringAsFixed(2)}'
        : '\$${plan.entryPrice.toStringAsFixed(4)}';

    final riskLabel = switch (plan.riskLevel) {
      TradingRisk.low => lang == 'ru' ? 'Низкий' : 'Low',
      TradingRisk.medium => lang == 'ru' ? 'Средний' : 'Medium',
      TradingRisk.high => lang == 'ru' ? 'Высокий' : 'High',
      TradingRisk.excessive => lang == 'ru' ? 'Чрезмерный' : 'Excessive',
    };

    if (short) {
      final sizeStr = '\$${plan.suggestedSizeUsd.toStringAsFixed(0)}';
      if (lang == 'ru') {
        final status =
            plan.executableByAi ? 'готов к исполнению' : 'заблокировано';
        return '$dirLabel ${plan.asset.symbol}. Цена $priceStr. '
            'Объём $sizeStr. Риск: $riskLabel. Статус: $status.';
      } else {
        final status = plan.executableByAi ? 'ready to execute' : 'blocked';
        return '$dirLabel ${plan.asset.symbol}. Price $priceStr. '
            'Size $sizeStr. Risk: $riskLabel. Status: $status.';
      }
    }

    final buf = StringBuffer();
    if (lang == 'ru') {
      buf.writeln('📋 **Торговый план: $dirLabel ${plan.asset.symbol}**\n');
    } else {
      buf.writeln('📋 **Trading Plan: $dirLabel ${plan.asset.symbol}**\n');
    }
    buf.writeln(lang == 'ru'
        ? '**Цена:** $priceStr | **Зона:** ${plan.zone}'
        : '**Price:** $priceStr | **Zone:** ${plan.zone}');
    if (plan.targetPrice != null && plan.stopLossPrice != null) {
      final targetStr = plan.targetPrice! >= 1
          ? '\$${plan.targetPrice!.toStringAsFixed(2)}'
          : '\$${plan.targetPrice!.toStringAsFixed(4)}';
      final stopStr = plan.stopLossPrice! >= 1
          ? '\$${plan.stopLossPrice!.toStringAsFixed(2)}'
          : '\$${plan.stopLossPrice!.toStringAsFixed(4)}';
      buf.writeln(lang == 'ru'
          ? '**Цель:** $targetStr | **Стоп:** $stopStr'
          : '**Target:** $targetStr | **Stop:** $stopStr');
    }
    buf.writeln(lang == 'ru'
        ? '**Объём:** \$${plan.suggestedSizeUsd.toStringAsFixed(0)} '
            '(макс: \$${plan.maxSizeUsd.toStringAsFixed(0)})'
        : '**Size:** \$${plan.suggestedSizeUsd.toStringAsFixed(0)} '
            '(max: \$${plan.maxSizeUsd.toStringAsFixed(0)})');
    buf.writeln(lang == 'ru'
        ? '**Маршрут:** ${plan.routeNote}'
        : '**Route:** ${plan.routeNote}');
    buf.writeln(lang == 'ru'
        ? '**Риск:** $riskLabel — ${plan.riskNote}'
        : '**Risk:** $riskLabel — ${plan.riskNote}');
    buf.writeln(lang == 'ru'
        ? '**Слиппейдж:** ~${plan.estimatedSlippagePct.toStringAsFixed(2)}%'
        : '**Slippage:** ~${plan.estimatedSlippagePct.toStringAsFixed(2)}%');
    buf.writeln();
    buf.writeln(lang == 'ru' ? '💡 ${plan.thesis}' : '💡 ${plan.thesis}');
    buf.writeln();
    if (plan.executableByAi) {
      buf.writeln(lang == 'ru'
          ? '✅ **Готов к исполнению** в текущем режиме.'
          : '✅ **Ready to execute** in current mode.');
    } else {
      buf.writeln(lang == 'ru'
          ? '⛔ **Заблокировано:** ${plan.blockReason ?? "см. мандат"}'
          : '⛔ **Blocked:** ${plan.blockReason ?? "see mandate"}');
    }

    return buf.toString();
  }

  List<UICommand> _fallbackUiCommandsForText(String input) {
    final lower = input.toLowerCase();
    if (AiControlService.instance.settings.mode == AiMode.manual &&
        (lower.contains('send') ||
            lower.contains('swap') ||
            lower.contains('отправ') ||
            lower.contains('обмен'))) {
      return const [];
    }

    // Balance — only explicit balance phrases, not just the word "баланс"
    if (_matchesAnyPhrase(lower, [
          'мой баланс',
          'покажи баланс',
          'проверь баланс',
          'баланс кошелька',
          'my balance',
          'show balance',
          'check balance',
        ]) &&
        !lower.contains('истор')) {
      return const [
        UICommand(type: UICommandType.navigate, target: 'wallet'),
      ];
    }

    // Address — only explicit address phrases
    if (_matchesAnyPhrase(lower, [
      'мой адрес',
      'адрес кошелька',
      'покажи адрес',
      'my address',
      'wallet address',
      'show address',
    ])) {
      return const [
        UICommand(type: UICommandType.navigate, target: 'wallet'),
        UICommand(type: UICommandType.openModal, target: 'wallet_receive'),
      ];
    }

    // Receive — only explicit receive phrases
    if (_matchesAnyPhrase(lower, [
      'получить крипту',
      'получить токены',
      'хочу получить',
      'receive crypto',
      'receive tokens',
      'receive funds',
    ])) {
      return const [
        UICommand(type: UICommandType.navigate, target: 'wallet'),
        UICommand(type: UICommandType.openModal, target: 'wallet_receive'),
      ];
    }

    // Send — only when explicitly about sending (with object)
    if (_matchesAnyPhrase(lower, [
      'отправить токены',
      'отправить деньги',
      'отправить крипту',
      'отправь токены',
      'отправь деньги',
      'send tokens',
      'send crypto',
      'send funds',
    ])) {
      return const [
        UICommand(type: UICommandType.navigate, target: 'wallet'),
        UICommand(type: UICommandType.openModal, target: 'wallet_send'),
      ];
    }

    if (lower.contains('security center') ||
        lower.contains('центр безопасности')) {
      return const [
        UICommand(type: UICommandType.navigate, target: 'security_center'),
      ];
    }

    // Market — only explicit open/show commands
    if (_matchesAnyPhrase(lower, [
      'открой рынок',
      'покажи рынок',
      'перейди на рынок',
      'open market',
      'show market',
      'go to market',
    ])) {
      return const [
        UICommand(type: UICommandType.navigate, target: 'market'),
      ];
    }

    if (lower.contains('политик') || lower.contains('policy')) {
      return const [
        UICommand(type: UICommandType.openModal, target: 'policy_limits'),
      ];
    }

    if (lower.contains('ai center') ||
        (lower.contains('центр') && lower.contains('ai'))) {
      return const [
        UICommand(type: UICommandType.openModal, target: 'ai_control'),
      ];
    }

    if (lower.contains('epk')) {
      return const [
        UICommand(type: UICommandType.openModal, target: 'epk_control'),
      ];
    }

    if (_matchesAnyPhrase(lower, [
      'аудит кошелька',
      'аудит разрешений',
      'покажи аудит',
      'audit wallet',
      'audit history',
    ])) {
      return const [
        UICommand(type: UICommandType.openModal, target: 'audit_history'),
      ];
    }

    // History — only explicit history phrases
    if (_matchesAnyPhrase(lower, [
      'покажи историю',
      'история операций',
      'история транзакций',
      'мои операции',
      'мои транзакции',
      'show history',
      'transaction history',
      'my history',
    ])) {
      return const [
        UICommand(type: UICommandType.openModal, target: 'wallet_history'),
      ];
    }

    if (lower.contains('адресн') ||
        lower.contains('address book') ||
        lower.contains('contacts') ||
        lower.contains('contact list') ||
        lower.contains('мои контакты')) {
      return const [
        UICommand(type: UICommandType.navigate, target: 'wallet'),
        UICommand(type: UICommandType.openModal, target: 'wallet_address_book'),
      ];
    }

    if ((lower.contains('настройк') && lower.contains('кошел')) ||
        lower.contains('wallet settings') ||
        (lower.contains('settings') && lower.contains('wallet'))) {
      return const [
        UICommand(type: UICommandType.navigate, target: 'wallet'),
        UICommand(type: UICommandType.openModal, target: 'wallet_settings'),
      ];
    }

    if (_matchesAnyPhrase(lower, [
          'обменять',
          'обменяй',
          'swap tokens',
        ]) ||
        (lower.contains('swap') && lower.contains(' to '))) {
      return const [
        UICommand(type: UICommandType.openModal, target: 'wallet_swap'),
      ];
    }

    if (lower.contains('panic') ||
        lower.contains('паник') ||
        lower.contains('revoke') ||
        lower.contains('отозв') ||
        (lower.contains('срочно') &&
            (lower.contains('разрешен') ||
                lower.contains('отозв') ||
                lower.contains('всё') ||
                lower.contains('все')))) {
      return const [
        UICommand(type: UICommandType.openModal, target: 'panic'),
      ];
    }

    if ((lower.contains('скан') && lower.contains('кошел')) ||
        (lower.contains('scan') && lower.contains('wallet')) ||
        lower.contains('safe review') ||
        lower.contains('безопасный режим') ||
        (lower.contains('провер') &&
            (lower.contains('разрешен') || lower.contains('контракт')))) {
      return const [
        UICommand(type: UICommandType.openModal, target: 'safe'),
      ];
    }

    return const [];
  }

  /// Helper: returns true if [text] contains any of the given [phrases].
  static bool _matchesAnyPhrase(String text, List<String> phrases) {
    return phrases.any((p) => text.contains(p));
  }

  /// Detect the optimal Voice Mode based on command traits
  AssistantToneMode _detectMode(String input, String actionName) {
    if ([
      'sendAsset',
      'revokeApproval',
      'scanApprovals',
      'showBalances',
      'showAddress',
      'swapAsset'
    ].contains(actionName)) {
      return AssistantToneMode.operator;
    }

    final lower = input.toLowerCase();
    final analystHints = [
      'курс',
      'цена',
      'рынок',
      'стратег',
      'bitcoin',
      'btc',
      'eth',
      'новости',
      'аналит',
      'доллар',
      'портфель',
      'price',
      'market'
    ];

    if (analystHints.any(lower.contains)) {
      return AssistantToneMode.analyst;
    }

    return AssistantToneMode.companion;
  }

  Future<AssistantResponse> process(
    String input, {
    String? languageCode,
    required AssistantInputSource source,
  }) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return AssistantResponse.error('Input is empty.');
    }

    // 1. Dynamic Language Detection
    final detectedLang = languageCode ?? LanguageDetector.detect(trimmed);
    final lower = trimmed.toLowerCase();

    // ── 0. Hard Greeting Fast-Path (Isolate "Hello" from Operational Context) ──
    // Strictly matching pure greetings to prevent LLM operational hallucinations.
    const pureGreetings = [
      'привет',
      'здравствуй',
      'здравствуйте',
      'hello',
      'hi',
      'добрый день',
      'доброе утро',
      'добрый вечер',
    ];

    // Whisper transcripts usually include punctuation (e.g. "Привет.").
    final normalizedGreeting =
        lower.replaceAll(RegExp(r'[^\w\sа-яА-Я]'), '').trim();

    // If the user says strictly just one of these words, we shortcut.
    if (pureGreetings.contains(normalizedGreeting)) {
      final isRu = detectedLang.startsWith('ru');
      return AssistantResponse.info(
        isRu ? 'Привет. Чем помочь?' : 'Hi. How can I help?',
        speechText: isRu ? 'Привет. Чем помочь?' : 'Hi. How can I help?',
      );
    }

    // ── Personal Memory Layer ────────────────────────────────────────────────
    final memory = UserMemoryService.instance;

    // 1a. Learn command: "запомни: котлета = купить на весь USDT"
    final learnResult = _tryLearnCommand(lower, trimmed, detectedLang);
    if (learnResult != null) return learnResult;

    // 1b. Forget command: "забудь что такое котлета"
    final forgetResult = _tryForgetCommand(lower, trimmed, detectedLang);
    if (forgetResult != null) return forgetResult;

    // 1c. Memory query: "что ты обо мне помнишь?"
    if (_isMemoryQuery(lower)) {
      return AssistantResponse.info(memory.describeMemory(detectedLang));
    }

    // 1d. Macro intercept — deterministic, bypasses AI entirely
    final macro = memory.matchMacro(trimmed);
    if (macro != null) {
      return _executeMacro(macro, detectedLang);
    }

    // 1e. Vocabulary expansion — rewrite slang before the rest of the pipeline
    final expanded = memory.expandVocab(trimmed);
    // -- Pipeline: mode/limits checks -> fast-path -> intent -> LLM --------

    if (_isModeStatusQuestion(expanded)) {
      return _modeContractResponse(detectedLang);
    }

    if (_isLimitsStatusQuestion(expanded)) {
      return _limitsStatusResponse(detectedLang);
    }

    // ── Amount Fast-Path: intercept "вставь 5" when a modal is open ────────
    final amountFastResult = _tryAmountFastPath(lower, detectedLang);
    if (amountFastResult != null) return amountFastResult;

    // ── Modal-open fast-path: intercept "открой отправку" BEFORE IntentParser ──
    // IntentParser would match 'отправ' → sendAsset (empty params) → orchestrate
    // would fail with "не удалось создать транзакцию". This fast-path dispatches
    // the actual UI commands and returns a friendly voice ack.
    final modalOpenFastPath = _modalOpenFastPath(expanded, detectedLang);
    if (modalOpenFastPath != null) return modalOpenFastPath;

    // ── Primary OpenAI & Local Fallback voice/chat trade intent pipeline ──────
    final isVoiceOrChat = source == AssistantInputSource.voice || source == AssistantInputSource.marketChat;
    if (isVoiceOrChat) {
      IntentData? resolvedTradeIntent;
      bool hasTradeIntent = false;

      // 1. Primary OpenAI Resolver
      final openaiResult = await _openai.solveTradeIntent(expanded, languageCode: detectedLang);
      if (openaiResult != null) {
        final typeStr = openaiResult['type'];
        final double confidence = (openaiResult['confidence'] ?? 0.0).toDouble();
        if (typeStr == 'capabilityQuestion' && confidence >= 0.6) {
          final isRu = detectedLang.startsWith('ru');
          final msg = isRu
              ? "Да. В Guarded я открою окно покупки для подтверждения. В Full могу купить сам в рамках лимитов. Скажите монету и сумму."
              : "Yes. In Guarded I open the trade window for confirmation. In Full I can execute within your limits. Tell me the coin and amount.";
          return AssistantResponse.info(msg, speechText: msg);
        }

        if (typeStr != 'unknown' && typeStr != 'capabilityQuestion' && confidence >= 0.6) {
          hasTradeIntent = true;
          final type = typeStr == 'sellAsset' ? IntentType.sellAsset : IntentType.buyAsset;
          final String? rawSymbol = openaiResult['tokenSymbol'];
          final double? amount = openaiResult['amount'] != null ? (openaiResult['amount'] as num).toDouble() : null;
          final bool isQuantity = openaiResult['isQuantity'] ?? false;

          // Resolve symbol. If it's null/implicit, fallback to screen context focusedSymbol
          String? symbol = rawSymbol;
          if (symbol == null || symbol.isEmpty || symbol.toLowerCase() == 'монету' || symbol.toLowerCase() == 'this coin' || symbol.toLowerCase() == 'it') {
            symbol = ScreenContextService.instance.focusedSymbol;
          }

          // If symbol is not null, verify if it is a known valid token.
          // If it's not a known token (like "blabla"), treat it as null/invalid.
          if (symbol != null && !MarketVoiceBrain.isValidToken(symbol)) {
            symbol = null;
          }

          resolvedTradeIntent = IntentData(
            type: type,
            rawInput: expanded,
            tokenSymbol: symbol,
            amount: amount,
            isQuantity: isQuantity,
          );
        }
      } else {
        // 2. Local fallback if OpenAI is offline, timed out, or failed
        final localIntent = MarketVoiceBrain.parseTradeIntent(expanded);
        if (localIntent != null) {
          hasTradeIntent = true;
          resolvedTradeIntent = localIntent;
        }
      }

      if (hasTradeIntent && resolvedTradeIntent != null) {
        final isRu = detectedLang.startsWith('ru');

        // Missing amount prompt
        if (resolvedTradeIntent.amount == null) {
          return AssistantResponse.info(
            isRu ? "Укажите сумму." : "Please specify the amount.",
            speechText: isRu ? "Сумма?" : "Amount?",
          );
        }

        // Missing token symbol prompt
        if (resolvedTradeIntent.tokenSymbol == null || resolvedTradeIntent.tokenSymbol!.isEmpty) {
          return AssistantResponse.info(
            isRu ? "Укажите монету." : "Please specify the token.",
            speechText: isRu ? "Монета?" : "Token?",
          );
        }

        if (resolvedTradeIntent.isExecutionIntent &&
            AiControlService.instance.settings.mode == AiMode.manual) {
          return _manualExecutionBlockedResponse(detectedLang);
        }

        final symbol = resolvedTradeIntent.tokenSymbol!.toUpperCase();
        final markets = MarketDataService.instance.cachedMarkets;
        final asset = markets.cast<MarketAsset?>().firstWhere(
              (a) => a!.symbol.toUpperCase() == symbol,
              orElse: () => null,
            );
        final isCexAsset = asset != null &&
            const ['mexc', 'binance', 'gateio', 'okx']
                .contains(asset.sourceId.toLowerCase());

        if (isCexAsset) {
          return await _handleCexTradeIntent(resolvedTradeIntent, source, detectedLang);
        } else {
          return await _handleOnChainTradeIntent(resolvedTradeIntent, detectedLang);
        }
      }
    }

    final parsedIntent =
        _resolveAddressBookRecipient(IntentParser.parse(expanded));

    if (parsedIntent.type != IntentType.unknown) {
      if (parsedIntent.isExecutionIntent &&
          AiControlService.instance.settings.mode == AiMode.manual) {
        return _manualExecutionBlockedResponse(detectedLang);
      }

      if (parsedIntent.type == IntentType.buyAsset ||
          parsedIntent.type == IntentType.sellAsset) {
        final symbol = parsedIntent.tokenSymbol ?? _extractAssetSymbol(expanded);
        final markets = MarketDataService.instance.cachedMarkets;
        final asset = markets.cast<MarketAsset?>().firstWhere(
              (a) => a!.symbol.toUpperCase() == symbol?.toUpperCase(),
              orElse: () => null,
            );
        final isCexAsset = asset != null &&
            const ['mexc', 'binance', 'gateio', 'okx']
                .contains(asset.sourceId.toLowerCase());

        if (isCexAsset) {
          return await _handleCexTradeIntent(parsedIntent, source, detectedLang);
        }
      }

      // ── Async swap branch: delegate to SwapVoiceOrchestrator ──────────────
      // SwapVoiceOrchestrator is async → cannot go through _fallbackUiCommandsForIntent()
      // which is sync. Intercept here, before the generic command pipeline.
      if (parsedIntent.type == IntentType.swapAsset) {
        final swapResult =
            await SwapVoiceOrchestrator.instance.handleSwapIntent(
          sourceSymbol: parsedIntent.sourceTokenSymbol,
          targetSymbol: parsedIntent.targetTokenSymbol,
          amount: parsedIntent.amount,
          lang: detectedLang,
        );
        if (swapResult.commands.isNotEmpty) {
          UICommandBus.instance.dispatchAll(swapResult.commands);
        }
        return AssistantResponse.info(
          swapResult.speechText,
          speechText: swapResult.speechText,
          commands: swapResult.commands,
        );
      }

      final parsedCommands = _commandsAllowedForMode(
        parsedIntent,
        _mergeUiCommands(
          _fallbackUiCommandsForIntent(parsedIntent),
          _fallbackUiCommandsForText(expanded),
        ),
      );
      // Apply window permissions (openWindows/closeWindows) on top of
      // _commandsAllowedForMode so Manual mode cannot navigate/openModal via
      // the IntentParser fast route either.
      final permParsedCmds = _applyWindowPermissions(parsedCommands);
      if (permParsedCmds.isNotEmpty) {
        UICommandBus.instance.dispatchAll(permParsedCmds);
      }

      final parsedActionName = parsedIntent.type.name;
      final parsedMode = _detectMode(expanded, parsedActionName);
      VoiceGreetingService.instance.setPersonaMode(
        parsedMode == AssistantToneMode.operator
            ? VoicePersonaMode.operator
            : parsedMode == AssistantToneMode.analyst
                ? VoicePersonaMode.analyst
                : VoicePersonaMode.companion,
      );

      if (parsedIntent.type == IntentType.sendAsset ||
          parsedIntent.type == IntentType.receiveAsset ||
          parsedIntent.type == IntentType.swapAsset ||
          parsedIntent.type == IntentType.scanApprovals ||
          parsedIntent.type == IntentType.revokeApproval ||
          parsedIntent.type == IntentType.showBalances ||
          parsedIntent.type == IntentType.showWalletCards ||
          parsedIntent.type == IntentType.showAddress ||
          parsedIntent.type == IntentType.showHistory ||
          parsedIntent.type == IntentType.openAddressBook ||
          parsedIntent.type == IntentType.openWalletSettings ||
          parsedIntent.type == IntentType.openMarket ||
          parsedIntent.type == IntentType.openSecurityCenter ||
          parsedIntent.type == IntentType.showRisks) {
        final parsedResponse =
            await _controller.orchestrate(IntentRouter.route(parsedIntent));
        return _enhanceForVoice(
          parsedResponse,
          languageCode: detectedLang,
          // Use permParsedCmds so the response records what was actually dispatched.
          commands: permParsedCmds,
        );
      }
    }

    final fastPath = await _fastPathCommand(expanded, detectedLang, source);
    if (fastPath != null) {
      return fastPath;
    }

    // LLM fallback — panic/safe/scan are already handled by _fastPathCommand()
    // so they won't reach here via voice. Chat path may still reach LLM.
    // 3. Fetch AI Intent via OpenAI, with optional market context prepend.
    // Market context is compact — only what the assistant needs to reason.
    // Built from cache (no new API calls).
    final enrichedInput = _enrichWithMarketContext(expanded);
    final aiResult = await _openai.solve(enrichedInput, detectedLang);
    final directive = AssistantDirective.fromJson(aiResult);

    final mergedUiCommands = _mergeUiCommands(
      _mergeUiCommands(
        directive.uiCommands,
        _fallbackUiCommandsForIntent(directive.explicitIntent),
      ),
      _fallbackUiCommandsForText(expanded),
    );
    final filteredUiCommands = _commandsAllowedForMode(
      directive.explicitIntent,
      mergedUiCommands,
    );

    if (directive.explicitIntent != null &&
        directive.explicitIntent!.isExecutionIntent &&
        AiControlService.instance.settings.mode == AiMode.manual) {
      return _manualExecutionBlockedResponse(detectedLang);
    }

    // Dispatch UI commands with unified window-permission filtering.
    // _commandsAllowedForMode handled execution intents; _applyWindowPermissions
    // handles navigate/openModal/dismiss based on openWindows/closeWindows flags.
    final permFilteredCmds = _applyWindowPermissions(filteredUiCommands);
    if (permFilteredCmds.isNotEmpty) {
      UICommandBus.instance.dispatchAll(permFilteredCmds);
    }

    final String actionName = directive.explicitIntent != null
        ? directive.explicitIntent!.type.name
        : 'CHAT';

    AssistantSessionContext.instance.update(
      symbol: directive.explicitIntent?.tokenSymbol,
      intentType: actionName,
      topic: expanded,
    );

    final mode = _detectMode(expanded, actionName);

    VoicePersonaMode personaMode = VoicePersonaMode.companion;
    if (mode == AssistantToneMode.operator) {
      personaMode = VoicePersonaMode.operator;
    }
    if (mode == AssistantToneMode.analyst) {
      personaMode = VoicePersonaMode.analyst;
    }

    // Explicit override for panic/security tasks handled by LLM explicitly
    if (actionName == 'PANIC_REVOKE' || actionName == 'SAFE_REVOKE') {
      personaMode = VoicePersonaMode.alert;
    }

    VoiceGreetingService.instance.setPersonaMode(personaMode);

    if (mode == AssistantToneMode.companion ||
        mode == AssistantToneMode.analyst ||
        directive.explicitIntent == null) {
      String finalDisplay = directive.displayMessage;
      String finalSpeech = directive.speechText;
      if (finalDisplay.isEmpty) {
        finalDisplay = detectedLang == 'ru'
            ? 'Простите, я не совсем понял.'
            : 'I didn\'t quite catch that.';
        finalSpeech = finalDisplay;
      }
      return AssistantResponse.info(finalDisplay,
          speechText: finalSpeech,
          // Use permFilteredCmds so the response records what was actually dispatched.
          commands: permFilteredCmds);
    }

    // Operator Mode
    final intent = directive.explicitIntent!;

    // Resolve specific tokens if it's a swap to fill missing backend data for demo
    if (intent.type == IntentType.swapAsset &&
        intent.sourceTokenAddress == null) {
      final intentMut = IntentData(
        type: IntentType.swapAsset,
        rawInput: intent.rawInput,
        amount: intent.amount,
        amountMode: intent.amountMode,
        slippageBps: intent.slippageBps,
        sourceTokenSymbol: intent.sourceTokenSymbol,
        targetTokenSymbol: intent.targetTokenSymbol,
        sourceTokenAddress:
            _resolveTokenAddress(intent.sourceTokenSymbol, detectedLang),
        targetTokenAddress:
            _resolveTokenAddress(intent.targetTokenSymbol, detectedLang),
        sourceTokenDecimals: _resolveTokenDecimals(intent.sourceTokenSymbol),
        targetTokenDecimals: _resolveTokenDecimals(intent.targetTokenSymbol),
      );
      final routerAction = IntentRouter.route(intentMut);
      final systemResponse = await _controller.orchestrate(routerAction);
      return _enhanceForVoice(systemResponse,
          languageCode: detectedLang,
          displayPreface: directive.displayMessage,
          speechPreface: directive.speechText,
          // Use permFilteredCmds so the response records what was actually dispatched.
          commands: permFilteredCmds);
    }

    final routerAction = IntentRouter.route(intent);
    final systemResponse = await _controller.orchestrate(routerAction);

    return _enhanceForVoice(systemResponse,
        languageCode: detectedLang,
        displayPreface: directive.displayMessage,
        speechPreface: directive.speechText,
        // Use permFilteredCmds so the response records what was actually dispatched.
        commands: permFilteredCmds);
  }

  AssistantResponse _enhanceForVoice(
    AssistantResponse response, {
    String languageCode = 'ru',
    String? speechPreface,
    String? displayPreface,
    List<UICommand> commands = const [],
  }) {
    List<String> spokenOutputs = [];
    if (speechPreface != null && speechPreface.isNotEmpty) {
      spokenOutputs.add(speechPreface);
    }

    if (response.policy?.blocked == true) {
      spokenOutputs.add(languageCode == 'ru'
          ? 'Операция заблокирована полиси.'
          : 'Operation blocked.');
    } else if (response.explanation != null) {
      if (response.policy?.requiresConfirmation == true) {
        spokenOutputs.add(languageCode == 'ru'
            ? 'Пожалуйста, подтвердите.'
            : 'Please confirm.');
      }
    } else {
      spokenOutputs.add(response.message);
    }

    final spoken = spokenOutputs
        .map((e) => e.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((e) => e.isNotEmpty)
        .join(' ');

    String finalDisplay = (displayPreface != null && displayPreface.isNotEmpty)
        ? displayPreface
        : response.message;
    if (response.explanation != null && displayPreface != null) {
      finalDisplay = '$displayPreface\n\n${response.explanation!.headline}';
    }

    if (spoken.isEmpty) {
      return AssistantResponse(
        message: finalDisplay,
        speechText: finalDisplay,
        uiCommands: commands,
        type: response.type,
        detail: response.detail,
        sourceIntent: response.sourceIntent,
        pendingTransaction: response.pendingTransaction,
        policy: response.policy,
        explanation: response.explanation,
        rpcSimulation: response.rpcSimulation,
        executionPath: response.executionPath,
        swapPlan: response.swapPlan,
      );
    }

    return AssistantResponse(
      message: finalDisplay,
      speechText: spoken,
      uiCommands: commands,
      type: response.type,
      detail: response.detail,
      sourceIntent: response.sourceIntent,
      pendingTransaction: response.pendingTransaction,
      policy: response.policy,
      explanation: response.explanation,
      rpcSimulation: response.rpcSimulation,
      executionPath: response.executionPath,
      swapPlan: response.swapPlan,
    );
  }

  Future<AssistantResponse> processAutomatedSignal(
      String automatedInput) async {
    if (!automatedInput.startsWith('_AUTO_ ')) {
      return AssistantResponse.error('Invalid syntax');
    }
    final split = automatedInput.replaceFirst('_AUTO_ ', '').split('||');
    if (split.length != 2) return AssistantResponse.error('Malformed syntax');
    final intent = IntentParser.parse(split[1]);
    final automatedIntent = IntentData(
      type: intent.type,
      rawInput: intent.rawInput,
      tokenSymbol: intent.tokenSymbol,
      toAddress: intent.toAddress,
      amount: intent.amount,
      rawAmount: intent.rawAmount,
      sourceTokenSymbol: intent.sourceTokenSymbol,
      sourceTokenAddress: intent.sourceTokenAddress,
      targetTokenSymbol: intent.targetTokenSymbol,
      targetTokenAddress: intent.targetTokenAddress,
      amountMode: intent.amountMode,
      slippageBps: intent.slippageBps,
      sourceTrigger: split[0],
    );
    final action = IntentRouter.route(automatedIntent);
    return await _controller.orchestrate(action);
  }

  Future<AssistantResponse> confirmTransaction(
      TransactionRequest tx, ExecutionPath path) async {
    return await _controller.orchestrateConfirmation(tx, path);
  }

  Future<AssistantResponse> confirmSwapStep(
      TransactionRequest step, ExecutionPath path) async {
    return await _controller.orchestrateSwapStep(step, path);
  }

  // ── Personal Memory Helpers ───────────────────────────────────────────────

  /// Detects "запомни: X = Y" / "remember: X means Y" patterns.
  /// Returns an AssistantResponse if this is a learn command, null otherwise.
  AssistantResponse? _tryLearnCommand(
      String lower, String original, String lang) {
    // Patterns:
    //   "запомни: котлета = купить на весь USDT"
    //   "запомни что котлета это купить на весь USDT"
    //   "remember: котлета means buy max USDT"
    //   "когда я говорю котлета, это значит купить на весь USDT"
    final isLearn = lower.startsWith('запомни') ||
        lower.startsWith('remember') ||
        lower.contains('когда я говорю') ||
        lower.contains('when i say');

    if (!isLearn) return null;

    String? phrase;
    String? meaning;

    // Try "X = Y" pattern
    if (original.contains('=')) {
      final parts = original.split('=');
      if (parts.length == 2) {
        phrase = parts[0]
            .replaceAll(
                RegExp(r'^(запомни|remember)[:\s]*', caseSensitive: false), '')
            .trim();
        meaning = parts[1].trim();
      }
    }

    // Try "когда я говорю X, это значит Y" pattern
    if (phrase == null && lower.contains('когда я говорю')) {
      final match =
          RegExp(r'когда я говорю\s+(.+?)\s*,?\s*(это значит|это)\s+(.+)')
              .firstMatch(lower);
      if (match != null) {
        phrase = match.group(1)?.trim();
        meaning = match.group(3)?.trim();
      }
    }

    // Try "when i say X, it means Y" pattern
    if (phrase == null && lower.contains('when i say')) {
      final match = RegExp(r'when i say\s+(.+?)\s*,?\s*(it means|means)\s+(.+)')
          .firstMatch(lower);
      if (match != null) {
        phrase = match.group(1)?.trim();
        meaning = match.group(3)?.trim();
      }
    }

    // Try "запомни: X это Y" pattern
    if (phrase == null) {
      final match = RegExp(
              r'(?:запомни|remember)[:\s]+(.+?)\s+(?:это|значит|means|is)\s+(.+)',
              caseSensitive: false)
          .firstMatch(original);
      if (match != null) {
        phrase = match.group(1)?.trim();
        meaning = match.group(2)?.trim();
      }
    }

    if (phrase == null ||
        meaning == null ||
        phrase.isEmpty ||
        meaning.isEmpty) {
      return AssistantResponse.info(
        lang == 'ru'
            ? 'Не смогла разобрать правило. Попробуйте так:\n'
                '«Запомни: котлета = купить на весь USDT»\n'
                'или: «Когда я говорю котлета, это значит купить на весь USDT»'
            : 'Could not parse the rule. Try:\n'
                '"Remember: котлета = buy max USDT"\n'
                'or: "When I say котлета, it means buy max USDT"',
      );
    }

    // Save it
    UserMemoryService.instance.addVocab(
      phrase: phrase,
      normalizedMeaning: meaning,
    );

    return AssistantResponse.info(
      lang == 'ru'
          ? '✓ Запомнила! Когда вы скажете «$phrase», я буду понимать это как «$meaning».'
          : '✓ Got it! When you say "$phrase", I will understand it as "$meaning".',
    );
  }

  /// Detects "забудь X" / "forget X" patterns.
  AssistantResponse? _tryForgetCommand(
      String lower, String original, String lang) {
    final isForget = lower.startsWith('забудь') ||
        lower.startsWith('forget') ||
        lower.contains('удали правило') ||
        lower.contains('delete rule');

    if (!isForget) return null;

    final phrase = original
        .replaceAll(
            RegExp(
                r'^(забудь|forget|удали правило|delete rule)\s*(что такое|about|)\s*',
                caseSensitive: false),
            '')
        .trim()
        .toLowerCase();

    if (phrase.isEmpty) {
      return AssistantResponse.info(
        lang == 'ru'
            ? 'Что именно забыть? Скажите: «Забудь котлета»'
            : 'What should I forget? Say: "Forget котлета"',
      );
    }

    final existing = UserMemoryService.instance.allVocab
        .where((v) => v.phrase == phrase)
        .firstOrNull;

    if (existing == null) {
      return AssistantResponse.info(
        lang == 'ru'
            ? 'У меня нет правила для «$phrase».'
            : 'I don\'t have a rule for "$phrase".',
      );
    }

    UserMemoryService.instance.removeVocab(phrase);
    return AssistantResponse.info(
      lang == 'ru'
          ? '✓ Забыла правило «$phrase».'
          : '✓ Forgot the rule "$phrase".',
    );
  }

  /// Detects "что ты помнишь" / "what do you remember" queries.
  bool _isMemoryQuery(String lower) {
    return lower.contains('что ты помнишь') ||
        lower.contains('что помнишь') ||
        lower.contains('что ты обо мне') ||
        lower.contains('мои правила') ||
        lower.contains('my rules') ||
        lower.contains('what do you remember') ||
        lower.contains('what do you know about me');
  }

  /// Execute a voice macro — deterministic action chain, bypasses AI.
  AssistantResponse _executeMacro(VoiceMacro macro, String lang) {
    final currentMode = AiControlService.instance.settings.mode;

    // Check if macro is allowed in current mode.
    if (!macro.allowedModes.contains(currentMode)) {
      return AssistantResponse.info(
        lang == 'ru'
            ? 'Макрос «${macro.triggerPhrase}» недоступен в режиме ${currentMode.name}.'
            : 'Macro "${macro.triggerPhrase}" is not available in ${currentMode.name} mode.',
      );
    }

    // Build UICommands from macro actions.
    final commands = <UICommand>[];
    for (final action in macro.actions) {
      switch (action.type) {
        case MacroActionType.navigate:
          commands.add(UICommand(
            type: UICommandType.navigate,
            target: action.target,
            payload: action.payload,
          ));
        case MacroActionType.openModal:
          commands.add(UICommand(
            type: UICommandType.openModal,
            target: action.target,
            payload: action.payload,
          ));
        case MacroActionType.executeAction:
          commands.add(UICommand(
            type: UICommandType.executeAction,
            target: action.target,
            payload: action.payload,
          ));
        case MacroActionType.switchMode:
          // Direct mode switch via AiControlService
          final targetMode = switch (action.target) {
            'manual' => AiMode.manual,
            'guarded' => AiMode.guarded,
            'fullAutonomy' => AiMode.fullAutonomy,
            _ => null,
          };
          if (targetMode != null) {
            AiControlService.instance.updateMode(targetMode);
          }
      }
    }

    // Apply permissions and dispatch
    final permitted = _applyWindowPermissions(commands);
    if (permitted.isNotEmpty) {
      UICommandBus.instance.dispatchAll(permitted);
    }

    return AssistantResponse(
      message: lang == 'ru'
          ? '⚡ Макрос «${macro.triggerPhrase}»: ${macro.description}'
          : '⚡ Macro "${macro.triggerPhrase}": ${macro.description}',
      speechText: lang == 'ru'
          ? 'Выполняю ${macro.triggerPhrase}.'
          : 'Executing ${macro.triggerPhrase}.',
      type: ResponseType.info,
    );
  }

  // ── Modal Voice Fast-Path ─────────────────────────────────────────────────
  // Deterministic intercept for voice commands when wallet_send or wallet_swap
  // modal is active. Handles:
  //   - Token selection: "выбери USDT", "USDT выбери", "актив USDT"
  //   - Amount fill: "вставь 5", "5 USDT", "поставь 10"
  //   - Amount correction: "убери 2 USDT и поставь 0.10", "замени на 0.05"
  //   - Combined: "поставь 2 USDT" → detect USDT → check balance → clamp
  // Fires BEFORE IntentParser and OpenAI — never touches the LLM.

  /// Extract all numbers from phrase
  static final _allNumbersRx = RegExp(r'([0-9]+(?:[.,][0-9]+)?)');

  AssistantResponse? _tryAmountFastPath(String lower, String lang) {
    final modal = ScreenContextService.instance.activeModal;

    // Check if the user is trying to set an amount
    final hasAmountVerb = lower.contains('поставь') ||
        lower.contains('вставь') ||
        lower.contains('ставь') ||
        lower.contains('укажи') ||
        lower.contains('введи') ||
        lower.contains('напиши') ||
        lower.contains('сумм') ||
        lower.contains('set') ||
        lower.contains('enter') ||
        lower.contains('put') ||
        lower.contains('amount');

    final isRu = lang.startsWith('ru');

    if (modal == null) {
      // ignore: avoid_print

      // If no modal is open but user is trying to set an amount for a known token, block LLM
      if (hasAmountVerb &&
          _containsKnownToken(lower) &&
          _allNumbersRx.hasMatch(lower)) {
        return AssistantResponse.info(isRu
            ? 'Откройте окно обмена или отправки, чтобы подставить сумму.'
            : 'Please open the swap or send window to set an amount.');
      }
      return null;
    }

    if (modal != 'wallet_send' && modal != 'wallet_swap') return null;

    if (AiControlService.instance.settings.mode == AiMode.manual) {
      return _manualExecutionBlockedResponse(lang);
    }

    // ignore: avoid_print
    // ignore: avoid_print

    final isSwap = modal == 'wallet_swap';
    final commands = <UICommand>[];
    final messageParts = <String>[];

    // ── 1. Token detection — scan ENTIRE phrase ──────────────────────────────
    String? selectedSymbol;
    final words = lower.split(RegExp(r'[\s,.:;!?]+'));
    for (final w in words) {
      if (w.isEmpty) continue;
      final norm = TokenSymbolNormalizer.normalize(w);
      if (_isKnownToken(norm)) {
        selectedSymbol = norm;
        break;
      }
    }

    if (selectedSymbol == null) {
      // Try 2-word, 3-word, 4-word bigrams for aliases like "ю эс ди ти"
      for (int window = 4; window >= 2; window--) {
        if (selectedSymbol != null) break;
        for (int i = 0; i <= words.length - window; i++) {
          final nGram = words.sublist(i, i + window).join(' ');
          final norm = TokenSymbolNormalizer.normalize(nGram);
          if (_isKnownToken(norm)) {
            selectedSymbol = norm;
            break;
          }
        }
      }
    }

    // ── 1b. Fallback: use token already selected in the modal ────────────────
    bool tokenFromModal = false;
    if (selectedSymbol == null) {
      final modalFrom = ScreenContextService.instance.selectedFromSymbol;
      if (modalFrom != null && modalFrom.isNotEmpty) {
        selectedSymbol = modalFrom;
        tokenFromModal = true;
        // ignore: avoid_print
      }
    }
    if (selectedSymbol != null) {
      // ignore: avoid_print
    }

    // ── 2. Determine intent: select token, fill amount, or both ─────────────
    final hasSelectVerb = lower.contains('выбери') ||
        lower.contains('выбрать') ||
        lower.contains('выбираю') ||
        lower.contains('актив') ||
        lower.contains('токен') ||
        lower.contains('select') ||
        lower.contains('choose');

    final hasCorrectionVerb = lower.contains('убери') ||
        lower.contains('замени') ||
        lower.contains('исправ') ||
        lower.contains('поменяй сумм') ||
        lower.contains('смени') ||
        lower.contains('remove') ||
        lower.contains('change') ||
        lower.contains('replace') ||
        lower.contains('fix');

    final hasToField = lower.contains('получа') ||
        lower.contains('получить') ||
        lower.contains('на что') ||
        lower.contains(' to ') ||
        lower.contains(' for ') ||
        lower.contains(' за ');

    // ── 3. Select token command ──────────────────────────────────────────────
    if (selectedSymbol != null &&
        !tokenFromModal &&
        (hasSelectVerb || hasAmountVerb || hasCorrectionVerb)) {
      final swapField = ScreenContextService.instance.activeSwapField ?? 'from';
      final fieldTarget = hasToField ? 'to' : swapField;
      final target = isSwap
          ? (fieldTarget == 'to' ? 'swap_to_token' : 'swap_from_token')
          : 'send_asset';
      commands.add(UICommand(
        type: UICommandType.selectToken,
        target: target,
        payload: {'symbol': selectedSymbol},
      ));
      // No select token voice message here to keep it concise, unless there is no amount
    }

    // ── 4. Extract amount ────────────────────────────────────────────────────
    final allNumbers = _allNumbersRx
        .allMatches(lower)
        .map((m) => m.group(1)!.replaceAll(',', '.'))
        .toList();

    double? requestedAmount;
    String? normalizedAmount;

    if (allNumbers.isNotEmpty) {
      final rawAmt = hasCorrectionVerb && allNumbers.length > 1
          ? allNumbers.last
          : allNumbers.first;
      normalizedAmount = rawAmt;
      requestedAmount = double.tryParse(rawAmt);
    }

    if (requestedAmount != null) {
      // ignore: avoid_print
    }

    // ── 5. Balance validation — BEFORE dispatching fillField ─────────────────
    if (requestedAmount != null && requestedAmount > 0) {
      double? balance;
      final portfolio = VaultPortfolioListener.instance.summary;

      final balanceSymbol = selectedSymbol;

      if (portfolio != null && balanceSymbol != null) {
        final matchingAsset = portfolio.allAssets.cast<dynamic>().firstWhere(
              (a) =>
                  a.symbol.toString().toUpperCase() ==
                  balanceSymbol.toUpperCase(),
              orElse: () => null,
            );
        if (matchingAsset != null) {
          balance = double.tryParse(matchingAsset.balance.toString()) ?? 0.0;
        }
      }

      if (balance != null) {
        // ignore: avoid_print

        if (balance <= 0) {
          final errMsg = isRu
              ? 'Недостаточно $balanceSymbol. Баланс: 0.'
              : 'Insufficient $balanceSymbol. Balance: 0.';
          if (commands.isNotEmpty) {
            UICommandBus.instance.dispatchAll(commands);
          }
          return AssistantResponse.info(
            errMsg,
            speechText: errMsg,
            commands: commands,
          );
        } else if (requestedAmount > balance) {
          normalizedAmount = balance.toStringAsFixed(balance >= 1
              ? 2
              : balance >= 0.01
                  ? 4
                  : 8);
          if (normalizedAmount.contains('.')) {
            normalizedAmount = normalizedAmount
                .replaceAll(RegExp(r'0*$'), '')
                .replaceAll(RegExp(r'\.$'), '');
          }
          requestedAmount = balance;
          messageParts.add(isRu
              ? 'Баланс $balanceSymbol: $normalizedAmount. Ставлю максимум $normalizedAmount $balanceSymbol.'
              : 'Balance $balanceSymbol: $normalizedAmount. Setting maximum $normalizedAmount $balanceSymbol.');
        }
      }

      final amountTarget = isSwap ? 'swap_amount' : 'send_amount';
      commands.add(UICommand(
        type: UICommandType.fillField,
        target: amountTarget,
        payload: {'value': normalizedAmount},
      ));

      if (messageParts.isEmpty) {
        messageParts.add(isRu
            ? 'Ставлю $normalizedAmount ${balanceSymbol ?? ''}.'.trim()
            : 'Setting $normalizedAmount ${balanceSymbol ?? ''}.'.trim());
      }
      // ignore: avoid_print
    } else if (selectedSymbol != null && commands.isNotEmpty) {
      // If only selecting token, say that we selected it
      messageParts
          .add(isRu ? 'Выбрала $selectedSymbol.' : 'Selected $selectedSymbol.');
    }

    if (commands.isEmpty) return null;

    UICommandBus.instance.dispatchAll(commands);

    final msg = messageParts.join(' ');
    // ignore: avoid_print
    return AssistantResponse.info(msg, speechText: msg, commands: commands);
  }

  /// Check if a symbol is a known token (not just a random uppercased word)
  static bool _isKnownToken(String symbol) {
    const known = {
      'IBITI', 'USDT', 'USDC', 'ETH', 'BNB', 'BTC', 'SOL', 'TRX',
      'POL', 'DOGE', 'PEPE', 'WBNB', 'BUSD', 'DAI', 'CAKE', 'ADA',
      'DOT', 'MATIC', 'ARB', 'OP', 'LINK', 'UNI', 'AAVE', 'SHIB',
      'AVAX', 'ATOM', 'FTM', 'NEAR', 'APT', 'SUI', 'SEI', 'INJ',
      // Add more as needed
    };
    return known.contains(symbol.toUpperCase());
  }

  /// Check if a lowercased phrase contains any known token symbol or alias.
  /// Used by dismiss guard to distinguish "убери окно" from "убери 2 USDT".
  static bool _containsKnownToken(String lower) {
    // Check common aliases/symbols that might appear in voice
    const checks = [
      'usdt', 'usdc', 'bnb', 'eth', 'btc', 'sol', 'ibiti', 'trx',
      'doge', 'pepe', 'busd', 'wbnb', 'dai', 'cake',
      // Russian aliases
      'юсдт', 'усдт', 'тезер', 'тетер', 'эфир', 'эфириум',
      'бнб', 'биткоин', 'солана', 'ибити', 'ибитикоин',
    ];
    return checks.any(lower.contains);
  }

  static const Map<String, String> _knownTokens = {
    'BNB': '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE',
    'USDT': '0x55d398326f99059fF775485246999027B3197955',
    'USDC': '0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d',
    'BUSD': '0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56',
    'WBNB': '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c',
    'ETH': '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE',
    'WETH': '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
    'SOL': '0x570A5D26f7765Ecb712C0924E4De545B89fD43dF',
  };

  /// Solana SPL mint addresses for known tokens.
  /// Jupiter requires these exact mint addresses, not symbols.
  static const Map<String, String> _knownSolanaMints = {
    'SOL': 'So11111111111111111111111111111111111111112',
    'USDC': 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
    'USDT': 'Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB',
  };

  /// Solana token decimals differ from BSC/EVM.
  static const Map<String, int> _knownSolanaDecimals = {
    'SOL': 9,
    'USDC': 6,
    'USDT': 6,
  };

  /// Tron TRC20 token addresses.
  static const Map<String, String> _knownTronTokens = {
    'TRX': '', // Native — no contract
    'WTRX': 'TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR',
    'USDT': 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t',
  };

  /// Tron token decimals.
  static const Map<String, int> _knownTronDecimals = {
    'TRX': 6,
    'WTRX': 6,
    'USDT': 6,
  };

  String _resolveTokenAddress(String? symbol, String lang) {
    if (symbol == null) return '';
    final upper = symbol.toUpperCase();
    final chainKey = IBITIVaultService.instance.chainKey;
    if (chainKey == 'solana') {
      return _knownSolanaMints[upper] ?? '';
    }
    if (chainKey == 'tron') {
      return _knownTronTokens[upper] ?? '';
    }
    return _knownTokens[upper] ?? '';
  }

  /// Known token decimals for BSC.
  /// BSC USDT/USDC are 18 decimals (unlike Ethereum/Polygon where they are 6).
  /// Returns null for unknown tokens — caller must handle.
  static const Map<String, int> _knownTokenDecimals = {
    'BNB': 18,
    'WBNB': 18,
    'ETH': 18,
    'WETH': 18,
    'USDT': 18, // BSC-pegged USDT is 18 decimals
    'USDC': 18, // BSC-pegged USDC is 18 decimals
    'BUSD': 18,
    'IBITI': 18,
    'SOL': 18,
  };

  int? _resolveTokenDecimals(String? symbol) {
    if (symbol == null) return null;
    final upper = symbol.toUpperCase();
    final chainKey = IBITIVaultService.instance.chainKey;
    if (chainKey == 'solana') {
      return _knownSolanaDecimals[upper];
    }
    if (chainKey == 'tron') {
      return _knownTronDecimals[upper];
    }
    return _knownTokenDecimals[upper];
  }

  // ── Market context injection ───────────────────────────────────────────────

  static const _marketContextKeywords = [
    'buy',
    'sell',
    'купи',
    'продай',
    'swap',
    'обмен',
    'price',
    'цена',
    'market',
    'рынок',
    'trade',
    'торг',
    'analyze',
    'анализ',
    'route',
    'маршрут',
    'план',
    'plan',
    'trend',
    'тренд',
    'btc',
    'eth',
    'bnb',
    'sol',
    'usdt',
    'usdc',
    'bitcoin',
    'ethereum',
    'solana',
  ];

  /// Returns true if the input looks like it might benefit from market context.
  /// More permissive than [_isMarketQuery] — used for GPT context enrichment.
  static bool _isMarketRelatedInput(String input) {
    final lower = input.toLowerCase();
    return _marketContextKeywords.any(lower.contains);
  }

  /// Builds a compact market context string from cached data.
  /// No network calls — reads only what is already in memory.
  /// Returns empty string if no relevant cached data is found.
  String _buildMarketContext(String input) {
    final lower = input.toLowerCase();
    final ai = AiControlService.instance.settings;
    final mode = switch (ai.mode) {
      AiMode.manual => 'Manual (analysis only)',
      AiMode.guarded => 'Guarded (prepare, user confirms)',
      AiMode.fullAutonomy => 'Full Autonomy (execute within limits)',
    };
    final mandate = ai.mandate;

    // Try to find a mentioned token in the cached market list
    final buffer = StringBuffer();

    // Look for a cached asset whose symbol or name appears in the query
    MarketAsset? matchedAsset;
    final cachedMarkets = MarketDataService.instance.cachedMarkets;
    for (final asset in cachedMarkets) {
      if (lower.contains(asset.symbol.toLowerCase()) ||
          lower.contains(asset.name.toLowerCase())) {
        matchedAsset = asset;
        break;
      }
    }

    if (matchedAsset != null) {
      final a = matchedAsset;
      final sign = a.change24h >= 0 ? '+' : '';
      buffer.writeln('[Market Context]');
      buffer.writeln(
          '${a.symbol} (${a.networkGroup}): \$${a.price.toStringAsFixed(a.price >= 1 ? 2 : 4)} '
          '| 24h: $sign${a.change24h.toStringAsFixed(2)}% '
          '| 7d: ${a.change7d >= 0 ? '+' : ''}${a.change7d.toStringAsFixed(2)}% '
          '| Status: ${a.status}');
      buffer.writeln('Volume: \$${(a.volume / 1000000).toStringAsFixed(1)}M '
          '| MCap: \$${(a.marketCap / 1000000000).toStringAsFixed(2)}B');

      // Exposure context — AI knows whether it can/should add, hold, or reduce.
      final exposure = WalletExposureService.instance.snapshotFor(
        a.symbol,
        mandate,
      );
      buffer.writeln(exposure.promptLine);
    }

    // AI mode + limits always included when market query detected
    buffer.writeln('[AI Context]');
    buffer
        .writeln('Mode: $mode | Per-tx: \$${ai.perTxLimit.toStringAsFixed(0)} '
            '| Daily: \$${ai.dailyLimit.toStringAsFixed(0)}');
    if (mandate.allowedAssets.isNotEmpty) {
      buffer.writeln('Mandate assets: ${mandate.allowedAssets.join(", ")}');
    }
    if (mandate.allowedNetworks.isNotEmpty) {
      buffer.writeln('Mandate networks: ${mandate.allowedNetworks.join(", ")}');
    }
    if (mandate.allowedVenues.isNotEmpty) {
      buffer.writeln('Mandate venues: ${mandate.allowedVenues.join(", ")}');
    }

    return buffer.toString().trim();
  }

  /// Returns the input enriched with compact market context if the query
  /// is market-related and cached data is available. Otherwise returns input as-is.
  String _enrichWithMarketContext(String input) {
    if (!_isMarketRelatedInput(input)) return input;
    final ctx = _buildMarketContext(input);
    if (ctx.isEmpty) return input;
    return '$ctx\n\n$input';
  }

  String _marketStatusRu(num change24h) {
    if (change24h > 2) return 'растёт';
    if (change24h < -2) return 'падает';
    return 'стабилен';
  }

  List<UICommand> _mergeUiCommands(
    List<UICommand> primary,
    List<UICommand> fallback,
  ) {
    if (primary.isNotEmpty) return primary;
    return fallback;
  }

  List<UICommand> _fallbackUiCommandsForIntent(dynamic intent) {
    if (intent == null) return const [];
    final type = intent.type.toString();
    if (AiControlService.instance.settings.mode == AiMode.manual) {
      return const [];
    }
    if (type.endsWith('swapAsset')) {
      final commands = <UICommand>[];
      final sourceSymbol = intent.sourceTokenSymbol?.toString();
      final targetSymbol = intent.targetTokenSymbol?.toString();
      final amount = intent.amount;
      if (sourceSymbol != null && sourceSymbol.isNotEmpty) {
        commands.add(UICommand(
          type: UICommandType.selectToken,
          target: 'swap_from_token',
          payload: {'symbol': TokenSymbolNormalizer.normalize(sourceSymbol)},
        ));
      }
      if (targetSymbol != null && targetSymbol.isNotEmpty) {
        commands.add(UICommand(
          type: UICommandType.selectToken,
          target: 'swap_to_token',
          payload: {'symbol': TokenSymbolNormalizer.normalize(targetSymbol)},
        ));
      }
      if (amount != null) {
        commands.add(UICommand(
          type: UICommandType.fillField,
          target: 'swap_amount',
          payload: {'value': amount.toString()},
        ));
      }
      if (targetSymbol != null && targetSymbol.isNotEmpty && amount != null) {
        commands.add(const UICommand(
          type: UICommandType.executeAction,
          target: 'wallet_swap_quote',
        ));
      }
      return commands;
    }
    if (type.endsWith('sendAsset')) {
      final commands = <UICommand>[];
      final symbol = intent.tokenSymbol?.toString();
      final amount = intent.amount;
      final recipient = intent.toAddress?.toString();
      if (symbol != null && symbol.isNotEmpty) {
        commands.add(UICommand(
          type: UICommandType.selectToken,
          target: 'send_token',
          payload: {'symbol': TokenSymbolNormalizer.normalize(symbol)},
        ));
      }
      if (amount != null) {
        commands.add(UICommand(
          type: UICommandType.fillField,
          target: 'send_amount',
          payload: {'value': amount.toString()},
        ));
      }
      if (recipient != null && recipient.isNotEmpty) {
        commands.add(UICommand(
          type: UICommandType.fillField,
          target: 'send_address',
          payload: {'value': recipient},
        ));
      }
      if (amount != null && recipient != null && recipient.isNotEmpty) {
        commands.add(const UICommand(
          type: UICommandType.executeAction,
          target: 'wallet_send_preview',
        ));
      }
      return commands;
    }
    return const [];
  }

  Future<AssistantResponse> _handleCexTradeIntent(
    IntentData intent,
    AssistantInputSource source,
    String lang,
  ) async {
    final isRu = lang.startsWith('ru');
    final isBuy = intent.type == IntentType.buyAsset;

    // 1. Input Source Constraints
    if (source != AssistantInputSource.voice && source != AssistantInputSource.marketChat) {
      final msg = isRu
          ? 'Торговля CEX поддерживается только через голосовые команды или рыночный чат.'
          : 'CEX trading is only supported via voice commands or market chat.';
      return AssistantResponse.info(msg, speechText: msg);
    }

    // 2. Resolve token symbol and handle placeholders
    String? rawSymbol = intent.tokenSymbol;
    String? symbol;
    if (rawSymbol != null) {
      final lowerSym = rawSymbol.toLowerCase();
      if (lowerSym == 'this coin' || lowerSym == 'эту монету' || lowerSym == 'эту' || lowerSym == 'this') {
        symbol = ScreenContextService.instance.focusedSymbol?.toUpperCase();
      } else {
        symbol = rawSymbol.toUpperCase();
      }
    }
    
    // Resolve slang/aliases if any
    if (symbol != null) {
      final canonicalSym = _assetAliases[symbol.toLowerCase()];
      if (canonicalSym != null) {
        symbol = canonicalSym;
      }
    }

    if (symbol == null || symbol.isEmpty) {
      final msg = isRu ? 'Укажите монету.' : 'Please specify the token.';
      final speech = isRu ? 'Монета?' : 'Token?';
      return AssistantResponse.info(msg, speechText: speech);
    }

    final mode = AiControlService.instance.settings.mode;
    final modeStr = mode == AiMode.manual
        ? 'manual'
        : mode == AiMode.guarded
            ? 'guarded'
            : 'fullAutonomy';

    // 3. Manual Mode
    if (mode == AiMode.manual) {
      final msg = isRu
          ? 'Торговля отключена в режиме Manual. Переключитесь в Guarded или Full Autonomy.'
          : 'Trading is disabled in Manual Mode. Switch to Guarded or Full Autonomy.';
      await MarketMemoryService.instance.record(
        action: isBuy ? 'buy' : 'sell',
        symbol: symbol,
        source: source.name,
        aiMode: modeStr,
        result: 'blocked',
        amount: intent.amount,
        priceThen: 0.0,
        reason: msg,
        rawInput: intent.rawInput,
      );
      return _manualExecutionBlockedResponse(lang);
    }

    // --- GUARDED MODE FAST PATH (Instant Modal, No Network Block) ---
    if (mode == AiMode.guarded) {
      if (intent.amount == null) {
        final msg = isRu ? 'Укажите сумму.' : 'Please specify the amount.';
        final speech = isRu ? 'Сумма?' : 'Amount?';
        return AssistantResponse.info(msg, speechText: speech);
      }

      final markets = MarketDataService.instance.cachedMarkets;
      final cachedAsset = markets.cast<MarketAsset?>().firstWhere(
            (a) => a!.symbol.toUpperCase() == symbol,
            orElse: () => null,
          );

      String exchangeId = 'mexc';
      String quoteAsset = 'USDT';
      double price = 1.0;

      if (cachedAsset != null) {
        final rawSrc = cachedAsset.sourceId.toLowerCase();
        exchangeId = rawSrc == 'gate.io' ? 'gateio' : rawSrc;
        price = cachedAsset.price > 0 ? cachedAsset.price : 1.0;
        if (cachedAsset.sourcePair.contains('-')) {
          quoteAsset = cachedAsset.sourcePair.split('-')[1];
        }
      }

      double? orderAmount;
      final double amt = intent.amount!;
      if (isBuy) {
        if (intent.isQuantity) {
          orderAmount = amt * price;
        } else {
          orderAmount = amt;
        }
      } else {
        if (amt == -1.0) {
          orderAmount = null;
        } else if (amt < 0.0) {
          orderAmount = null;
        } else if (intent.isQuantity) {
          orderAmount = amt;
        } else {
          orderAmount = amt / price;
        }
      }

      final modalPayload = {
        'symbol': symbol,
        'isBuy': isBuy,
        'exchangeId': exchangeId,
        'initialAmount': orderAmount,
        'price': price,
        'quoteAsset': quoteAsset,
      };

      final modalCmd = UICommand(
        type: UICommandType.openModal,
        target: 'cex_trade',
        payload: modalPayload,
      );

      UICommandBus.instance.dispatch(modalCmd);

      // Async/fire-and-forget record to MarketMemory
      MarketMemoryService.instance.record(
        action: isBuy ? 'buy' : 'sell',
        symbol: symbol,
        source: source.name,
        aiMode: modeStr,
        result: 'opened_preview',
        amount: orderAmount,
        priceThen: price,
        rawInput: intent.rawInput,
      );

      final msg = isRu
          ? 'Подготовила ордер на ${isBuy ? 'покупку' : 'продажу'} $symbol на ${exchangeId.toUpperCase()}. Пожалуйста, подтвердите вручную.'
          : 'Prepared trade modal to ${isBuy ? 'buy' : 'sell'} $symbol on ${exchangeId.toUpperCase()}. Please confirm manually.';
      return AssistantResponse.info(
        msg,
        speechText: msg,
        commands: [modalCmd],
      );
    }

    // 4. Resolve exchange (Full Autonomy Mode only)
    final resolvedInfo = await _resolveBestExchangeAndPrice(symbol);
    if (resolvedInfo == null) {
      final msg = isRu
          ? 'Не удалось найти подходящую и подключенную биржу с активной торговой парой для $symbol.'
          : 'Could not find a suitable, connected exchange with an active trading pair for $symbol.';
      await MarketMemoryService.instance.record(
        action: isBuy ? 'buy' : 'sell',
        symbol: symbol,
        source: source.name,
        aiMode: modeStr,
        result: 'failed',
        amount: intent.amount,
        priceThen: 0.0,
        reason: msg,
        rawInput: intent.rawInput,
      );
      return AssistantResponse.info(msg, speechText: msg);
    }

    final String exchangeId = resolvedInfo['exchangeId'];
    final String quoteAsset = resolvedInfo['quoteAsset'];
    final double price = resolvedInfo['price'];
    final ExchangeExecutionAdapter adapter = resolvedInfo['adapter'];

    // 5. Amount Checks & Conversion Rules (Full Autonomy Mode only)
    double? orderAmount; // For buy: quote value to spend. For sell: base qty to sell.
    double? sellQty; // Only for sell

    if (intent.amount == null) {
      final msg = isRu ? 'Укажите сумму.' : 'Please specify the amount.';
      final speech = isRu ? 'Сумма?' : 'Amount?';
      return AssistantResponse.info(msg, speechText: speech);
    }

    final double amt = intent.amount!;
    if (isBuy) {
      if (intent.isQuantity) {
        orderAmount = amt * price;
      } else {
        orderAmount = amt;
      }
    } else {
      final baseBalance = await adapter.fetchAssetBalance(symbol);
      if (amt == -1.0) {
        sellQty = baseBalance;
      } else if (amt < 0.0) {
        sellQty = baseBalance * amt.abs();
      } else if (intent.isQuantity) {
        sellQty = amt;
      } else {
        sellQty = amt / price;
      }
      orderAmount = sellQty;
    }

    final settings = AiControlService.instance.settings;

    // 6. Balance Checks (Full Autonomy Mode only)
    if (isBuy) {
      final quoteBalance = await adapter.fetchAssetBalance(quoteAsset);
      final minTradeBal = settings.minTradeBalance;
      if (quoteBalance < minTradeBal || quoteBalance < orderAmount) {
        final msg = isRu
            ? 'Недостаточный баланс $quoteAsset на ${exchangeId.toUpperCase()}. Доступно: $quoteBalance, требуется: $orderAmount'
            : 'Insufficient $quoteAsset balance on ${exchangeId.toUpperCase()}. Available: $quoteBalance, required: $orderAmount';
        await MarketMemoryService.instance.record(
          action: 'buy',
          symbol: symbol,
          source: source.name,
          aiMode: modeStr,
          result: 'failed',
          amount: orderAmount,
          priceThen: price,
          reason: msg,
          rawInput: intent.rawInput,
        );
        return AssistantResponse.info(msg, speechText: msg);
      }
    } else {
      final baseBalance = await adapter.fetchAssetBalance(symbol);
      if (sellQty == null || sellQty <= 0.0 || baseBalance < sellQty) {
        final msg = isRu
            ? 'Недостаточный баланс $symbol на ${exchangeId.toUpperCase()}. Доступно: $baseBalance, требуется: ${sellQty ?? 0.0}'
            : 'Insufficient $symbol balance on ${exchangeId.toUpperCase()}. Available: $baseBalance, required: ${sellQty ?? 0.0}';
        await MarketMemoryService.instance.record(
          action: 'sell',
          symbol: symbol,
          source: source.name,
          aiMode: modeStr,
          result: 'failed',
          amount: sellQty,
          priceThen: price,
          reason: msg,
          rawInput: intent.rawInput,
        );
        return AssistantResponse.info(msg, speechText: msg);
      }
    }

    // 7. Policy Limits & EPK check (Full Autonomy Mode only)
    if (!settings.isActive) {
      final msg = isRu
          ? 'Торговля заблокирована политикой AI Control (активен экстренный стоп или истекло время разрешений).'
          : 'Trading is blocked by AI Control settings (Kill Switch active or permissions expired).';
      await MarketMemoryService.instance.record(
        action: isBuy ? 'buy' : 'sell',
        symbol: symbol,
        source: source.name,
        aiMode: modeStr,
        result: 'blocked',
        amount: orderAmount,
        priceThen: price,
        reason: msg,
        rawInput: intent.rawInput,
      );
      return AssistantResponse.info(msg, speechText: msg);
    }

    final txValueUsdt = isBuy ? orderAmount! : sellQty! * price;
    final delegation = DelegationController.instance;

    if (isBuy) {
      final perTxLimit = settings.perTxLimit;
      if (txValueUsdt > perTxLimit) {
        final msg = isRu
            ? 'Сумма ордера (\$${txValueUsdt.toStringAsFixed(2)}) превышает лимит одной транзакции (\$${perTxLimit.toStringAsFixed(2)}).'
            : 'Order value (\$${txValueUsdt.toStringAsFixed(2)}) exceeds single transaction limit (\$${perTxLimit.toStringAsFixed(2)}).';
        await MarketMemoryService.instance.record(
          action: 'buy',
          symbol: symbol,
          source: source.name,
          aiMode: modeStr,
          result: 'blocked',
          amount: orderAmount,
          priceThen: price,
          reason: msg,
          rawInput: intent.rawInput,
        );
        return AssistantResponse.info(msg, speechText: msg);
      }

      if (!delegation.canSpend(txValueUsdt)) {
        final msg = isRu
            ? 'Сумма ордера (\$${txValueUsdt.toStringAsFixed(2)}) превышает оставшийся дневной бюджет. ${delegation.usageSummary()}'
            : 'Order value (\$${txValueUsdt.toStringAsFixed(2)}) exceeds remaining daily budget. ${delegation.usageSummary()}';
        await MarketMemoryService.instance.record(
          action: 'buy',
          symbol: symbol,
          source: source.name,
          aiMode: modeStr,
          result: 'blocked',
          amount: orderAmount,
          priceThen: price,
          reason: msg,
          rawInput: intent.rawInput,
        );
        return AssistantResponse.info(msg, speechText: msg);
      }
    }

    if (mode == AiMode.guarded) {
      final modalPayload = {
        'symbol': symbol,
        'isBuy': isBuy,
        'exchangeId': exchangeId,
        'initialAmount': orderAmount,
        'price': price,
        'quoteAsset': quoteAsset,
      };
      
      final modalCmd = UICommand(
        type: UICommandType.openModal,
        target: 'cex_trade',
        payload: modalPayload,
      );

      UICommandBus.instance.dispatch(modalCmd);

      await MarketMemoryService.instance.record(
        action: isBuy ? 'buy' : 'sell',
        symbol: symbol,
        source: source.name,
        aiMode: modeStr,
        result: 'opened_preview',
        amount: orderAmount,
        priceThen: price,
        rawInput: intent.rawInput,
      );

      final msg = isRu
          ? 'Подготовила ордер на ${isBuy ? 'покупку' : 'продажу'} $symbol на ${exchangeId.toUpperCase()}. Пожалуйста, подтвердите вручную.'
          : 'Prepared trade modal to ${isBuy ? 'buy' : 'sell'} $symbol on ${exchangeId.toUpperCase()}. Please confirm manually.';
      return AssistantResponse.info(
        msg,
        speechText: msg,
        commands: [modalCmd],
      );
    }

    if (mode == AiMode.fullAutonomy) {
      final orderResult = await ExchangeOrderService.instance.placeMarketOrder(
        exchangeId: exchangeId,
        symbol: symbol,
        isBuy: isBuy,
        amount: orderAmount,
        price: price,
        source: source.name,
      );

      if (orderResult.isSuccess) {
        final successMsg = isRu
            ? 'Ордер успешно выполнен на ${exchangeId.toUpperCase()}! ID ордера: ${orderResult.orderId}'
            : 'Order executed successfully on ${exchangeId.toUpperCase()}! Order ID: ${orderResult.orderId}';

        final speechMsg = isRu
            ? 'Ордер исполнен, удачных торгов.'
            : 'Order executed, happy trading.';

        final modalPayload = {
          'symbol': symbol,
          'isBuy': isBuy,
          'exchangeId': exchangeId,
          'initialAmount': orderAmount,
          'price': price,
          'quoteAsset': quoteAsset,
          'isSuccess': true,
          'orderId': orderResult.orderId,
          'executedQty': orderResult.executedQty,
          'executedPrice': orderResult.executedPrice,
        };

        final modalCmd = UICommand(
          type: UICommandType.openModal,
          target: 'cex_trade',
          payload: modalPayload,
        );

        UICommandBus.instance.dispatch(modalCmd);

        return AssistantResponse(
          message: successMsg,
          speechText: speechMsg,
          type: ResponseType.info,
          uiCommands: [modalCmd],
        );
      } else {
        // ── Localize error message instead of embedding raw English ──
        final raw = orderResult.errorMessage ?? '';
        final String displayMsg;
        final String speechMsg;

        // Min notional / minimum order value
        if (raw.contains('below the minimum required') ||
            raw.contains('minNotional') ||
            raw.contains('MIN_NOTIONAL')) {
          final minMatch = RegExp(r'\$(\d+(?:\.\d+)?)').allMatches(raw).toList();
          final minVal = minMatch.length >= 2 ? minMatch[1].group(1) : '5';
          displayMsg = isRu
              ? 'Минимальная сумма для покупки — \$$minVal.'
              : 'Minimum order amount is \$$minVal.';
          speechMsg = isRu
              ? 'Не могу купить на ${orderAmount.toStringAsFixed(0)} долларов. '
                'Минимум для покупки, $minVal долларов.'
              : 'Cannot buy for ${orderAmount.toStringAsFixed(0)} dollars. '
                'Minimum is $minVal dollars.';
        }
        // Insufficient balance
        else if (raw.contains('Insufficient') || raw.contains('баланс меньше')) {
          displayMsg = isRu
              ? 'Недостаточно средств для этого ордера.'
              : 'Insufficient balance for this order.';
          speechMsg = isRu
              ? 'Недостаточно средств для покупки.'
              : 'Not enough balance for this order.';
        }
        // Policy / AI limits block
        else if (raw.contains('Blocked by AI Policy') || raw.contains('Kill Switch')) {
          displayMsg = isRu
              ? 'Ордер заблокирован политикой безопасности.'
              : 'Order blocked by security policy.';
          speechMsg = displayMsg;
        }
        // Daily budget exceeded
        else if (raw.contains('daily budget') || raw.contains('dailyLimit')) {
          displayMsg = isRu
              ? 'Превышен дневной лимит торговли.'
              : 'Daily trading limit exceeded.';
          speechMsg = displayMsg;
        }
        // Per-tx limit
        else if (raw.contains('single transaction limit') || raw.contains('perTxLimit')) {
          displayMsg = isRu
              ? 'Сумма превышает лимит на одну сделку.'
              : 'Amount exceeds per-transaction limit.';
          speechMsg = displayMsg;
        }
        // Symbol not found
        else if (raw.contains('does not exist')) {
          displayMsg = isRu
              ? 'Торговая пара не найдена на ${exchangeId.toUpperCase()}.'
              : 'Trading pair not found on ${exchangeId.toUpperCase()}.';
          speechMsg = displayMsg;
        }
        // Fallback
        else {
          displayMsg = isRu
              ? 'Не удалось выполнить ордер.'
              : 'Failed to execute order.';
          speechMsg = displayMsg;
        }

        return AssistantResponse(
          message: '$displayMsg${raw.isNotEmpty ? '\n\n$raw' : ''}',
          speechText: speechMsg,
          type: ResponseType.error,
        );
      }
    }

    return const AssistantResponse(
      message: 'Unknown AI mode.',
      type: ResponseType.error,
    );
  }

  Future<Map<String, dynamic>?> _resolveBestExchangeAndPrice(String tokenSymbol) async {
    final settings = AiControlService.instance.settings;
    final candidates = ['mexc', 'gateio', 'binance', 'okx'];
    for (final ex in candidates) {
      if (!settings.activeSources.contains(ex)) continue;
      final isConnected = await ExchangeAccountStore.instance.isConnected(ex);
      if (!isConnected) continue;
      final adapter = ExchangeOrderService.instance.adapterFor(ex);
      if (adapter == null) continue;
      
      String quoteAsset = 'USDT';
      if (ex == 'okx') {
        final region = await ExchangeAccountStore.instance.getOkxRegion() ?? 'global';
        final okxPair = await OkxExchangeService.instance.findBestPair(tokenSymbol, region);
        if (okxPair == null) continue;
        quoteAsset = okxPair.split('-')[1];
      }
      final price = _resolveLivePrice(exchangeId: ex, baseSymbol: tokenSymbol, quoteAsset: quoteAsset);
      if (price == null || price <= 0.0) continue;
      
      return {
        'exchangeId': ex,
        'quoteAsset': quoteAsset,
        'price': price,
        'adapter': adapter,
      };
    }
    return null;
  }

  double? _resolveLivePrice({
    required String exchangeId,
    required String baseSymbol,
    required String quoteAsset,
  }) {
    final live = MarketLiveEngine.instance;
    final ex = exchangeId.toLowerCase();
    final base = baseSymbol.toUpperCase();
    final quote = quoteAsset.toUpperCase();
    final pairStr = '$base$quote';
    final key = MarketLiveEngine.key(ex, pairStr);
    final ticker = live.latestByKey(key);
    if (ticker != null && ticker.lastPrice > 0) {
      return ticker.lastPrice;
    }
    return null;
  }

  Future<AssistantResponse> _handleOnChainTradeIntent(
    IntentData intent,
    String lang,
  ) async {
    final isRu = lang.startsWith('ru');
    final symbol = intent.tokenSymbol!.toUpperCase();
    final markets = MarketDataService.instance.cachedMarkets;
    var asset = markets.cast<MarketAsset?>().firstWhere(
          (a) => a!.symbol.toUpperCase() == symbol,
          orElse: () => null,
        );

    if (asset == null) {
      final price = ScreenContextService.instance.focusedSymbol == symbol
          ? (ScreenContextService.instance.focusedPrice ?? 1.0)
          : 1.0;
      asset = MarketAsset(
        id: 'dummy-${symbol.toLowerCase()}',
        symbol: symbol,
        name: symbol,
        imageUrl: '',
        price: price,
        change24h: 0.0,
        marketCap: 0.0,
        volume: 0.0,
        rank: 999,
        sparkline: const [],
        high24h: price,
        low24h: price,
        change7d: 0.0,
        change30d: 0.0,
        networkGroup: 'Ethereum',
        sourceId: 'coingecko',
        sourcePair: '',
        sourceUpdatedAt: DateTime.now(),
      );
    }

    final aiSettings = AiControlService.instance.settings;
    final direction = intent.type == IntentType.sellAsset
        ? TradingDirection.sell
        : TradingDirection.buy;

    final plan = TradingPlanBuilder.build(
      asset: asset,
      direction: direction,
      settings: aiSettings,
    );

    final fullPlan = _buildTradingPlanBriefing(plan, lang, short: false);
    final voicePlan = _buildTradingPlanBriefing(plan, lang, short: true);

    if (aiSettings.mode == AiMode.manual) {
      final manualNote = isRu
          ? '\n\n⚠️ Режим Manual. Это только анализ.'
          : '\n\n⚠️ Manual mode. Analysis only.';
      return AssistantResponse.info(fullPlan + manualNote, speechText: voicePlan);
    }

    final commands = <UICommand>[
      UICommand(
        type: UICommandType.showTradingPlan,
        payload: {'plan': plan},
      ),
      UICommand(
        type: UICommandType.openModal,
        target: direction == TradingDirection.sell ? 'wallet_sell' : 'wallet_buy',
      ),
    ];

    if (direction == TradingDirection.sell) {
      commands.add(UICommand(
        type: UICommandType.selectToken,
        target: 'swap_from_token',
        payload: {'symbol': symbol},
      ));
      commands.add(const UICommand(
        type: UICommandType.selectToken,
        target: 'swap_to_token',
        payload: {'symbol': 'USDT'},
      ));
    } else {
      commands.add(const UICommand(
        type: UICommandType.selectToken,
        target: 'swap_from_token',
        payload: {'symbol': 'USDT'},
      ));
      commands.add(UICommand(
        type: UICommandType.selectToken,
        target: 'swap_to_token',
        payload: {'symbol': symbol},
      ));
    }

    final amount = intent.amount;
    if (amount != null && amount > 0) {
      final amountStr = amount >= 1
          ? amount.toStringAsFixed(2)
          : amount.toStringAsFixed(4);
      commands.add(UICommand(
        type: UICommandType.fillField,
        target: 'swap_amount',
        payload: {'value': amountStr},
      ));
    }

    final permCmds = _applyWindowPermissions(commands);
    if (permCmds.isNotEmpty) {
      UICommandBus.instance.dispatchAll(permCmds);
    }

    return AssistantResponse.info(
      fullPlan,
      speechText: voicePlan,
      commands: permCmds,
    );
  }
}
