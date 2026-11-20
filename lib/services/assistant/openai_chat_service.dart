import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/models/jarvis_personality.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';
import 'package:ibiti_guardian/services/adapters/portfolio_adapter.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/execution/tx_registry.dart';
import 'package:ibiti_guardian/services/wallet/address_book_service.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_resolver.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/services/policy/trusted_address_directory.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';

/// OpenAI Chat service — replaces GeminiService entirely.
import 'package:ibiti_guardian/services/assistant/language_detector.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/services/assistant/user_memory_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_account_store.dart';
import 'package:ibiti_guardian/services/audit_log_service.dart';
import 'package:ibiti_guardian/services/wallet/market_watchlist_service.dart';
import 'package:ibiti_guardian/services/history/tx_history_service.dart';
import 'package:ibiti_guardian/models/on_chain_tx.dart';
import 'package:ibiti_guardian/services/assistant/app_guide.dart';
import 'package:ibiti_guardian/services/security/system_status_service.dart';
import 'package:ibiti_guardian/services/security/approval_scan_service.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/models/approval.dart';
import 'package:ibiti_guardian/services/voice/ai_voice.dart';

/// Resolves user intent into structured JSON with [chatModel]
/// (OpenAI Chat Completions).
class OpenAIChatService {
  OpenAIChatService._();
  static final instance = OpenAIChatService._();
  static const _log = GuardianLogger('OpenAI');

  /// Chat model for [solve] and [solveTradeIntent]. gpt-4o-mini is
  /// deprecated (shutdown 2027-01-14); gpt-6-luna is its replacement. It is a
  /// reasoning model: function tools on Chat Completions work only with
  /// reasoning_effort "none", temperature is allowed only at "none", and the
  /// output cap is max_completion_tokens (not max_tokens).
  static const chatModel = 'gpt-6-luna';

  /// Used for [fallbackRetryAfter] when [chatModel] is rejected (unknown
  /// model or an unsupported parameter), with the old request parameters.
  static const fallbackChatModel = 'gpt-4o-mini';

  /// How long requests go straight to [fallbackChatModel] after a rejection.
  /// Then [chatModel] is tried again: a rejection can be temporary (model
  /// rollout, account access), and the fallback model is deprecated.
  static const fallbackRetryAfter = Duration(minutes: 10);

  static const _completionsUrl = 'https://api.openai.com/v1/chat/completions';

  /// Per-request timeout for [solve]. Stays under the voice pipeline's 30 s
  /// LLM cap (VoiceTurnController._llmTimeout).
  static const _solveRequestTimeout = Duration(seconds: 20);

  /// Strict per-request timeout for [solveTradeIntent]; on timeout the
  /// caller falls back to the local parser.
  static const _tradeIntentTimeout = Duration(milliseconds: 2500);

  /// Set when [chatModel] was rejected: until then requests go straight to
  /// [fallbackChatModel]; null = [chatModel] first.
  DateTime? _fallbackUntil;

  /// Clock for [fallbackRetryAfter]; tests move it forward.
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  bool get _useFallbackModel {
    final until = _fallbackUntil;
    return until != null && clock().isBefore(until);
  }

  /// Tests inject a mock client here; null = the real network.
  @visibleForTesting
  http.Client? httpClientForTest;

  @visibleForTesting
  bool get usingFallbackModel => _useFallbackModel;

  @visibleForTesting
  void resetModelFallbackForTest() {
    _fallbackUntil = null;
    clock = DateTime.now;
  }

  bool _initialized = false;
  String? _apiKey;
  String? _cachedKey;

  /// Broadcasts current tool activity to the UI (e.g. "Reading website...", "Fetching price...")
  final ValueNotifier<String?> activityStatus = ValueNotifier<String?>(null);

  // Ref-counted activity stack: prevents flicker when multiple tools run.
  int _activityDepth = 0;

  void _setActivity(String? status) {
    if (status != null) {
      _activityDepth++;
      activityStatus.value = status;
    } else {
      _activityDepth--;
      if (_activityDepth <= 0) {
        _activityDepth = 0;
        activityStatus.value = null;
      }
    }
  }

  /// Internal Message History — capped at 6 turns (12 messages): enough for
  /// follow-ups, small enough to keep every turn cheap and focused.
  static const _maxHistoryTurns = 6;

  /// Longest canned answer kept by [rememberTurn] (long lists add cost and
  /// nothing the next question needs).
  static const _maxRememberedAnswerChars = 1500;

  /// Tools whose results carry third-party text (web pages, search results,
  /// token names from history or markets). A response produced after any of
  /// them is flagged `untrustedContext` so no transaction is built from it.
  static const _untrustedContentTools = {
    'web_search',
    'read_url',
    'get_transaction_history',
    'get_market_overview',
  };
  final List<Map<String, dynamic>> _history = [];

  void clearHistory() {
    _history.clear();
  }

  @visibleForTesting
  List<Map<String, dynamic>> get historyForTest => List.unmodifiable(_history);

  /// Adds one user/assistant exchange to the LLM history and keeps the cap.
  void _appendHistory(String user, String assistant) {
    _history.add({'role': 'user', 'content': user});
    _history.add({'role': 'assistant', 'content': assistant});
    if (_history.length > _maxHistoryTurns * 2) {
      _history.removeRange(0, _history.length - _maxHistoryTurns * 2);
    }
  }

  /// Records a turn answered without the LLM (a canned or fast-path answer)
  /// so a follow-up question ("а почему?", "and the second one?") still has
  /// its context. Same cap as the LLM's own turns. The answer is stored in
  /// the JSON shape the model itself returns, so the model keeps answering
  /// in that shape, but only once, as displayMessage: a speechText copy
  /// would send the same text twice on every later turn.
  void rememberTurn({required String user, required String assistant}) {
    final u = user.trim();
    final a = assistant.trim();
    if (u.isEmpty || a.isEmpty) return;
    final shortAnswer = a.length > _maxRememberedAnswerChars
        ? '${a.substring(0, _maxRememberedAnswerChars)}…'
        : a;
    _appendHistory(
      u,
      jsonEncode({
        'displayMessage': shortAnswer,
        'uiCommands': <Object>[],
        'explicitIntent': null,
      }),
    );
  }

  // ── Requests ────────────────────────────────────────────────────────────

  /// Chat Completions request body. [fallback] = the old [fallbackChatModel]
  /// parameters (max_tokens, no reasoning_effort).
  @visibleForTesting
  static Map<String, dynamic> buildChatRequestBody({
    required List<Map<String, dynamic>> messages,
    required double temperature,
    required int maxTokens,
    bool fallback = false,
    List<Map<String, dynamic>>? tools,
    String? toolChoice,
  }) {
    return {
      'model': fallback ? fallbackChatModel : chatModel,
      // Function tools and temperature work only at reasoning_effort "none".
      if (!fallback) 'reasoning_effort': 'none',
      'temperature': temperature,
      if (fallback)
        'max_tokens': maxTokens
      else
        'max_completion_tokens': maxTokens,
      'messages': messages,
      if (tools != null) 'tools': tools,
      if (tools != null && toolChoice != null) 'tool_choice': toolChoice,
    };
  }

  /// True when an error response says the model or one of its request
  /// parameters is not accepted — the cases the fallback model fixes.
  /// Quota, auth, rate and server errors are not: the old model would fail
  /// the same way.
  @visibleForTesting
  static bool isModelRejection(int statusCode, String body) {
    if (statusCode != 400 && statusCode != 403 && statusCode != 404) {
      return false;
    }
    String code = '';
    String param = '';
    String message = '';
    try {
      final decoded = jsonDecode(body);
      final error = decoded is Map ? decoded['error'] : null;
      if (error is Map) {
        code = error['code']?.toString().toLowerCase() ?? '';
        param = error['param']?.toString().toLowerCase() ?? '';
        message = error['message']?.toString().toLowerCase() ?? '';
      }
    } catch (_) {
      message = body.toLowerCase();
    }
    const modelCodes = {
      'model_not_found',
      'invalid_model',
      'unsupported_parameter',
      'unsupported_value',
    };
    const modelParams = {
      'model',
      'reasoning_effort',
      'max_completion_tokens',
      'temperature',
      'tool_choice',
    };
    if (modelCodes.contains(code)) return true;
    // 403 only when it is about access to the model itself.
    if (statusCode == 403) {
      return message.contains('model') && message.contains('access');
    }
    if (modelParams.contains(param)) return true;
    return message.contains('reasoning_effort') ||
        message.contains('unsupported parameter') ||
        message.contains('invalid model') ||
        (message.contains('model') &&
            (message.contains('does not exist') ||
                message.contains('not found')));
  }

  Future<http.Response> _postJson(
      Map<String, dynamic> body, Duration timeout) {
    final uri = Uri.parse(_completionsUrl);
    final headers = {
      'Authorization': 'Bearer $_apiKey',
      'Content-Type': 'application/json',
    };
    final encoded = jsonEncode(body);
    final client = httpClientForTest;
    final request = client != null
        ? client.post(uri, headers: headers, body: encoded)
        : http.post(uri, headers: headers, body: encoded);
    return request.timeout(timeout);
  }

  /// Sends a chat request with [chatModel]. If that model or one of its
  /// parameters is rejected, retries once with [fallbackChatModel] and keeps
  /// using it for [fallbackRetryAfter]; after that [chatModel] is tried
  /// again.
  Future<http.Response> _postChat(
    Map<String, dynamic> Function(bool fallback) buildBody,
    Duration timeout,
  ) async {
    if (_useFallbackModel) return _postJson(buildBody(true), timeout);
    final response = await _postJson(buildBody(false), timeout);
    if (response.statusCode == 200 ||
        !isModelRejection(response.statusCode, response.body)) {
      return response;
    }
    _fallbackUntil = clock().add(fallbackRetryAfter);
    _log.w('$chatModel rejected (HTTP ${response.statusCode}: '
        '${_errorDetail(response)}); using $fallbackChatModel for '
        '${fallbackRetryAfter.inMinutes} min');
    return _postJson(buildBody(true), timeout);
  }

  static String _errorDetail(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      final error = decoded is Map ? decoded['error'] : null;
      final message = error is Map ? error['message'] : null;
      if (message != null) return message.toString();
    } catch (_) {}
    return response.body.length > 300
        ? response.body.substring(0, 300)
        : response.body;
  }

  /// Russian if the message (or, when it gives no hint, the app) is Russian.
  static bool _isRu(String input, String languageCode) {
    final detected = LanguageDetector.detect(input);
    final code = detected.isNotEmpty ? detected : languageCode;
    return code.startsWith('ru');
  }

  /// The user-facing "AI can't answer right now" reply. No key, quota or
  /// HTTP details: the user can't act on them (logged instead).
  static Map<String, dynamic> _unavailableResponse(bool isRu) => {
        'displayMessage': isRu
            ? 'Guardian AI сейчас недоступен. Попробуйте чуть позже.'
            : 'Guardian AI is temporarily unavailable. Please try again later.',
        'speechText': isRu
            ? AiVoice.ru('Я сейчас недоступен. Попробуйте чуть позже.',
                'Я сейчас недоступна. Попробуйте чуть позже.')
            : "I'm unavailable right now. Please try again later.",
      };

  /// Which grammatical gender the assistant uses about itself in Russian:
  /// the gender of the voice chosen in Settings ([AiVoice]).
  static String _voiceGenderInstruction() => AiVoice.isFemale
      ? 'Your voice is female: in Russian always use feminine forms about '
          'yourself (я проверила, я нашла, я не уверена, я сама).'
      : 'Your voice is male: in Russian always use masculine forms about '
          'yourself (я проверил, я нашёл, я не уверен, я сам).';

  /// What the AI may do in each mode, and what holds in every mode (owner
  /// decisions of 2026-11-20). Static, so it stays in the cached prompt
  /// prefix; the current mode and PIN setting come later in the prompt.
  @visibleForTesting
  static const String aiModeRules = '''
━━━ AI MODES: WHAT YOU MAY DO ━━━
Act by the current AI mode and AI action PIN confirmation (both given below).
- «Советник» (Advisor): ONLY advise and explain. Return no uiCommands and no
  action intent: open, fill, prepare or create nothing (no windows, orders,
  sends, swaps, watchlist entries, price alerts, TP/SL, scans or revokes).
  Say what the user can do themselves (their own actions work in every
  mode) or that «Ручной» / «Автономный» lets you do it.
- «Ручной» (Manual): prepare only (open and fill the window or order); the
  user checks it and confirms with the PIN.
- «Автономный» (Autonomous): carry out what the user asks. PIN confirmation
  ON: every action shows a card (what, amount, to / exchange, network, fee),
  then «Подтвердить» or a spoken «да», then the PIN. OFF: no card only within
  the daily trading limit and «AI Мандат», with EPK active, to trusted
  addresses or the owner's own cards, with the app open and the wallet
  unlocked; a new address, a locked wallet, or an exchange order while EPK
  is paused gets the card + PIN. While EPK is paused nothing on-chain is
  carried out (revoking aside). After each action the notification
  «ИИ выполнил: …» comes.
- Never carry out yourself an operation whose USD value is unknown (a coin
  without a price), PIN confirmation ON or OFF: the app opens the filled
  wallet window and the user confirms it there with the PIN. Never promise a
  card for it.
- Every mode: never exceed a limit or go around Policy, «AI Мандат» or EPK.
  A request over a limit (daily trading limit, max position, a wallet limit)
  or outside «AI Мандат»: refuse it, name the limit and its value, and say
  that for more the owner raises it in «Политика» (Security → Policy) with
  their PIN. Never suggest splitting an order or any other way around it.
- Never say an operation is done: the app shows the card, asks the PIN and
  reports the result itself (with the PIN ON, say to confirm on screen).
''';

  /// The AI action PIN confirmation setting and what it means right now.
  /// The setting exists only in «Автономный»; elsewhere it is always on.
  @visibleForTesting
  static String pinConfirmationLabel(AiControlSettings s) {
    if (s.mode != AiMode.fullAutonomy) {
      return 'ON (the setting exists only in «Автономный»; in this mode the AI '
          'carries out nothing by itself)';
    }
    return s.aiPinConfirm
        ? 'ON (every AI action shows a card and asks the PIN first; one with '
            'an unknown USD value opens in the filled wallet window instead)'
        : 'OFF (no card only within the daily trading limit and «AI Мандат», '
            'with EPK active, to trusted addresses or own cards, with the app '
            'open and the wallet unlocked; a new address, a locked wallet or '
            'an exchange order while EPK is paused = card + PIN; an unknown '
            'USD value = the filled wallet window for the user, never you; '
            'then the «ИИ выполнил» notification)';
  }

  /// One context line: what the AI can do in [mode].
  static String _aiModeDuty(AiMode mode) => switch (mode) {
        AiMode.manual =>
          'advise only: analyse balances, prices, market routes, limits and '
              'risks; open, fill, create and execute nothing',
        AiMode.guarded =>
          'prepare: open screens and windows, fill send / swap / order fields, '
              'prepare previews, manage watchlist, price alerts and TP/SL; the '
              'user confirms every money action with the PIN',
        AiMode.fullAutonomy =>
          'carry out the exchange orders, sends, swaps and revokes the user '
              'asks for, within limits, «AI Мандат» and EPK, under the PIN '
              'setting below; everything «Ручной» does as well',
      };

  Future<void> init() async {
    final settings = SettingsService.instance.settings;
    final isEnabled = settings.isNeuralOperatorEnabled;

    if (!isEnabled) {
      _apiKey = null;
      _initialized = false;
      return;
    }

    String? key = settings.openaiApiKey;

    // Fallback to assets if settingsKey is empty (Phase 3 Dev Logic)
    if (key == null || key.isEmpty) {
      try {
        final secretString = await rootBundle.loadString('secrets/openai.json');
        final Map<String, dynamic> secrets = jsonDecode(secretString);
        key = secrets['apiKey'];
      } catch (e) {
        _log.d('Secrets fallback check: $e');
      }
    }

    if (key != null && key.isNotEmpty) {
      if (!_initialized || _cachedKey != key) {
        _apiKey = key;
        _cachedKey = key;
        _initialized = true;
      }
    } else {
      _apiKey = null;
      _initialized = false;
    }
  }

  /// Neural Intent Resolver: converts natural language into structured JSON.
  /// Now includes stateful memory and automated language recovery.
  Future<Map<String, dynamic>> solve(
    String input, [
    String languageCode = 'ru',
    bool allowActionTools = true,
  ]) async {
    await init();

    if (_apiKey == null) {
      final isRu = _isRu(input, languageCode);
      // Settings has a switch for the AI but no key field: only the switch
      // is something the user can change.
      if (!SettingsService.instance.settings.isNeuralOperatorEnabled) {
        return {
          'displayMessage': isRu
              ? 'Guardian AI выключен. Включите его: Меню → Guardian AI.'
              : 'Guardian AI is turned off. Turn it on in Settings → Guardian AI.',
          'speechText': isRu
              ? AiVoice.ru(
                  'Я выключен. Включите меня в меню, раздел Guardian AI.',
                  'Я выключена. Включите меня в меню, раздел Guardian AI.')
              : "I'm turned off. Turn me on in Settings, Guardian AI.",
        };
      }
      _log.w('No API key available');
      return _unavailableResponse(isRu);
    }

    final aiSettings = AiControlService.instance.settings;
    final epkState = EPKPolicyManager.instance.state;
    final appContext = await _buildAppContextSnapshot();
    final rawPersonalContext =
        UserMemoryService.instance.buildPersonalContext();
    // Cap personal context to prevent prompt bloat.
    // Truncate at LINE boundaries so individual vocab/macro entries stay intact.
    final personalContext = _truncateAtLineBoundary(rawPersonalContext, 1000);

    // Static sections first, per-turn values last: the provider caches a
    // repeated prompt prefix, which makes most of each turn cheaper.
    final systemPrompt = '''
You are IBITI Guardian, an AI assistant and voice OS for the IBITI Guardian app.
Always infer the language of the CURRENT user message and answer in that
language. Understand mixed language and surzhyk naturally. Use the preferred
app language (given below) only when the current message does not provide
enough evidence.

━━━ OUTPUT FORMAT (STRICT JSON) ━━━
You must return a JSON object with this exact schema:
{
  "displayMessage": "Detailed user-facing message, keeping it natural, clear, and context-aware.",
  "speechText": "Short voice-friendly version (2-4 sentences), NO markdown, read numbers naturally.",
  "uiCommands": [],
  "explicitIntent": {
    "type": "buyAsset"|"sellAsset"|"swapAsset"|"showBalances"|"showAddress"|null,
    "params": {
      "amount": double|null,
      "tokenSymbol": string|null,
      "isQuantity": boolean
    }
  }
}

If a buy/sell trade amount or coin is missing, return explicitIntent of type buyAsset/sellAsset with the missing field as null. Set displayMessage/speechText to prompt for it ("Укажите сумму." / "Сумма?" or "Укажите монету." / "Монета?").

━━━ OPENING WINDOWS AND ACTIONS ━━━
Return uiCommands or an explicitIntent ONLY when the user clearly asks you to
open or show something, or to do something ("открой политику", "покажи
историю", "купи BTC на 10"). For questions, explanations, opinions, advice,
small talk, emotions ("я в панике"), or stories about what already happened
("я вчера отправил…"), return "uiCommands": [] and "explicitIntent": null and
just answer. Never open a window on your own initiative.

━━━ WHAT THE APP CAN AND CANNOT DO ━━━
Answer only from this list, the APP GUIDE, the live context below and your
tool results.
- Wallet networks (exactly seven): BNB Chain, Ethereum, Polygon, Arbitrum,
  Base, Solana, Tron. Nothing else (no Optimism, Bitcoin network, TON…).
- Wallet: send, receive, swap (0x on EVM networks, Jupiter on Solana,
  SunSwap on Tron), history, address book, several wallet cards.
- Exchanges: live prices from MEXC, Binance, Gate.io and OKX; SPOT buy/sell
  only, on exchanges connected with API keys (Policy → Funding sources).
  No futures, margin, leverage, staking, lending, earn or copy trading.
- Security: Safe Scan (token approval check) with Safe review and Panic
  revoke, the System status card, EPK on-chain policy, limits in Policy, AI
  modes «Советник» (Advisor) / «Ручной» (Manual) / «Автономный» (Autonomous).
- Trusted addresses (AI whitelist; Command Center → Trusted addresses): in
  «Автономный» you send WITHOUT the confirmation card only to these, the
  owner's own cards and wallets; any other (new) address always gets the
  card + PIN, and while the policy is STRICT AI sends go only to these. Only
  the owner adds them, with the PIN (Address book → ⋯ → Trust for AI, or Add
  on that screen). You can list and explain them (get_trusted_addresses) and
  open the screen (openModal trusted_addresses) but never add or remove
  entries. The owner's own manual sends are not limited by this list.
- There is no autonomous trading bot running in the app; you act only on the
  user's request and within the limits.
If something is not covered here, in the context or by a tool, say plainly
that you don't know or that the app can't do it. Never invent balances,
prices, features, transactions or results.
Questions about the app itself ("what is Safe Scan", "why is the status card
red", "how do I add a card", "what does the approve limit do") are questions:
answer them from the APP GUIDE and the live context. Call a tool only for live
values (balances, prices, scan results, the status card right now).

${AppGuide.text}
$aiModeRules
━━━ HOW YOU SOUND ━━━
Your tone, length and wording come from YOUR PERSONALITY at the end of this
prompt; follow it. speechText is read aloud by a voice: plain sentences, no
lists, no symbols, no emoji, no addresses or hashes. Round numbers sensibly
(amounts and prices of 1 or more to two decimals, smaller ones to two
significant digits) and keep them as digits — the app turns them into words.

━━━ THIS TURN ━━━
The preferred app language is: $languageCode.
${_voiceGenderInstruction()}
${allowActionTools ? '' : '''
This is a conversation-only turn. The user has not authorized an app action.
Answer or explain naturally. Do not propose, simulate, or claim that you opened,
changed, bought, sold, sent, swapped, scanned, revoked, or executed anything.
'''}
━━━ AI MODE & POLICY ━━━
Current AI mode: ${_aiModeLabel(aiSettings.mode)}.
AI action PIN confirmation: ${aiSettings.pinRequiredForAi ? 'ON' : 'OFF'}.
Permitted AI actions: ${aiSettings.allowedActions.map((e) => e.name).join(", ")}.
EPK protection: ${epkState.isActive ? 'ACTIVE' : 'PAUSED'} (${epkState.isDeployed ? 'on-chain kernel' : 'local checks'}).
Limits, the System status and what this mode allows are in the live context
below; follow AI MODES: WHAT YOU MAY DO above.
If an action is blocked by the mode or a limit, say which one and where the
owner changes it: the AI mode in Security → AI Center (or Policy → AI mode),
limits in Security → Policy. Raising the mode or a spending limit needs the
PIN; you can't change them.

━━━ LIVE APP CONTEXT ━━━
$appContext

━━━ PERSONALITY & MEMORY ━━━
${SettingsService.instance.settings.jarvisPersonality.systemPromptInjection}
Memory context:
$personalContext
''';

    final tools = [
      {
        "type": "function",
        "function": {
          "name": "get_wallet_balance",
          "description":
              "Fetch the user's live blockchain wallet balance, portfolio overview, and asset list. Use ONLY for questions about: balance, money amount, token values, portfolio value. Russian triggers: баланс, сколько денег, сколько токенов, портфель. Do NOT use for questions about cards (карточки/карты) or wallet count — use get_vault_info instead."
        }
      },
      {
        "type": "function",
        "function": {
          "name": "get_vault_info",
          "description":
              "Fetch information about the user's vault: number of wallet cards (EVM cards), all addresses (EVM, Solana, Tron). Use for questions about: how many cards, how many wallets, how many addresses, card count, wallet structure. Russian triggers: сколько карточек, сколько карт, карточки, карты, кошельки, адреса. ALWAYS use this tool when user asks about wallet cards (карточки/карты). NOT for the System status card (статус системы, красная/опасно, what's wrong): use get_system_status. NOT for trusted / whitelisted addresses (доверенные адреса, белый список): use get_trusted_addresses."
        }
      },
      {
        "type": "function",
        "function": {
          "name": "get_wallet_address",
          "description": "Fetch the user's blockchain wallet public address."
        }
      },
      {
        "type": "function",
        "function": {
          "name": "get_crypto_price",
          "description":
              "Fetch the CURRENT real-time price of any cryptocurrency (BTC, ETH, USDT, SOL, BNB, etc.) in USD. Always call this when user asks about crypto price.",
          "parameters": {
            "type": "object",
            "properties": {
              "query": {
                "type": "string",
                "description": "Token symbol e.g. BTC, ETH, USDT"
              }
            },
            "required": ["query"]
          }
        }
      },
      {
        "type": "function",
        "function": {
          "name": "get_fiat_rate",
          "description":
              "Fetch the CURRENT real-time exchange rate between any two fiat currencies (e.g. USD to UAH, USD to EUR, EUR to GBP). Always call this when user asks about currency rates.",
          "parameters": {
            "type": "object",
            "properties": {
              "from": {
                "type": "string",
                "description": "Source currency code e.g. USD"
              },
              "to": {
                "type": "string",
                "description": "Target currency code e.g. UAH"
              }
            },
            "required": ["from", "to"]
          }
        }
      },
      {
        "type": "function",
        "function": {
          "name": "scan_security_risks",
          "description":
              "READ-ONLY. Results of Safe Scan (the token approval check): the latest scan of this session, "
                  "plus saved results of earlier scans (risky approvals per network and wallet). "
                  "Does NOT start a scan; if none ran this session it says so (the user scans in Security → Safe/Panic). "
                  "Use when user asks: 'что нашёл Safe Scan', 'есть опасные разрешения', 'результаты сканирования', "
                  "'did the scan find anything', 'risky approvals'."
        }
      },
      {
        "type": "function",
        "function": {
          "name": "get_system_status",
          "description":
              "READ-ONLY. The live 'System status' card on the Wallet tab (RU «Статус системы»): "
                  "isSafe (green «Безопасно») or not (red «Опасно»), the problems behind red "
                  "(riskyApprovals found by Safe Scan, sessionExpired sign-in, notificationsOff) with how to fix each, "
                  "and riskyScans (network, wallet, count). "
                  "Use when user asks: 'статус системы', 'почему карточка статуса красная', 'что не так', "
                  "'всё ли в порядке', 'system status', 'why is it red', 'is my wallet safe'. "
                  "NOT get_vault_info: this card is not a wallet card."
        }
      },
      {
        "type": "function",
        "function": {
          "name": "web_search",
          "description":
              "Search the internet for any information: news, websites, projects, people, events, or any general knowledge. Use this when the user asks about something you are not sure about or want current info on.",
          "parameters": {
            "type": "object",
            "properties": {
              "query": {
                "type": "string",
                "description":
                    "Search query, e.g. 'ibiticoin.com', 'IBITI token price', 'latest ETH news'"
              }
            },
            "required": ["query"]
          }
        }
      },
      {
        "type": "function",
        "function": {
          "name": "read_url",
          "description":
              "Read and extract the full text content of any web page. Use this when user mentions a specific URL, asks to check a website, or asks what is written on a specific page. Powered by Jina Reader.",
          "parameters": {
            "type": "object",
            "properties": {
              "url": {
                "type": "string",
                "description":
                    "Full URL to read, e.g. 'https://www.ibiticoin.com/' or 'https://coinmarketcap.com/currencies/bitcoin/'"
              }
            },
            "required": ["url"]
          }
        }
      },
      {
        "type": "function",
        "function": {
          "name": "panic_revoke_all",
          "description":
              "EMERGENCY: immediately open Panic Revoke mode. It scans and lists ALL critical dangerous approvals; the user confirms once to revoke them all. Call when user says: паника, emergency, revoke all, опасность, экстренно, всё ревокнуть."
        }
      },
      {
        "type": "function",
        "function": {
          "name": "safe_revoke_review",
          "description":
              "Open Safe Review mode: scan the wallet and show a list of risky approvals for user to review and selectively revoke. Call when user says: безопасный режим, safe review, проверь разрешения, покажи контракты."
        }
      },
      {
        "type": "function",
        "function": {
          "name": "get_market_overview",
          "description":
              "Fetch current market overview: top gainers, top losers, and key assets (BTC, ETH, BNB) with prices and 24h changes. "
                  "Use when user asks general market questions like 'что на рынке', 'market overview', 'analyze the market', 'обзор рынка', 'какие тренды'. "
                  "Returns cached data — no external API calls needed."
        }
      },
      // ── Phase K: expanded knowledge tools ──────────────────────────────
      {
        "type": "function",
        "function": {
          "name": "get_transaction_history",
          "description":
              "Fetch the user's recent on-chain transaction history (last 10 transactions). "
                  "Returns: hash, type (send/receive/swap/approval), token, value, date, success status. "
                  "Use when user asks: 'когда я отправлял', 'история', 'last transactions', 'что было', 'кому переводил'."
        }
      },
      {
        "type": "function",
        "function": {
          "name": "get_audit_log",
          "description":
              "Fetch the session action log: recent executed operations (sends, swaps, revokes, network switches). "
                  "Use when user asks: 'что я делал', 'what did I do', 'лог действий', 'мои операции', 'покажи лог'."
        }
      },
      {
        "type": "function",
        "function": {
          "name": "get_address_book",
          "description":
              "Fetch the user's saved contacts (address book). Returns list of {label, address}. "
                  "Use when user asks: 'мои контакты', 'адресная книга', 'contacts', 'кому я отправлял', "
                  "or when user mentions a name to send to (e.g. 'отправь Алисе'). "
                  "NOT for trusted addresses / whitelist: use get_trusted_addresses."
        }
      },
      {
        "type": "function",
        "function": {
          "name": "get_trusted_addresses",
          "description":
              "Fetch the user's TRUSTED ADDRESSES (AI whitelist): the addresses the AI may send to. "
                  "Returns {label (address book name or null), address (short), full_address, type: address|contract}, "
                  "count, policy_mode, strict. READ-ONLY: you cannot add or remove entries; only the owner can, with the PIN. "
                  "Use when user asks: 'доверенные адреса', 'белый список', 'вайтлист', 'whitelist', "
                  "'trusted addresses', 'кому ты можешь переводить'. Do NOT use get_address_book for these."
        }
      },
      {
        "type": "function",
        "function": {
          "name": "get_pending_transactions",
          "description":
              "Check if there are any in-flight (pending/submitted) transactions. "
                  "Returns active tx details and recent tx history count. "
                  "Use when user asks: 'есть что-то в обработке', 'pending', 'прошла ли транзакция', 'статус'."
        }
      },
      {
        "type": "function",
        "function": {
          "name": "manage_watchlist",
          "description":
              "Add or remove a token from the user's market watchlist (starred tokens). "
                  "Use when user says: 'добавь в отслеживание', 'убери из вотчлиста', 'follow SOL', "
                  "'звёздочку на BTC', 'watch ETH', 'unwatch DOGE'.",
          "parameters": {
            "type": "object",
            "properties": {
              "action": {
                "type": "string",
                "enum": ["add", "remove"],
                "description": "Whether to add or remove from watchlist."
              },
              "symbol": {
                "type": "string",
                "description": "Token symbol, e.g. BTC, ETH, SOL"
              }
            },
            "required": ["action", "symbol"]
          }
        }
      }
    ];
    // scan_security_risks and get_system_status only read results, so
    // conversation-only (voice) turns may use them. In «Советник» the AI
    // only advises: action tools are not offered at all (and
    // _isToolAllowedByMode refuses them if the model calls one anyway).
    const actionToolNames = {
      'panic_revoke_all',
      'safe_revoke_review',
      'manage_watchlist',
    };
    final offerActionTools =
        allowActionTools && aiSettings.mode != AiMode.manual;
    final advertisedTools = offerActionTools
        ? tools
        : tools.where((tool) {
            final function = tool['function'];
            if (function is! Map) return false;
            return !actionToolNames.contains(function['name']);
          }).toList();

    // Inject a tool-routing hint as a system message (NOT in user input).
    // Putting it in user content risks the model echoing it back.
    final toolHint = _buildToolHint(input);

    // Maintain a temporary "Current Round" messages list starting with System Prompt
    List<Map<String, dynamic>> currentMessages = [
      {'role': 'system', 'content': systemPrompt},
      // Insert history
      ..._history,
      // Tool routing hint as a separate system message (if any)
      if (toolHint != null) {'role': 'system', 'content': toolHint},
      {'role': 'user', 'content': input},
    ];

    // Track if a guardian modal was requested during tool execution
    String? pendingGuardianMode;
    var usedUntrustedTool = false;

    final isRuTurn = _isRu(input, languageCode);

    try {
      const maxLoops = 3;
      for (int i = 0; i < maxLoops; i++) {
        // The last round must produce the answer: no more tool calls, so the
        // user never gets a "limit reached" instead of a reply.
        final isLastRound = i == maxLoops - 1;
        // NOTE: response_format: json_object is intentionally not used
        // because it conflicts with 'tools'. With tools active, the model
        // returns tool_calls OR a final message. We enforce JSON via the
        // system prompt.
        final response = await _postChat(
          (fallback) => buildChatRequestBody(
            messages: currentMessages,
            temperature: 0.3,
            maxTokens: 1200,
            fallback: fallback,
            tools: advertisedTools,
            toolChoice: isLastRound ? 'none' : 'auto',
          ),
          _solveRequestTimeout,
        );

        if (response.statusCode != 200) {
          _log.e('Chat request failed: HTTP ${response.statusCode}: '
              '${_errorDetail(response)}');
          return _unavailableResponse(isRuTurn);
        }

        final body = jsonDecode(response.body);
        final choice = body['choices'][0];
        final message = choice['message'];
        final finishReason = choice['finish_reason']?.toString() ?? '';
        currentMessages.add(message);

        // ── Truncation guard ────────────────────────────────────────────
        // If the model hit max_tokens, the JSON is almost certainly
        // incomplete. Don't even attempt to parse — return a clean error
        // so the UI/voice pipeline gets a real message, not a crash.
        if (finishReason == 'length') {
          _log.w('Response truncated (finish_reason=length)');
          // Same language choice as every other reply of this turn.
          return {
            'displayMessage': isRuTurn
                ? 'Ответ оказался слишком длинным и был обрезан. '
                    'Попробуйте задать вопрос конкретнее.'
                : 'My response was too long and got cut off. '
                    'Please try a simpler question.',
            'speechText': isRuTurn
                ? 'Ответ слишком длинный. Спросите конкретнее.'
                : 'Sorry, my answer was too long. Can you ask more specifically?',
          };
        }

        // Tool execution logic
        if (message['tool_calls'] != null &&
            (message['tool_calls'] as List).isNotEmpty) {
          final toolCalls = message['tool_calls'] as List;
          for (final tool in toolCalls) {
            final functionName = tool['function']['name'];
            final callId = tool['id'];
            if (_untrustedContentTools.contains(functionName)) {
              usedUntrustedTool = true;
            }
            String toolResult;
            if (!_isToolAllowedByMode(functionName)) {
              final mode = AiControlService.instance.settings.mode;
              toolResult = jsonEncode({
                'error':
                    'Action "$functionName" is not available in the AI mode '
                        '${_aiModeLabel(mode)}: the AI only advises there. '
                        'The owner can switch to «Ручной» or «Автономный» in '
                        'Security → AI-Центр.',
                'mode': mode.name,
              });
            } else {
              toolResult = await _executeTool(
                  functionName, tool['function']['arguments']);
            }

            // Capture guardian modal intent before sending result back to AI
            try {
              final resultMap = jsonDecode(toolResult);
              if (resultMap['action'] == 'OPEN_GUARDIAN_MODAL') {
                pendingGuardianMode = resultMap['mode']?.toString();
              }
            } catch (e) {
              _log.d('Tool result parse: $e');
            }

            currentMessages.add({
              'role': 'tool',
              'tool_call_id': callId,
              'content': toolResult,
            });
          }
          continue; // Loop again for the final thought
        }

        // Final response handling — safe JSON extraction
        final text = message['content']?.toString() ?? '';
        if (text.trim().isEmpty) {
          _log.w('Empty answer (finish_reason=$finishReason)');
          // An assistant message with neither text nor tool calls is not
          // valid input for the next round.
          currentMessages.removeLast();
          continue;
        }
        Map<String, dynamic>? decoded;
        try {
          decoded = Map<String, dynamic>.from(jsonDecode(text) as Map);
        } catch (_) {
          // Model sometimes wraps JSON in markdown or adds trailing text.
          // Extract the outermost balanced {...} block instead of greedy regex
          // which would fail on nested objects or trailing garbage.
          final jsonStr = _extractBalancedJson(text);
          if (jsonStr != null) {
            try {
              decoded = Map<String, dynamic>.from(jsonDecode(jsonStr) as Map);
            } catch (e) {
              _log.w('JSON fallback parse failed', e);
            }
          }
        }
        if (decoded != null) {
          String aiSpeech = decoded['speechText']?.toString() ?? "";

          // Phase 2: Language retry — use detected user language, not just app setting
          final responseLanguageCode = LanguageDetector.detect(input).isNotEmpty
              ? LanguageDetector.detect(input)
              : languageCode;
          // No retry on the last round: an answer in the wrong language is
          // better than no answer.
          if (!isLastRound &&
              aiSpeech.isNotEmpty &&
              LanguageDetector.isWrongLanguage(
                  aiSpeech, responseLanguageCode)) {
            currentMessages.add({
              'role': 'user',
              'content':
                  'IMPORTANT: Your previous answer was in wrong language. Please repeat it ONLY in [$responseLanguageCode].'
            });
            continue;
          }

          // Persistence: Update memory (original user input, not tool-hinted)
          _appendHistory(input, text);

          // Override if phantom modal was pending
          if (pendingGuardianMode != null) {
            decoded['uiCommands'] = [
              {'type': 'openModal', 'target': pendingGuardianMode}
            ];
            if (decoded['explicitIntent'] == null) {
              decoded['explicitIntent'] = {'type': 'revokeAsset'};
            }
          }

          // Enforce mode constraints on AI output (defense-in-depth)
          _enforceModeOnResponse(decoded);
          decoded['untrustedContext'] = usedUntrustedTool;

          return decoded;
        } else {
          // Could not parse JSON at all — treat raw text as response
          if (pendingGuardianMode != null) {
            return {
              'displayMessage': text,
              'speechText': text,
              'uiCommands': [
                {'type': 'openModal', 'target': pendingGuardianMode}
              ],
              'explicitIntent': {'type': 'revokeAsset'},
            };
          }
          return {'displayMessage': text, 'speechText': text};
        }
      }
      // Only reached if even the tool-free last round gave no usable text.
      _log.w('No answer after $maxLoops rounds');
      final msg = isRuTurn
          ? 'Не получилось ответить. Спросите, пожалуйста, ещё раз.'
          : "I couldn't finish the answer. Please ask again.";
      return {'displayMessage': msg, 'speechText': msg};
    } catch (e) {
      // Timeouts, network and parse errors: the details go to the log.
      _log.e('solve failed', e);
      return _unavailableResponse(isRuTurn);
    }
  }

  /// Primary trading intent resolver using [chatModel].
  /// Strictly classifies buy/sell intents and extracts trading details.
  Future<Map<String, dynamic>?> solveTradeIntent(String input,
      {String? languageCode}) async {
    await init();
    if (_apiKey == null) {
      _log.w('solveTradeIntent: apiKey is null, falling back to local brain');
      return null;
    }

    final settings = AiControlService.instance.settings;
    final screenCtx = ScreenContextService.instance;
    final activeScreen = screenCtx.activeScreen;
    final activeSubScreen = screenCtx.activeSubScreen;
    final focusedSymbol = screenCtx.focusedSymbol;
    final activeExchange = screenCtx.activeExchange;
    final mode = settings.mode.name;
    final venues = settings.activeSources.join(', ');

    final contextStr = '''
- transcript: "$input"
- current screen: "$activeScreen" / "${activeSubScreen ?? 'none'}"
- focusedSymbol: "${focusedSymbol ?? 'none'}"
- active exchange: "${activeExchange ?? 'none'}"
- current AI mode: "$mode"
- available venues: "$venues"
''';

    final systemPrompt = '''
You are the primary trading intent resolver for IBITI Guardian.
Analyze the user's query and extract the trade intent.

━━━ COMPACT CONTEXT ━━━
$contextStr

━━━ PARSING RULES ━━━
1. Determine if user wants to buy or sell a cryptocurrency asset.
   - If the user is asking whether you are capable of buying/selling (e.g., "можешь покупать?", "умеешь покупать?", "can you buy?", "are you able to buy?", "ты можешь купить?", "можешь продать?") and names no coin AND amount, this is a capability question, NOT an active trade command. Set type to "capabilityQuestion" and confidence to 1.0. A polite request that names a coin and an amount ("А можешь купить BTC на 10 USDT?", "could you buy 10 USDT of BTC?") is a trade command.
   - If the user is giving an actual imperative command to execute a trade (e.g. "купи SOL", "продай BTC", "купи монету на 1 долар"), set type to "buyAsset" or "sellAsset" accordingly.
   - Advice or opinion questions ("стоит ли купить BTC?", "когда продавать?", "should I buy?") and stories about past trades ("я вчера купил SOL", "I sold ETH") are NOT trade commands: set type to "unknown".
   - If neither, set type to "unknown".
2. Token symbol (tokenSymbol) resolution:
   - Identify the coin ticker (e.g. BTC, ETH, SOL).
   - Handle Russian slang/aliases (e.g. "биток" -> BTC, "солана" -> SOL, "эфир" -> ETH).
   - If the user refers to the token implicitly (e.g. "монету", "это", "её", "эту монету", "this coin", "it"), use the Focused Symbol if available.
   - If no token is mentioned and no Focused Symbol is available, set tokenSymbol to null.
3. Amount (amount) and Quantity (isQuantity) resolution:
   - Extract the numeric or slang amount.
   - Slang amounts: "пол бакса" -> 0.50, "сотку" -> 100.0, "десятку" -> 10.0, "косарь" -> 1000.0.
   - Slang sell amounts: "все", "всё", "all", "100%" -> amount: -1.0, isQuantity: true; "половина", "half", "50%" -> amount: -0.5, isQuantity: true.
   - Determine if amount is USDT/fiat value (isQuantity: false) or token quantity (isQuantity: true).
     - "купи SOL на 100" -> amount: 100.0, isQuantity: false
     - "купи 2 SOL" -> amount: 2.0, isQuantity: true
     - "продай SOL на сотку" -> amount: 100.0, isQuantity: false
     - "купи монету на 1 долар" -> amount: 1.0, isQuantity: false
4. Source Exchange (sourceId) resolution:
   - If the user specifies an exchange/venue (e.g. MEXC, Binance, OKX, Gate.io), set sourceId to its lowercase name.
   - Otherwise, set sourceId to active exchange or null.
5. Missing fields (missingField):
   - If amount is missing, set missingField to "amount".
   - If token symbol is missing and cannot be resolved, set missingField to "tokenSymbol".
   - Otherwise, set missingField to null.
6. Confidence (confidence):
   - A float between 0.0 and 1.0. If the query is clearly a trade request or a direct capability question, set it to >= 0.8. If it's general chat or unrelated, set it to < 0.5 and type to "unknown".

━━━ OUTPUT FORMAT (STRICT JSON ONLY) ━━━
Return ONLY a raw JSON object matching this schema, no markdown wrapping, no explanation:
{
  "type": "buyAsset" | "sellAsset" | "capabilityQuestion" | "unknown",
  "tokenSymbol": string | null,
  "sourceId": string | null,
  "amount": double | null,
  "isQuantity": boolean,
  "missingField": "amount" | "tokenSymbol" | null,
  "confidence": double
}
''';

    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': input},
    ];

    try {
      final response = await _postChat(
        (fallback) => buildChatRequestBody(
          messages: messages,
          temperature: 0.0, // Strict and deterministic parsing
          maxTokens: 150,
          fallback: fallback,
        ),
        _tradeIntentTimeout,
      );

      if (response.statusCode != 200) {
        _log.w('solveTradeIntent failed with status: ${response.statusCode}');
        return null;
      }

      final body = jsonDecode(response.body);
      final content = body['choices'][0]['message']['content'] as String;

      Map<String, dynamic>? decoded;
      try {
        decoded = Map<String, dynamic>.from(jsonDecode(content) as Map);
      } catch (_) {
        final jsonStr = _extractBalancedJson(content);
        if (jsonStr != null) {
          decoded = Map<String, dynamic>.from(jsonDecode(jsonStr) as Map);
        }
      }
      return decoded;
    } catch (e) {
      _log.e('solveTradeIntent error: $e');
      return null;
    }
  }

  /// Extracts the outermost balanced `{...}` JSON block from [text].
  ///
  /// Unlike a greedy regex (`\{.*\}`), this tracks brace depth and respects
  /// string literals, so it won't capture truncated or unbalanced JSON.
  /// Returns `null` if no balanced block is found.
  static String? _extractBalancedJson(String text) {
    int? start;
    int depth = 0;
    bool inString = false;
    bool escape = false;

    for (int i = 0; i < text.length; i++) {
      final c = text[i];

      if (escape) {
        escape = false;
        continue;
      }
      if (c == '\\' && inString) {
        escape = true;
        continue;
      }
      if (c == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;

      if (c == '{') {
        if (depth == 0) start = i;
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0 && start != null) {
          return text.substring(start, i + 1);
        }
      }
    }
    return null; // No balanced block found (truncated or missing)
  }

  /// Truncates [text] to at most [maxChars] characters, cutting at the last
  /// complete line boundary. Appends a count of dropped lines so the AI knows
  /// the full memory is larger than what's shown.
  static String _truncateAtLineBoundary(String text, int maxChars) {
    if (text.length <= maxChars) return text;

    final lines = text.split('\n');
    final buf = StringBuffer();
    int kept = 0;

    for (final line in lines) {
      // +1 for the newline character
      if (buf.length + line.length + 1 > maxChars) break;
      if (kept > 0) buf.write('\n');
      buf.write(line);
      kept++;
    }

    final dropped = lines.length - kept;
    if (dropped > 0) {
      buf.write('\n  ... ($dropped more entries not shown)');
    }

    return buf.toString();
  }

  // ── Streaming variant for voice pipeline ─────────────────────────────────
  // Delegates to solve() for ALL logic (tools, JSON, mode enforcement,
  // history, language retry) — zero code duplication.
  // Then chunks the speechText result for TTS pipelining.
  //
  // Chunk strategy (pause-based, NOT sentence-split):
  //  - First chunk:  ~20 chars — fastest perceived response
  //  - Later chunks: ~50 chars — natural speech pacing
  //  - Emit on space/comma/period when buffer is long enough

  Stream<String> solveStreaming(String input,
      [String languageCode = 'ru']) async* {
    final isRu = _isRu(input, languageCode);
    try {
      final result = await solve(input, languageCode);
      final speechText = result['speechText']?.toString() ?? '';
      if (speechText.isEmpty) {
        yield result['displayMessage']?.toString() ??
            (isRu ? 'Нет ответа.' : 'No response.');
        return;
      }

      // Chunk the speechText for TTS streaming.
      bool isFirst = true;
      final buf = StringBuffer();

      for (int i = 0; i < speechText.length; i++) {
        buf.write(speechText[i]);
        final threshold = isFirst ? 20 : 50;

        if (buf.length >= threshold && isNaturalBreak(speechText[i])) {
          yield buf.toString();
          buf.clear();
          isFirst = false;
        }
      }

      if (buf.isNotEmpty) {
        yield buf.toString();
      }
    } catch (e) {
      _log.e('solveStreaming error', e);
      yield _unavailableResponse(isRu)['speechText'] as String;
    }
  }

  /// Returns true if the character is a natural speech pause point.
  static bool isNaturalBreak(String char) {
    return char == ' ' ||
        char == ',' ||
        char == '.' ||
        char == '!' ||
        char == '?' ||
        char == ';' ||
        char == ':' ||
        char == '\n';
  }

  @visibleForTesting
  Future<String> executeToolForTest(String name,
          [String argumentsJson = '{}']) =>
      _executeTool(name, argumentsJson);

  Future<String> _executeTool(String name, String argumentsJson) async {
    final wallet = WalletAdapter.instance;
    final ts = DateTime.now().toIso8601String();

    switch (name) {
      case 'get_wallet_balance':
        _setActivity('Проверяю баланс кошелька...');
        if (!wallet.isConnected) {
          _setActivity(null);
          return '{"error": "Wallet disconnected"}';
        }
        final summary = await PortfolioAdapter.instance
            .fetchSummary(wallet.address, wallet.chainKey);
        final allAssets = summary.allAssets
            .take(5)
            .map((a) =>
                '${a.symbol}: ${a.balance.toStringAsFixed(4)} (~\$${a.valueUsd.toStringAsFixed(2)})')
            .toList();
        _setActivity(null);
        return jsonEncode({
          'balance_usd': summary.totalBalanceUsd,
          'asset_count': summary.assetsCount,
          'top_assets': allAssets,
          'timestamp': ts,
        });

      case 'get_vault_info':
        _setActivity('Получаю информацию о кошельке...');
        final vaultInfo = IBITIVaultService.instance;
        final cards = vaultInfo.evmCardAddresses;
        // Card names follow the CardAccent order: Black, Silver, Gold, Platinum
        const cardNames = ['Black', 'Silver', 'Gold', 'Platinum'];
        final namedCards = List.generate(cards.length, (i) {
          final name = i < cardNames.length ? cardNames[i] : 'Card ${i + 1}';
          final addr = cards[i];
          final short = addr.length > 10
              ? '${addr.substring(0, 6)}...${addr.substring(addr.length - 4)}'
              : addr;
          return {'name': 'Card $name', 'address': short};
        });
        _setActivity(null);
        return jsonEncode({
          'card_count': cards.length,
          'cards': namedCards,
          'solana_address': vaultInfo.solanaAddress != null
              ? '${vaultInfo.solanaAddress!.substring(0, 6)}...'
              : null,
          'tron_address': vaultInfo.tronAddress != null
              ? '${vaultInfo.tronAddress!.substring(0, 6)}...'
              : null,
          'active_address': vaultInfo.activeAddress,
          'timestamp': ts,
        });

      case 'get_wallet_address':
        _setActivity('Получаю адрес кошелька...');
        if (!wallet.isConnected) {
          _setActivity(null);
          return '{"error": "Wallet disconnected"}';
        }
        final activeAddress = IBITIVaultService.instance.activeAddress;
        _setActivity(null);
        return jsonEncode({
          'address': activeAddress,
          'timestamp': ts,
        });

      case 'get_crypto_price':
        _setActivity('Получаю актуальную цену...');
        try {
          final args = jsonDecode(argumentsJson);
          final symbol = (args['query']?.toString() ?? 'ETH').toLowerCase();
          final result = await _fetchCryptoPrice(symbol);
          _setActivity(null);
          return result;
        } catch (e) {
          _setActivity(null);
          return '{"error": "Price fetch failed: $e"}';
        }

      case 'get_fiat_rate':
        _setActivity('Смотрю курс валют...');
        try {
          final args = jsonDecode(argumentsJson);
          final from = (args['from']?.toString() ?? 'USD').toUpperCase();
          final to = (args['to']?.toString() ?? 'UAH').toUpperCase();
          final result = await _fetchFiatRate(from, to);
          _setActivity(null);
          return result;
        } catch (e) {
          _setActivity(null);
          return '{"error": "Rate fetch failed: $e"}';
        }

      case 'scan_security_risks':
        // Reads results only. It used to report "0 risks" when no scan had
        // run at all, which sounded like a clean wallet.
        _setActivity('Смотрю результаты Safe Scan...');
        await _loadSystemStatus();
        final scanPayload = buildSafeScanPayload(
          lastScanAt: ApprovalScanService.lastScanTime,
          lastScanApprovals: ApprovalScanService.lastScannedApprovals,
          savedRiskyScans: SystemStatusService.instance.riskyScans,
        );
        _setActivity(null);
        return jsonEncode({...scanPayload, 'timestamp': ts});

      case 'get_system_status':
        _setActivity('Проверяю статус системы...');
        await _loadSystemStatus();
        final statusPayload = buildSystemStatusPayload(
          problems: SystemStatusService.instance.problems,
          riskyScans: SystemStatusService.instance.riskyScans,
        );
        _setActivity(null);
        return jsonEncode({...statusPayload, 'timestamp': ts});

      case 'panic_revoke_all':
        _setActivity('Запускаю экстренный отзыв...');
        _setActivity(null);
        // Signal to the UI layer to open panic modal
        return jsonEncode({
          'action': 'OPEN_GUARDIAN_MODAL',
          'mode': 'panic',
          'timestamp': ts,
          'message':
              'Panic window opened: it scans the wallet and lists the critical '
              'approvals; they are revoked only after the user taps revoke '
              '(«Ручной»: + PIN; «Автономный»: per the AI PIN setting).',
        });

      // Security policy belongs to the user alone. The assistant may explain the
      // Trust List but must never mutate it: model context can carry text that
      // came from read_url / web_search, i.e. from a third party, and that text
      // is indistinguishable from a spoken user command once it is in the window.
      // The tool is no longer advertised; this case is the code-level refusal in
      // case the model invents the call anyway.
      case 'manage_trusted_list':
        return jsonEncode({
          'error': 'policy_change_requires_user',
          'message':
              'Trusted addresses are part of the security policy and can only '
              'be changed by the owner, with the PIN: Command Center > Trusted '
              'addresses, or Address book > Trust for AI.',
          'timestamp': ts,
        });

      case 'safe_revoke_review':
        _setActivity('Открываю безопасный режим...');
        _setActivity(null);
        // Signal to the UI layer to open safe modal
        return jsonEncode({
          'action': 'OPEN_GUARDIAN_MODAL',
          'mode': 'safe',
          'timestamp': ts,
          'message':
              'Safe Review flow initiated. Scanning your wallet for risky approvals.',
        });

      case 'web_search':
        _setActivity('Ищу в интернете...');
        try {
          final args = jsonDecode(argumentsJson);
          final query = args['query']?.toString() ?? '';
          final result = await _webSearch(query);
          _setActivity(null);
          return result;
        } catch (e) {
          _setActivity(null);
          return '{"error": "Web search failed: $e"}';
        }

      case 'read_url':
        try {
          final args = jsonDecode(argumentsJson);
          final url = args['url']?.toString() ?? '';
          // Show the domain being read for a more informative status
          final domain = Uri.tryParse(url)?.host ?? url;
          _setActivity('Читаю сайт $domain...');
          final result = await _readUrl(url);
          _setActivity(null);
          return result;
        } catch (e) {
          _setActivity(null);
          return '{"error": "URL read failed: $e"}';
        }

      case 'get_market_overview':
        _setActivity('Анализирую рынок...');
        final markets = MarketDataService.instance.cachedMarkets;
        if (markets.isEmpty) {
          _setActivity(null);
          return jsonEncode({
            'error': 'Market data not loaded yet. Try again in a few seconds.'
          });
        }
        final sorted = List<MarketAsset>.from(markets)
          ..sort((a, b) => b.change24h.compareTo(a.change24h));
        final topGainers = sorted
            .take(5)
            .map((a) => {
                  'symbol': a.symbol,
                  'name': a.name,
                  'price': a.price,
                  'change24h': a.change24h,
                  'volume': a.volume,
                })
            .toList();
        final topLosers = sorted.reversed
            .take(5)
            .map((a) => {
                  'symbol': a.symbol,
                  'name': a.name,
                  'price': a.price,
                  'change24h': a.change24h,
                  'volume': a.volume,
                })
            .toList();
        final keySymbols = {'BTC', 'ETH', 'BNB', 'SOL'};
        final keyAssets = markets
            .where((a) => keySymbols.contains(a.symbol))
            .map((a) => {
                  'symbol': a.symbol,
                  'price': a.price,
                  'change24h': a.change24h,
                })
            .toList();
        _setActivity(null);
        return jsonEncode({
          'totalAssets': markets.length,
          'topGainers': topGainers,
          'topLosers': topLosers,
          'keyAssets': keyAssets,
          'timestamp': ts,
        });

      // ── Phase K: expanded knowledge tool handlers ─────────────────────
      case 'get_transaction_history':
        _setActivity('Загружаю историю транзакций...');
        if (!wallet.isConnected) {
          _setActivity(null);
          return '{"error": "Wallet disconnected"}';
        }
        try {
          final page = await TxHistoryService.fetch(
            address: wallet.address,
            chainKey: wallet.chainKey,
          );
          final txList = page.transactions.take(10).map((tx) => {
                'hash': tx.shortHash,
                'type': tx.type.name,
                'token': tx.tokenSymbol ?? (tx.type == OnChainTxType.swap
                    ? '${tx.sellSymbol} → ${tx.buySymbol}'
                    : 'native'),
                'value': tx.type == OnChainTxType.swap
                    ? '${tx.sellValue?.toStringAsFixed(4)} → ${tx.buyValue?.toStringAsFixed(4)}'
                    : tx.value.toStringAsFixed(4),
                'date': tx.blockTimestamp.toIso8601String(),
                'success': tx.isSuccess,
                'summary': tx.summary,
              }).toList();
          _setActivity(null);
          return jsonEncode({
            'transactions': txList,
            'count': txList.length,
            'chain': wallet.chainKey,
            'timestamp': ts,
          });
        } catch (e) {
          _setActivity(null);
          return jsonEncode({'error': 'History fetch failed: $e'});
        }

      case 'get_audit_log':
        _setActivity('Читаю лог действий...');
        final entries = AuditLogService.instance.entries.take(10).map((e) => {
              'action': e.actionLabel,
              'summary': e.summary,
              'success': e.result.success,
              'source': e.executionSource.name,
              'time': e.initiatedAt.toIso8601String(),
            }).toList();
        _setActivity(null);
        return jsonEncode({
          'entries': entries,
          'count': entries.length,
          'total_session': AuditLogService.instance.entries.length,
          'timestamp': ts,
        });

      case 'get_address_book':
        _setActivity('Загружаю контакты...');
        final contacts = AddressBookService.instance.entries.map((e) {
          final addr = e.address;
          final short = addr.length > 10
              ? '${addr.substring(0, 6)}...${addr.substring(addr.length - 4)}'
              : addr;
          return {'label': e.label, 'address': short, 'full_address': addr};
        }).toList();
        _setActivity(null);
        return jsonEncode({
          'contacts': contacts,
          'count': contacts.length,
          'timestamp': ts,
        });

      case 'get_trusted_addresses':
        _setActivity('Загружаю доверенные адреса...');
        final payload = buildTrustedAddressesPayload(
          PolicyProfileStore.instance.current,
          TrustedAddressDirectory.current(),
        );
        _setActivity(null);
        return jsonEncode({...payload, 'timestamp': ts});

      case 'get_pending_transactions':
        _setActivity('Проверяю статус транзакций...');
        final reg = TxRegistry.instance;
        final active = reg.activeTx;
        final recentTerminal = reg.history
            .where((e) => e.isTerminal)
            .toList()
            .reversed
            .take(5)
            .map((e) => {
                  'hash': e.txHash.length > 16
                      ? '${e.txHash.substring(0, 10)}...${e.txHash.substring(e.txHash.length - 6)}'
                      : e.txHash,
                  'status': e.status.name,
                  'operation': e.operationLabel,
                  'asset': e.assetLabel,
                  'time': e.timestamp.toIso8601String(),
                })
            .toList();
        _setActivity(null);
        return jsonEncode({
          'has_pending': reg.hasPending,
          'active_tx': active != null
              ? {
                  'hash': active.txHash.length > 16
                      ? '${active.txHash.substring(0, 10)}...${active.txHash.substring(active.txHash.length - 6)}'
                      : active.txHash,
                  'status': active.status.name,
                  'operation': active.operationLabel,
                  'asset': active.assetLabel,
                }
              : null,
          'recent_completed': recentTerminal,
          'total_history': reg.history.length,
          'timestamp': ts,
        });

      case 'manage_watchlist':
        try {
          final args = jsonDecode(argumentsJson);
          final action = args['action']?.toString() ?? 'add';
          final symbol = (args['symbol']?.toString() ?? '').toUpperCase();
          if (symbol.isEmpty) {
            return jsonEncode({'error': 'Symbol is required'});
          }

          final isAdd = action == 'add';
          _setActivity(isAdd
              ? 'Добавляю $symbol в отслеживание...'
              : 'Убираю $symbol из отслеживания...');

          // MarketWatchlistService uses asset IDs (lowercase symbol for simplicity)
          final assetId = symbol.toLowerCase();
          final alreadyWatched =
              MarketWatchlistService.instance.contains(assetId);

          if (isAdd && alreadyWatched) {
            _setActivity(null);
            return jsonEncode({
              'success': true,
              'action': 'already_watched',
              'symbol': symbol,
              'message': '$symbol is already in your watchlist.',
              'timestamp': ts,
            });
          }
          if (!isAdd && !alreadyWatched) {
            _setActivity(null);
            return jsonEncode({
              'success': true,
              'action': 'not_in_watchlist',
              'symbol': symbol,
              'message': '$symbol is not in your watchlist.',
              'timestamp': ts,
            });
          }

          await MarketWatchlistService.instance.toggle(assetId);
          _setActivity(null);
          return jsonEncode({
            'success': true,
            'action': action,
            'symbol': symbol,
            'timestamp': ts,
          });
        } catch (e) {
          _setActivity(null);
          return jsonEncode({'error': 'Watchlist operation failed: $e'});
        }

      default:
        return '{"error": "Unknown tool: $name"}';
    }
  }

  /// Code-level tool permission gate. In «Советник» (AiMode.manual) the AI
  /// only advises: only read-only tools are allowed. Action tools (panic,
  /// safe_revoke, manage_watchlist) need «Ручной» or «Автономный». Panic and
  /// safe only open a window where the user confirms; they never mutate
  /// security policy themselves.
  static bool _isToolAllowedByMode(String toolName) {
    final settings = AiControlService.instance.settings;
    if (settings.mode == AiMode.manual) {
      const readOnlyTools = {
        'get_wallet_balance',
        'get_vault_info',
        'get_wallet_address',
        'get_crypto_price',
        'get_fiat_rate',
        'web_search',
        'read_url',
        'scan_security_risks',
        'get_system_status',
        'get_market_overview',
        // Phase K: expanded knowledge read-only tools
        'get_transaction_history',
        'get_audit_log',
        'get_address_book',
        'get_trusted_addresses',
        'get_pending_transactions',
      };
      return readOnlyTools.contains(toolName);
    }
    return true;
  }

  /// Post-processing gate: strips uiCommands and blocks dangerous explicitIntents
  /// based on the current AI mode. Defense-in-depth — even if the LLM hallucinates
  /// an action in «Советник» (AiMode.manual), it won't reach the UI layer.
  static void _enforceModeOnResponse(Map<String, dynamic> decoded) {
    final mode = AiControlService.instance.settings.mode;

    if (mode == AiMode.manual) {
      // «Советник»: advice only, no UI mutations allowed
      decoded.remove('uiCommands');

      final intent = decoded['explicitIntent'];
      if (intent is Map) {
        final type = intent['type']?.toString();
        const blockedIntents = {
          'swapAsset',
          'sendAsset',
          'revokeAsset',
          'approveAsset',
        };
        if (blockedIntents.contains(type)) {
          decoded['explicitIntent'] = {
            'type': 'explainOnly',
            'reason':
                'Blocked in «Советник» (Advisor): the AI only advises. Switch '
                    'to «Ручной» or «Автономный» in Security → AI-Центр.',
          };
        }
      }
    }
  }

  // ---------- Real price APIs ----------

  /// CoinGecko free API — no key required.
  static const _geckoSymbolMap = {
    'btc': 'bitcoin',
    'eth': 'ethereum',
    'usdt': 'tether',
    'usdc': 'usd-coin',
    'bnb': 'binancecoin',
    'sol': 'solana',
    'xrp': 'ripple',
    'ada': 'cardano',
    'doge': 'dogecoin',
    'dot': 'polkadot',
    'avax': 'avalanche-2',
    'link': 'chainlink',
    'matic': 'matic-network',
    'shib': 'shiba-inu',
    'trx': 'tron',
    'ltc': 'litecoin',
    'atom': 'cosmos',
    'uni': 'uniswap',
    'dai': 'dai',
    'ibiti': 'ibiti',
  };

  Future<String> _fetchCryptoPrice(String symbolLower) async {
    final geckoId = _geckoSymbolMap[symbolLower] ?? symbolLower;
    try {
      final url = Uri.parse(
        'https://api.coingecko.com/api/v3/simple/price?ids=$geckoId&vs_currencies=usd&include_24hr_change=true',
      );
      final resp = await http.get(url).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data[geckoId] != null) {
          final price = data[geckoId]['usd'];
          final change = data[geckoId]['usd_24h_change'];
          return jsonEncode({
            'symbol': symbolLower.toUpperCase(),
            'price_usd': price,
            'change_24h':
                change != null ? '${change.toStringAsFixed(2)}%' : 'N/A',
            'timestamp': DateTime.now().toIso8601String(),
          });
        }
      }
      return jsonEncode({'error': 'Token $symbolLower not found on CoinGecko'});
    } catch (e) {
      return jsonEncode({'error': 'CoinGecko fetch failed: $e'});
    }
  }

  Future<String> _fetchFiatRate(String from, String to) async {
    try {
      final url = Uri.parse('https://open.er-api.com/v6/latest/$from');
      final resp = await http.get(url).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data['rates'] != null && data['rates'][to] != null) {
          final rate = data['rates'][to];
          return jsonEncode({
            'from': from,
            'to': to,
            'rate': rate,
            'timestamp': DateTime.now().toIso8601String(),
          });
        }
      }
      return jsonEncode({'error': 'Rate $from/$to not found'});
    } catch (e) {
      return jsonEncode({'error': 'Exchange rate fetch failed: $e'});
    }
  }

  /// web_search: uses DuckDuckGo Instant Answer API (completely free, no key required)
  Future<String> _webSearch(String query) async {
    _log.d('webSearch query: $query');
    try {
      final url = Uri.parse(
          'https://api.duckduckgo.com/?q=${Uri.encodeComponent(query)}&format=json&no_html=1&skip_disambig=1');
      final resp = await http.get(
        url,
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final abstract = data['AbstractText']?.toString() ?? '';
        final answer = data['Answer']?.toString() ?? '';
        final related = (data['RelatedTopics'] as List?)
                ?.take(3)
                .map((t) => t['Text']?.toString() ?? '')
                .where((s) => s.isNotEmpty)
                .join(' | ') ??
            '';

        final result =
            [answer, abstract, related].where((s) => s.isNotEmpty).join(' | ');
        if (result.isNotEmpty) {
          _log.d('webSearch got result (${result.length} chars)');
          return jsonEncode({'query': query, 'result': result});
        }
        // If DDG has no instant answer, tell the AI to use read_url instead
        return jsonEncode({
          'query': query,
          'result':
              'No instant answer found. Try read_url with a specific website URL for this topic.'
        });
      }
      _log.w('webSearch status: ${resp.statusCode}');
    } catch (e) {
      _log.e('webSearch error', e);
    }
    return jsonEncode({
      'error':
          'Не удалось выполнить поиск. Попробуйте использовать read_url с конкретным URL.'
    });
  }

  /// read_url: reads full text of any web page via Jina Reader (no API key required)
  Future<String> _readUrl(String url) async {
    _log.d('readUrl: $url');
    try {
      // Ensure URL has scheme
      final target = url.startsWith('http') ? url : 'https://$url';
      final jinaUrl = Uri.parse('https://r.jina.ai/$target');
      final resp = await http.get(
        jinaUrl,
        headers: {'Accept': 'text/plain'},
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final content =
            resp.body.length > 4000 ? resp.body.substring(0, 4000) : resp.body;
        _log.d('readUrl got ${resp.body.length} bytes from $target');
        return jsonEncode({'url': target, 'content': content});
      }
      _log.w('readUrl status: ${resp.statusCode}');
    } catch (e) {
      _log.e('readUrl error', e);
    }
    return jsonEncode({
      'error':
          'Не удалось загрузить страницу. Проверьте соединение или попробуйте другой URL.'
    });
  }

  /// Builds response-style instruction based on user's reviewStyle preference.
  String _buildReviewStyleInstruction(String personalContext) {
    final style = UserMemoryService.instance.preferences.reviewStyle;
    if (style == 'detailed') {
      return '''- Provide THOROUGH, DETAILED analysis with reasoning and context.
- When tool returns data — explain what it means, why it matters, and what the user should consider.
- Include numbers, percentages, comparisons where available.
- Structure longer responses with clear sections. Be informative but still natural.
- NEVER repeat the same data point twice in one response.''';
    }
    // Default: concise
    return '''- When tool returns data (balance, price, etc.) — write ONE clean sentence. NEVER repeat the same number twice.
- BAD: "Ваш баланс составляет \$12.38. У вас 3 актива. Баланс: \$12.38. Токенов: 3."
- GOOD: "У вас 3 актива на сумму \$12.38."
- Keep responses SHORT and NATURAL — like a smart human assistant, not a report generator.''';
  }

  /// Safe chain ID label for AI context — never throws.
  /// "0x7376…9015" — enough to tell wallets apart, not a full identifier
  /// sent to the LLM provider on every turn.
  static String _maskAddress(String? address) {
    if (address == null || address.isEmpty) return 'none';
    if (address.length <= 12) return address;
    return '${address.substring(0, 6)}…${address.substring(address.length - 4)}';
  }

  static String _safeChainIdLabel(WalletAdapter wallet) {
    try {
      return wallet.chainId.toString();
    } on StateError {
      return 'non-EVM:${wallet.chainKey}';
    }
  }

  /// The mode names the user sees (code names stay manual / guarded /
  /// fullAutonomy).
  static String _aiModeLabel(AiMode mode) => switch (mode) {
        AiMode.manual => '«Советник» (Advisor)',
        AiMode.guarded => '«Ручной» (Manual)',
        AiMode.fullAutonomy => '«Автономный» (Autonomous)',
      };

  /// Makes sure the saved Safe Scan results are loaded (the status card
  /// usually did it already). Never blocks a turn for long, never throws.
  static Future<void> _loadSystemStatus() async {
    try {
      await SystemStatusService.instance
          .load()
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      _log.w('System status not loaded', e);
    }
  }

  /// "send $50" style value of one wallet limit as the policy engine applies
  /// it: an expired temporary limit is back at the safe default
  /// (GuardianPolicyEngine._activeLimit).
  static String _walletLimitLabel(PolicyProfile profile, String action,
      double configured, double safeDefault) {
    final expiry = profile.actionExpiries[action];
    final now = DateTime.now();
    if (expiry != null && !now.isBefore(expiry)) {
      return '\$${safeDefault.toStringAsFixed(0)} (temporary limit ended)';
    }
    final until = expiry == null
        ? ''
        : ' (temporary, until ${expiry.toIso8601String().substring(0, 16)})';
    return '\$${configured.toStringAsFixed(0)}$until';
  }

  Future<String> _buildAppContextSnapshot() async {
    final wallet = WalletAdapter.instance;
    await _loadSystemStatus();
    final status = SystemStatusService.instance;
    final statusProblems = status.problems;
    final statusLine = statusProblems.isEmpty
        ? 'Safe (green)'
        : 'Danger (red); problems: ${statusProblems.map((p) => p == SystemProblem.riskyApprovals ? '${p.name} (${status.riskyApprovals})' : p.name).join(', ')}';
    final safeDefaults = PolicyProfile.safe();
    final okxConnected = await ExchangeAccountStore.instance.isConnected('okx');
    String okxRegionStr = 'disconnected';
    String okxQuoteStr = 'USDT';
    if (okxConnected) {
      final reg = await ExchangeAccountStore.instance.getOkxRegion() ?? 'global';
      okxRegionStr = reg;
      okxQuoteStr = reg == 'eea' ? 'USDC' : 'USDT';
    }
    final vault = IBITIVaultService.instance;
    final summary = VaultPortfolioListener.instance.summary;
    final assets = summary?.allAssets ?? const [];
    final latestTx = TxRegistry.instance.latest;
    final topAssets = assets
        .take(5)
        .map(
          (asset) =>
              '${asset.symbol}:${asset.balance.toStringAsFixed(4)}(~\$${asset.valueUsd.toStringAsFixed(2)})',
        )
        .join(', ');
    final aiSettings = AiControlService.instance.settings;
    final mandate = aiSettings.mandate;
    final trustProfile = PolicyProfileStore.instance.current;
    final evmCards = vault.evmCardAddresses;
    final perCardLines = evmCards.isEmpty
        ? 'none'
        : evmCards.map((address) {
            final cardSummary = VaultPortfolioListener.instance
                .summaryForAddress(address, vault.chainKey);
            final total =
                cardSummary?.totalBalanceUsd.toStringAsFixed(2) ?? 'loading';
            return '${address.substring(0, address.length > 10 ? 10 : address.length)}:$total USD';
          }).join(', ');
    final activeAssets = assets.take(8).map((asset) {
      final chain =
          asset.chainKey.isNotEmpty ? asset.chainKey : '${asset.chainId}';
      return '${asset.symbol}@$chain:${asset.balance.toStringAsFixed(4)}(~\$${asset.valueUsd.toStringAsFixed(2)})';
    }).join(', ');

    return '''
- Wallet connected: ${wallet.isConnected}
- Active address: ${_maskAddress(wallet.address)}
- Active chain key: ${wallet.chainKey}
- Active chain id: ${_safeChainIdLabel(wallet)}
- Active vault cards: ${evmCards.length} of ${vault.maxEvmCards} max (tiers: Black, Silver, Gold, Platinum)
- EVM card balances USD: $perCardLines
- Can create more cards: ${vault.canCreateAdditionalEvmCard}
- Solana address: ${_maskAddress(vault.solanaAddress)}
- Tron address: ${_maskAddress(vault.tronAddress)}
- Portfolio total USD: ${summary?.totalBalanceUsd.toStringAsFixed(2) ?? 'unknown'}
- Asset count: ${summary?.assetsCount ?? assets.length}
- Top assets: ${topAssets.isEmpty ? 'none' : topAssets}
- Active assets by network: ${activeAssets.isEmpty ? 'none' : activeAssets}
- Recent tx count: ${TxRegistry.instance.history.length}
- Latest tx: ${latestTx == null ? 'none' : '${latestTx.status.name} ${latestTx.assetLabel ?? latestTx.operationLabel ?? latestTx.txHash.substring(0, 8)}'}
- Saved recipients: ${AddressBookService.instance.entries.length}
- Trusted addresses (AI whitelist, read-only for AI): ${trustProfile.trustedAddresses.length + trustProfile.trustedContracts.length}; policy mode ${trustProfile.mode.name}${trustProfile.mode == PolicyMode.safe ? ' (STRICT: AI may send only to these)' : ''}
- System status card: $statusLine
- AI mode: ${_aiModeLabel(aiSettings.mode)}: ${_aiModeDuty(aiSettings.mode)}
- AI action PIN confirmation: ${pinConfirmationLabel(aiSettings)}
- Wallet limits (USD value of ONE operation; Security → Policy): send ${_walletLimitLabel(trustProfile, 'SEND', trustProfile.sendLimitUsd, safeDefaults.sendLimitUsd)}, swap ${_walletLimitLabel(trustProfile, 'SWAP', trustProfile.swapLimitUsd, safeDefaults.swapLimitUsd)}, approve ${_walletLimitLabel(trustProfile, 'APPROVE', trustProfile.approveLimitUsd, safeDefaults.approveLimitUsd)} (unlimited approvals always blocked)
- Block unknown contracts: ${trustProfile.allowUnknownContracts ? 'OFF (unknown contracts allowed)' : 'ON'}
- Daily trading limit USD (everything not started in the wallet's own Send/Swap windows: exchange buys, the AI's exchange sells, and the sends, swaps and trades the AI carries out itself from chat, voice or «Делегировать AI»): ${aiSettings.dailyLimit.toStringAsFixed(0)}
- Min trade balance USD (no exchange buy below it): ${aiSettings.minTradeBalance.toStringAsFixed(0)}
- AI mandate goal: ${mandate.goal.name}
- AI mandate assets: ${mandate.allowedAssets.isEmpty ? 'any' : mandate.allowedAssets.join(', ')}
- AI mandate networks: ${mandate.allowedNetworks.isEmpty ? 'any' : mandate.allowedNetworks.join(', ')}
- AI mandate venues: ${mandate.allowedVenues.isEmpty ? 'any' : mandate.allowedVenues.join(', ')}
- AI mandate max position size USD: ${mandate.maxPositionUsd.toStringAsFixed(2)}
- AI mandate max gas USD: ${mandate.maxGasUsd.toStringAsFixed(2)}
- AI mandate max slippage bps: ${mandate.maxSlippageBps}
- AI mandate requires human for unknown: ${mandate.requireHumanForUnknown}
- User preferred stablecoin: ${UserMemoryService.instance.preferences.preferredStablecoin ?? 'not set'}
- User preferred venue: ${UserMemoryService.instance.preferences.preferredVenue ?? 'not set'}
- User preferred network: ${UserMemoryService.instance.preferences.preferredNetwork ?? 'not set'}
- Known app surfaces: wallet, market, security_center, settings, wallet_send, wallet_receive, wallet_swap, wallet_history, wallet_settings, wallet_address_book, trusted_addresses, safe, panic, ai_control, policy_limits, epk_control, audit_history
- OKX Spot connected: $okxConnected (Region: $okxRegionStr, Quote Currency: $okxQuoteStr)
- OKX Quote/Trading Rules: If OKX region is eea, OKX trading is processed in USDC instead of USDT (e.g. BTC-USDC, SOL-USDC) due to MiCA regulations. If global, trading is primarily in USDT. No blind fallback to USDT is permitted. Use USDT only if the exact OKX pair exists and findBestPair selected it; if the resolved pair is not available, trading is blocked. Explain this to the user in their preferred language if they ask.
- When suggesting swaps, use the user's preferred stablecoin as the default quote token if set.
- When suggesting venues or routes, prefer the user's preferred venue if set.
- When discussing networks, prefer the user's preferred network if set.

- Current screen context:
${ScreenContextService.instance.buildContextPrompt()}
  ''';
  }

  // ── Tool Routing Hints ──────────────────────────────────────────────────

  @visibleForTesting
  static String? toolHintFor(String input) => _buildToolHint(input);

  /// "System status" card wording that needs no card word: "статус системы",
  /// "system status", "status card".
  static final _systemStatusPhrase = RegExp(
      r'статус[а-яё]*\s+систем|систем[а-яё]*\s+статус|system status|status card');

  /// Words that, next to a card word, mean the status card (its title, its
  /// colours, its «Опасно» badge) rather than a wallet card.
  static final _statusCardWord =
      RegExp(r'статус|status|красн|зел[её]н|опасн|danger|\bred\b|\bgreen\b');

  static final _anyCardWord = RegExp(r'карт|card');

  /// True when [lower] asks about the System status card on the Wallet tab.
  static bool _mentionsSystemStatusCard(String lower) {
    if (_systemStatusPhrase.hasMatch(lower)) return true;
    // "безопасно" / "прекрасно" contain "опасн" / "красн" but say nothing
    // about the card's colour.
    final cleaned =
        lower.replaceAll('безопасн', ' ').replaceAll('прекрасн', ' ');
    return _anyCardWord.hasMatch(cleaned) && _statusCardWord.hasMatch(cleaned);
  }

  /// Deterministic pre-processor: detects what kind of question the user is
  /// asking and returns a strong routing hint, sent as a system message
  /// before the user message. It keeps the model from picking a tool by an
  /// ambiguous keyword ("кошелёк", "карточка").
  static String? _buildToolHint(String input) {
    final lower = input.toLowerCase();

    // Trusted addresses (AI whitelist) → get_trusted_addresses. Checked first:
    // "доверенные адреса карты" is still about the whitelist.
    if (UICommandResolver.mentionsTrustedList(
      lower,
      contactLabels: AddressBookService.instance.entries.map((e) => e.label),
    )) {
      return '[TOOL ROUTING: The user is asking about TRUSTED ADDRESSES (AI '
          'whitelist), not the address book and not their own wallet '
          'address. You MUST call get_trusted_addresses. You cannot add or '
          'remove trusted addresses; if asked, say only the owner can, with '
          'the PIN, in Command Center → Trusted addresses or Address book → '
          'Trust for AI.]';
    }

    // The System status card (green Safe / red Danger) is not a wallet card:
    // "почему карточка статуса красная?" → get_system_status. Checked before
    // the wallet-card patterns below, which would match "карточка".
    if (_mentionsSystemStatusCard(lower)) {
      return '[TOOL ROUTING: The user is asking about the "System status" '
          'card on the Wallet tab (RU «Статус системы»: green «Безопасно» / '
          'red «Опасно»), NOT about wallet cards. You MUST call '
          'get_system_status. Do NOT call get_vault_info. Explain each '
          'problem and its button as the APP GUIDE describes.]';
    }

    // Card / vault structure queries → get_vault_info
    final cardPatterns = [
      'карточ', // карточек, карточки, карточку
      'карт ', // карт (standalone, e.g. "сколько карт")
      'карты',
      'карта ',
      'карта\n',
      'карту',
      'карте',
      'какая карта',
      'какие карт',
      'cards',
      'card count',
      'card balance',
      'card status',
      'which card',
      'how many cards',
      'how many wallets',
      'сколько кошельк', // сколько кошельков
      'карт создано',
      'список карт',
      'карточки в кошельке',
      'карты в кошельке',
    ];
    if (cardPatterns.any((p) => lower.contains(p))) {
      return '[TOOL ROUTING: The user is asking about CARDS / wallet structure. '
          'Cards have 4 tiers: Black (primary), Silver, Gold, Platinum. '
          'Each card is a separate EVM address with its own balance. '
          'You MUST call get_vault_info. Do NOT call get_wallet_balance.]';
    }

    return null;
  }
}

/// The `get_trusted_addresses` tool result, without the timestamp.
@visibleForTesting
Map<String, dynamic> buildTrustedAddressesPayload(
  PolicyProfile profile,
  List<TrustedAddressItem> items,
) {
  final list = [
    for (final i in items)
      {
        'label': i.label,
        'address': i.shortAddress,
        'full_address': i.address,
        'type': i.isContract ? 'contract' : 'address',
      },
  ];
  return {
    'trusted': list,
    'count': list.length,
    'policy_mode': profile.mode.name,
    'strict': profile.mode == PolicyMode.safe,
    'ai_can_modify': false,
    'how_to_change': 'Owner only, with PIN: Command Center > Trusted '
        'addresses > Add, or Address book > Trust for AI.',
    'note': 'Applies to AI, market and dApp sends on every wallet network '
        "while the policy is STRICT; the owner's own wallet sends are not "
        'limited.',
  };
}

/// What each System status problem means and the button that fixes it (the
/// "What's wrong" sheet: wallet_space_screen.dart _ProblemTile / _fix).
const Map<SystemProblem, ({String meaning, String fix})> _systemProblemInfo = {
  SystemProblem.riskyApprovals: (
    meaning: 'Safe Scan found token approvals that can be used to take '
        'tokens (see riskyScans).',
    fix: 'Tap the red card → «Открыть «Защиту»» (Open Security) → tile '
        '«Safe/Panic» (or «Рисков: N») → «Сейф» or «Паника» → revoke them. '
        'Each revoke is an on-chain transaction with a small network fee. '
        'Revoking works in every AI mode when the user opens Safe/Panic; '
        'a window the AI opened is review-only in «Советник», needs the PIN '
        'in «Ручной» and follows the AI PIN setting in «Автономный».',
  ),
  SystemProblem.sessionExpired: (
    meaning: 'The sign-in (Privy) session expired: transfers cannot be '
        'signed until the user signs in again.',
    fix: 'Tap the red card → «Войти» (Sign in): email code or Google.',
  ),
  SystemProblem.notificationsOff: (
    meaning: 'Android notifications are blocked: no top-up, price or API '
        'key messages.',
    fix: 'Tap the red card → «Разрешить» (Allow). If that does not help: '
        'Android Settings → Apps → IBITI Guardian → Notifications.',
  ),
};

String _networkName(int chainId) =>
    PrivyChainRegistry.getEvmChain(chainId)?.displayName ?? 'Chain $chainId';

List<Map<String, dynamic>> _riskyScanRows(List<RiskyScan> scans) => [
      for (final s in scans)
        {
          'network': _networkName(s.chainId),
          'wallet': OpenAIChatService._maskAddress(s.wallet),
          'count': s.count,
        },
    ];

/// The `get_system_status` tool result, without the timestamp: what the
/// "System status" card on the Wallet tab shows right now.
@visibleForTesting
Map<String, dynamic> buildSystemStatusPayload({
  required List<SystemProblem> problems,
  required List<RiskyScan> riskyScans,
}) {
  final safe = problems.isEmpty;
  return {
    'isSafe': safe,
    'card': safe ? 'green «Безопасно» (Safe)' : 'red «Опасно» (Danger)',
    'problems': [
      for (final p in problems)
        {
          'problem': p.name,
          'meaning': _systemProblemInfo[p]?.meaning,
          'fix': _systemProblemInfo[p]?.fix,
        },
    ],
    'riskyScans': _riskyScanRows(riskyScans),
    'note': safe
        ? 'Green means: no Safe Scan result with unrevoked risky approvals, '
            'sign-in active, notifications allowed. A wallet or network '
            'that was never scanned is not checked.'
        : 'Tapping the red card opens «Что не так» (What\'s wrong) with one '
            'button per problem. The card turns green by itself once all '
            'are fixed (risky approvals: after revoking them in the app, or '
            'a new scan of that wallet + network that finds none).',
  };
}

/// The `scan_security_risks` tool result, without the timestamp. It reports
/// scan results and never starts a scan; "not scanned yet" is said plainly.
///
/// The scan's own list ([lastScanApprovals]) is not updated by a revoke, so
/// what is still risky comes from [savedRiskyScans] (SystemStatusService:
/// set after every full scan and lowered after every in-app revoke, per
/// wallet + network), the same numbers the System status card shows.
@visibleForTesting
Map<String, dynamic> buildSafeScanPayload({
  required DateTime? lastScanAt,
  required List<ApprovalData> lastScanApprovals,
  required List<RiskyScan> savedRiskyScans,
}) {
  final scanned = lastScanAt != null;
  final first = lastScanApprovals.isEmpty ? null : lastScanApprovals.first;
  final scannedWallet = first?.walletAddress?.toLowerCase();
  final scannedChainId = first?.chainId;
  final foundRisky =
      lastScanApprovals.where((a) => a.assessment.shouldRevoke).length;
  // Risky approvals of the scanned wallet + network not revoked yet. Unknown
  // only when the scan result carries no wallet (then see saved results).
  int? notRevoked;
  if (foundRisky == 0) {
    notRevoked = 0;
  } else if (scannedWallet != null) {
    notRevoked = 0;
    for (final s in savedRiskyScans) {
      if (s.chainId == scannedChainId &&
          s.wallet.toLowerCase() == scannedWallet) {
        notRevoked = s.count;
        break;
      }
    }
  }
  return {
    'scanned_this_session': scanned,
    if (lastScanAt == null) 'status': 'not_scanned_yet',
    if (lastScanAt != null)
      'last_scan': {
        'at': lastScanAt.toIso8601String(),
        if (first != null) 'network': _networkName(first.chainId),
        if (first != null && first.walletAddress != null)
          'wallet': OpenAIChatService._maskAddress(first.walletAddress),
        'approvals_checked': lastScanApprovals.length,
        'risky_found_by_scan': foundRisky,
        if (notRevoked != null) 'risky_not_revoked': notRevoked,
      },
    'saved_risky_results': _riskyScanRows(savedRiskyScans),
    'note': scanned
        ? 'The last scan covered one card on one network. '
            'risky_found_by_scan is what that scan found; '
            'risky_not_revoked is what is left after revokes made in the app '
            'since then (the System status card counts the same): report '
            'that one as still risky. saved_risky_results lists every '
            'wallet + network where risky approvals are not revoked yet.'
        : 'Safe Scan has not run in this session, so there is no fresh '
            'result; this tool does not scan. saved_risky_results lists only '
            'wallet + network pairs where an earlier scan found risky '
            'approvals not revoked yet. To scan: Security «Защита» → tile '
            '«Safe/Panic» → «Сейф» or «Паника» (opening either scans; '
            'scanning is free).',
  };
}
