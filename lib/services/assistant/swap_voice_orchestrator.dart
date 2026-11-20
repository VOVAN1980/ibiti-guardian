import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';
import 'package:ibiti_guardian/services/market/token_discovery_service.dart';
import 'package:ibiti_guardian/utils/token_symbol_normalizer.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';

// ─── Swap Voice Result ──────────────────────────────────────────────────────────

class SwapVoiceResult {
  final String speechText;
  final List<UICommand> commands;

  const SwapVoiceResult({
    required this.speechText,
    this.commands = const [],
  });
}

// ─── Swap Voice Orchestrator ────────────────────────────────────────────────────
///
/// Handles swap-specific voice intents. Called from GuardianAssistantService
/// process() as an async branch AFTER IntentParser detects swapAsset.
///
/// Responsibilities:
///   - Resolve source and target tokens via TokenDiscoveryService
///   - Build UICommands for the swap modal
///   - Return human-readable speech for the voice pipeline
///
/// This keeps GuardianAssistantService thin and swap logic contained.
class SwapVoiceOrchestrator {
  SwapVoiceOrchestrator._();
  static final SwapVoiceOrchestrator instance = SwapVoiceOrchestrator._();

  final _discovery = TokenDiscoveryService.instance;

  // ── Full swap intent: "поменяй USDT на PEPE" ─────────────────────────────

  Future<SwapVoiceResult> handleSwapIntent({
    required String? sourceSymbol,
    required String? targetSymbol,
    required double? amount,
    required String lang,
  }) async {
    final isRu = lang.startsWith('ru');
    final commands = <UICommand>[];

    // First, ensure the swap modal is open
    commands.add(
      const UICommand(type: UICommandType.openModal, target: 'wallet_swap'),
    );

    // Normalize symbols
    final srcNorm = sourceSymbol != null && sourceSymbol.isNotEmpty
        ? TokenSymbolNormalizer.normalize(sourceSymbol)
        : null;
    final tgtNorm = targetSymbol != null && targetSymbol.isNotEmpty
        ? TokenSymbolNormalizer.normalize(targetSymbol)
        : null;

    // ignore: avoid_print

    // ── Resolve source token ────────────────────────────────────────────────
    TokenDiscoveryResult? srcResult;
    if (srcNorm != null) {
      final candidates = await _discovery.resolve(srcNorm);
      if (candidates.isNotEmpty) {
        srcResult = candidates.first;
        commands.add(UICommand(
          type: UICommandType.selectToken,
          target: 'swap_from_token',
          payload: {'symbol': srcResult.symbol},
        ));
      }
    }

    // ── Fill amount with balance validation ─────────────────────────────────
    double? finalAmount;
    String? finalAmountText;
    bool wasClamped = false;
    String? balanceText;

    if (amount != null) {
      if (srcResult == null) {
        return SwapVoiceResult(
          speechText: isRu
              ? 'Сначала выберите токен, который отдаёте. Без него я не могу проверить баланс.'
              : 'Choose the source token first. I cannot verify balance without it.',
          commands: commands,
        );
      }

      finalAmount = amount;

      // Validate balance since we have a source token
      final portfolio = VaultPortfolioListener.instance.summary;
      if (portfolio == null) {
        return SwapVoiceResult(
          speechText: isRu
              ? 'Баланс ${srcResult.symbol} не загружен. Не ставлю сумму.'
              : 'Balance for ${srcResult.symbol} is not loaded. Skipping amount.',
          commands: commands, // Still open modal and select token
        );
      }

      final matchingAsset = portfolio.allAssets.cast<dynamic>().firstWhere(
            (a) =>
                a.symbol.toString().toUpperCase() ==
                srcResult!.symbol.toUpperCase(),
            orElse: () => null,
          );

      if (matchingAsset == null) {
        return SwapVoiceResult(
          speechText: isRu
              ? '${srcResult.symbol} не найден в кошельке. Не ставлю сумму.'
              : '${srcResult.symbol} not found in wallet. Skipping amount.',
          commands: commands,
        );
      }

      final balance = double.tryParse(matchingAsset.balance.toString()) ?? 0.0;
      balanceText = balance >= 1
          ? balance.toStringAsFixed(2)
          : (balance * 100).truncateToDouble() == balance * 100
              ? balance.toStringAsFixed(2)
              : balance.toStringAsFixed(4).replaceAll(RegExp(r'0*$'), '');
      if (balanceText.endsWith('.')) {
        balanceText = balanceText.substring(0, balanceText.length - 1);
      }

      // ignore: avoid_print
      // ignore: avoid_print

      if (balance <= 0) {
        return SwapVoiceResult(
          speechText: isRu
              ? 'Недостаточно ${srcResult.symbol}. Баланс: 0.'
              : 'Insufficient ${srcResult.symbol}. Balance: 0.',
          commands: commands,
        );
      }

      if (amount > balance) {
        finalAmount = balance;
        wasClamped = true;
        // ignore: avoid_print
      }

      // Format the amount
      {
        if (finalAmount >= 1) {
          finalAmountText = finalAmount.toStringAsFixed(2);
        } else {
          final s =
              finalAmount.toStringAsFixed(4).replaceAll(RegExp(r'0*$'), '');
          // ensure at least 2 decimal places if it's not a whole number
          if (s.endsWith('.')) {
            finalAmountText = '${s}00';
          } else {
            final parts = s.split('.');
            if (parts.length > 1 && parts[1].length < 2) {
              finalAmountText = '${parts[0]}.${parts[1].padRight(2, '0')}';
            } else {
              finalAmountText = s;
            }
          }
        }
      }

      // ignore: avoid_print
      // ignore: avoid_print

      commands.add(UICommand(
        type: UICommandType.fillField,
        target: 'swap_amount',
        payload: {'value': finalAmountText},
      ));
    }

    // ── Resolve target token ────────────────────────────────────────────────
    if (tgtNorm == null) {
      // Short confirmation — full tutorial is spoken by WalletSwapModal._startGuideOnce()
      final speech = srcResult != null
          ? (isRu
              ? 'Открываю обмен. Выбрала ${srcResult.symbol}.'
              : 'Opening swap. Selected ${srcResult.symbol}.')
          : (isRu ? 'Открываю обмен.' : 'Opening swap.');
      return SwapVoiceResult(speechText: speech, commands: commands);
    }

    final tgtCandidates = await _discovery.resolve(tgtNorm);

    if (tgtCandidates.isEmpty) {
      // Not found anywhere
      final speech = isRu
          ? 'Токен $tgtNorm не найден. Проверьте название или вставьте contract address в окне обмена.'
          : 'Token $tgtNorm not found. Check the name or paste the contract address in the swap form.';
      // Open search tab in picker
      commands.add(const UICommand(
        type: UICommandType.executeAction,
        target: 'swap_open_search',
      ));
      return SwapVoiceResult(speechText: speech, commands: commands);
    }

    final bestTarget = tgtCandidates.first;

    if (!bestTarget.hasContract) {
      // Found name/price but no contract address
      if (tgtCandidates.length > 1) {
        // Multiple candidates without contracts
        final names = tgtCandidates.take(3).map((c) => c.name).join(', ');
        final speech = isRu
            ? 'Нашла несколько вариантов: $names. Контракт неизвестен. Вставьте contract address в окне обмена.'
            : 'Found multiple matches: $names. Contract unknown. Paste the contract address in the swap form.';
        commands.add(const UICommand(
          type: UICommandType.executeAction,
          target: 'swap_open_search',
        ));
        return SwapVoiceResult(speechText: speech, commands: commands);
      }

      final speech = isRu
          ? 'Нашла ${bestTarget.name}, но контракт неизвестен. Вставьте contract address в окне обмена.'
          : 'Found ${bestTarget.name}, but contract is unknown. Paste the contract address in the swap form.';
      commands.add(const UICommand(
        type: UICommandType.executeAction,
        target: 'swap_open_search',
      ));
      return SwapVoiceResult(speechText: speech, commands: commands);
    }

    // ── Target resolved with contract → select and optionally quote ─────────
    commands.add(UICommand(
      type: UICommandType.selectToken,
      target: 'swap_to_token',
      payload: {'symbol': bestTarget.symbol},
    ));

    // If we have both tokens + amount → auto-request quote
    if (srcResult != null && amount != null) {
      commands.add(const UICommand(
        type: UICommandType.executeAction,
        target: 'wallet_swap_quote',
      ));
      final displayAmount = finalAmountText ?? amount.toString();

      String prefix = '';
      if (wasClamped) {
        prefix = isRu
            ? 'Баланс ${srcResult.symbol}: $balanceText. Ставлю максимум $displayAmount ${srcResult.symbol}. '
            : 'Balance ${srcResult.symbol}: $balanceText. Setting max $displayAmount ${srcResult.symbol}. ';
      }

      final speech = isRu
          ? '${prefix}Нашла ${bestTarget.symbol}. Готовлю котировку: $displayAmount ${srcResult.symbol} → ${bestTarget.symbol}.'
          : '$prefix Found ${bestTarget.symbol}. Preparing quote: $displayAmount ${srcResult.symbol} → ${bestTarget.symbol}.';
      return SwapVoiceResult(speechText: speech, commands: commands);
    }

    // Partial fill
    final speech = isRu
        ? 'Нашла ${bestTarget.symbol}. Выберите сумму и проверьте котировку.'
        : 'Found ${bestTarget.symbol}. Enter the amount and check the quote.';
    return SwapVoiceResult(speechText: speech, commands: commands);
  }

  // ── Single token selection: "выбери IBITI" ──────────────────────────────

  /// Single token selection: "выбери IBITI"
  /// Routes to the active swap picker field (from or to) based on
  /// ScreenContextService.activeSwapField. Defaults to 'from' if unknown.
  SwapVoiceResult handleTokenSelection(String rawSymbol, String lang) {
    final isRu = lang.startsWith('ru');
    final symbol = TokenSymbolNormalizer.normalize(rawSymbol);

    // Determine target field from screen context
    final swapField = ScreenContextService.instance.activeSwapField ?? 'from';
    final target = swapField == 'to' ? 'swap_to_token' : 'swap_from_token';

    final commands = <UICommand>[
      UICommand(
        type: UICommandType.selectToken,
        target: target,
        payload: {'symbol': symbol},
      ),
    ];
    final fieldLabel = swapField == 'to'
        ? (isRu ? 'получение' : 'receive')
        : (isRu ? 'отправку' : 'send');
    final speech = isRu
        ? 'Выбрала $symbol для $fieldLabel.'
        : 'Selected $symbol for $fieldLabel.';
    return SwapVoiceResult(speechText: speech, commands: commands);
  }

  // ── Quote request: "получи котировку" ─────────────────────────────────

  SwapVoiceResult handleQuoteRequest(String lang) {
    final isRu = lang.startsWith('ru');
    final commands = <UICommand>[
      const UICommand(
        type: UICommandType.executeAction,
        target: 'wallet_swap_quote',
      ),
    ];
    final speech = isRu ? 'Запрашиваю котировку.' : 'Requesting quote.';
    return SwapVoiceResult(speechText: speech, commands: commands);
  }
}

// ─── Swap Window Link ───────────────────────────────────────────────────────────
///
/// The open wallet Swap window (WalletSwapModal) and the assistant's checks of
/// the swap windows it prepares.
///
/// «Автономный»: a swap the user confirms in the window counts as the user's
/// own, so the only AI-limit check of a window the AI prepares is the one
/// before it is prepared (GuardianAssistantService). That check values what
/// the window will really pay — the coin it can pick on its network or the
/// one it keeps, and the amount it will use (this open window's field, the
/// amount waiting on the bus) — and approves the quote for exactly those coins
/// up to those amounts. The window asks for a quote by itself (an AI command,
/// not the user's tap) in «Автономный» only within such an approval: an
/// unknown value, another coin, another network or a larger amount leaves the
/// quote to the user's tap. One approval, one quote.
class SwapWindowLink {
  SwapWindowLink._();
  static final SwapWindowLink instance = SwapWindowLink._();

  /// How long an approval waits for its window: the UICommandBus cache TTL,
  /// within which a window opened later still reads the AI's commands.
  static const approvalTtl = Duration(seconds: 60);

  // ── The open window ─────────────────────────────────────────────────────

  Object? _owner;
  String? _chainKey;
  String? _payingSymbol;
  String _amountText = '';

  /// Whether a Swap window is open (it published itself).
  bool get isOpen => _owner != null;

  /// The open window's own network (it can differ from the wallet's).
  String? get chainKey => _chainKey;

  /// The coin the open window pays with (upper case; the native coin when
  /// it has none selected).
  String? get payingSymbol => _payingSymbol;

  /// The amount in the open window's field; null when empty or not a number.
  double? get amount {
    if (!isOpen) return null;
    final value = double.tryParse(
        _amountText.replaceAll(RegExp(r'\s'), '').replaceAll(',', '.'));
    return value != null && value.isFinite && value > 0 ? value : null;
  }

  /// Called by the window whenever its network, paying coin or amount
  /// changes. [owner]: the window's state, so a late close of another
  /// window never clears this one.
  void publish(
    Object owner, {
    required String chainKey,
    required String payingSymbol,
    required String amountText,
  }) {
    _owner = owner;
    _chainKey = chainKey;
    _payingSymbol = payingSymbol.trim().toUpperCase();
    _amountText = amountText;
  }

  /// Called by the window when it closes.
  void clear(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _chainKey = null;
    _payingSymbol = null;
    _amountText = '';
  }

  // ── The approved AI quote ───────────────────────────────────────────────

  String? _approvedChainKey;
  Map<String, double> _approvedAmounts = const {};
  DateTime? _approvedAt;

  /// The check passed: the window may quote by itself on [chainKey], paying
  /// one of [amounts]' coins, up to its amount. Replaces any earlier one.
  void approveAiQuote({
    required String chainKey,
    required Map<String, double> amounts,
    DateTime? now,
  }) {
    final clean = <String, double>{};
    amounts.forEach((symbol, amount) {
      final key = _key(symbol);
      if (key.isEmpty || !amount.isFinite || amount <= 0) return;
      final previous = clean[key];
      clean[key] = previous == null || amount > previous ? amount : previous;
    });
    if (clean.isEmpty) {
      revokeAiQuote();
      return;
    }
    _approvedChainKey = chainKey;
    _approvedAmounts = clean;
    _approvedAt = now ?? DateTime.now();
  }

  /// No AI quote is approved any more (a new check started, or one failed).
  void revokeAiQuote() {
    _approvedChainKey = null;
    _approvedAmounts = const {};
    _approvedAt = null;
  }

  /// Whether the window may quote by itself now: paying [payingSymbol] on
  /// [chainKey], [amount] at most what was approved, within [approvalTtl].
  /// Takes the approval (one quote).
  bool takeAiQuoteApproval({
    required String chainKey,
    required String payingSymbol,
    required double amount,
    DateTime? now,
  }) {
    final at = _approvedAt;
    if (at == null) return false;
    if ((now ?? DateTime.now()).difference(at) > approvalTtl) {
      revokeAiQuote();
      return false;
    }
    if (chainKey != _approvedChainKey) return false;
    final approved = _approvedAmounts[_key(payingSymbol)];
    if (approved == null || !amount.isFinite || amount <= 0) return false;
    if (amount > approved * (1 + 1e-9)) return false;
    revokeAiQuote();
    return true;
  }

  static String _key(String symbol) =>
      TokenSymbolNormalizer.normalize(symbol).trim().toUpperCase();

  @visibleForTesting
  void resetForTest() {
    _owner = null;
    _chainKey = null;
    _payingSymbol = null;
    _amountText = '';
    revokeAiQuote();
  }
}
