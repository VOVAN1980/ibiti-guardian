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
import 'package:ibiti_guardian/services/adapters/security_adapter.dart';
import 'package:ibiti_guardian/services/execution/tx_registry.dart';
import 'package:ibiti_guardian/services/wallet/address_book_service.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';

/// OpenAI Chat service — replaces GeminiService entirely.
import 'package:ibiti_guardian/services/assistant/language_detector.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart'
    as policy_store;
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/services/assistant/user_memory_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_account_store.dart';

/// Uses gpt-4o-mini to resolve user intent into structured JSON.
class OpenAIChatService {
  OpenAIChatService._();
  static final instance = OpenAIChatService._();
  static const _log = GuardianLogger('OpenAI');

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

  /// Internal Message History — capped at 6 turns (12 messages).
  /// Beyond 6 turns, gpt-4o-mini degrades on intent classification.
  static const _maxHistoryTurns = 6;
  final List<Map<String, dynamic>> _history = [];

  void clearHistory() {
    _history.clear();
  }

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
  Future<Map<String, dynamic>> solve(String input,
      [String languageCode = 'ru']) async {
    await init();

    if (_apiKey == null) {
      return {
        'displayMessage':
            'Guardian AI is offline. Please check your OpenAI API key in Settings.',
        'speechText': 'Connection offline.',
      };
    }

    final aiSettings = AiControlService.instance.settings;
    final epkState = EPKPolicyManager.instance.state;
    final appContext = await _buildAppContextSnapshot();
    final rawPersonalContext =
        UserMemoryService.instance.buildPersonalContext();
    // Cap personal context to prevent prompt bloat.
    // Truncate at LINE boundaries so individual vocab/macro entries stay intact.
    final personalContext = _truncateAtLineBoundary(rawPersonalContext, 1000);

    final systemPrompt = '''
You are IBITI Guardian, an AI assistant and voice OS for the IBITI Guardian app.
App language is: $languageCode. Always respond in the user's language.

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

━━━ AI MODE & POLICY ━━━
Current Mode: ${aiSettings.mode.name.toUpperCase()}
Daily trading limit: ${aiSettings.dailyLimit}\$ per day.
Permitted Actions: ${aiSettings.allowedActions.map((e) => e.name).join(", ")}.
EPK State: ${epkState.isActive ? 'ACTIVE' : 'PAUSED'}, daily limit ${epkState.dailyLimit}\$.
If an action is blocked by mode or limits, explain the restriction clearly and guide the user on where to change it in settings.

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
              "Fetch information about the user's vault: number of wallet cards (EVM cards), all addresses (EVM, Solana, Tron). Use for questions about: how many cards, how many wallets, how many addresses, card count, wallet structure. Russian triggers: сколько карточек, сколько карт, карточки, карты, кошельки, адреса. ALWAYS use this tool when user asks about cards (карточки/карты)."
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
          "name": "manage_trusted_list",
          "description":
              "Add or remove a specific blockchain address or contract from the user's trusted whitelist (Trust List). Use when user asks to 'trust this address', 'whiten contact', or 'remove from trusted'.",
          "parameters": {
            "type": "object",
            "properties": {
              "action": {
                "type": "string",
                "enum": ["add", "remove"],
                "description": "Whether to add or remove the address."
              },
              "address": {
                "type": "string",
                "description": "The 0x blockchain address."
              },
              "type": {
                "type": "string",
                "enum": ["address", "contract"],
                "description":
                    "Whether it's a person/wallet (address) or a smart contract (contract)."
              }
            },
            "required": ["action", "address", "type"]
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
          "description": "Scan wallet for dangerous smart contract approvals."
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
              "EMERGENCY: immediately open Panic Revoke mode. Scans and revokes ALL critical dangerous approvals without delay. Call when user says: паника, emergency, revoke all, опасность, экстренно, всё ревокнуть."
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
      }
    ];

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

    try {
      int maxLoops = 3;
      for (int i = 0; i < maxLoops; i++) {
        final requestBody = {
          'model': 'gpt-4o-mini',
          'temperature': 0.7,
          'max_tokens': 1200,
          // NOTE: response_format: json_object is intentionally REMOVED
          // because it conflicts with 'tools'. With tools active, the model
          // returns tool_calls OR a final message. We enforce JSON via the system prompt.
          'messages': currentMessages,
          'tools': tools,
          'tool_choice': 'auto',
        };

        final response = await http
            .post(
              Uri.parse('https://api.openai.com/v1/chat/completions'),
              headers: {
                'Authorization': 'Bearer $_apiKey',
                'Content-Type': 'application/json'
              },
              body: jsonEncode(requestBody),
            )
            .timeout(const Duration(seconds: 45));

        if (response.statusCode != 200) {
          String errorDetail = '';
          try {
            final errBody = jsonDecode(response.body);
            errorDetail =
                errBody['error']?['message']?.toString() ?? response.body;
          } catch (_) {
            errorDetail = response.body;
          }
          final statusMsg = switch (response.statusCode) {
            401 =>
              'Invalid or expired API key (401). Please update your OpenAI key in Settings.',
            429 =>
              'OpenAI quota exceeded (429). Your account may have run out of credits.',
            500 ||
            503 =>
              'OpenAI server error (${response.statusCode}). Try again later.',
            _ => 'HTTP ${response.statusCode}: $errorDetail',
          };
          _log.e('$statusMsg');
          return {
            'displayMessage': statusMsg,
            'speechText': response.statusCode == 429
                ? 'Закончились токены OpenAI.'
                : response.statusCode == 401
                    ? 'Неверный API ключ.'
                    : 'Ошибка подключения.',
          };
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
          final isRu = languageCode.startsWith('ru');
          return {
            'displayMessage': isRu
                ? 'Ответ оказался слишком длинным и был обрезан. '
                    'Попробуйте задать вопрос конкретнее.'
                : 'My response was too long and got cut off. '
                    'Please try a simpler question.',
            'speechText': isRu
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
            String toolResult;
            if (!_isToolAllowedByMode(functionName)) {
              toolResult = jsonEncode({
                'error':
                    'Action "$functionName" is blocked in current AI mode (${AiControlService.instance.settings.mode.name}). '
                        'Change mode in Security → AI Control.',
                'mode': AiControlService.instance.settings.mode.name,
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
        final text = message['content'] as String;
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
          if (aiSpeech.isNotEmpty &&
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
          _history.add({'role': 'user', 'content': input});
          _history.add({'role': 'assistant', 'content': text});
          if (_history.length > _maxHistoryTurns * 2) {
            _history.removeRange(0, _history.length - _maxHistoryTurns * 2);
          }

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
      return {
        'displayMessage': 'Neural limit reached.',
        'speechText': 'Limit reached.'
      };
    } catch (e) {
      return {
        'displayMessage': 'Neural bridge failure: $e',
        'speechText': 'Failed.'
      };
    }
  }

  /// Primary trading intent resolver using gpt-4o-mini.
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
   - If the user is asking whether you are capable of buying/selling (e.g., "можешь покупать?", "умеешь покупать?", "can you buy?", "are you able to buy?", "ты можешь купить?", "можешь продать?"), this is a capability question, NOT an active trade command. Set type to "capabilityQuestion" and confidence to 1.0.
   - If the user is giving an actual imperative command to execute a trade (e.g. "купи SOL", "продай BTC", "купи монету на 1 долар"), set type to "buyAsset" or "sellAsset" accordingly.
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

    final messages = [
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': input},
    ];

    try {
      final requestBody = {
        'model': 'gpt-4o-mini',
        'temperature': 0.0, // Strict and deterministic parsing
        'max_tokens': 150,
        'messages': messages,
      };

      final response = await http
          .post(
            Uri.parse('https://api.openai.com/v1/chat/completions'),
            headers: {
              'Authorization': 'Bearer $_apiKey',
              'Content-Type': 'application/json'
            },
            body: jsonEncode(requestBody),
          )
          .timeout(const Duration(milliseconds: 2500)); // Strict 2.5 second timeout

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
    try {
      final result = await solve(input, languageCode);
      final speechText = result['speechText']?.toString() ?? '';
      if (speechText.isEmpty) {
        yield result['displayMessage']?.toString() ?? 'No response.';
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
      yield 'Failed.';
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
        _setActivity('Сканирую смарт-контракты...');
        if (!wallet.isConnected) {
          _setActivity(null);
          return '{"error": "No wallet"}';
        }
        final secSummary = await SecurityAdapter.instance
            .getSummary(wallet.address, wallet.chainId);
        _setActivity(null);
        return jsonEncode(
            {'risks': secSummary.riskyApprovalsCount, 'timestamp': ts});

      case 'panic_revoke_all':
        _setActivity('Запускаю экстренный отзыв...');
        _setActivity(null);
        // Signal to the UI layer to open panic modal
        return jsonEncode({
          'action': 'OPEN_GUARDIAN_MODAL',
          'mode': 'panic',
          'timestamp': ts,
          'message':
              'Panic revoke flow initiated. All critical approvals will be revoked immediately.',
        });

      case 'manage_trusted_list':
        final args = jsonDecode(argumentsJson);
        final action = args['action'];
        final address = args['address'];
        final type = args['type'];
        final isAdd = action == 'add';
        final isContract = type == 'contract';

        _setActivity(
            isAdd ? 'Добавляю в доверенные...' : 'Удаляю из доверенных...');
        final pStore = policy_store.PolicyProfileStore.instance;

        if (isAdd) {
          if (isContract) {
            await pStore.addTrustedContract(address);
          } else {
            await pStore.addTrustedAddress(address);
          }
        } else {
          if (isContract) {
            await pStore.removeTrustedContract(address);
          } else {
            await pStore.removeTrustedAddress(address);
          }
        }

        _setActivity(null);
        return jsonEncode({
          'success': true,
          'action': action,
          'address': address,
          'type': type,
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

      default:
        return '{"error": "Unknown tool: $name"}';
    }
  }

  /// Code-level tool permission gate. In Manual mode, only read-only tools are allowed.
  /// Mutating tools (panic, safe_revoke, manage_trusted_list) require Guarded or above.
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
        'get_market_overview',
      };
      return readOnlyTools.contains(toolName);
    }
    return true;
  }

  /// Post-processing gate: strips uiCommands and blocks dangerous explicitIntents
  /// based on the current AI mode. Defense-in-depth — even if the LLM hallucinates
  /// an action in Manual mode, it won't reach the UI layer.
  static void _enforceModeOnResponse(Map<String, dynamic> decoded) {
    final mode = AiControlService.instance.settings.mode;

    if (mode == AiMode.manual) {
      // Manual mode: no UI mutations allowed
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
                'Blocked in Manual mode. Switch to Guarded or Full Autonomy in Security → AI Control.',
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
  static String _safeChainIdLabel(WalletAdapter wallet) {
    try {
      return wallet.chainId.toString();
    } on StateError {
      return 'non-EVM:${wallet.chainKey}';
    }
  }

  Future<String> _buildAppContextSnapshot() async {
    final wallet = WalletAdapter.instance;
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
- Active address: ${wallet.address}
- Active chain key: ${wallet.chainKey}
- Active chain id: ${_safeChainIdLabel(wallet)}
- Active vault cards: ${evmCards.length} of ${vault.maxEvmCards} max (tiers: Black, Silver, Gold, Platinum)
- EVM card balances USD: $perCardLines
- Can create more cards: ${vault.canCreateAdditionalEvmCard}
- Solana address: ${vault.solanaAddress ?? 'none'}
- Tron address: ${vault.tronAddress ?? 'none'}
- Portfolio total USD: ${summary?.totalBalanceUsd.toStringAsFixed(2) ?? 'unknown'}
- Asset count: ${summary?.assetsCount ?? assets.length}
- Top assets: ${topAssets.isEmpty ? 'none' : topAssets}
- Active assets by network: ${activeAssets.isEmpty ? 'none' : activeAssets}
- Recent tx count: ${TxRegistry.instance.history.length}
- Latest tx: ${latestTx == null ? 'none' : '${latestTx.status.name} ${latestTx.assetLabel ?? latestTx.operationLabel ?? latestTx.txHash.substring(0, 8)}'}
- Saved recipients: ${AddressBookService.instance.entries.length}
- AI mode: ${aiSettings.mode.name}
- Allowed AI actions: ${aiSettings.allowedActions.map((e) => e.name).join(', ')}
- AI daily limit USD: ${aiSettings.dailyLimit.toStringAsFixed(2)}
- AI mandate goal: ${mandate.goal.name}
- AI mandate assets: ${mandate.allowedAssets.isEmpty ? 'any' : mandate.allowedAssets.join(', ')}
- AI mandate networks: ${mandate.allowedNetworks.isEmpty ? 'any' : mandate.allowedNetworks.join(', ')}
- AI mandate venues: ${mandate.allowedVenues.isEmpty ? 'any' : mandate.allowedVenues.join(', ')}
- AI mandate max daily trading limit USD: ${mandate.maxPositionUsd.toStringAsFixed(2)}
- AI mandate max daily loss USD: ${mandate.maxDailyLossUsd.toStringAsFixed(2)}
- AI mandate max drawdown pct: ${mandate.maxDrawdownPct.toStringAsFixed(2)}
- AI mandate max gas USD: ${mandate.maxGasUsd.toStringAsFixed(2)}
- AI mandate max slippage bps: ${mandate.maxSlippageBps}
- AI mandate max open positions: ${mandate.maxOpenPositions}
- AI mandate stop after losses: ${mandate.stopAfterLosses}
- AI mandate requires human for unknown: ${mandate.requireHumanForUnknown}
- User preferred stablecoin: ${UserMemoryService.instance.preferences.preferredStablecoin ?? 'not set'}
- User preferred venue: ${UserMemoryService.instance.preferences.preferredVenue ?? 'not set'}
- User preferred network: ${UserMemoryService.instance.preferences.preferredNetwork ?? 'not set'}
- Known app surfaces: wallet, market, security_center, settings, wallet_send, wallet_receive, wallet_swap, wallet_history, wallet_settings, wallet_address_book, safe, panic, ai_control, policy_limits, epk_control, audit_history
- AI can open screens, open modals, fill send/swap fields, prepare preview flows, analyze balances, compare market routes, and explain limits.
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

  /// Deterministic pre-processor: detects what kind of question the user is
  /// asking and returns a strong routing hint that is prepended to the user
  /// message. This compensates for gpt-4o-mini frequently ignoring tool
  /// descriptions when the query contains ambiguous keywords like "кошелёк".
  static String? _buildToolHint(String input) {
    final lower = input.toLowerCase();

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
