// ─── JARVIS AI Core ─────────────────────────────────────────────────────────────
//
// Phase 18E: The reasoning brain of JARVIS.
//
// Takes a JarvisContextPack, builds a prompt, sends to LLM, parses response.
// Handles provider selection, fallback chain, rate limiting, and cost tracking.
//
// Flow:
//   ContextPack → System Prompt + User Prompt → LLMProvider → JarvisThought
//
// The AI Core does NOT make the final trading decision.
// It produces a JarvisThought which the Debate/Loop uses as ADVISORY input.
// The deterministic rules remain as safety rails.
// ─────────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/services/ibiti/llm_provider.dart';
import 'package:ibiti_guardian/services/ibiti/jarvis_context_pack.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

const _log = GuardianLogger('JarvisAI');

// ═════════════════════════════════════════════════════════════════════════════
// JARVIS THOUGHT — structured LLM reasoning output
// ═════════════════════════════════════════════════════════════════════════════

class JarvisThought {
  /// JARVIS's internal reasoning chain.
  final String thought;

  /// Decision: BUY_SCOUT, BUY_MAIN, WATCH, SKIP, RESEARCH
  final String decision;

  /// Confidence in the decision (0.0–1.0).
  final double confidence;

  /// Human-readable reasoning.
  final String reasoning;

  /// Risk level: low, medium, high, extreme.
  final String riskLevel;

  /// Which rules JARVIS would override (if any).
  final List<String> rulesOverridden;

  /// What past memory influenced this decision.
  final List<String> memoryUsed;

  /// What JARVIS learned from this signal (preview for memory).
  final String lessonPreview;

  /// Suggested TP/SL adjustments (if JARVIS disagrees with TA).
  final double? suggestedTpPctOverride;
  final double? suggestedSlPctOverride;

  /// Which provider generated this thought.
  final String provider;

  /// How long the LLM took.
  final Duration latency;

  const JarvisThought({
    required this.thought,
    required this.decision,
    required this.confidence,
    required this.reasoning,
    required this.riskLevel,
    this.rulesOverridden = const [],
    this.memoryUsed = const [],
    this.lessonPreview = '',
    this.suggestedTpPctOverride,
    this.suggestedSlPctOverride,
    required this.provider,
    required this.latency,
  });

  /// Parse from LLM JSON response.
  /// HARDENED: LLMs return unpredictable types — String instead of List,
  /// int instead of double, null instead of empty. Handle all gracefully.
  factory JarvisThought.fromLLMResponse(LLMResponse response) {
    final j = response.json ?? {};

    return JarvisThought(
      thought: _asString(j['thought'], ''),
      decision: _asString(j['decision'], 'SKIP'),
      confidence: _asDouble(j['confidence'], 0.3),
      reasoning: _asString(j['reasoning'], 'No reasoning provided'),
      riskLevel: _asString(j['risk_level'], 'unknown'),
      rulesOverridden: _asStringList(j['rules_overridden']),
      memoryUsed: _asStringList(j['memory_used']),
      lessonPreview: _asString(j['lesson_preview'], ''),
      suggestedTpPctOverride: _asDoubleOrNull(j['suggested_tp_pct']),
      suggestedSlPctOverride: _asDoubleOrNull(j['suggested_sl_pct']),
      provider: response.provider,
      latency: response.latency,
    );
  }

  // ── Safe LLM parsers ──────────────────────────────────────────────────
  // LLMs are writers, not accountants. These handle any type gracefully.

  /// Safely convert any LLM value to a List<String>.
  /// Handles: null, List, String (comma-separated), single value.
  static List<String> _asStringList(dynamic v) {
    if (v == null) return const [];
    if (v is List) return v.map((e) => e.toString()).toList();
    if (v is String) {
      if (v.trim().isEmpty) return const [];
      return v
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return [v.toString()];
  }

  /// Safely convert any LLM value to a String.
  static String _asString(dynamic v, String fallback) {
    if (v == null) return fallback;
    if (v is String) return v.isEmpty ? fallback : v;
    return v.toString();
  }

  /// Safely convert any LLM value to a double.
  static double _asDouble(dynamic v, double fallback) {
    if (v == null) return fallback;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? fallback;
    return fallback;
  }

  /// Safely convert any LLM value to a double? (nullable).
  static double? _asDoubleOrNull(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  /// Fallback thought when LLM is unavailable.
  factory JarvisThought.unavailable(String reason) => JarvisThought(
        thought: 'LLM unavailable: $reason',
        decision: 'DEFER_TO_RULES',
        confidence: 0.0,
        reasoning: 'No LLM available — using deterministic rules only',
        riskLevel: 'unknown',
        provider: 'none',
        latency: Duration.zero,
      );

  bool get isLLMGenerated => provider != 'none';

  @override
  String toString() => '[JARVIS_THOUGHT] $decision '
      'conf=${confidence.toStringAsFixed(2)} '
      'risk=$riskLevel provider=$provider '
      '${latency.inMilliseconds}ms';
}

// ═════════════════════════════════════════════════════════════════════════════
// JARVIS AI CORE — orchestrator
// ═════════════════════════════════════════════════════════════════════════════

class JarvisAICore {
  JarvisAICore._();
  static final JarvisAICore instance = JarvisAICore._();

  // ── Providers ──
  final GroqProvider _groq = GroqProvider();
  final OllamaProvider _ollama = OllamaProvider();
  final GeminiProvider _gemini = GeminiProvider();
  final DeepSeekProvider _deepSeek = DeepSeekProvider();
  final OpenAICompatibleProvider _openai = OpenAICompatibleProvider.openai();
  final OpenAICompatibleProvider _claude = OpenAICompatibleProvider.claude();
  final OpenAICompatibleProvider _mistral = OpenAICompatibleProvider.mistral();
  final OpenAICompatibleProvider _cerebras =
      OpenAICompatibleProvider.cerebras();
  final OpenAICompatibleProvider _openRouter =
      OpenAICompatibleProvider.openRouter();
  OpenAICompatibleProvider _localLLM = OpenAICompatibleProvider.local();

  /// All providers in fallback order.
  /// SMART FIRST → free cloud → paid cloud.
  /// Gemini REMOVED: blocked by Google in this region.
  List<LLMProvider> get _fallbackChain => [
        _groq, // PRIMARY: 70B model, fast, reliable JSON, understands Russian
        _mistral, // Fast, good JSON
        _cerebras, // Free tier: 120B model, ultra-fast
        _openRouter, // Free tier: llama-3.3-70b
        _localLLM, // Local LLM (if configured)
        _ollama, // Local Ollama fallback
        _deepSeek, // Cheap cloud (needs balance)
        _openai, // Paid fallback
        _claude, // Paid fallback
      ];

  /// Whether AI Core is enabled (false = pure deterministic mode).
  bool _enabled = false;
  bool get isEnabled => _enabled;

  /// Rate limiter: minimum interval between LLM calls.
  static const _minInterval = Duration(seconds: 5);
  DateTime _lastCallAt = DateTime(2000);

  /// Stats
  int _totalCalls = 0;
  int _successCalls = 0;
  int _fallbackCalls = 0;
  int _failedCalls = 0;

  // ── Circuit Breaker State ──
  // Tracks consecutive failures per provider. After _cbThreshold failures,
  // the provider is "circuit open" (skipped) for _cbCooldown duration.
  // After cooldown, one test call is made ("half-open"). Success = restore.
  static const _cbThreshold = 5; // failures before opening circuit
  static const _cbCooldown = Duration(minutes: 30);
  final Map<String, int> _cbFailures = {}; // provider -> consecutive failures
  final Map<String, DateTime> _cbOpenUntil = {}; // provider -> skip until
  final Map<String, String> _cbDisableReason = {}; // provider -> permanent disable reason

  /// Circuit breaker DISABLED — never block providers, just try next.
  /// Every call gets a fresh attempt at all providers.
  bool _isCircuitOpen(LLMProvider provider) => false;

  /// Record a provider failure. Opens circuit after threshold.
  void _cbRecordFailure(LLMProvider provider, String? errorMsg) {
    final name = provider.name;
    final count = (_cbFailures[name] ?? 0) + 1;
    _cbFailures[name] = count;

    // Auth/key errors — disable permanently until restart
    if (errorMsg != null && (errorMsg.contains('401') || errorMsg.contains('403') || errorMsg.contains('Unauthorized'))) {
      _cbDisableReason[name] = 'auth_error';
      _log.w('[CIRCUIT_BREAKER] $name DISABLED (auth error) until restart');
      return;
    }

    // Rate limit → open circuit, try to parse Retry-After
    if (errorMsg != null && (errorMsg.contains('429') || errorMsg.contains('rate') || errorMsg.contains('quota'))) {
      final cooldown = const Duration(minutes: 60); // rate limits usually reset hourly
      _cbOpenUntil[name] = DateTime.now().add(cooldown);
      _log.w('[CIRCUIT_BREAKER] $name RATE LIMITED → cooldown ${cooldown.inMinutes}min');
      return;
    }

    // Generic failures → open after threshold
    if (count >= _cbThreshold) {
      _cbOpenUntil[name] = DateTime.now().add(_cbCooldown);
      _cbFailures[name] = 0; // reset counter for next cycle
      _log.w('[CIRCUIT_BREAKER] $name CIRCUIT OPEN after $count failures → cooldown ${_cbCooldown.inMinutes}min');
    }
  }

  /// Record a provider success. Resets failure counter.
  void _cbRecordSuccess(LLMProvider provider) {
    final name = provider.name;
    _cbFailures[name] = 0;
    _cbOpenUntil.remove(name);
    // Don't clear _cbDisableReason — auth errors need new key/restart
  }

  /// Reset ALL circuit breakers — gives every provider a fresh chance.
  /// Called when user sends a chat message (user commands are high priority).
  void resetCircuitBreakers() {
    _cbFailures.clear();
    _cbOpenUntil.clear();
    _cbDisableReason.clear();
    _log.i('[CIRCUIT_BREAKER] All circuits RESET (user priority)');
  }

  // ── Initialization ──────────────────────────────────────────────────────

  /// Load API keys from secrets file.
  /// Expected format: assets/secrets/jarvis_llm.json
  /// {
  ///   "LOCAL_LLM_URL": "http://localhost:1234/v1/chat/completions",
  ///   "LOCAL_LLM_MODEL": "qwen2.5:14b",
  ///   "GROQ_API_KEY": "...",
  ///   "GEMINI_API_KEY": "...",
  ///   "DEEPSEEK_API_KEY": "...",
  ///   "OPENAI_API_KEY": "...",
  ///   "ANTHROPIC_API_KEY": "...",
  ///   "MISTRAL_API_KEY": "...",
  ///   "OLLAMA_URL": "http://localhost:11434"
  /// }
  Future<void> initialize() async {
    try {
      final s = await rootBundle.loadString('secrets/jarvis_llm.json');
      final keys = jsonDecode(s) as Map<String, dynamic>;

      if (keys['GROQ_API_KEY'] != null) {
        _groq.setApiKey(keys['GROQ_API_KEY'] as String);
      }
      if (keys['GEMINI_API_KEY'] != null) {
        _gemini.setApiKey(keys['GEMINI_API_KEY'] as String);
      }
      if (keys['DEEPSEEK_API_KEY'] != null) {
        _deepSeek.setApiKey(keys['DEEPSEEK_API_KEY'] as String);
      }
      if (keys['OPENAI_API_KEY'] != null) {
        _openai.setApiKey(keys['OPENAI_API_KEY'] as String);
      }
      if (keys['ANTHROPIC_API_KEY'] != null) {
        _claude.setApiKey(keys['ANTHROPIC_API_KEY'] as String);
      }
      if (keys['MISTRAL_API_KEY'] != null) {
        _mistral.setApiKey(keys['MISTRAL_API_KEY'] as String);
      }
      if (keys['CEREBRAS_API_KEY'] != null) {
        _cerebras.setApiKey(keys['CEREBRAS_API_KEY'] as String);
      }
      if (keys['OPENROUTER_API_KEY'] != null) {
        _openRouter.setApiKey(keys['OPENROUTER_API_KEY'] as String);
      }

      // Configure local LLM if URL is provided.
      // If empty, LocalLLM stays with _localReachable=false → isAvailable=false → instantly skipped.
      final localUrl = keys['LOCAL_LLM_URL'] as String?;
      final localModel = keys['LOCAL_LLM_MODEL'] as String? ?? 'local-model';
      if (localUrl != null && localUrl.isNotEmpty) {
        _localLLM = OpenAICompatibleProvider.local(
          baseUrl: localUrl,
          model: localModel,
        );
        _log.i('[AI_CORE] Local LLM configured: $localUrl model=$localModel');

        // Try pinging local LLM server (only if configured)
        unawaited(_localLLM.ping().then((ok) {
          if (ok) {
            _log.i(
                '[AI_CORE] ★ Local LLM is ONLINE — your own brain, zero cost');
            if (!_enabled) _enabled = true;
          } else {
            _log.w(
                '[AI_CORE] Local LLM configured but not responding — using cloud fallback');
          }
        }));
      }

      // Count available providers
      final available =
          _fallbackChain.where((p) => p.isAvailable).map((p) => p.name);
      _enabled = available.isNotEmpty;

      _log.i('[AI_CORE] Initialized | '
          'providers=${available.join(",")} '
          'enabled=$_enabled');

      // Try pinging Ollama (doesn't need API key)
      unawaited(_ollama.ping().then((ok) {
        if (ok) {
          _log.i('[AI_CORE] Ollama available at localhost');
          if (!_enabled) _enabled = true;
        }
      }));
    } catch (e) {
      _log.w('[AI_CORE] No secrets/jarvis_llm.json found — '
          'AI Core disabled (deterministic mode only). $e');
      _enabled = false;
    }
  }

  // ── Core Thinking ───────────────────────────────────────────────────────

  /// Ask JARVIS to think about a market signal.
  ///
  /// Returns a [JarvisThought] with decision, reasoning, confidence.
  /// If no provider is available, returns a "defer to rules" thought.
  Future<JarvisThought> think(JarvisContextPack context) async {
    if (!_enabled) {
      return JarvisThought.unavailable('AI Core disabled');
    }

    // Rate limiting
    final now = DateTime.now();
    final elapsed = now.difference(_lastCallAt);
    if (elapsed < _minInterval) {
      return JarvisThought.unavailable(
          'Rate limited (${_minInterval.inSeconds - elapsed.inSeconds}s remaining)');
    }
    _lastCallAt = now;
    _totalCalls++;

    final systemPrompt = _buildSystemPrompt();
    final userPrompt = context.toLLMContext();

    // Try providers in fallback order (circuit-breaker aware)
    for (int i = 0; i < _fallbackChain.length; i++) {
      final provider = _fallbackChain[i];
      if (!provider.isAvailable) continue;

      // Circuit breaker: skip providers that are failing
      if (_isCircuitOpen(provider)) {
        continue;
      }

      _log.d('[AI_CORE] Trying ${provider.name} for ${context.symbol}...');

      final response = await provider.complete(
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        maxTokens: 512,
        temperature: 0.2,
      );

      if (response.isSuccess) {
        _cbRecordSuccess(provider);
        final thought = JarvisThought.fromLLMResponse(response);
        if (i > 0) _fallbackCalls++;
        _successCalls++;

        _log.i('[AI_CORE] $thought');
        return thought;
      }

      _log.w('[AI_CORE] ${provider.name} failed: ${response.error}');
      _cbRecordFailure(provider, response.error);
    }

    // All providers failed
    _failedCalls++;
    _log.e('[AI_CORE] All providers failed for ${context.symbol}');
    return JarvisThought.unavailable('All providers failed');
  }

  /// Raw LLM call with custom prompts (for self-evolution, reports, etc.).
  /// No rate limiting — caller is responsible for throttling.
  Future<LLMResponse> thinkRaw({
    required String systemPrompt,
    required String userPrompt,
    int maxTokens = 1024,
    double temperature = 0.3,
  }) async {
    if (!_enabled) {
      return LLMResponse(
        text: '',
        provider: 'none',
        latency: Duration.zero,
        error: 'AI Core disabled',
      );
    }

    _totalCalls++;

    for (int i = 0; i < _fallbackChain.length; i++) {
      final provider = _fallbackChain[i];
      if (!provider.isAvailable) continue;
      if (_isCircuitOpen(provider)) {
        continue;
      }

      final response = await provider.complete(
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        maxTokens: maxTokens,
        temperature: temperature,
      );

      if (response.isSuccess) {
        _cbRecordSuccess(provider);
        if (i > 0) _fallbackCalls++;
        _successCalls++;
        return response;
      }

      _cbRecordFailure(provider, response.error);
      _log.w('[AI_CORE] ${provider.name} failed (raw): ${response.error}');
    }

    _failedCalls++;
    return LLMResponse(
      text: '',
      provider: 'none',
      latency: Duration.zero,
      error: 'All providers failed',
    );
  }

  // ── System Prompt ───────────────────────────────────────────────────────

  String _buildSystemPrompt() => '''
You are JARVIS, an AI crypto trading assistant. Analyze market signals and provide structured decisions.

## Decision Options
- **BUY_SCOUT**: Small learning position — I have a thesis but limited conviction
- **BUY_MAIN**: Standard position — strong thesis backed by memory and evidence
- **WATCH**: Interesting signal, monitoring but not ready to enter
- **SKIP**: Not worth trading — memory/thesis/evidence don't support entry
- **RESEARCH**: Need more data before deciding

## Response Format (JSON)
{
  "thought": "Internal reasoning (1-2 sentences)",
  "decision": "BUY_SCOUT|BUY_MAIN|WATCH|SKIP|RESEARCH",
  "confidence": 0.0-1.0,
  "reasoning": "Memory used: [what my memory said]. Why similar/different: [vs past]. Decision: [what I chose and why]. Learning plan: [what I will learn].",
  "risk_level": "low|medium|high|extreme",
  "rules_overridden": ["RULE_ID", ...],
  "memory_used": ["journal: BSBUSDT disaster trap", "pattern: whale inflow unreliable"],
  "lesson_preview": "What to remember from this signal"
}

Be concise. Every word should be useful. Think before you decide.
''';

  // ── Status ──────────────────────────────────────────────────────────────

  /// Log AI Core status (called during Brain fullReport).
  void logStatus() {
    final available =
        _fallbackChain.where((p) => p.isAvailable).map((p) => p.name);
    _log.i('');
    _log.i('╔════════════════════════════════════════════════════');
    _log.i('║ [AI_CORE] Status Report');
    _log.i('╠════════════════════════════════════════════════════');
    _log.i('║ Enabled: $_enabled');
    _log.i('║ Providers: ${available.join(", ")}');
    _log.i('║ Calls: total=$_totalCalls '
        'success=$_successCalls '
        'fallback=$_fallbackCalls '
        'failed=$_failedCalls');
    _log.i('╚════════════════════════════════════════════════════');
    _log.i('');
  }

  /// Get provider by name (for manual testing / UI).
  LLMProvider? getProvider(String name) {
    try {
      return _fallbackChain
          .firstWhere((p) => p.name.toLowerCase() == name.toLowerCase());
    } catch (_) {
      return null;
    }
  }

  /// List all providers with status.
  List<Map<String, dynamic>> providerStatus() {
    return _fallbackChain
        .map((p) => {
              'name': p.name,
              'available': p.isAvailable,
            })
        .toList();
  }
}
