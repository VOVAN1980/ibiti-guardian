import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_bus.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';

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

  /// Returns fallback UI commands based on raw text matching.
  /// This is a safety net for the LLM path when fast-path missed.
  static List<UICommand> fallbackUiCommandsForText(String input) {
    final lower = input.toLowerCase();
    if (AiControlService.instance.settings.mode == AiMode.manual &&
        (lower.contains('send') ||
            lower.contains('swap') ||
            lower.contains('отправ') ||
            lower.contains('обмен'))) {
      return const [];
    }

    // Balance — AI answers verbally, no navigation (P3-3 fix).
    // User must say "открой кошелёк" explicitly to navigate.
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
      return const [];
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
        lower.contains('мои контакты')) {
      return const [
        UICommand(type: UICommandType.openModal, target: 'wallet_address_book'),
      ];
    }

    if (lower.contains('настройк') && lower.contains('кошел')) {
      return const [
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
}
