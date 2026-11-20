import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart'
    show ScaffoldMessenger, SnackBar, SnackBarBehavior, Text;
import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';
import 'package:ibiti_guardian/models/trading_plan.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/services/intents/intent_parser.dart';
import 'package:ibiti_guardian/services/intents/intent_router.dart';
import 'package:ibiti_guardian/services/execution/guardian_execution_controller.dart';
import 'package:ibiti_guardian/services/assistant/openai_chat_service.dart';
import 'package:ibiti_guardian/services/assistant/assistant_session_context.dart';
import 'package:ibiti_guardian/services/assistant/language_detector.dart';
import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_bus.dart';
import 'package:ibiti_guardian/services/assistant/llm_intent_guard.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
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
import 'package:ibiti_guardian/services/assistant/ui_command_resolver.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_registry.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_interface.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/services/wallet/address_book_service.dart';
import 'package:ibiti_guardian/services/assistant/user_memory_service.dart';
import 'package:ibiti_guardian/models/user_memory.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/utils/token_symbol_normalizer.dart';
import 'package:ibiti_guardian/services/assistant/swap_voice_orchestrator.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/services/market/market_live_engine.dart';
import 'package:ibiti_guardian/services/market/market_memory_service.dart';
import 'package:ibiti_guardian/services/market/market_intent_normalizer.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_order_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_account_store.dart';
import 'package:ibiti_guardian/services/exchanges/okx_exchange_service.dart';
import 'package:ibiti_guardian/services/market/market_multi_action_parser.dart';
import 'package:ibiti_guardian/services/wallet/market_price_alert_service.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/services/policy/trusted_address_directory.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/services/assistant/market_voice_brain.dart';
import 'package:ibiti_guardian/services/voice/ai_voice.dart';
import 'package:ibiti_guardian/services/execution/ai_onchain_executor.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/market/automation_intent_builder.dart';
import 'package:ibiti_guardian/services/market/token_registry_service.dart';
import 'package:ibiti_guardian/services/security/ai_action_gate.dart';
import 'package:ibiti_guardian/services/swap/zerox_swap_provider.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';


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

  static const _log = GuardianLogger('Assistant');

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

  @visibleForTesting
  bool isLimitsStatusQuestionForTest(String input) =>
      _isLimitsStatusQuestion(input);

  bool _isLimitsStatusQuestion(String input) {
    final lower = input.toLowerCase();
    // "Отзови все разрешения" revokes token approvals; it is not a question
    // about what the AI is allowed to do.
    if (lower.contains('отзов') ||
        lower.contains('отозв') ||
        lower.contains('revoke') ||
        lower.contains('паник') ||
        lower.contains('panic')) {
      return false;
    }
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
    // A bare "разрешение" is a token approval ("Что такое разрешение?"), not
    // a question about the AI's limits: only "лимит" or a question about
    // what the AI itself may do gets the limits answer.
    return lower.contains('лимит') ||
        lower.contains('limits') ||
        lower.contains('what are your limits') ||
        lower.contains('allowed actions') ||
        _aiAllowedQuestion.hasMatch(lower);
  }

  // "что тебе можно / разрешено", "какие действия тебе разрешены",
  // "разрешённые действия", "какие сети разрешены" (the AI mandate),
  // "what are you allowed to do".
  static final _aiAllowedQuestion = RegExp(
    'что\\s+(тебе|ии)\\s+(можно|разреш|позвол)|'
    '(^|[^а-яё])(тебе|ии)\\s+(разреш|позвол)|'
    '(^|[^а-яё])(разреш[её]н\\S*|позволен\\S*)\\s+(ли\\s+)?(тебе|ии)([^а-яё]|\$)|'
    'разреш[её]нн\\S*\\s+(действи|актив|монет|токен|сет|площадк|бирж)|'
    '(^|[^а-яё])(действи|актив|монет|токен|сет[иья]|площадк|бирж)\\S*\\s+'
    '(тебе\\s+|ии\\s+)?разреш[её]н([ыао]|\\s|\$|[,.?!])|'
    r'(^|[^a-z])ai\s+(is\s+)?allowed|what\s+(are\s+)?you\s+allowed|'
    r'your\s+permissions',
  );

  // Words about changing the list ("добавь", "удали", "сделай доверенным").
  // They only add the note that the owner changes it, with the PIN — the
  // list itself is always shown, so a question never gets a bare refusal.
  static final _trustChangeWords = RegExp(
    '(^|[^а-яёіїєґ])(добав|внес|внест|занес|занест|убер|убра|удал|исключ|'
    'очист|измен|постав|сделай|сделать|запрет|доверь|доверить|разреши|'
    'додай|додати|видали|видалити|прибер|прибрати)|'
    r'(^|[^a-z])(add|remove|delete|clear|put|make|allow)([^a-z]|$)|'
    r'whitelist\s+(0x|this|that|it\b|him\b|her\b)|trust\s+(0x|this|that)',
  );

  /// Trusted addresses (the AI whitelist): answers what is on it, opens the
  /// screen when asked to, and never changes it. Only the owner adds or
  /// removes entries, with the PIN.
  AssistantResponse? _trustedAddressesFastPath(
    String input,
    String lang, {
    required bool conversationOnly,
  }) {
    final lower = input.toLowerCase();
    if (!UICommandResolver.mentionsTrustedList(
      lower,
      contactLabels: AddressBookService.instance.entries.map((e) => e.label),
    )) {
      return null;
    }
    // A limits question keeps the full limits answer.
    if (lower.contains('лимит') || lower.contains('limit')) return null;
    // "хочу отправить 20 USDT на доверенный адрес MEXC" is a transfer.
    if (IntentParser.parse(input).isExecutionIntent) return null;
    final isRu = lang.startsWith('ru') || lang.startsWith('uk');

    final items = TrustedAddressDirectory.current();
    final names = items.map((i) => i.displayName).join(', ');
    final spokenNames = items
        .map((i) => i.label ?? (isRu ? 'адрес без имени' : 'unnamed address'))
        .join(', ');
    String text;
    String speech;
    if (items.isEmpty) {
      text = isRu
          ? 'Доверенных адресов пока нет. Это адреса, на которые я могу '
              'переводить ${AiVoice.ru('сам', 'сама')}; ваши ручные переводы '
              'они не ограничивают. '
              'Добавить: адресная книга → «⋯» → «Доверить ИИ».'
          : 'No trusted addresses yet. These are the addresses I may send to '
              'myself; your own transfers are not limited. To add one: '
              'Address book → ⋯ → Trust for AI.';
      speech = text;
    } else {
      text = isRu
          ? 'Доверенные адреса (${items.length}): $names. Только на них я '
              'могу переводить ${AiVoice.ru('сам', 'сама')}; ваши ручные '
              'переводы не ограничены.'
          : 'Trusted addresses (${items.length}): $names. I may send only '
              'to these; your own transfers are not limited.';
      speech = isRu
          ? 'Доверенных адресов: ${items.length}. $spokenNames.'
          : 'Trusted addresses: ${items.length}. $spokenNames.';
    }

    if (_trustChangeWords.hasMatch(lower)) {
      final note = isRu
          ? 'Добавлять и убирать доверенные адреса можете только вы, с '
              'ПИН-кодом: адресная книга → «⋯» → «Доверить ИИ» или Командный '
              'центр → «Доверенные адреса». ${AiVoice.ru('Сам', 'Сама')} я '
              'этот список не меняю. '
          : 'Only you add or remove trusted addresses, with your PIN: '
              'Address book → ⋯ → Trust for AI, or Command Center → Trusted '
              "addresses. I don't change this list myself. ";
      text = '$note$text';
      speech = '$note$speech';
    }

    var commands = const <UICommand>[];
    if (!conversationOnly && UICommandResolver.asksToOpenWindow(lower)) {
      commands = UICommandResolver.resolveAndDispatch(
        intent: null,
        commands: const [
          UICommand(type: UICommandType.openModal, target: 'trusted_addresses'),
        ],
      );
    }
    if (commands.isNotEmpty) {
      final opening = isRu ? 'Открываю доверенные адреса. ' : 'Opening trusted addresses. ';
      return AssistantResponse.info('$opening$text',
          speechText: '$opening$speech', commands: commands);
    }
    return AssistantResponse.info(text, speechText: speech);
  }

  /// What the AI does in the current mode, with the state of «Подтверждать
  /// действия ИИ ПИН-кодом» in «Автономный» (checked in code: exchange
  /// orders and on-chain operations go through AiActionGate — card + PIN,
  /// or with the setting OFF only within the daily limit, «AI Мандат», EPK
  /// and to trusted addresses; selling a balance share keeps the window).
  AssistantResponse _modeContractResponse(String languageCode) {
    final settings = AiControlService.instance.settings;
    final pinOn = settings.aiPinConfirm;
    if (languageCode == 'ru') {
      switch (settings.mode) {
        case AiMode.manual:
          return AssistantResponse.info(
            'Сейчас режим «Советник». Я только советую и объясняю: '
            'рассказываю о балансе, активах, рынке, истории, лимитах и '
            'рисках. ${AiVoice.ru('Сам', 'Сама')} я ничего не открываю, не '
            'готовлю и не выполняю: ни переводов и обменов, ни ордеров на '
            'биржах, ни алертов, стоп-лоссов и избранного. Ваши собственные '
            'действия работают как обычно. Чтобы я '
            '${AiVoice.ru('готовил', 'готовила')} операции, включите '
            '«Ручной», чтобы ${AiVoice.ru('выполнял', 'выполняла')} — '
            '«Автономный» (в AI-Центре, с ПИН-кодом).',
          );
        case AiMode.guarded:
          return AssistantResponse.info(
            'Сейчас режим «Ручной». Я готовлю операции: открываю и заполняю '
            'окна перевода, обмена и ордера на бирже, собираю превью и '
            'маршрут. Подтверждаете их вы, кнопкой и ПИН-кодом; без вас '
            'ничего не выполняется.',
          );
        case AiMode.fullAutonomy:
          final common = 'Продажу всего баланса монеты или его доли вы '
              'подтверждаете в окне. Всегда действуют дневной лимит, «AI '
              'Мандат», политика и EPK, превысить их я не могу: хотите '
              'больше — поднимите порог в «Политике» (нужен ПИН). '
              '${AiVoice.ru('Сам', 'Сама')}, без вашей просьбы, я не торгую.';
          if (pinOn) {
            return AssistantResponse.info(
              'Сейчас режим «Автономный», подтверждение действий ИИ '
              'ПИН-кодом включено. Операции, о которых вы просите голосом '
              'или в чате, я ${AiVoice.ru('сам', 'сама')} заполняю и '
              'выполняю: ордера на биржах (MEXC, Binance, Gate.io, OKX), '
              'переводы, обмены и сделки по «Делегировать AI». Перед каждой '
              'показываю карточку: что, сколько, куда и комиссия. Вы '
              'подтверждаете её кнопкой или словом «да» и вводите ПИН-код; '
              'после выполнения приходит уведомление «ИИ выполнил». $common',
            );
          }
          return AssistantResponse.info(
            'Сейчас режим «Автономный», подтверждение действий ИИ ПИН-кодом '
            'выключено. Операции, о которых вы просите голосом или в чате, '
            'я ${AiVoice.ru('сам', 'сама')} заполняю и выполняю без '
            'карточки и ПИН-кода, но только в рамках дневного лимита, «AI '
            'Мандат» и EPK и только на доверенные адреса; после каждой '
            'приходит уведомление «ИИ выполнил». Перевод на новый адрес или '
            'операцию без известной цены я показываю карточкой и прошу '
            'ПИН-код. $common',
          );
      }
    }
    switch (settings.mode) {
      case AiMode.manual:
        return AssistantResponse.info(
          'The "Advisor" mode is active. I only advise and explain: '
          'balances, assets, market, history, limits and risks. I open, '
          'prepare and carry out nothing myself: no transfers or swaps, no '
          'exchange orders, no alerts, stop-losses or watchlist changes. '
          'Your own actions work as usual. Choose "Manual" for me to '
          'prepare operations or "Autonomous" for me to carry them out (in '
          'AI Center, with your PIN).',
        );
      case AiMode.guarded:
        return AssistantResponse.info(
          'The "Manual" mode is active. I prepare operations: I open and '
          'fill the send, swap and exchange order windows and build previews '
          'and routes. You confirm them with the button and your PIN; '
          'nothing runs without you.',
        );
      case AiMode.fullAutonomy:
        const common = 'Selling all or a share of a coin balance still '
            'opens a window for you to confirm. The daily limit, the "AI '
            'Mandate", policy and EPK always apply and I cannot exceed them: '
            'to allow more, raise the threshold in Policy (PIN needed). I '
            'never trade on my own without your request.';
        if (pinOn) {
          return AssistantResponse.info(
            'The "Autonomous" mode is active, AI action PIN confirmation is '
            'ON. The operations you ask for by voice or in chat I fill in '
            'and carry out myself: exchange orders (MEXC, Binance, Gate.io, '
            'OKX), transfers, swaps and "Delegate to AI" trades. Before each '
            'one I show a card (what, how much, where, fee); you confirm it '
            'with the button or by saying "yes" and enter your PIN. '
            'Afterwards an "AI did" notification arrives. $common',
          );
        }
        return AssistantResponse.info(
          'The "Autonomous" mode is active, AI action PIN confirmation is '
          'OFF. The operations you ask for by voice or in chat I carry out '
          'myself without a card or PIN, but only within the daily limit, '
          'the "AI Mandate" and EPK, and only to trusted addresses; an "AI '
          'did" notification follows each one. A transfer to a new address '
          'or an operation with an unknown price still gets a card and the '
          'PIN. $common',
        );
    }
  }

  AssistantResponse _limitsStatusResponse(String languageCode) {
    final s = AiControlService.instance.settings;
    final policy = PolicyProfileStore.instance.current;
    final isRu = languageCode == 'ru';
    final actions = s.allowedActions
        .map((action) => _aiActionLabel(action, isRu: isRu))
        .join(', ');
    final assets = _allowedListLabel(
      s.mandate.allowedAssets,
      isRu: isRu,
      ruAll: 'любые активы',
      enAll: 'any assets',
    );
    final networks = _allowedListLabel(
      s.mandate.allowedNetworks,
      isRu: isRu,
      ruAll: 'любые сети',
      enAll: 'any networks',
    );
    final venues = _allowedListLabel(
      s.mandate.allowedVenues,
      isRu: isRu,
      ruAll: 'любые подключённые площадки',
      enAll: 'any connected venues',
    );
    if (languageCode == 'ru') {
      return AssistantResponse.info(
        'Текущий режим ИИ: ${_aiModeLabel(s.mode, isRu: true)}. '
        'Профиль безопасности: ${_policyModeLabel(policy.mode, isRu: true)}. '
        'Лимит одного перевода: \$${policy.sendLimitUsd.toStringAsFixed(0)}. '
        'Лимит одного обмена: \$${policy.swapLimitUsd.toStringAsFixed(0)}. '
        'Лимит разрешения токена: \$${policy.approveLimitUsd.toStringAsFixed(0)}. '
        'Дневной лимит торговли: \$${s.dailyLimit.toStringAsFixed(0)}. '
        'Минимальный баланс для торговли: \$${s.minTradeBalance.toStringAsFixed(0)}. '
        'Максимальный размер одной позиции: \$${s.mandate.maxPositionUsd.toStringAsFixed(0)}. '
        'Максимальная комиссия сети: \$${s.mandate.maxGasUsd.toStringAsFixed(0)}. '
        'Максимальное проскальзывание: ${s.mandate.maxSlippageBps.toStringAsFixed(0)} базисных пунктов. '
        'Разрешённые действия: $actions. '
        'Разрешённые активы: $assets. '
        'Разрешённые сети: $networks. '
        'Разрешённые площадки: $venues. '
        'Неизвестные контракты: ${policy.allowUnknownContracts ? 'разрешены' : 'запрещены'}. '
        '${s.mode == AiMode.fullAutonomy ? 'Подтверждение действий ИИ ПИН-кодом: ${s.aiPinConfirm ? 'включено' : 'выключено'}. ' : ''}'
        'Превысить лимиты я не могу; менять их можете только вы, в «Политике», с ПИН-кодом.',
      );
    }
    return AssistantResponse.info(
      'Current AI mode: ${_aiModeLabel(s.mode, isRu: false)}. '
      'Security profile: ${_policyModeLabel(policy.mode, isRu: false)}. '
      'Per-transfer limit: \$${policy.sendLimitUsd.toStringAsFixed(0)}. '
      'Per-swap limit: \$${policy.swapLimitUsd.toStringAsFixed(0)}. '
      'Token approval limit: \$${policy.approveLimitUsd.toStringAsFixed(0)}. '
      'Daily trading limit: \$${s.dailyLimit.toStringAsFixed(0)}. '
      'Minimum trading balance: \$${s.minTradeBalance.toStringAsFixed(0)}. '
      'Maximum position size: \$${s.mandate.maxPositionUsd.toStringAsFixed(0)}. '
      'Maximum network fee: \$${s.mandate.maxGasUsd.toStringAsFixed(0)}. '
      'Maximum slippage: ${s.mandate.maxSlippageBps.toStringAsFixed(0)} basis points. '
      'Allowed actions: $actions. '
      'Allowed assets: $assets. '
      'Allowed networks: $networks. '
      'Allowed venues: $venues. '
      'Unknown contracts: ${policy.allowUnknownContracts ? 'allowed' : 'blocked'}. '
      '${s.mode == AiMode.fullAutonomy ? 'AI action PIN confirmation: ${s.aiPinConfirm ? 'ON' : 'OFF'}. ' : ''}'
      'I cannot exceed these limits; only you change them, in Policy, with your PIN.',
    );
  }

  String _allowedListLabel(
    List<String> values, {
    required bool isRu,
    required String ruAll,
    required String enAll,
  }) {
    if (values.isEmpty) return isRu ? ruAll : enAll;
    return values.join(', ');
  }

  /// «Советник» / «Ручной» / «Автономный»; EN Advisor / Manual /
  /// Autonomous (the code names stay manual / guarded / fullAutonomy).
  static String _aiModeLabel(AiMode mode, {required bool isRu}) {
    if (!isRu) {
      return switch (mode) {
        AiMode.manual => 'Advisor',
        AiMode.guarded => 'Manual',
        AiMode.fullAutonomy => 'Autonomous',
      };
    }
    return switch (mode) {
      AiMode.manual => '«Советник»',
      AiMode.guarded => '«Ручной»',
      AiMode.fullAutonomy => '«Автономный»',
    };
  }

  String _policyModeLabel(PolicyMode mode, {required bool isRu}) {
    if (!isRu) {
      return switch (mode) {
        PolicyMode.safe => 'Safe',
        PolicyMode.defi => 'DeFi',
        PolicyMode.advanced => 'Advanced',
      };
    }
    return switch (mode) {
      PolicyMode.safe => 'безопасный',
      PolicyMode.defi => 'децентрализованные финансы',
      PolicyMode.advanced => 'расширенный',
    };
  }

  String _aiActionLabel(AiAction action, {required bool isRu}) {
    if (!isRu) {
      return switch (action) {
        AiAction.revoke => 'revoke permissions',
        AiAction.send => 'send transfers',
        AiAction.swap => 'swap assets',
        AiAction.approve => 'approve tokens',
        AiAction.policyUpdate => 'update policy',
        AiAction.contactPayments => 'pay contacts',
        AiAction.scheduledActions => 'scheduled actions',
        AiAction.openWindows => 'open screens and windows',
        AiAction.closeWindows => 'close screens and windows',
      };
    }
    return switch (action) {
      AiAction.revoke => 'отзыв разрешений',
      AiAction.send => 'переводы',
      AiAction.swap => 'обмен активов',
      AiAction.approve => 'разрешения токенов',
      AiAction.policyUpdate => 'изменение политики',
      AiAction.contactPayments => 'платежи контактам',
      AiAction.scheduledActions => 'запланированные действия',
      AiAction.openWindows => 'открытие экранов и окон',
      AiAction.closeWindows => 'закрытие экранов и окон',
    };
  }

  // «Советник» (AiMode.manual): the AI only advises — zero UI navigation,
  // nothing prepared or run. The user acts themselves.
  AssistantResponse _manualExecutionBlockedResponse(String languageCode) {
    return AssistantResponse(
      message: languageCode == 'ru'
          ? 'Сейчас режим «Советник»: я только советую. Могу объяснить, что '
              'нужно для этого действия, а сделать его можете вы сами. Чтобы '
              'я ${AiVoice.ru('готовил', 'готовила')} операции, включите '
              '«Ручной», чтобы ${AiVoice.ru('выполнял', 'выполняла')} — '
              '«Автономный».'
          : 'The "Advisor" mode is active: I only advise. I can explain what '
              'this action needs, and you can do it yourself. Choose "Manual" '
              'for me to prepare operations or "Autonomous" for me to carry '
              'them out.',
      speechText: languageCode == 'ru'
          ? 'Режим «Советник»: я только советую. Для действий нужен «Ручной» '
              'или «Автономный».'
          : 'Advisor mode: I only advise. Choose Manual or Autonomous for '
              'actions.',
      type: ResponseType.info,
    );
  }

  /// «Советник»: the AI sets and changes no alerts, stop-losses,
  /// take-profits or watchlist entries — the user does that in the coin card.
  AssistantResponse _advisorMarketRefusal(String languageCode) {
    final msg = languageCode == 'ru'
        ? 'Сейчас режим «Советник»: я только советую и не ставлю и не меняю '
            'алерты, стоп-лоссы, тейк-профиты и избранное. Сделайте это сами '
            'в карточке монеты или включите «Ручной».'
        : 'The "Advisor" mode is active: I only advise and do not set or '
            'change alerts, stop-losses, take-profits or the watchlist. Do it '
            'yourself in the coin card, or choose "Manual".';
    return AssistantResponse.info(msg, speechText: msg);
  }

  AssistantResponse _untrustedExecutionBlockedResponse(String languageCode) {
    return AssistantResponse(
      message: languageCode == 'ru'
          ? 'Для ответа я ${AiVoice.ru('читал', 'читала')} внешние данные '
              '(сайт, поиск, историю или рынок), '
              'поэтому не создаю из него перевод или обмен. '
              'Если операция нужна, дайте команду отдельным сообщением.'
          : 'I read external data (a web page, search, history or market data) '
              'for this answer, so I will not create a send or swap from it. '
              'If you need the operation, ask for it in a separate message.',
      speechText: languageCode == 'ru'
          ? 'Операцию из этого ответа не создаю. Дайте команду отдельно.'
          : 'I will not create an operation from this answer. Ask separately.',
      type: ResponseType.info,
    );
  }

  AssistantResponse _unsupportedSwapTokenResponse(
      String languageCode, String symbol) {
    final chain = IBITIVaultService.instance.chainKey.toUpperCase();
    return AssistantResponse(
      message: languageCode == 'ru'
          ? 'Не знаю адрес токена $symbol в сети $chain, поэтому обмен не готовлю. '
              'Выберите токен в окне обмена.'
          : 'I do not know the $symbol token address on $chain, so I will not '
              'prepare the swap. Pick the token in the swap window.',
      speechText: languageCode == 'ru'
          ? 'Не знаю токен $symbol в этой сети.'
          : 'I do not know the $symbol token on this network.',
      type: ResponseType.info,
    );
  }

  bool _isActiveNativeSymbol(String? symbol) {
    final native =
        PrivyChainRegistry.getChain(IBITIVaultService.instance.chainKey)
            .nativeSymbol
            ?.toUpperCase();
    return native != null && symbol?.toUpperCase() == native;
  }

  /// UI commands authored by the model: none after untrusted content, and a
  /// send-address prefill only when the address is one the user gave.
  List<UICommand> _guardLlmUiCommands(
    List<UICommand> commands, {
    required String userText,
    required bool untrustedContext,
    required Iterable<String> knownAddresses,
  }) {
    if (untrustedContext) return const <UICommand>[];
    return commands.where((c) {
      if (c.type != UICommandType.fillField || c.target != 'send_address') {
        return true;
      }
      return LlmIntentGuard.isVerifiedRecipient(
        c.payload?['value']?.toString(),
        userText: userText,
        knownAddresses: knownAddresses,
      );
    }).map(_withoutResultPayload).toList();
  }

  /// Order results (isSuccess, orderId, executed qty/price) are set only by
  /// the app after a real order; from the model they would show a fake
  /// "order filled" screen.
  static const _resultPayloadKeys = {
    'isSuccess',
    'orderId',
    'executedQty',
    'executedPrice',
    // Only the user's own macros may mark a window as the user's.
    'byUserMacro',
  };

  UICommand _withoutResultPayload(UICommand c) {
    final payload = c.payload;
    if (payload == null || !payload.keys.any(_resultPayloadKeys.contains)) {
      return c;
    }
    return UICommand(
      type: c.type,
      target: c.target,
      payload: Map<String, dynamic>.from(payload)
        ..removeWhere((k, _) => _resultPayloadKeys.contains(k)),
    );
  }

  /// Full descriptive message for UI/chat display.
  ///
  /// The window commands that go with it are dropped when the "Open windows
  /// & screens" permission is off (always off in Manual), so the message
  /// then says so instead of claiming the window was opened.
  String _surfaceOpenMessage(
    String languageCode, {
    required String surfaceRu,
    required String surfaceEn,
  }) {
    final canOpen = AiControlService.instance.settings.allowedActions
        .contains(AiAction.openWindows);
    if (!canOpen) {
      return languageCode == 'ru'
          ? 'Открыть $surfaceRu ${AiVoice.ru('сам', 'сама')} не могу: в AI '
              'Control выключено '
              '«Открытие окон и экранов» (в режиме «Советник» оно всегда '
              'выключено). Откройте вручную.'
          : 'I cannot open the $surfaceEn myself: "Open windows & screens" '
              'is off in AI Control (always off in the Advisor mode). '
              'Please open it yourself.';
    }
    return languageCode == 'ru'
        ? '${AiVoice.ru('Открыл', 'Открыла')} $surfaceRu.'
        : 'Opened $surfaceEn.';
  }

  /// Parser intents whose only effect is opening a screen; their controller
  /// answer is just "Opening …".
  static const _navigationOnlyIntents = {
    IntentType.receiveAsset,
    IntentType.showHistory,
    IntentType.openAddressBook,
    IntentType.openWalletSettings,
    IntentType.openMarket,
    IntentType.openSecurityCenter,
  };

  /// Answer for a "go to screen" request (market, history, address book...)
  /// when the AI may not open windows: nothing opens, and it says so.
  AssistantResponse _windowsBlockedResponse(String languageCode) {
    final msg = languageCode == 'ru'
        ? 'Открывать окна ${AiVoice.ru('сам', 'сама')} сейчас не могу: в AI '
            'Control выключено '
            '«Открытие окон и экранов» (в режиме «Советник» оно всегда '
            'выключено). Откройте нужный экран вручную.'
        : 'I cannot open windows right now: "Open windows & screens" is off '
            'in AI Control (always off in the Advisor mode). Please open the '
            'screen yourself.';
    return AssistantResponse.info(msg, speechText: msg);
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

  /// Window commands for one window, all or nothing: when the window may not
  /// open («Открытие окон» off — always so in «Советник»), its fills and
  /// auto-actions are dropped too, so nothing stays pending on the bus for
  /// a window the user opens later.
  List<UICommand> _windowBundle(List<UICommand> commands) {
    final allowed = _applyWindowPermissions(commands);
    bool opens(UICommand c) =>
        c.type == UICommandType.openModal || c.type == UICommandType.navigate;
    if (commands.any(opens) && !allowed.any(opens)) return const [];
    return allowed;
  }

  /// Dispatches one prepared window; false when «Открытие окон» is off.
  bool _dispatchWindow(UICommand command) {
    final allowed = _windowBundle([command]);
    if (allowed.isEmpty) return false;
    UICommandBus.instance.dispatchAll(allowed);
    return true;
  }

  // ── «Автономный»: the AI carries the operation out (D4–D6) ─────────────────

  /// Voice and the market chat in «Автономный»: the AI runs an operation
  /// itself through [AiActionGate] instead of opening its window. The general
  /// chat gets a preview card instead, which carries it out the same way.
  static bool _runsHeadless(AssistantInputSource source) =>
      AiControlService.instance.settings.mode == AiMode.fullAutonomy &&
      (source == AssistantInputSource.voice ||
          source == AssistantInputSource.marketChat);

  /// A transfer with a recipient and an amount, or a swap with both tokens
  /// and an amount. Never a revoke (C12) — that stays in Panic / Safe.
  static bool _isHeadlessCandidate(IntentData intent) {
    final amount = intent.amount;
    if (amount == null || amount <= 0 || !amount.isFinite) return false;
    switch (intent.type) {
      case IntentType.sendAsset:
        return (intent.toAddress?.trim().isNotEmpty ?? false);
      case IntentType.swapAsset:
        return (intent.sourceTokenSymbol?.trim().isNotEmpty ?? false) &&
            (intent.targetTokenSymbol?.trim().isNotEmpty ?? false);
      default:
        return false;
    }
  }

  /// A swap side on the ACTIVE network, resolved the way the swap window
  /// does: the native coin, a token held on this network, or the built-in
  /// registry. Null when it cannot be resolved reliably — then the
  /// prefilled window opens instead (D17).
  ({String address, int decimals})? _resolveSwapSide(String symbol) {
    final upper = TokenSymbolNormalizer.normalize(symbol).trim().toUpperCase();
    if (upper.isEmpty) return null;
    final chainKey = IBITIVaultService.instance.chainKey;
    final chain = PrivyChainRegistry.getChain(chainKey);
    if (upper == (chain.nativeSymbol ?? '').toUpperCase()) {
      return switch (chainKey) {
        'solana' => (
            address: 'So11111111111111111111111111111111111111112',
            decimals: 9,
          ),
        'tron' => (address: upper, decimals: 6),
        _ => (address: ZeroXSwapProvider.nativeTokenSentinel, decimals: 18),
      };
    }
    final evmId = chain.evmChainId;
    WalletAsset? held;
    for (final a in VaultPortfolioListener.instance.summary?.allAssets ??
        const <WalletAsset>[]) {
      final onChain = a.chainKey.isNotEmpty
          ? a.chainKey == chainKey
          : (evmId != null && a.chainId == evmId);
      if (!onChain || a.symbol.toUpperCase() != upper) continue;
      if (a.isNative || a.address.isEmpty) continue;
      if (a.address.toLowerCase() == 'native') continue;
      if (held == null || a.valueUsd > held.valueUsd) held = a;
    }
    if (held != null) return (address: held.address, decimals: held.decimals);
    final entry = TokenRegistryService.instance
        .resolveFromRegistry(symbol: upper, chainKey: chainKey);
    final address = entry?.address;
    if (entry == null || address == null || address.isEmpty) return null;
    return (address: address, decimals: entry.decimals);
  }

  /// The controller's swap preview for [intent] on the active network, or
  /// null when a token cannot be resolved reliably.
  Future<AssistantResponse?> _buildSwapPreview(IntentData intent) async {
    final src = intent.sourceTokenSymbol;
    final tgt = intent.targetTokenSymbol;
    if (src == null || tgt == null) return null;
    final from = _resolveSwapSide(src);
    final to = _resolveSwapSide(tgt);
    if (from == null || to == null) return null;
    final swapIntent = IntentData(
      type: IntentType.swapAsset,
      rawInput: intent.rawInput,
      amount: intent.amount,
      amountMode: intent.amountMode ?? AmountMode.exactIn,
      slippageBps: intent.slippageBps,
      sourceTokenSymbol: TokenSymbolNormalizer.normalize(src).toUpperCase(),
      targetTokenSymbol: TokenSymbolNormalizer.normalize(tgt).toUpperCase(),
      sourceTokenAddress: from.address,
      targetTokenAddress: to.address,
      sourceTokenDecimals: from.decimals,
      targetTokenDecimals: to.decimals,
    );
    return _controller.requestSwapPreview(swapIntent);
  }

  /// A preview the AI may run itself, or the reason it cannot. A refusal
  /// (limits, policy, mandate, no route) never opens a window instead: that
  /// would be a way around the limit (D6).
  AssistantResponse _headlessFromPreview(
    AssistantResponse preview, {
    required AssistantInputSource source,
    required String lang,
    String? preface,
  }) {
    final ready = preview.type == ResponseType.preview &&
        preview.executionPath != null &&
        preview.policy?.blocked != true &&
        (preview.pendingTransaction != null || preview.swapPlan != null);
    if (!ready) {
      final isRu = lang.startsWith('ru');
      final reason = preview.message.trim().isNotEmpty
          ? preview.message.trim()
          : (isRu
              ? 'Эту операцию я выполнить не могу.'
              : 'I cannot carry out this operation.');
      final msg = _withRaiseHint(reason, isRu);
      return AssistantResponse(
        message: _withPreface(preface, msg),
        speechText: msg,
        type: preview.type == ResponseType.error
            ? ResponseType.error
            : ResponseType.info,
      );
    }
    return _executeHeadless(preview,
        source: source, lang: lang, preface: preface);
  }

  /// Hands [preview] to [AiOnchainExecutor] without waiting: the card + PIN
  /// may take longer than the 30 s voice turn (D15). The executor reports
  /// the result itself (snack bar, «ИИ выполнил: …»). A refusal known now
  /// (limits, mandate, EPK, permissions) is said right away, with the hint
  /// how to allow more (D6).
  AssistantResponse _executeHeadless(
    AssistantResponse preview, {
    required AssistantInputSource source,
    required String lang,
    String? preface,
  }) {
    final isRu = lang.startsWith('ru');
    final summary = AiOnchainExecutor.summaryFor(preview, source: source.name);
    final gate = AiActionGate.instance;

    final pre = gate.precheck(summary);
    if (!pre.mayExecute) {
      final msg = pre.reason ??
          (isRu
              ? 'Эту операцию я выполнить не могу.'
              : 'I cannot carry out this operation.');
      return AssistantResponse.info(_withPreface(preface, msg),
          speechText: msg);
    }
    final plan = preview.swapPlan;
    final steps = [
      if (plan?.approveStep != null) plan!.approveStep!,
      if (plan != null) plan.swapStep else preview.pendingTransaction!,
    ];
    for (final step in steps) {
      final stop = _controller.aiPreflight(step);
      if (stop != null) {
        final msg = _withRaiseHint(stop.message, isRu);
        return AssistantResponse.info(_withPreface(preface, msg),
            speechText: msg);
      }
    }
    if (gate.hasOpenCard) return _busyResponse(isRu, preface: preface);

    _trackPending(AiOnchainExecutor.instance
        .executePreview(preview, source: source.name)
        .then((r) {
      // Nothing ran because another AI operation holds the lock or nobody
      // could be asked: the executor stays silent then, so say it here.
      if (r.deferred) _notifyInApp(r.message);
    }));

    final what = '${summary.title}, ${summary.amountLabel}';
    final pinOn = AiControlService.instance.settings.pinRequiredForAi;
    final String msg;
    final String speech;
    if (pinOn) {
      msg = isRu
          ? 'Карточка операции на экране: $what. Подтвердите её кнопкой или '
              'словом «да» и введите ПИН-код.'
          : 'The operation card is on the screen: $what. Confirm it with the '
              'button or by saying "yes", then enter your PIN.';
      speech = isRu
          ? 'Подтвердите на экране: кнопкой или словом «да», затем ПИН-код.'
          : 'Please confirm on the screen, then enter your PIN.';
    } else {
      msg = isRu
          ? 'Выполняю: $what. Если адрес новый или цена неизвестна, покажу '
              'карточку и попрошу ПИН-код. Результат придёт уведомлением.'
          : 'Carrying it out: $what. For a new address or an unknown price I '
              'show a card and ask for your PIN. The result comes as a '
              'notification.';
      speech = isRu ? 'Выполняю.' : 'On it.';
    }
    return AssistantResponse.info(_withPreface(preface, msg),
        speechText: speech);
  }

  AssistantResponse _busyResponse(bool isRu, {String? preface}) {
    final msg = isRu
        ? 'Сначала ответьте на открытую карточку операции: одновременно я '
            'выполняю только одно действие с деньгами.'
        : 'Please answer the open operation card first: I run only one money '
            'action at a time.';
    return AssistantResponse.info(_withPreface(preface, msg), speechText: msg);
  }

  static String _withPreface(String? preface, String msg) {
    final p = preface?.trim() ?? '';
    return p.isEmpty ? msg : '$p\n\n$msg';
  }

  static final _limitWords = RegExp(
    r'limit|budget|mandate|position cap|лимит|бюджет|мандат|позици',
    caseSensitive: false,
  );

  /// Over a limit or outside «AI Мандат»: say how to allow more — never
  /// prepare a way around it (D6).
  static String _withRaiseHint(String msg, bool isRu) {
    final lower = msg.toLowerCase();
    if (!_limitWords.hasMatch(msg) ||
        lower.contains('поднимите порог') ||
        lower.contains('raise the')) {
      return msg;
    }
    return '$msg ${_raiseHint(isRu)}';
  }

  static String _raiseHint(bool isRu) => isRu
      ? 'Хотите больше — поднимите порог в «Политике» (нужен ПИН).'
      : 'Want more? Raise the threshold in Policy (PIN needed).';

  /// The last AI money action started without waiting (card + PIN). Tests
  /// await it; the app does not.
  Future<void>? _pendingAiAction;

  void _trackPending(Future<void> job) {
    _pendingAiAction = job.catchError((Object e) {
      _log.e('AI action failed', e);
    });
  }

  /// Completes when the AI money action started by the last [process] call
  /// (card + PIN, then the order or transaction) has finished.
  @visibleForTesting
  Future<void> pendingAiActionForTest() =>
      _pendingAiAction ?? Future<void>.value();

  /// A short line at the bottom of the screen (the voice turn has already
  /// ended when a confirmed order or a refusal comes back).
  void _notifyInApp(String text) {
    if (text.trim().isEmpty) return;
    try {
      final ctx = AiActionGate.instance.resolveContext();
      if (ctx == null || !ctx.mounted) return;
      ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
      ));
    } catch (e) {
      _log.w('in-app note failed: $e');
    }
  }

  static final _cardYes = RegExp(
    r'^(да|ага|угу|давай|подтверждаю|подтверди|подтвердить|верно|ок|окей|'
    r'хорошо|конечно|выполняй|yes|yeah|yep|sure|confirm|ok|okay|go ahead|'
    r'do it|proceed)'
    r'([\s,]+(да|давай|подтверждаю|подтверди|подтвердить|выполняй|конечно|'
    r'пожалуйста|yes|confirm|please|go ahead|do it))*$',
  );

  static final _cardNo = RegExp(
    r'^(нет|не надо|не нужно|не делай|отмена|отмени|отменить|отменяй|стоп|'
    r'стой|no|nope|cancel|stop|do not|dont)'
    r'([\s,]+(нет|не надо|не нужно|отмена|отмени|отменить|стоп|пожалуйста|'
    r'no|cancel|stop|please))*$',
  );

  /// «да» / «нет» while an AI confirmation card is open, else null.
  static bool? _cardAnswerFor(String lower, AssistantInputSource source) {
    if (source == AssistantInputSource.automated) return null;
    if (!AiActionGate.instance.hasOpenCard) return null;
    final text = lower
        .replaceAll(RegExp('[.!?…«»"\'’]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) return null;
    if (_cardYes.hasMatch(text)) return true;
    if (_cardNo.hasMatch(text)) return false;
    return null;
  }

  /// «А можешь купить…?» — what the AI does in the current mode.
  static String _canTradeAnswer(bool isRu) {
    final settings = AiControlService.instance.settings;
    switch (settings.mode) {
      case AiMode.manual:
        return isRu
            ? 'В режиме «Советник» я только советую: купить можете вы сами, '
                'в окне биржи или кошелька. Чтобы я '
                '${AiVoice.ru('готовил', 'готовила')} покупки, включите '
                '«Ручной».'
            : 'In the "Advisor" mode I only advise: you can buy yourself in '
                'the exchange or wallet window. Choose "Manual" for me to '
                'prepare purchases.';
      case AiMode.guarded:
        return isRu
            ? 'Да. В режиме «Ручной» я открою заполненное окно покупки, а '
                'подтвердите его вы ПИН-кодом. Скажите монету и сумму.'
            : 'Yes. In the "Manual" mode I open a filled-in trade window and '
                'you confirm it with your PIN. Tell me the coin and amount.';
      case AiMode.fullAutonomy:
        if (settings.aiPinConfirm) {
          return isRu
              ? 'Да. В режиме «Автономный» я куплю '
                  '${AiVoice.ru('сам', 'сама')} в рамках лимитов и «AI '
                  'Мандат»: покажу карточку, а вы подтвердите её ПИН-кодом. '
                  'Скажите монету и сумму.'
              : 'Yes. In the "Autonomous" mode I buy myself within your '
                  'limits and mandate: I show a card and you confirm it with '
                  'your PIN. Tell me the coin and amount.';
        }
        return isRu
            ? 'Да. В режиме «Автономный» я куплю ${AiVoice.ru('сам', 'сама')} '
                'в рамках лимитов и «AI Мандат», без ПИН-кода, и пришлю '
                'уведомление. Скажите монету и сумму.'
            : 'Yes. In the "Autonomous" mode I buy myself within your limits '
                'and mandate, without the PIN, and send a notification. Tell '
                'me the coin and amount.';
    }
  }

  static String _advisorPlanNote(String lang) => lang.startsWith('ru')
      ? '\n\n💡 Режим «Советник»: это только совет, сделку вы делаете сами.'
      : '\n\n💡 Advisor mode: this is advice only; you make the trade '
          'yourself.';

  IntentData _resolveAddressBookRecipient(IntentData intent) {
    if (intent.type != IntentType.sendAsset || intent.toAddress != null) {
      return intent;
    }

    final input = intent.rawInput.toLowerCase();
    for (final entry in AddressBookService.instance.entries) {
      final label = entry.label.trim().toLowerCase();
      if (label.isNotEmpty && input.contains(label)) {
        return intent.copyWith(toAddress: entry.address);
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
    'юсдт': 'USDT',
    'ю эс ди ти': 'USDT',
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

  /// Read-only balance questions must never enter the voice trade resolver.
  ///
  /// The trade resolver intentionally has a narrow buy/sell schema. Sending a
  /// question such as "сколько у меня USDT?" through that schema can coerce it
  /// into a buy proposal before the existing balance fast path gets a chance
  /// to answer. Explicit execution intents remain on their original route.
  static bool _isExplicitBalanceReadQuestion(String input) {
    final lower = input.trim().toLowerCase();
    final localIntent = IntentParser.parse(input);
    if (localIntent.isExecutionIntent || _mentionsTrading(lower)) {
      return false;
    }

    return lower.contains('баланс') ||
        lower.contains('balance') ||
        lower.contains('сколько у меня') ||
        lower.contains('сколько у нас') ||
        lower.contains('сколько usdt') ||
        lower.contains('сколько юсдт') ||
        lower.contains('how much do i have') ||
        lower.contains('what do i have');
  }

  /// Returns true only when a voice transcript contains an explicit request
  /// to perform an app action.
  ///
  /// Mentioning an action in a question or discussion is not authorization.
  /// For example, "Стоит ли покупать SOL?" and "Чем Safe Scan отличается от
  /// Panic Mode?" must remain ordinary conversation. Existing deterministic
  /// action routes are only enabled for imperative or explicit polite
  /// requests such as "Купи SOL" or "Можешь открыть кошелёк?".
  static bool _isExplicitVoiceActionRequest(String input) {
    final lower = input.trim().toLowerCase();
    if (lower.isEmpty) return false;

    final informationalStart = RegExp(
      r'^(что|чем|как|почему|зачем|когда|где|кто|какой|какая|какие|'
      r'стоит ли|можно ли|нужно ли|расскажи|объясни|поясни|'
      r'what|why|how|when|where|who|which|should|is it|tell me|explain)'
      r'(?:\s|[?!,.]|$)',
      caseSensitive: false,
    );

    const actionVerbs = <String>[
      'купи',
      'продай',
      'слей',
      'обменяй',
      'поменяй',
      'отправь',
      'переведи',
      'открой',
      'покажи',
      'закрой',
      'запусти',
      'включи',
      'выключи',
      'установи',
      'измени',
      'создай',
      'отмени',
      'сканируй',
      'проверь',
      'отзови',
      'заблокируй',
      'buy',
      'sell',
      'swap',
      'send',
      'transfer',
      'receive',
      'open',
      'show',
      'close',
      'start',
      'enable',
      'disable',
      'set',
      'change',
      'create',
      'cancel',
      'scan',
      'check',
      'revoke',
      'block',
    ];

    bool beginsWithAction(String text) {
      return actionVerbs.any(
        (verb) => RegExp(
          '^${RegExp.escape(verb)}' r'(?:\s|[?!,.]|$)',
          caseSensitive: false,
        ).hasMatch(text),
      );
    }

    final politePrefix = RegExp(
      r'^(пожалуйста[,\s]+|давай\s+|можешь(?:\s+ли)?\s+|'
      r'не мог(?:ла|ли)? бы ты\s+|'
      r'please[,\s]+|can you\s+|could you\s+|would you\s+)',
      caseSensitive: false,
    );

    const explicitShorthands = {
      'настройки кошелька',
      'wallet settings',
    };

    // A command may follow an ordinary sentence, for example:
    // "Мы тестируем. Купи SOL на 5". Inspect each sentence independently so
    // prompt-injection preambles cannot hide a real imperative.
    final sentences = lower
        .split(RegExp(r'[.!?]+'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty);

    for (final sentence in sentences) {
      if (informationalStart.hasMatch(sentence)) continue;
      if (explicitShorthands.contains(sentence)) return true;
      if (beginsWithAction(sentence)) return true;

      final politeMatch = politePrefix.firstMatch(sentence);
      if (politeMatch != null &&
          beginsWithAction(sentence.substring(politeMatch.end).trimLeft())) {
        return true;
      }
    }

    // The same request rule as text chat: "ты можешь открыть отправку?",
    // "could you please open send?", "откроешь отправку?", "давай купим
    // BTC", "ну что, открой отправку", "как обычно купи BTC на 10$".
    return IntentParser.isActionRequest(lower);
  }

  @visibleForTesting
  static bool isVoiceActionRequestForTest(String input) =>
      _isExplicitVoiceActionRequest(input);

  /// "Откроешь отправку?" / "покажешь обмен?" ask to open a window.
  static final _secondPersonOpen = RegExp(
    '(^|[^а-яё])(откроешь|откроете|покажешь|покажете)([^а-яё]|\$)',
  );

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
        _secondPersonOpen.hasMatch(lower) ||
        lower.contains('open') ||
        lower.contains('show') ||
        lower.contains('launch');

    if (!hasOpenVerb) return null;

    // "покажи историю переводов" is the history, not the send window.
    if (lower.contains('истори') || lower.contains('history')) return null;

    final wantsSend = lower.contains('отправ') ||
        lower.contains('перевод') ||
        lower.contains('send') ||
        lower.contains('transfer');
    final wantsSwap = lower.contains('обмен') ||
        lower.contains('свап') ||
        lower.contains('своп') ||
        lower.contains('swap') ||
        lower.contains('поменя');
    // Only the send and swap windows are handled here. Every other open
    // request ("покажи баланс", "открой рынок") goes on to its own rule,
    // so the Manual refusal below never answers it.
    if (!wantsSend && !wantsSwap) return null;

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
              'Включите разрешение «Открытие окон» чтобы я '
              '${AiVoice.ru('мог', 'могла')} это сделать.'
          : 'Opening windows is currently blocked in AI Control settings. '
              'Enable the "Open windows" permission to allow this.';
      return AssistantResponse.info(msg, speechText: msg);
    }

    final isRu = lang.startsWith('ru');

    if (wantsSend) {
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

    if (wantsSwap) {
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
            ? 'Закрывать окна ${AiVoice.ru('сам', 'сама')} сейчас не могу: в '
                'AI-Центре выключено «Закрытие окон» (в режиме «Советник» оно '
                'всегда выключено).'
            : 'I cannot close windows right now: "Close windows" is off in '
                'AI Center (always off in the Advisor mode).';
        return info(
          msg,
          const [],
          speech: msg,
        );
      }
      final msg =
          effectiveLang == 'ru' ? AiVoice.ru('Закрыл.', 'Закрыла.') : 'Closed.';
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
      final s = AiControlService.instance.settings;
      final daily = '\$${s.dailyLimit.toStringAsFixed(0)}';
      final String capText;
      if (effectiveLang == 'ru') {
        switch (mode) {
          case AiMode.manual:
            // «Советник»: window permissions are off (_applyWindowPermissions);
            // the AI only explains and reads data.
            capText = 'Я в режиме «Советник»: только советую. Могу '
                'рассказать о балансе, активах, адресе, истории, рынке и '
                'лимитах и объяснить, что и как сделать. Окна не открываю, '
                'операции не готовлю и не выполняю, алерты и стоп-лоссы не '
                'ставлю. Чтобы я ${AiVoice.ru('начал', 'начала')} '
                'действовать, включите «Ручной» или «Автономный».';
            break;
          case AiMode.guarded:
            capText = 'Я в режиме «Ручной». Знаю ваш баланс, активы, лимиты '
                'и рынок. Открываю и заполняю окна отправки, обмена, '
                'получения и ордера на бирже; могу открыть Safe, Panic, EPK, '
                'AI-Центр и политики. Подтверждаете всегда вы — кнопкой и '
                'ПИН-кодом.';
            break;
          case AiMode.fullAutonomy:
            capText = 'Я в режиме «Автономный». По вашей просьбе заполняю и '
                'выполняю операции в рамках дневного лимита $daily, «AI '
                'Мандат» и EPK${s.aiPinConfirm ? ': перед каждой показываю '
                    'карточку и прошу ПИН-код' : ': без ПИН-кода, только на '
                    'доверенные адреса, с уведомлением после каждой'}. Знаю '
                'баланс, активы и рынок, могу открыть любой экран.';
            break;
        }
      } else {
        switch (mode) {
          case AiMode.manual:
            capText = 'I am in the Advisor mode: I only advise. I can tell '
                'you your balance, assets, address, history, market data and '
                'limits and explain what to do. I open no windows and '
                'prepare or run no operations, alerts or stop-losses. Choose '
                'Manual or Autonomous for me to act.';
            break;
          case AiMode.guarded:
            capText = 'I am in the Manual mode. I know your balance, assets, '
                'limits and market. I open and fill the send, swap, receive '
                'and exchange order windows, and can open Safe, Panic, EPK, '
                'AI Center and policy limits. You always confirm, with the '
                'button and your PIN.';
            break;
          case AiMode.fullAutonomy:
            capText = 'I am in the Autonomous mode. On your request I fill '
                'in and carry out operations within the daily limit of '
                '$daily, the AI Mandate and EPK${s.aiPinConfirm ? ', with a '
                    'card and your PIN before each one' : ', without the PIN, '
                    'only to trusted addresses, with a notification after '
                    'each one'}. I know your balance, assets and market and '
                'can open any screen.';
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
    // A bare "сколько" / "how much" is not a balance question: "Сколько
    // стоит Safe Scan?" and "How much does a revoke cost?" ask about a price.
    final specificSym = _extractAssetSymbol(lower);
    final asksCost = lower.contains('стоит') ||
        lower.contains('стоимост') ||
        lower.contains('цена') ||
        lower.contains('цену') ||
        lower.contains('комисси') ||
        lower.contains('платн') ||
        lower.contains('cost') ||
        lower.contains('price') ||
        lower.contains('fee');
    final asksAmountOfAsset = (lower.contains('сколько') ||
            lower.contains('how much') ||
            lower.contains('how many')) &&
        specificSym != null &&
        !asksCost;
    final isBalanceQuery = lower.contains('баланс') ||
        lower.contains('balance') ||
        lower.contains('сколько у меня') ||
        lower.contains('сколько у нас') ||
        lower.contains('сколько денег') ||
        lower.contains('сколько средств') ||
        lower.contains('мои актив') ||
        lower.contains('мои монет') ||
        lower.contains('how much money') ||
        lower.contains('what do i have') ||
        (lower.contains('how much') && lower.contains('do i have')) ||
        asksAmountOfAsset;
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
        _secondPersonOpen.hasMatch(lower) ||
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
    // A story or question ("Я вчера купил BTC на 10$", "не знаю, стоит ли
    // купить BTC") never gets here: an exchange order in Full Autonomy
    // would be real.
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

          final direction = _extractTradingDirection(lower);
          // A buy or a sell of a wallet (non-exchange) coin: the same rules
          // for voice, market chat and general chat (prepare in «Ручной»,
          // the gate in «Автономный», advice in «Советник»).
          if (direction != TradingDirection.swap) {
            final parsed = IntentParser.parse(input);
            final tradeIntent = IntentData(
              type: direction == TradingDirection.sell
                  ? IntentType.sellAsset
                  : IntentType.buyAsset,
              tokenSymbol: symbol,
              amount: parsed.amount ?? _extractAmount(lower),
              isQuantity: parsed.isQuantity,
              rawInput: input,
            );
            return await _handleOnChainTradeIntent(
              tradeIntent,
              effectiveLang,
              source: source,
              asset: asset,
            );
          }

          final aiSettings = AiControlService.instance.settings;
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
            return info(fullPlan + _advisorPlanNote(effectiveLang), const [],
                speech: voicePlan);
          }

          // «Ручной» / «Автономный»: show plan + open swap modal with prefill
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
        if (currentMode == AiMode.manual) {
          return info(
            effectiveLang == 'ru'
                ? 'Сейчас режим «Советник»: Panic я '
                    '${AiVoice.ru('сам', 'сама')} не запускаю. Откройте его '
                    'вручную в разделе «Защита» или включите «Ручной».'
                : 'The "Advisor" mode is active: I do not start Panic '
                    'myself. Open it in the Security tab, or choose "Manual".',
            const [],
            speech: effectiveLang == 'ru'
                ? 'Режим «Советник»: Panic запускается вручную.'
                : 'Advisor mode: open Panic yourself.',
          );
        }
        return info(
          _surfaceOpenMessage(effectiveLang,
              surfaceRu: 'Panic', surfaceEn: 'Panic'),
          const [],
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
    // Naming Safe Scan is not a request to run it ("что такое Safe Scan",
    // "Safe Scan нашёл риск"): it needs "запусти / открой / сделай скан",
    // "scan my wallet" or the bare command "скан" / "scan".
    final mentionsSafeScan = lower.contains('скан') ||
        lower.contains('scan') ||
        lower.contains('сафе') ||
        (lower.contains('safe') &&
            !lower.contains('panic') &&
            !lower.contains('паник'));
    final isSafeIntent = (mentionsSafeScan &&
            _safeScanRunRequest.hasMatch(lower)) ||
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
        if (currentMode == AiMode.manual) {
          return info(
            effectiveLang == 'ru'
                ? 'Сейчас режим «Советник»: я могу рассказать о рисках, но '
                    'сканирование ${AiVoice.ru('сам', 'сама')} не запускаю. '
                    'Запустите Safe Scan в разделе «Защита» или включите '
                    '«Ручной».'
                : 'The "Advisor" mode is active: I can explain risks but do '
                    'not run the scan myself. Start Safe Scan in the Security '
                    'tab, or choose "Manual".',
            const [],
            speech: effectiveLang == 'ru'
                ? 'Режим «Советник»: сканирование запускается вручную.'
                : 'Advisor mode: start the scan yourself.',
          );
        }
        return info(
          _surfaceOpenMessage(effectiveLang,
              surfaceRu: 'Safe\u00a0Scan', surfaceEn: 'Safe\u00a0Scan'),
          const [],
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
      if (currentMode == AiMode.manual) {
        return _advisorMarketRefusal(effectiveLang);
      }
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
      if (currentMode == AiMode.manual) {
        return _advisorMarketRefusal(effectiveLang);
      }
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
      if (currentMode == AiMode.manual) {
        return _advisorMarketRefusal(effectiveLang);
      }
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
      if (currentMode == AiMode.manual) {
        return _advisorMarketRefusal(effectiveLang);
      }
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
      if (currentMode == AiMode.manual) {
        return _advisorMarketRefusal(effectiveLang);
      }
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
      if (currentMode == AiMode.manual) {
        return _advisorMarketRefusal(effectiveLang);
      }
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
      if (currentMode == AiMode.manual) {
        return _advisorMarketRefusal(effectiveLang);
      }
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

  /// A request to run or open Safe Scan (used only together with a Safe Scan
  /// word): an action verb, "scan my wallet", or the bare word "скан".
  static final _safeScanRunRequest = RegExp(
    '(^|[^а-яё])(запусти|запустить|запускай|открой|открыть|сделай|сделать|'
    'проведи|провести|начни|начать|покажи|показать|включи|проверь|'
    'просканируй|просканировать|отсканируй|сканируй|сканировать)'
    '([^а-яё]|\$)|'
    r'(^|[^a-z])(run|start|open|launch|show|perform|begin)([^a-z]|$)|'
    r'(^|[^a-z])scan\s+(my|the|this|wallet|approvals?|all|now|it)([^a-z]|$)|'
    r'^[\s.,!]*(safe\s*)?(scan|скан)[\s.,!]*$',
  );

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

  /// Trade imperatives as whole words: "купил" (a story) and "покупка" (a
  /// noun) are not "купи".
  static final _tradeImperativeRu = RegExp(
    '(^|[^а-яё])(купи|купите|покупай|покупайте|продай|продайте|продавай|'
    'обменяй|обменяйте|поменяй|поменяйте|вложи|вложите|инвестируй|'
    'инвестируйте)(?=[^а-яё]|\$)',
  );
  static final _tradeImperativeEn = RegExp(
    r'(^|[^a-z])(buy|sell|purchase|invest)(?=[^a-z]|$)',
  );

  /// Infinitives and "давай купим": a trade only in a request ("хочу купить
  /// BTC", "можешь купить BTC?", "давай купим BTC") or at the start of a
  /// sentence ("Купить BTC на 10$").
  static final _tradeInfinitive = RegExp(
    '(^|[^а-яё])(купить|продать|обменять|поменять|вложить|инвестировать|'
    'купим|продадим|обменяем|поменяем|вложим)(?=[^а-яё]|\$)',
  );
  static final _tradeInfinitiveStart = RegExp(
    '^(купить|продать|обменять|поменять|вложить|инвестировать)'
    '(?=[^а-яё]|\$)',
  );
  static final _wantsTo = RegExp(
    '(^|[^а-яё])(хочу|хотим|хотел|хотела|надо|нужно|давай|давайте)'
    '(?=[^а-яё]|\$)',
  );
  static final _negationBefore = RegExp(
    r"(^|[^а-яёa-z])(не|don't|dont|do not|never|not)\s*$",
  );

  static bool _hasUnnegated(RegExp rx, String lower) {
    for (final m in rx.allMatches(lower)) {
      final verbStart = m.start + (m.group(1)?.length ?? 0);
      if (!_negationBefore.hasMatch(lower.substring(0, verbStart))) {
        return true;
      }
    }
    return false;
  }

  /// Returns true if the user is giving a direct trading command
  /// (buy/sell/swap a specific asset), NOT a general market query.
  ///
  /// Never for a story or a question ("Я вчера купил BTC на 10$", "Не знаю,
  /// стоит ли купить BTC на 10$"): in Full Autonomy this branch can place a
  /// real exchange order. The verbs are whole words, so "купил" is not
  /// "купи".
  static bool _isTradingCommand(String lower) {
    if (IntentParser.isConversational(lower)) return false;
    if (_hasUnnegated(_tradeImperativeRu, lower) ||
        _hasUnnegated(_tradeImperativeEn, lower)) {
      return true;
    }
    if (!_hasUnnegated(_tradeInfinitive, lower)) return false;
    if (IntentParser.isActionRequest(lower) || _wantsTo.hasMatch(lower)) {
      return true;
    }
    return lower
        .split(RegExp(r'[!?;\n]+|\.(?!\d)'))
        .map(IntentParser.withoutLeadIns)
        .any(_tradeInfinitiveStart.hasMatch);
  }

  @visibleForTesting
  static bool isTradingCommandForTest(String text) =>
      _isTradingCommand(text.trim().toLowerCase());

  /// Any word about trading, even in a question ("Сколько BTC я могу
  /// купить?"): such a text is not a plain balance question.
  static bool _mentionsTrading(String lower) {
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

  List<UICommand> _fallbackUiCommandsForText(String input) =>
      UICommandResolver.fallbackUiCommandsForText(input);

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

  // ── Text chat question guard ──────────────────────────────────────────────

  /// A question opener, optionally after a filler ("а", "слушай,", "hey").
  static final _chatQuestionStart = RegExp(
    r'^((а|и|ну|слушай|скажи|скажите|guardian|гардиан|hey|ok|okay|so)[,\s]+)?'
    r'(что|чем|как|почему|отчего|зачем|когда|где|куда|откуда|кто|чей|'
    r'какой|какая|какое|какие|каким|какую|каких|сколько|'
    r'стоит ли|можно ли|нужно ли|надо ли|правда ли|есть ли|'
    r'расскажи|расскажите|объясни|объясните|поясни|поясните|подскажи|'
    r'what|why|how|when|where|who|whose|which|should i|is it|is there|'
    r'are there|do i|does|can i|could i|tell me|explain)'
    r'(?![a-zа-яё])',
  );

  /// A question: a "?" or a sentence that opens with a question word. Lead-ins
  /// that only look like one ("как обычно", "как договаривались", "что ж",
  /// "ну что") do not count.
  static bool _looksLikeChatQuestion(String lower) {
    if (lower.contains('?')) return true;
    return lower
        .split(RegExp(r'[.!?]+'))
        .map(IntentParser.withoutLeadIns)
        .any((part) => part.isNotEmpty && _chatQuestionStart.hasMatch(part));
  }

  /// A question or a story that does not ask for anything.
  static bool _isQuestionOrStory(String lower) =>
      _looksLikeChatQuestion(lower) || IntentParser.isConversational(lower);

  /// Text-chat twin of the voice rule (see `voiceConversationOnly` in
  /// [process]): a question ("Что такое Safe Scan?", "Сколько стоит
  /// отзыв?", "What is Safe Scan?") or a story ("Я вчера купил BTC на 10$")
  /// is conversation and goes to the LLM without opening windows or starting
  /// actions. An explicit request ("открой отправку", "покажи баланс", "купи
  /// BTC на 10$", "ты можешь открыть отправку?", "could you please open
  /// send?", "давай купим BTC на 10$?", "откроешь отправку?") and a balance
  /// question ("сколько у меня USDT?") keep their command routes.
  static bool _isChatConversationOnly(
    String input,
    AssistantInputSource source,
  ) {
    if (source != AssistantInputSource.generalChat &&
        source != AssistantInputSource.marketChat) {
      return false;
    }
    final lower = input.trim().toLowerCase();
    if (lower.isEmpty || !_isQuestionOrStory(lower)) return false;
    if (_isExplicitVoiceActionRequest(lower)) return false;
    if (_isExplicitBalanceReadQuestion(input)) return false;
    return true;
  }

  @visibleForTesting
  static bool isChatConversationOnlyForTest(
    String input, {
    AssistantInputSource source = AssistantInputSource.generalChat,
  }) =>
      _isChatConversationOnly(input, source);

  /// Gives a turn answered without the LLM (canned text, fast path, command
  /// route) to the LLM history, so a follow-up ("а почему?") keeps its
  /// context. LLM turns are recorded by [OpenAIChatService.solve] itself.
  void _rememberAnswer(String input, AssistantResponse response) {
    final answer = response.message.trim().isNotEmpty
        ? response.message
        : response.speechText;
    _openai.rememberTurn(user: input, assistant: answer);
  }

  Future<AssistantResponse> process(
    String input, {
    String? languageCode,
    required AssistantInputSource source,
  }) async {
    final turn = _TurnTrace();
    final response = await _processTurn(
      input,
      languageCode: languageCode,
      source: source,
      turn: turn,
    );
    if (!turn.askedLlm && source != AssistantInputSource.automated) {
      _rememberAnswer(input, response);
    }
    return response;
  }

  Future<AssistantResponse> _processTurn(
    String input, {
    String? languageCode,
    required AssistantInputSource source,
    required _TurnTrace turn,
  }) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return AssistantResponse.error('Input is empty.');
    }

    // 1. Dynamic Language Detection
    final detectedLang = languageCode ?? LanguageDetector.detect(trimmed);
    final lower = trimmed.toLowerCase();

    // An AI confirmation card is open: «да» = tap «Подтвердить» (the PIN
    // still follows), «нет» / «отмена» = cancel.
    final cardAnswer = _cardAnswerFor(lower, source);
    if (cardAnswer != null) {
      AiActionGate.instance.answerByVoice(cardAnswer);
      final isRu = detectedLang.startsWith('ru');
      final msg = cardAnswer
          ? (isRu
              ? 'Подтверждено. Введите ПИН-код на экране.'
              : 'Confirmed. Enter your PIN on the screen.')
          : (isRu
              ? 'Отменено. Ничего не выполнено.'
              : 'Cancelled. Nothing was done.');
      return AssistantResponse.info(msg, speechText: msg);
    }

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
    final voiceConversationOnly = source == AssistantInputSource.voice &&
        !_isExplicitVoiceActionRequest(expanded);
    // Text chat gets the same guard for questions: "Что такое Safe Scan?"
    // must not open the scanner, "Сколько стоит Safe Scan?" must not read
    // out the balance. Explicit requests keep their command routes.
    final conversationOnly =
        voiceConversationOnly || _isChatConversationOnly(expanded, source);
    // -- Pipeline: mode/limits checks -> fast-path -> intent -> LLM --------

    if (_isModeStatusQuestion(expanded)) {
      return _modeContractResponse(detectedLang);
    }

    // Before the limits answer: "разрешённые адреса" contains "разрешен".
    final trustedAnswer = _trustedAddressesFastPath(
      expanded,
      detectedLang,
      conversationOnly: conversationOnly,
    );
    if (trustedAnswer != null) return trustedAnswer;

    if (_isLimitsStatusQuestion(expanded)) {
      return _limitsStatusResponse(detectedLang);
    }

    // ── Amount Fast-Path: intercept "вставь 5" when a modal is open ────────
    final amountFastResult = _tryAmountFastPath(
      lower,
      detectedLang,
      conversationOnly: conversationOnly,
    );
    if (amountFastResult != null) return amountFastResult;

    // ── Modal-open fast-path: intercept "открой отправку" BEFORE IntentParser ──
    // IntentParser would match 'отправ' → sendAsset (empty params) → orchestrate
    // would fail with "не удалось создать транзакцию". This fast-path dispatches
    // the actual UI commands and returns a friendly voice ack.
    if (!conversationOnly) {
      final modalOpenFastPath = _modalOpenFastPath(expanded, detectedLang);
      if (modalOpenFastPath != null) return modalOpenFastPath;
    }

    // A voice balance question is read-only. Give the existing balance fast
    // path first refusal and, even if live portfolio data is unavailable,
    // never coerce the question through the buy/sell-only trade resolver.
    final isVoiceBalanceRead = source == AssistantInputSource.voice &&
        _isExplicitBalanceReadQuestion(expanded);
    if (isVoiceBalanceRead) {
      final balanceFastPath =
          await _fastPathCommand(expanded, detectedLang, source);
      if (balanceFastPath != null) return balanceFastPath;
    }

    // ── Primary OpenAI & Local Fallback voice/chat trade intent pipeline ──────
    // Never for a story or a question ("Я вчера купил BTC на 10$", "Не знаю,
    // стоит ли купить BTC на 10$"): the local fallback reads "купил" as
    // "купи", and in Full Autonomy an exchange order is real. Polite
    // requests ("можешь купить BTC на 10$?") are not questions here.
    final isVoiceOrChat = (source == AssistantInputSource.voice ||
            source == AssistantInputSource.marketChat) &&
        !conversationOnly &&
        !IntentParser.isConversational(expanded);
    if (isVoiceOrChat && !isVoiceBalanceRead) {
      IntentData? resolvedTradeIntent;
      bool hasTradeIntent = false;

      // 1. Primary OpenAI Resolver
      final openaiResult = await _openai.solveTradeIntent(expanded, languageCode: detectedLang);
      if (openaiResult != null) {
        final typeStr = openaiResult['type'];
        final double confidence = (openaiResult['confidence'] ?? 0.0).toDouble();
        // "А можешь купить BTC на 10$?" names the coin and the amount: a
        // polite request, not a question about what the assistant can do.
        final politeTrade = typeStr == 'capabilityQuestion' &&
                IntentParser.isActionRequest(expanded)
            ? MarketVoiceBrain.parseTradeIntent(expanded)
            : null;
        if (politeTrade != null &&
            politeTrade.amount != null &&
            (politeTrade.tokenSymbol?.isNotEmpty ?? false)) {
          hasTradeIntent = true;
          resolvedTradeIntent = politeTrade;
        } else if (typeStr == 'capabilityQuestion' && confidence >= 0.6) {
          final msg = _canTradeAnswer(detectedLang.startsWith('ru'));
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
          return await _handleOnChainTradeIntent(
            resolvedTradeIntent,
            detectedLang,
            source: source,
          );
        }
      }
    }

    final parsedIntent =
        _resolveAddressBookRecipient(IntentParser.parse(expanded));

    if (parsedIntent.type != IntentType.unknown && !conversationOnly) {
      if (parsedIntent.isExecutionIntent &&
          AiControlService.instance.settings.mode == AiMode.manual) {
        return _manualExecutionBlockedResponse(detectedLang);
      }

      // A "go to screen" request while the AI may not open windows (always
      // so in Manual): say so instead of "Opening market." with nothing open.
      if (_navigationOnlyIntents.contains(parsedIntent.type) &&
          !AiControlService.instance.settings.allowedActions
              .contains(AiAction.openWindows)) {
        return _windowsBlockedResponse(detectedLang);
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
        // «Автономный»: a swap with both tokens and the amount runs through
        // the gate (voice / market chat) or comes back as a preview card
        // the chat carries out (general chat), without opening the window.
        // A token it cannot resolve reliably opens the prefilled window.
        if (AiControlService.instance.settings.mode == AiMode.fullAutonomy &&
            source != AssistantInputSource.automated &&
            _isHeadlessCandidate(parsedIntent)) {
          final preview = await _buildSwapPreview(parsedIntent);
          if (preview != null) {
            if (_runsHeadless(source)) {
              return _headlessFromPreview(preview,
                  source: source, lang: detectedLang);
            }
            if (preview.type != ResponseType.preview) {
              // Refused (limits, policy, no route): the reason, never a
              // window around it.
              final msg = _withRaiseHint(
                  preview.message, detectedLang.startsWith('ru'));
              return AssistantResponse(
                message: msg,
                speechText: msg,
                type: preview.type,
              );
            }
            return _enhanceForVoice(preview, languageCode: detectedLang);
          }
        }
        final swapResult =
            await SwapVoiceOrchestrator.instance.handleSwapIntent(
          sourceSymbol: parsedIntent.sourceTokenSymbol,
          targetSymbol: parsedIntent.targetTokenSymbol,
          amount: parsedIntent.amount,
          lang: detectedLang,
        );
        // The prefilled window obeys «Открытие окон» like every other.
        final swapCmds = _windowBundle(swapResult.commands);
        if (swapResult.commands.isNotEmpty && swapCmds.isEmpty) {
          return _windowsBlockedResponse(detectedLang);
        }
        if (swapCmds.isNotEmpty) {
          UICommandBus.instance.dispatchAll(swapCmds);
        }
        return AssistantResponse.info(
          swapResult.speechText,
          speechText: swapResult.speechText,
          commands: swapCmds,
        );
      }

      // «Автономный»: a transfer with a recipient and an amount is carried
      // out by the AI itself through the gate — headless from voice / market
      // chat, as the preview card in the general chat — so the send window
      // is decided against BEFORE anything is dispatched (C11). A revoke
      // never runs this way (C12).
      final aiRunsSend = parsedIntent.type == IntentType.sendAsset &&
          AiControlService.instance.settings.mode == AiMode.fullAutonomy &&
          source != AssistantInputSource.automated &&
          _isHeadlessCandidate(parsedIntent);
      final headlessSend = aiRunsSend && _runsHeadless(source);

      final parsedCommands = aiRunsSend
          ? const <UICommand>[]
          : _commandsAllowedForMode(
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
        if (headlessSend) {
          return _headlessFromPreview(parsedResponse,
              source: source, lang: detectedLang);
        }
        return _enhanceForVoice(
          parsedResponse,
          languageCode: detectedLang,
          // Use permParsedCmds so the response records what was actually dispatched.
          commands: permParsedCmds,
        );
      }
    }

    if (!conversationOnly) {
      final fastPath = await _fastPathCommand(expanded, detectedLang, source);
      if (fastPath != null) {
        return fastPath;
      }
    }

    // LLM fallback — panic/safe/scan are already handled by _fastPathCommand()
    // so they won't reach here via voice. Chat path may still reach LLM.
    // 3. Fetch AI Intent via OpenAI, with optional market context prepend.
    // Market context is compact — only what the assistant needs to reason.
    // Built from cache (no new API calls).
    final enrichedInput = _enrichWithMarketContext(expanded);
    // The LLM keeps its own history of this turn (process() must not add it
    // a second time).
    turn.askedLlm = true;
    final aiResult = await _openai.solve(
      enrichedInput,
      detectedLang,
      !conversationOnly,
    );
    final directive = AssistantDirective.fromJson(aiResult);

    // The model's JSON is untrusted (it may have read a web page or token
    // names): keep only the user-level meaning and re-derive addresses and
    // amounts in the app. See LlmIntentGuard.
    final untrustedContext = aiResult['untrustedContext'] == true;
    final knownAddresses = AddressBookService.instance.entries
        .map((e) => e.address)
        .toList(growable: false);
    // A story or a question that asks for nothing never becomes a money
    // action or opens a window, from any source (the automated one has no
    // chat guard).
    final storyOrQuestion = IntentParser.isConversational(expanded) &&
        !IntentParser.isActionRequest(expanded);
    final modelIntent = conversationOnly ? null : directive.explicitIntent;
    final llmIntent = (modelIntent != null &&
            storyOrQuestion &&
            modelIntent.isExecutionIntent)
        ? null
        : modelIntent;
    final guardedIntent = LlmIntentGuard.sanitize(
      llmIntent,
      userText: expanded,
      untrustedContext: untrustedContext,
      knownAddresses: knownAddresses,
    );
    if (llmIntent != null &&
        llmIntent.isExecutionIntent &&
        guardedIntent == null) {
      return _untrustedExecutionBlockedResponse(detectedLang);
    }
    final effectiveIntent = guardedIntent == null
        ? null
        : _resolveAddressBookRecipient(guardedIntent);
    final llmUiCommands = _guardLlmUiCommands(
      directive.uiCommands,
      userText: expanded,
      untrustedContext: untrustedContext,
      knownAddresses: knownAddresses,
    );

    final mergedUiCommands = (conversationOnly || storyOrQuestion)
        ? const <UICommand>[]
        : _mergeUiCommands(
            _mergeUiCommands(
              llmUiCommands,
              _fallbackUiCommandsForIntent(effectiveIntent),
            ),
            _fallbackUiCommandsForText(expanded),
          );
    final filteredUiCommands = _commandsAllowedForMode(
      effectiveIntent,
      mergedUiCommands,
    );

    if (effectiveIntent != null &&
        effectiveIntent.isExecutionIntent &&
        AiControlService.instance.settings.mode == AiMode.manual) {
      return _manualExecutionBlockedResponse(detectedLang);
    }

    // Dispatch UI commands with unified window-permission filtering.
    // _commandsAllowedForMode handled execution intents; _applyWindowPermissions
    // handles navigate/openModal/dismiss based on openWindows/closeWindows flags.
    // «Автономный»: a transfer or swap the AI can run itself goes through
    // the gate (headless from voice / market chat, the preview card in the
    // general chat) instead of its window, so the window commands are not
    // dispatched at all (C11).
    final aiRunsIntent = effectiveIntent != null &&
        AiControlService.instance.settings.mode == AiMode.fullAutonomy &&
        source != AssistantInputSource.automated &&
        _isHeadlessCandidate(effectiveIntent);
    final headlessIntent = aiRunsIntent && _runsHeadless(source);
    final permFilteredCmds = aiRunsIntent
        ? const <UICommand>[]
        : _applyWindowPermissions(filteredUiCommands);
    if (permFilteredCmds.isNotEmpty) {
      UICommandBus.instance.dispatchAll(permFilteredCmds);
    }

    final String actionName = effectiveIntent != null
        ? effectiveIntent.type.name
        : 'CHAT';

    AssistantSessionContext.instance.update(
      symbol: effectiveIntent?.tokenSymbol,
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
        effectiveIntent == null) {
      String finalDisplay = directive.displayMessage;
      String finalSpeech = directive.speechText;
      if (finalDisplay.isEmpty) {
        finalDisplay = detectedLang == 'ru'
            ? 'Простите, я не совсем ${AiVoice.ru('понял', 'поняла')}.'
            : 'I didn\'t quite catch that.';
        finalSpeech = finalDisplay;
      }
      return AssistantResponse.info(finalDisplay,
          speechText: finalSpeech,
          // Use permFilteredCmds so the response records what was actually dispatched.
          commands: permFilteredCmds);
    }

    // Operator Mode
    final intent = effectiveIntent!;

    if (aiRunsIntent && intent.type == IntentType.swapAsset) {
      final preview = await _buildSwapPreview(intent);
      if (preview != null) {
        if (headlessIntent) {
          return _headlessFromPreview(preview,
              source: source,
              lang: detectedLang,
              preface: directive.displayMessage);
        }
        if (preview.type != ResponseType.preview) {
          // Refused (limits, policy, no route): the reason, never a window.
          final msg = _withRaiseHint(
              preview.message, detectedLang.startsWith('ru'));
          return AssistantResponse(
            message: _withPreface(directive.displayMessage, msg),
            speechText: msg,
            type: preview.type,
          );
        }
        return _enhanceForVoice(preview,
            languageCode: detectedLang,
            displayPreface: directive.displayMessage,
            speechPreface: directive.speechText);
      }
      // A token it cannot resolve reliably: the prefilled window (D17).
      final windowCmds = _windowBundle(filteredUiCommands);
      if (windowCmds.isNotEmpty) {
        UICommandBus.instance.dispatchAll(windowCmds);
      }
      return _unsupportedSwapTokenResponse(
          detectedLang,
          _resolveSwapSide(intent.sourceTokenSymbol ?? '') == null
              ? (intent.sourceTokenSymbol ?? '?')
              : (intent.targetTokenSymbol ?? '?'));
    }

    // Resolve specific tokens if it's a swap to fill missing backend data for demo
    if (intent.type == IntentType.swapAsset &&
        intent.sourceTokenAddress == null) {
      final sourceAddress =
          _resolveTokenAddress(intent.sourceTokenSymbol, detectedLang);
      final targetAddress =
          _resolveTokenAddress(intent.targetTokenSymbol, detectedLang);
      // An empty address is only valid for the chain's native coin (TRX);
      // for anything else it would silently become the native coin.
      if (sourceAddress.isEmpty &&
          !_isActiveNativeSymbol(intent.sourceTokenSymbol)) {
        return _unsupportedSwapTokenResponse(
            detectedLang, intent.sourceTokenSymbol ?? '?');
      }
      if (targetAddress.isEmpty &&
          !_isActiveNativeSymbol(intent.targetTokenSymbol)) {
        return _unsupportedSwapTokenResponse(
            detectedLang, intent.targetTokenSymbol ?? '?');
      }
      final intentMut = IntentData(
        type: IntentType.swapAsset,
        rawInput: intent.rawInput,
        amount: intent.amount,
        amountMode: intent.amountMode,
        slippageBps: intent.slippageBps,
        sourceTokenSymbol: intent.sourceTokenSymbol,
        targetTokenSymbol: intent.targetTokenSymbol,
        sourceTokenAddress: sourceAddress,
        targetTokenAddress: targetAddress,
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

    if (headlessIntent) {
      return _headlessFromPreview(systemResponse,
          source: source,
          lang: detectedLang,
          preface: directive.displayMessage);
    }

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
            ? '${AiVoice.ru('Не смог', 'Не смогла')} разобрать правило. '
                'Попробуйте так:\n'
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
          ? '✓ ${AiVoice.ru('Запомнил', 'Запомнила')}! Когда вы скажете '
              '«$phrase», я буду понимать это как «$meaning».'
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
          ? '✓ ${AiVoice.ru('Забыл', 'Забыла')} правило «$phrase».'
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
      final label = _aiModeLabel(currentMode, isRu: lang == 'ru');
      return AssistantResponse.info(
        lang == 'ru'
            ? 'Макрос «${macro.triggerPhrase}» недоступен в режиме $label.'
            : 'Macro "${macro.triggerPhrase}" is not available in the $label mode.',
      );
    }

    // Build UICommands from macro actions. A macro is the user's own fixed
    // phrase: the windows it opens are marked as the user's ('byUserMacro'),
    // so a Panic opened by «эвакуация» keeps its revoke button after the
    // switch to «Советник».
    final commands = <UICommand>[];
    var modeRaiseBlocked = false;
    AiMode? switchTo;
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
            payload: {...?action.payload, 'byUserMacro': true},
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
          // A phrase may only tighten the mode. Raising it (towards
          // «Автономный») needs PIN in AI Control — never a typed/spoken
          // macro.
          if (targetMode != null) {
            if (targetMode.index <= currentMode.index) {
              if (switchTo == null || targetMode.index < switchTo.index) {
                switchTo = targetMode;
              }
            } else {
              modeRaiseBlocked = true;
            }
          }
      }
    }

    // Windows first, with the permissions in force when the phrase was
    // said; the mode switch after. «эвакуация» used to switch to «Советник»
    // first, which has no «Открытие окон», so Panic never opened.
    final permitted = _windowBundle(commands);
    final windowsDropped = commands.isNotEmpty && permitted.isEmpty;
    if (permitted.isNotEmpty) {
      UICommandBus.instance.dispatchAll(permitted);
    }
    final newMode = switchTo;
    if (newMode != null && newMode != currentMode) {
      unawaited(AiControlService.instance.updateMode(newMode));
    }

    final raiseNote = !modeRaiseBlocked
        ? ''
        : lang == 'ru'
            ? '\nРежим ИИ макросом не повышаю — включите его в «Безопасность → AI Control» (нужен PIN).'
            : '\nI will not raise the AI mode from a macro — enable it in Security → AI Control (PIN required).';
    final windowNote = !windowsDropped
        ? ''
        : lang == 'ru'
            ? '\nОкно я не ${AiVoice.ru('открыл', 'открыла')}: «Открытие окон» '
                'выключено (в режиме «Советник» всегда). Откройте его сами.'
            : '\nI did not open the window: "Open windows" is off (always in '
                'the Advisor mode). Please open it yourself.';
    // The built-in «эвакуация» was saved with the old mode name.
    final description = macro.description ==
            'Panic → отозвать все разрешения → переключить на Manual'
        ? (lang == 'ru'
            ? 'Panic → отозвать все разрешения → режим «Советник»'
            : 'Panic → revoke all approvals → the Advisor mode')
        : macro.description;
    return AssistantResponse(
      message: lang == 'ru'
          ? '⚡ Макрос «${macro.triggerPhrase}»: $description$raiseNote$windowNote'
          : '⚡ Macro "${macro.triggerPhrase}": $description$raiseNote$windowNote',
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

  /// Market commands with a coin and a number are not amounts: "поставь
  /// стоп-лосс на SOL 120", "set stop loss SOL 120", "поставь алерт на BTC
  /// 70000" go on to the TP/SL and alert handlers.
  static final _marketOrderWord = RegExp(
    '(стоп|тейк|алерт)|(^|[^a-z])(stop|take|alert)',
  );

  static bool _isMarketCommandText(String lower) =>
      MarketIntentNormalizer.instance.isMarketCommand(lower) ||
      _marketOrderWord.hasMatch(lower);

  AssistantResponse? _tryAmountFastPath(
    String lower,
    String lang, {
    bool conversationOnly = false,
  }) {
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
      // A stop-loss, take-profit or alert with a coin and a price is not an
      // amount: its own handler in _fastPathCommand answers it.
      if (_isMarketCommandText(lower)) return null;

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

    // A question with the window open ("Сколько стоит отправка USDT?") is
    // conversation: it neither fills the form nor gets the Manual refusal.
    // "5 USDT" and "поставь 10" still fill it.
    if (conversationOnly && !hasAmountVerb && _isQuestionOrStory(lower)) {
      return null;
    }

    if (AiControlService.instance.settings.mode == AiMode.manual) {
      // Manual never fills the form. Only an amount or token instruction
      // gets the refusal; anything else (a question) goes on to its answer.
      final fillsForm = hasAmountVerb ||
          _allNumbersRx.hasMatch(lower) ||
          _containsKnownToken(lower);
      return fillsForm ? _manualExecutionBlockedResponse(lang) : null;
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
          .add(isRu
              ? '${AiVoice.ru('Выбрал', 'Выбрала')} $selectedSymbol.'
              : 'Selected $selectedSymbol.');
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
      AiMode.manual =>
        'Advisor (advice only: the AI opens, prepares and runs nothing)',
      AiMode.guarded =>
        'Manual (the AI prepares windows; the user confirms with the PIN)',
      AiMode.fullAutonomy =>
        'Autonomous (the AI executes within limits, mandate and EPK; '
            'AI action PIN confirmation: ${ai.aiPinConfirm ? 'ON' : 'OFF'})',
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
        .writeln('Mode: $mode | Daily: \$${ai.dailyLimit.toStringAsFixed(0)}');
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
    // Navigation intents come only from explicit phrases ("настройки
    // кошелька", "адресная книга", "история транзакций"), so they open their
    // window here. This used to happen through the broad keyword fallback,
    // which also fired on conversation.
    if (intent is IntentData) {
      switch (intent.type) {
        case IntentType.showAddress:
        case IntentType.receiveAsset:
        case IntentType.showHistory:
        case IntentType.openAddressBook:
        case IntentType.openWalletSettings:
        case IntentType.openMarket:
        case IntentType.openSecurityCenter:
          return UICommandResolver.fallbackUiCommandsForIntent(intent);
        default:
          break;
      }
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

    // 1. Exchange orders only on the user's own request — voice, market
    // chat or general chat (D8). Automated signals never place them.
    if (source == AssistantInputSource.automated) {
      final msg = isRu
          ? 'Торговля CEX поддерживается только по вашей просьбе: голосом или в чате.'
          : 'CEX trading is only supported on your request: by voice or in chat.';
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

    // 3. «Советник»: advice only — the user places the order himself.
    if (mode == AiMode.manual) {
      const msg = 'Advisor mode: the AI only advises.';
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

    // --- «Ручной»: the prefilled order window, the user confirms with PIN ---
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

      // The prepared window obeys «Открытие окон» like every other.
      if (!_dispatchWindow(modalCmd)) {
        return _windowsBlockedResponse(lang);
      }

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
          ? '${AiVoice.ru('Подготовил', 'Подготовила')} ордер на ${isBuy ? 'покупку' : 'продажу'} $symbol на ${exchangeId.toUpperCase()}. Пожалуйста, подтвердите вручную: кнопкой и ПИН-кодом.'
          : 'Prepared trade modal to ${isBuy ? 'buy' : 'sell'} $symbol on ${exchangeId.toUpperCase()}. Please confirm manually, with the button and your PIN.';
      return AssistantResponse.info(
        msg,
        speechText: msg,
        commands: [modalCmd],
      );
    }

    // 4. Resolve exchange («Автономный» only)
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

    // 5. Amount Checks & Conversion Rules («Автономный» only)
    if (intent.amount == null) {
      final msg = isRu ? 'Укажите сумму.' : 'Please specify the amount.';
      final speech = isRu ? 'Сумма?' : 'Amount?';
      return AssistantResponse.info(msg, speechText: speech);
    }

    // For a buy: the quote value to spend. For a sell: the coins to sell.
    final double amt = intent.amount!;
    final double orderAmount;
    if (isBuy) {
      orderAmount = intent.isQuantity ? amt * price : amt;
    } else {
      final baseBalance = await adapter.fetchAssetBalance(symbol);
      if (amt == -1.0) {
        orderAmount = baseBalance;
      } else if (amt < 0.0) {
        orderAmount = baseBalance * amt.abs();
      } else if (intent.isQuantity) {
        orderAmount = amt;
      } else {
        orderAmount = amt / price;
      }
    }

    final settings = AiControlService.instance.settings;

    // 6. Balance Checks («Автономный» only)
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
      if (orderAmount <= 0.0 || baseBalance < orderAmount) {
        final msg = isRu
            ? 'Недостаточный баланс $symbol на ${exchangeId.toUpperCase()}. Доступно: $baseBalance, требуется: $orderAmount'
            : 'Insufficient $symbol balance on ${exchangeId.toUpperCase()}. Available: $baseBalance, required: $orderAmount';
        await MarketMemoryService.instance.record(
          action: 'sell',
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
    }

    // 7. Policy Limits check («Автономный» only)
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

    final txValueUsdt = isBuy ? orderAmount : orderAmount * price;
    final delegation = DelegationController.instance;

    if (isBuy) {
      if (!delegation.canSpend(txValueUsdt)) {
        final msg = isRu
            ? 'Сумма ордера (\$${txValueUsdt.toStringAsFixed(2)}) превышает оставшийся дневной бюджет. ${delegation.usageSummary()} ${_raiseHint(true)}'
            : 'Order value (\$${txValueUsdt.toStringAsFixed(2)}) exceeds remaining daily budget. ${delegation.usageSummary()} ${_raiseHint(false)}';
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

    // Selling the whole balance (or a share of it) always goes through the
    // order window, even in «Автономный» and with the PIN setting off: one
    // misheard "продай всё" must not dump a position (D8).
    final sellsBalanceShare = !isBuy && amt < 0.0;
    if (sellsBalanceShare) {
      final modalCmd = UICommand(
        type: UICommandType.openModal,
        target: 'cex_trade',
        payload: {
          'symbol': symbol,
          'isBuy': isBuy,
          'exchangeId': exchangeId,
          'initialAmount': orderAmount,
          'price': price,
          'quoteAsset': quoteAsset,
        },
      );
      if (!_dispatchWindow(modalCmd)) {
        final msg = isRu
            ? 'Продажу всего баланса или его доли вы подтверждаете в окне '
                'ордера, а открыть его я сейчас не могу: «Открытие окон» '
                'выключено. Откройте ордер сами на экране рынка.'
            : 'Selling all or a share of a balance is confirmed in the order '
                'window, and I cannot open it now: "Open windows" is off. '
                'Open the order yourself on the Market screen.';
        return AssistantResponse.info(msg, speechText: msg);
      }

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
          ? '${AiVoice.ru('Подготовил', 'Подготовила')} ордер на продажу $symbol на ${exchangeId.toUpperCase()}. Пожалуйста, подтвердите вручную: продажу всего баланса или его доли я без вас не выполняю.'
          : 'Prepared trade modal to sell $symbol on ${exchangeId.toUpperCase()}. Please confirm manually: I never sell all or a share of a balance without you.';
      return AssistantResponse.info(
        msg,
        speechText: msg,
        commands: [modalCmd],
      );
    }

    // 8. «Автономный»: through AiActionGate — the card + PIN (the setting ON,
    // the default) or by itself within the limits (OFF); never above a limit
    // or outside «AI Мандат» (D5–D7).
    final amountLabel = isBuy
        ? '${_fmtAmount(orderAmount)} $quoteAsset'
        : '${_fmtAmount(orderAmount)} $symbol (≈ ${txValueUsdt.toStringAsFixed(2)} $quoteAsset)';
    final summary = ExchangeOrderService.aiOrderSummary(
      exchangeId: exchangeId,
      symbol: symbol,
      isBuy: isBuy,
      valueUsd: txValueUsdt,
      title: _cexOrderTitle(isBuy, symbol, exchangeId),
      amountLabel: amountLabel,
      feeLabel: LocalizationService.instance
          .t('aiCexFeeLabel', {'default': '≈0.1% exchange fee'}),
      source: source.name,
    );

    final pre = AiActionGate.instance.precheck(summary);
    if (!pre.mayExecute) {
      final msg = pre.reason ??
          (isRu
              ? 'Этот ордер я выставить не могу.'
              : 'I cannot place this order.');
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
    if (AiActionGate.instance.hasOpenCard) return _busyResponse(isRu);

    Future<AssistantResponse> run({required bool background}) =>
        _runGatedCexOrder(
          summary: summary,
          exchangeId: exchangeId,
          symbol: symbol!,
          isBuy: isBuy,
          orderAmount: orderAmount,
          price: price,
          quoteAsset: quoteAsset,
          source: source,
          modeStr: modeStr,
          lang: lang,
          rawInput: intent.rawInput,
          background: background,
        );

    // The card + PIN may take longer than the 30 s voice turn: never wait
    // for them inside it (D15). The result comes as the order window
    // (success) or a line on the screen, plus «ИИ выполнил: …».
    final needsCard = settings.pinRequiredForAi ||
        !IBITIVaultService.instance.isUnlocked;
    if (needsCard) {
      _trackPending(run(background: true).then((_) {}));
      final exchange = _exchangeLabel(exchangeId);
      final msg = isRu
          ? 'Карточка ордера на экране: ${isBuy ? 'покупка' : 'продажа'} '
              '$symbol на $exchange, $amountLabel. Подтвердите её кнопкой или '
              'словом «да» и введите ПИН-код.'
          : 'The order card is on the screen: ${isBuy ? 'buy' : 'sell'} '
              '$symbol on $exchange, $amountLabel. Confirm it with the button '
              'or by saying "yes", then enter your PIN.';
      final speech = isRu
          ? 'Подтвердите на экране: кнопкой или словом «да», затем ПИН-код.'
          : 'Please confirm on the screen, then enter your PIN.';
      return AssistantResponse.info(msg, speechText: speech);
    }
    return run(background: false);
  }

  /// The gate, then the order, then the report (audit + «ИИ выполнил»).
  /// [background]: nobody waits for the answer (the voice turn has ended),
  /// so a refusal or a failure is also shown as a line on the screen.
  Future<AssistantResponse> _runGatedCexOrder({
    required AiActionSummary summary,
    required String exchangeId,
    required String symbol,
    required bool isBuy,
    required double orderAmount,
    required double price,
    required String quoteAsset,
    required AssistantInputSource source,
    required String modeStr,
    required String lang,
    required String rawInput,
    required bool background,
  }) async {
    final isRu = lang.startsWith('ru');
    final gate = AiActionGate.instance;

    AssistantResponse notDone(String msg, {String memory = 'blocked'}) {
      MarketMemoryService.instance.record(
        action: isBuy ? 'buy' : 'sell',
        symbol: symbol,
        source: source.name,
        aiMode: modeStr,
        result: memory,
        amount: orderAmount,
        priceThen: price,
        reason: msg,
        rawInput: rawInput,
      );
      if (background) _notifyInApp(msg);
      return AssistantResponse.info(msg, speechText: msg);
    }

    AiGateDecision decision;
    try {
      decision = await gate.confirm(summary);
    } catch (e) {
      _log.e('AI order confirmation failed', e);
      return notDone(isRu
          ? 'Не удалось показать подтверждение. Ордер не выставлен.'
          : 'Could not show the confirmation. No order was placed.');
    }
    if (!decision.mayExecute) {
      final msg = decision.reason ??
          (isRu
              ? 'Ордер не выставлен.'
              : 'No order was placed.');
      return notDone(msg,
          memory: decision.outcome == AiGateOutcome.cancelled
              ? 'cancelled'
              : 'blocked');
    }
    if (!decision.matches(summary)) {
      gate.release(decision);
      return notDone(isRu
          ? 'Подтверждение не совпало с ордером. Ордер не выставлен.'
          : 'The confirmation does not match this order. No order was placed.');
    }

    ExchangeOrderResult orderResult;
    try {
      orderResult = await ExchangeOrderService.instance.placeMarketOrder(
        exchangeId: exchangeId,
        symbol: symbol,
        isBuy: isBuy,
        amount: orderAmount,
        price: price,
        source: source.name,
        aiGate: decision,
      );
    } catch (e) {
      orderResult = ExchangeOrderResult(
          isSuccess: false, errorMessage: 'Execution error: $e');
    }

    try {
      await gate.reportExecuted(
        summary,
        decision,
        success: orderResult.isSuccess,
        detail: orderResult.isSuccess
            ? (orderResult.orderId == null ? null : '#${orderResult.orderId}')
            : orderResult.errorMessage,
        historyId: orderResult.historyId,
      );
    } catch (e) {
      _log.w('AI order report failed: $e');
      gate.release(decision);
    }

    if (orderResult.isSuccess) {
      final successMsg = isRu
          ? 'Ордер успешно выполнен на ${exchangeId.toUpperCase()}! ID ордера: ${orderResult.orderId}'
          : 'Order executed successfully on ${exchangeId.toUpperCase()}! Order ID: ${orderResult.orderId}';

      final speechMsg = isRu
          ? 'Ордер исполнен, удачных торгов.'
          : 'Order executed, happy trading.';

      final modalCmd = UICommand(
        type: UICommandType.openModal,
        target: 'cex_trade',
        payload: {
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
          if (orderResult.historyId != null)
            'historyId': orderResult.historyId,
        },
      );
      // The result window obeys «Открытие окон»; the notification and the
      // history entry are there either way.
      final shown = _dispatchWindow(modalCmd);

      return AssistantResponse(
        message: successMsg,
        speechText: speechMsg,
        type: ResponseType.info,
        uiCommands: shown ? [modalCmd] : const [],
      );
    }

    final failure = _cexFailureResponse(
      orderResult.errorMessage ?? '',
      isRu: isRu,
      exchangeId: exchangeId,
      orderAmount: orderAmount,
    );
    if (background) _notifyInApp(failure.speechText);
    return failure;
  }

  /// A failed exchange order, said in the user's language.
  AssistantResponse _cexFailureResponse(
    String raw, {
    required bool isRu,
    required String exchangeId,
    required double orderAmount,
  }) {
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
    // Daily budget exceeded
    else if (raw.contains('daily budget') || raw.contains('dailyLimit')) {
      displayMsg = isRu
          ? 'Превышен дневной лимит торговли. ${_raiseHint(true)}'
          : 'Daily trading limit exceeded. ${_raiseHint(false)}';
      speechMsg = displayMsg;
    }
    // Policy / AI limits block
    else if (raw.contains('Blocked by AI Policy') || raw.contains('Kill Switch')) {
      displayMsg = isRu
          ? 'Ордер заблокирован политикой безопасности. ${_raiseHint(true)}'
          : 'Order blocked by security policy. ${_raiseHint(false)}';
      speechMsg = displayMsg;
    }
    // Per-tx limit
    else if (raw.contains('single transaction limit') || raw.contains('perTxLimit')) {
      displayMsg = isRu
          ? 'Сумма превышает лимит на одну сделку. ${_raiseHint(true)}'
          : 'Amount exceeds per-transaction limit. ${_raiseHint(false)}';
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

  static String _exchangeLabel(String exchangeId) =>
      switch (exchangeId.toLowerCase()) {
        'mexc' => 'MEXC',
        'binance' => 'Binance',
        'gateio' || 'gate.io' => 'Gate.io',
        'okx' => 'OKX',
        _ => exchangeId.toUpperCase(),
      };

  /// The card / notification title, in the app language.
  static String _cexOrderTitle(bool isBuy, String symbol, String exchangeId) {
    final ex = _exchangeLabel(exchangeId);
    final t = LocalizationService.instance;
    return isBuy
        ? t.t('aiCexBuyTitle', {
            'symbol': symbol,
            'exchange': ex,
            'default': 'Buy $symbol on $ex',
          })
        : t.t('aiCexSellTitle', {
            'symbol': symbol,
            'exchange': ex,
            'default': 'Sell $symbol on $ex',
          });
  }

  /// 20 → '20', 0.5 → '0.5', 0.00012345 → '0.00012345'.
  static String _fmtAmount(double v) {
    if (v == 0) return '0';
    final digits = v.abs() >= 1 ? 4 : 8;
    var s = v.toStringAsFixed(digits);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '');
      if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    }
    return s;
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

  /// A buy or a sell of a wallet (non-exchange) coin, from any source.
  ///
  /// «Советник»: the plan as advice only. «Ручной»: the prefilled trade
  /// window with the quote requested; the user confirms with the PIN.
  /// «Автономный»: the swap is built on the active network and carried out
  /// through [AiActionGate] (voice / market chat) or shown as a preview
  /// card the chat carries out (general chat). Selling all or a share of a
  /// balance keeps the window (C13); a coin the app cannot resolve reliably
  /// opens the prefilled window (D17); a refusal over a limit never does.
  Future<AssistantResponse> _handleOnChainTradeIntent(
    IntentData intent,
    String lang, {
    required AssistantInputSource source,
    MarketAsset? asset,
  }) async {
    final isRu = lang.startsWith('ru');
    final symbol = intent.tokenSymbol!.toUpperCase();
    final markets = MarketDataService.instance.cachedMarkets;
    var resolved = asset ??
        markets.cast<MarketAsset?>().firstWhere(
              (a) => a!.symbol.toUpperCase() == symbol,
              orElse: () => null,
            );

    // A real price only: never size a trade from a guessed one.
    final focus = ScreenContextService.instance;
    final focusedPrice = focus.focusedSymbol?.toUpperCase() == symbol
        ? focus.focusedPrice
        : null;
    final double? realPrice = (resolved != null && resolved.price > 0)
        ? resolved.price
        : ((focusedPrice != null && focusedPrice > 0) ? focusedPrice : null);

    if (resolved == null) {
      // For the plan text only.
      final price = realPrice ?? 1.0;
      resolved = MarketAsset(
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
    final isBuy = direction == TradingDirection.buy;

    final plan = TradingPlanBuilder.build(
      asset: resolved,
      direction: direction,
      settings: aiSettings,
    );

    final fullPlan = _buildTradingPlanBriefing(plan, lang, short: false);
    final voicePlan = _buildTradingPlanBriefing(plan, lang, short: true);

    if (aiSettings.mode == AiMode.manual) {
      return AssistantResponse.info(fullPlan + _advisorPlanNote(lang),
          speechText: voicePlan);
    }

    final amount = intent.amount;
    // «всё» / «половину» come as -1 / -0.5 (MarketVoiceBrain).
    final sellsShare = !isBuy && amount != null && amount < 0;
    String note = '';

    if (aiSettings.mode == AiMode.fullAutonomy &&
        source != AssistantInputSource.automated &&
        amount != null &&
        amount > 0) {
      final built = AutomationIntentBuilder.buildTrade(
        symbol: symbol,
        isBuy: isBuy,
        amountUsd: intent.isQuantity ? null : amount,
        quantity: intent.isQuantity ? amount : null,
        priceUsd: realPrice,
      );
      if (built is AutomationIntentReady) {
        final preview = await _controller.requestSwapPreview(built.intent);
        if (source == AssistantInputSource.generalChat) {
          // The chat shows the preview card and carries it out through the
          // gate; a refusal is said with its reason.
          if (preview.type == ResponseType.preview &&
              preview.swapPlan != null) {
            return _enhanceForVoice(preview,
                languageCode: lang, displayPreface: fullPlan);
          }
          final msg = _withRaiseHint(preview.message, isRu);
          return AssistantResponse(
            message: '$fullPlan\n\n$msg',
            speechText: msg,
            type: preview.type == ResponseType.error
                ? ResponseType.error
                : ResponseType.info,
          );
        }
        return _headlessFromPreview(preview,
            source: source, lang: lang, preface: fullPlan);
      }
      final why = built is AutomationIntentBlocked ? built.reason : '';
      note = isRu
          ? '\n\n${AiVoice.ru('Сам', 'Сама')} выполнить не могу ($why). '
              'Открываю заполненное окно — подтвердите его ПИН-кодом.'
          : "\n\nI can't carry this out myself ($why). Opening the filled-in "
              'window: confirm it with your PIN.';
    } else if (sellsShare) {
      note = isRu
          ? '\n\nПродажу всего баланса или его доли вы подтверждаете в окне.'
          : '\n\nSelling all or a share of a balance is confirmed in the '
              'window.';
    }

    // «Ручной» (and the fallbacks above): the prefilled window + quote.
    final commands = <UICommand>[
      UICommand(
        type: UICommandType.showTradingPlan,
        payload: {'plan': plan},
      ),
      UICommand(
        type: UICommandType.openModal,
        target: isBuy ? 'wallet_buy' : 'wallet_sell',
      ),
    ];

    if (!isBuy) {
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

    // The amount field is in the FROM token: USDT for a buy, the coin for
    // a sell. Dollars and coins are converted with a real price only.
    double? fill;
    if (amount != null && amount > 0) {
      if (isBuy) {
        fill = intent.isQuantity
            ? (realPrice != null ? amount * realPrice : null)
            : amount;
      } else {
        fill = intent.isQuantity
            ? amount
            : (realPrice != null ? amount / realPrice : null);
      }
    }
    if (fill != null && fill > 0 && fill.isFinite) {
      commands.add(UICommand(
        type: UICommandType.fillField,
        target: 'swap_amount',
        payload: {'value': _fmtAmount(fill)},
      ));
      // «Ручной» prepares everything: the quote is requested too.
      commands.add(const UICommand(
        type: UICommandType.executeAction,
        target: 'wallet_swap_quote',
      ));
    }

    final permCmds = _windowBundle(commands);
    if (permCmds.isNotEmpty) {
      UICommandBus.instance.dispatchAll(permCmds);
      MarketMemoryService.instance.record(
        action: isBuy ? 'buy' : 'sell',
        symbol: symbol,
        source: source.name,
        aiMode: aiSettings.mode.name,
        result: 'opened_form',
        amount: amount,
        priceThen: realPrice,
        rawInput: intent.rawInput,
      );
    }
    final opened = permCmds.any((c) => c.type == UICommandType.openModal);
    if (!opened) {
      note = isRu
          ? '\n\nОткрыть окно ${AiVoice.ru('сам', 'сама')} не могу: в AI-Центре '
              'выключено «Открытие окон». Откройте покупку или продажу в '
              'кошельке сами.'
          : '\n\nI cannot open the window myself: "Open windows" is off in AI '
              'Center. Open the buy or sell window in the wallet yourself.';
    } else if (note.isEmpty) {
      note = isRu
          ? '\n\n🛡️ Открываю заполненное окно. Подтвердите его ПИН-кодом.'
          : '\n\n🛡️ Opening the filled-in window. Confirm it with your PIN.';
    }

    return AssistantResponse.info(
      fullPlan + note,
      speechText: voicePlan,
      commands: permCmds,
    );
  }
}

/// Per-turn trace for [GuardianAssistantService.process]: whether the LLM
/// was asked (it keeps its own history of that turn).
class _TurnTrace {
  bool askedLlm = false;
}
