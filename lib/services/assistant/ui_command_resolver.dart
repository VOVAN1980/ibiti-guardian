import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_bus.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/intents/intent_parser.dart';

/// Central firewall for all UI commands.
///
/// Every UI command — from fast-path, LLM, IntentParser, or macros —
/// MUST pass through [UICommandResolver] before dispatch.
/// This guarantees unified permission enforcement (mode + window rights).
///
/// Extracted from [GuardianAssistantService] as part of P3-1 decomposition.
class UICommandResolver {
  UICommandResolver._();

  // ── Permission Filtering ──────────────────────────────────────────────────

  /// Filters commands based on current AI mode.
  /// In Manual mode, execution-intent commands are blocked entirely.
  static List<UICommand> commandsAllowedForMode(
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
  /// permissions. This is the core security gate — no path may bypass it.
  static List<UICommand> applyWindowPermissions(List<UICommand> commands) {
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

  /// Whether the current mode+permissions allow opening windows/modals.
  static bool get canOpenWindows {
    return AiControlService.instance.settings.allowedActions
        .contains(AiAction.openWindows);
  }

  /// Whether the current mode+permissions allow closing/dismissing windows.
  static bool get canCloseWindows {
    return AiControlService.instance.settings.allowedActions
        .contains(AiAction.closeWindows);
  }

  /// Full resolve pipeline: mode filter → window permissions → dispatch.
  /// Returns the list of commands that were actually dispatched.
  static List<UICommand> resolveAndDispatch({
    required IntentData? intent,
    required List<UICommand> commands,
  }) {
    final modeFiltered = commandsAllowedForMode(intent, commands);
    final permitted = applyWindowPermissions(modeFiltered);
    if (permitted.isNotEmpty) {
      UICommandBus.instance.dispatchAll(permitted);
    } else {}
    return permitted;
  }

  // ── Command Merging ───────────────────────────────────────────────────────

  /// Merges two lists of UI commands, deduplicating by type+target+payload.
  static List<UICommand> mergeUiCommands(
    List<UICommand> primary,
    List<UICommand> fallback,
  ) {
    final merged = <UICommand>[];
    for (final command in [...primary, ...fallback]) {
      final duplicate = merged.any(
        (existing) =>
            existing.type == command.type &&
            existing.target == command.target &&
            _payloadEquals(existing.payload, command.payload),
      );
      if (!duplicate) {
        merged.add(command);
      }
    }
    return merged;
  }

  static bool _payloadEquals(
    Map<String, dynamic>? a,
    Map<String, dynamic>? b,
  ) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  // ── Fallback Commands ─────────────────────────────────────────────────────

  /// Returns fallback UI commands based on parsed intent type.
  static List<UICommand> fallbackUiCommandsForIntent(IntentData? intent) {
    if (intent == null) return const [];

    switch (intent.type) {
      case IntentType.showBalances:
      case IntentType.showWalletCards:
        // Informational — AI answers verbally, no navigation.
        return const [];
      case IntentType.showAddress:
        return const [
          UICommand(type: UICommandType.navigate, target: 'wallet'),
          UICommand(type: UICommandType.openModal, target: 'wallet_receive'),
        ];
      case IntentType.receiveAsset:
        return const [
          UICommand(type: UICommandType.navigate, target: 'wallet'),
          UICommand(type: UICommandType.openModal, target: 'wallet_receive'),
        ];
      case IntentType.showHistory:
        return const [
          UICommand(type: UICommandType.navigate, target: 'wallet'),
          UICommand(type: UICommandType.openModal, target: 'wallet_history'),
        ];
      case IntentType.openAddressBook:
        return const [
          UICommand(type: UICommandType.navigate, target: 'wallet'),
          UICommand(
              type: UICommandType.openModal, target: 'wallet_address_book'),
        ];
      case IntentType.openWalletSettings:
        return const [
          UICommand(type: UICommandType.navigate, target: 'wallet'),
          UICommand(type: UICommandType.openModal, target: 'wallet_settings'),
        ];
      case IntentType.openMarket:
        return const [
          UICommand(type: UICommandType.navigate, target: 'market'),
        ];
      case IntentType.openSecurityCenter:
        return const [
          UICommand(type: UICommandType.navigate, target: 'security_center'),
        ];
      case IntentType.scanApprovals:
        // scanApprovals → open Safe Scan modal (NOT security_center navigate)
        return const [
          UICommand(type: UICommandType.openModal, target: 'safe'),
        ];
      case IntentType.revokeApproval:
        // revokeApproval → open Panic / Revoke modal (NOT security_center navigate)
        return const [
          UICommand(type: UICommandType.openModal, target: 'panic'),
        ];
      case IntentType.sendAsset:
        return [
          const UICommand(type: UICommandType.navigate, target: 'wallet'),
          const UICommand(type: UICommandType.openModal, target: 'wallet_send'),
          if (intent.tokenSymbol != null && intent.tokenSymbol!.isNotEmpty)
            UICommand(
              type: UICommandType.selectToken,
              target: 'send_token',
              payload: {'symbol': intent.tokenSymbol},
            ),
          if (intent.toAddress != null && intent.toAddress!.isNotEmpty)
            UICommand(
              type: UICommandType.fillField,
              target: 'send_address',
              payload: {'value': intent.toAddress},
            ),
          if (intent.amount != null)
            UICommand(
              type: UICommandType.fillField,
              target: 'send_amount',
              payload: {'value': intent.amount!.toString()},
            ),
          if (intent.toAddress != null &&
              intent.toAddress!.isNotEmpty &&
              intent.amount != null)
            const UICommand(
              type: UICommandType.executeAction,
              target: 'wallet_send_preview',
            ),
        ];
      case IntentType.swapAsset:
        return [
          const UICommand(type: UICommandType.navigate, target: 'wallet'),
          const UICommand(type: UICommandType.openModal, target: 'wallet_swap'),
          if (intent.sourceTokenSymbol != null &&
              intent.sourceTokenSymbol!.isNotEmpty)
            UICommand(
              type: UICommandType.selectToken,
              target: 'swap_from_token',
              payload: {'symbol': intent.sourceTokenSymbol},
            ),
          if (intent.targetTokenSymbol != null &&
              intent.targetTokenSymbol!.isNotEmpty)
            UICommand(
              type: UICommandType.selectToken,
              target: 'swap_to_token',
              payload: {'symbol': intent.targetTokenSymbol},
            ),
          if (intent.amount != null)
            UICommand(
              type: UICommandType.fillField,
              target: 'swap_amount',
              payload: {'value': intent.amount!.toString()},
            ),
          if (intent.sourceTokenSymbol != null &&
              intent.sourceTokenSymbol!.isNotEmpty &&
              intent.targetTokenSymbol != null &&
              intent.targetTokenSymbol!.isNotEmpty &&
              intent.amount != null)
            const UICommand(
              type: UICommandType.executeAction,
              target: 'wallet_swap_quote',
            ),
        ];
      case IntentType.showRisks:
        // Informational — AI reports risks verbally, no auto-navigation.
        // User must say "открой security center" explicitly.
        return const [];
      case IntentType.buyAsset:
      case IntentType.sellAsset:
        return const [];
      case IntentType.unknown:
        return const [];
    }
  }

  /// Safety net for the LLM path: opens a window only when the user's own
  /// words clearly ask for it — "открой / покажи / перейди / open / show…"
  /// or an unambiguous command ("отправь деньги", "отзови разрешения").
  /// Questions and conversation open nothing: "я в панике, рынок падает"
  /// used to open the Panic window, "что такое политика лимитов?" Policy,
  /// "как обменять BNB?" the swap window. The model's own uiCommands still
  /// apply when it decides a window is wanted.
  static List<UICommand> fallbackUiCommandsForText(String input) {
    final lower = input.toLowerCase().trim();
    if (lower.isEmpty) return const [];
    if (AiControlService.instance.settings.mode == AiMode.manual &&
        (lower.contains('send') ||
            lower.contains('swap') ||
            lower.contains('отправ') ||
            lower.contains('обмен'))) {
      return const [];
    }

    final asksToOpen = _matchesAnyPhrase(lower, _openVerbs);
    if (!asksToOpen && IntentParser.isConversational(lower)) return const [];
    bool openAnd(List<String> words) =>
        asksToOpen && _matchesAnyPhrase(lower, words);

    const wallet = UICommand(type: UICommandType.navigate, target: 'wallet');
    UICommand modal(String target) =>
        UICommand(type: UICommandType.openModal, target: target);

    // Trusted addresses (the AI whitelist) come before the generic
    // "адрес / address" rule below, which would open Receive instead.
    if (mentionsTrustedList(lower)) {
      return asksToOpen ? [modal('trusted_addresses')] : const [];
    }

    // Address book before "адрес": "адресную книгу" contains "адрес".
    if (openAnd(['адресн', 'контакт', 'address book', 'contacts'])) {
      return [wallet, modal('wallet_address_book')];
    }

    // Balance: the AI answers; only "открой/покажи баланс" goes to Wallet.
    if (openAnd(['баланс', 'balance']) && !lower.contains('истор')) {
      return const [wallet];
    }

    // Address / receive
    if (_matchesAnyPhrase(lower, [
          'мой адрес',
          'покажи адрес',
          'my address',
          'show address',
          'show my address',
        ]) ||
        openAnd(['адрес', 'address', 'получени', 'receive', 'пополнени'])) {
      return [wallet, modal('wallet_receive')];
    }
    if (_matchesAnyPhrase(lower, [
      'хочу получить',
      'получить крипту',
      'получить токены',
      'receive crypto',
      'receive tokens',
      'receive funds',
    ])) {
      return [wallet, modal('wallet_receive')];
    }

    // Send
    if (_matchesAnyPhrase(lower, [
          'отправь токены',
          'отправь деньги',
          'отправь крипту',
          'отправь монеты',
          'хочу отправить',
          'send tokens',
          'send crypto',
          'send funds',
        ]) ||
        openAnd(['отправк', 'окно отправки', 'send window'])) {
      return [wallet, modal('wallet_send')];
    }

    if (openAnd(['центр безопасности', 'security center', 'безопасност'])) {
      return const [
        UICommand(type: UICommandType.navigate, target: 'security_center'),
      ];
    }

    if (openAnd(['рынок', 'market'])) {
      return const [UICommand(type: UICommandType.navigate, target: 'market')];
    }

    if (openAnd(['политик', 'policy', 'лимит', 'limits'])) {
      return [modal('policy_limits')];
    }

    if (openAnd(['ai center', 'центр ai', 'центр ии', 'ai control',
      'управление ии', 'управление ai'])) {
      return [modal('ai_control')];
    }

    if (openAnd(['epk', 'епк'])) {
      return [modal('epk_control')];
    }

    if (openAnd(['аудит', 'audit'])) {
      return [modal('audit_history')];
    }

    // History
    if (_matchesAnyPhrase(lower, [
          'покажи историю',
          'show history',
          'show my history',
        ]) ||
        openAnd(['истори', 'операци', 'транзакци', 'history', 'transactions'])) {
      return [modal('wallet_history')];
    }

    if (openAnd(['адресн', 'контакт', 'address book', 'contacts'])) {
      return [wallet, modal('wallet_address_book')];
    }

    if (openAnd(['настройки кошел', 'настройки кошёл', 'wallet settings'])) {
      return [wallet, modal('wallet_settings')];
    }

    // Swap
    if (_matchesAnyPhrase(lower, ['обменяй', 'хочу обменять', 'swap tokens']) ||
        openAnd(['обмен', 'swap'])) {
      return [modal('wallet_swap')];
    }

    // Panic / revoke: only as a clear request.
    if (_matchesAnyPhrase(lower, [
          'режим паники',
          'кнопка паники',
          'кнопку паники',
          'panic mode',
          'panic button',
        ]) ||
        openAnd(['паник', 'panic']) ||
        (_matchesAnyPhrase(lower, ['отзови', 'отозвать', 'revoke']) &&
            _matchesAnyPhrase(
                lower, ['разрешен', 'доступ', 'approval', 'allowance']))) {
      return [modal('panic')];
    }

    // Safe scan
    if ((lower.contains('скан') && lower.contains('кошел')) ||
        (lower.contains('scan') && lower.contains('wallet')) ||
        (lower.contains('провер') && lower.contains('разрешен')) ||
        (lower.contains('check') && lower.contains('approval')) ||
        lower.contains('safe review') ||
        lower.contains('безопасный режим')) {
      return [modal('safe')];
    }

    return const [];
  }

  /// The one phrase rule for "trusted addresses" (the AI whitelist), shared
  /// by every assistant layer. Expects lower-case text. [contactLabels] are
  /// the address-book names: naming a contact ("удали MEXC из белого
  /// списка") makes an ambiguous "white list" phrase about this list.
  ///
  /// False for transfers and trades that merely mention the list ("переведи
  /// 10 USDT на доверенный адрес"): those keep their normal money flow.
  static bool mentionsTrustedList(
    String lower, {
    Iterable<String> contactLabels = const [],
  }) {
    if (looksLikeMoneyCommand(lower)) return false;
    if (_trustedListPattern.hasMatch(lower)) return true;
    if (!_ambiguousListPattern.hasMatch(lower)) return false;
    final namesContact = contactLabels.any((label) {
      final l = label.trim().toLowerCase();
      return l.length >= 2 && lower.contains(l);
    });
    // Otherwise "белый список" may be an exchange's IP / API whitelist or
    // the AI's allowed coins, networks and actions.
    return namesContact || !_otherWhitelistContext.hasMatch(lower);
  }

  /// A transfer, swap or trade: a money imperative ("отправь", "закинь",
  /// "send …"), or any money verb together with an amount ("можешь
  /// перевести 10 USDT", "хочу отправить всё"). "Кому ты можешь
  /// переводить?" has no amount and stays a question.
  static bool looksLikeMoneyCommand(String lower) =>
      _moneyImperative.hasMatch(lower) ||
      (_moneyStem.hasMatch(lower) && _amount.hasMatch(lower));

  static const _ru = 'а-яёіїєґ';

  static final _moneyImperative = RegExp(
    '(^|[^$_ru])(отправь|отправьте|переведи|переведите|перекинь|закинь|'
    'скинь|пошли|перешли|вышли|купи|продай|обменяй|поменяй|свапни|'
    'відправ|відправте|надішли|переказ|переведіть)([^$_ru]|\$)|'
    r'^(please\s+|ok(ay)?\s+|hey\s+\w+\s+)?(send|transfer|pay|buy|sell|swap|move)\s',
  );

  static final _moneyStem = RegExp(
    r'отправ|перев[её]?д|перевест|перекин|закин|скин|пошл|перешл|вышл|'
    r'купи|купит|прода|обмен|поменя|свап|відправ|надісл|надішл|переказ|'
    r'(^|[^a-z])(send|sending|transfer|pay|move|buy|sell|swap)([^a-z]|$)',
  );

  static final _amount = RegExp(
    '(^|[\\s\$])\\d+([.,]\\d+)?([\\s%]|\$)|'
    '(^|[^$_ru])(все|всё|весь|половин\\S*|усе|все)([^$_ru]|\$)|'
    r'(^|[^a-z])(all|half|everything)([^a-z]|$)',
  );

  static final _trustedListPattern = RegExp(
    '(доверенн(ый|ая|ое|ые|ого|ому|ым|ыми|ых|ом|ую)\\s+'
    '(адрес|контакт|спис|кошел|получател))|'
    '(^|[^$_ru])(в|из|к|среди)\\s+доверенн(ые|ых|ым)(?!\\s+лиц)|'
    'адрес\\S*\\s+(\\S+\\s+)?доверенн(ый|ые|ых|ым|ыми|ого|ом|ая|ую)'
    '(?!\\s+лиц)|'
    'список\\s+доверенн|'
    'адрес\\S*\\s+(из|в)\\s+бел(ого|ом|ый)\\s+спис|'
    'кому\\s+(ты|ии)\\s+(можешь|может|можно)\\s+(перевод|перевест|отправ)|'
    'довірен\\S*\\s+(адрес|контакт|спис)|'
    r'(who|where)\s+can\s+you\s+(send|transfer)|'
    r'trusted\s+(address|contact|list|recipient|wallet)',
  );

  static final _ambiguousListPattern = RegExp(
    r'бел(ый|ого|ом|ому)\s+спис|вайт\s*-?\s*лист|'
    r'разреш[её]нн\S*\s+адрес|'
    r'адрес\S*\s+(\S+\s+)?разреш[её]н([ыао]|\s|$|[,.?!])|'
    r'біл(ий|ого|ому)\s+спис|'
    r'trust\s*list|white\s*-?\s*list|allow\s*-?\s*list',
  );

  static final _otherWhitelistContext = RegExp(
    r'(^|[^a-z])(ip|api|key|keys|exchange|mexc|gate|gateio|binance|okx|'
    r'bybit|coin|coins|token|tokens|action|actions|network|networks|pair|'
    r'pairs|venue|venues|withdraw\w*)([^a-z]|$)|'
    '(^|[^$_ru])(ключ\\S*|апи|айпи|ип|бирж\\S*|бинанс\\S*|мекс\\S*|'
    'гейт\\S*|окх|монет\\S*|токен\\S*|действи[еяй]\\S*|вывод\\S*|'
    'сет(ь|и|ей|ям|ях)|пар(а|ы|у)|площадк\\S*)([^$_ru]|\$)',
  );

  /// True when [lower] asks to open or show something.
  static bool asksToOpenWindow(String lower) =>
      _matchesAnyPhrase(lower, _openVerbs);

  static const _openVerbs = [
    'открой',
    'открыть',
    'откройте',
    'покажи',
    'показать',
    'покажите',
    'перейди',
    'перейти',
    'зайди',
    'запусти',
    'выведи',
    'open ',
    'show ',
    'go to',
    'take me',
    'launch',
  ];

  /// Helper: returns true if [text] contains any of the given [phrases].
  static bool _matchesAnyPhrase(String text, List<String> phrases) {
    return phrases.any((p) => text.contains(p));
  }
}
