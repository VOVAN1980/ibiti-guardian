// ─── JARVIS LLM Provider Interface ──────────────────────────────────────────────
//
// Phase 18E: Universal LLM abstraction for JARVIS AI Core.
//
// JARVIS doesn't depend on ONE provider. He can switch brains:
//   - Groq (free, fast) — default for signal evaluation
//   - Ollama (local, free) — fallback / offline
//   - Gemini (free tier) — alternative cloud
//   - DeepSeek (cheap) — budget cloud
//   - Claude (premium) — complex reasoning
//   - OpenAI (premium) — complex reasoning
//   - Mistral (free tier) — EU alternative
//
// Provider Selection:
//   Fast signals → Groq/Ollama
//   Complex analysis → Claude/OpenAI/Gemini
//   No internet → Ollama
//   Error → fallback chain
// ─────────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/utils/guardian_logger.dart';

const _log = GuardianLogger('LLMProvider');

// ═════════════════════════════════════════════════════════════════════════════
// LLM RESPONSE MODEL
// ═════════════════════════════════════════════════════════════════════════════

class LLMResponse {
  /// Raw text response from LLM.
  final String text;

  /// Parsed JSON if response was structured.
  final Map<String, dynamic>? json;

  /// Which provider generated this response.
  final String provider;

  /// How long the call took.
  final Duration latency;

  /// Token usage (if reported by provider).
  final int? promptTokens;
  final int? completionTokens;

  /// Whether this is a fallback response (not from primary provider).
  final bool isFallback;

  /// Error message if the call partially failed.
  final String? error;

  const LLMResponse({
    required this.text,
    this.json,
    required this.provider,
    required this.latency,
    this.promptTokens,
    this.completionTokens,
    this.isFallback = false,
    this.error,
  });

  bool get isSuccess => error == null && text.isNotEmpty;

  @override
  String toString() => 'LLMResponse(provider=$provider '
      'latency=${latency.inMilliseconds}ms '
      'tokens=${promptTokens ?? "?"}+${completionTokens ?? "?"} '
      '${isFallback ? "FALLBACK " : ""}'
      '${error != null ? "ERR=$error" : "OK"})';
}

// ═════════════════════════════════════════════════════════════════════════════
// ABSTRACT LLM PROVIDER
// ═════════════════════════════════════════════════════════════════════════════

abstract class LLMProvider {
  /// Human-readable name (e.g. "Groq", "Ollama", "Claude").
  String get name;

  /// Whether this provider has a valid API key / is reachable.
  bool get isAvailable;

  /// Send a completion request.
  ///
  /// [systemPrompt] — JARVIS identity and instructions.
  /// [userPrompt] — Market context (from ContextPack).
  /// [jsonMode] — If true, request structured JSON output.
  /// [maxTokens] — Maximum response tokens.
  /// [temperature] — Creativity (0.0 = deterministic, 1.0 = creative).
  Future<LLMResponse> complete({
    required String systemPrompt,
    required String userPrompt,
    bool jsonMode = true,
    int maxTokens = 1024,
    double temperature = 0.3,
  });

  /// Test connectivity to this provider.
  Future<bool> ping();
}

// ═════════════════════════════════════════════════════════════════════════════
// GROQ PROVIDER — Free, fast, primary
// ═════════════════════════════════════════════════════════════════════════════

class GroqProvider extends LLMProvider {
  static const _baseUrl = 'https://api.groq.com/openai/v1/chat/completions';
  static const _defaultModel = 'llama-3.3-70b-versatile';

  String? _apiKey;
  final String _model;

  GroqProvider({String? apiKey, String model = _defaultModel})
      : _apiKey = apiKey,
        _model = model;

  @override
  String get name => 'Groq';

  @override
  bool get isAvailable => _apiKey != null && _apiKey!.isNotEmpty;

  void setApiKey(String key) => _apiKey = key;

  @override
  Future<LLMResponse> complete({
    required String systemPrompt,
    required String userPrompt,
    bool jsonMode = true,
    int maxTokens = 1024,
    double temperature = 0.3,
  }) async {
    if (!isAvailable) {
      return LLMResponse(
        text: '',
        provider: name,
        latency: Duration.zero,
        error: 'No API key',
      );
    }

    final sw = Stopwatch()..start();
    try {
      final body = jsonEncode({
        'model': _model,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userPrompt},
        ],
        'max_tokens': maxTokens,
        'temperature': temperature,
        if (jsonMode) 'response_format': {'type': 'json_object'},
      });

      final response = await http
          .post(
            Uri.parse(_baseUrl),
            headers: {
              'Authorization': 'Bearer $_apiKey',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 30));

      sw.stop();

      if (response.statusCode != 200) {
        return LLMResponse(
          text: '',
          provider: name,
          latency: sw.elapsed,
          error:
              'HTTP ${response.statusCode}: ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final text = (data['choices'] as List?)?.firstOrNull?['message']
              ?['content'] as String? ??
          '';

      final usage = data['usage'] as Map<String, dynamic>?;

      Map<String, dynamic>? parsed;
      if (jsonMode && text.isNotEmpty) {
        try {
          parsed = jsonDecode(text) as Map<String, dynamic>;
        } catch (_) {
          // Not valid JSON — still return raw text
        }
      }

      return LLMResponse(
        text: text,
        json: parsed,
        provider: name,
        latency: sw.elapsed,
        promptTokens: usage?['prompt_tokens'] as int?,
        completionTokens: usage?['completion_tokens'] as int?,
      );
    } catch (e) {
      sw.stop();
      return LLMResponse(
        text: '',
        provider: name,
        latency: sw.elapsed,
        error: e.toString(),
      );
    }
  }

  @override
  Future<bool> ping() async {
    try {
      final r = await complete(
        systemPrompt: 'Reply with {"status":"ok"}',
        userPrompt: 'ping',
        maxTokens: 10,
      );
      return r.isSuccess;
    } catch (_) {
      return false;
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// OLLAMA PROVIDER — Local, free, offline fallback
// ═════════════════════════════════════════════════════════════════════════════

class OllamaProvider extends LLMProvider {
  static const _defaultModel = 'llama3.2';

  final String _baseUrl;
  final String _model;
  bool _reachable = false;

  OllamaProvider({
    String baseUrl = 'http://localhost:11434',
    String model = _defaultModel,
  })  : _baseUrl = baseUrl,
        _model = model;

  @override
  String get name => 'Ollama';

  @override
  bool get isAvailable => _reachable;

  @override
  Future<LLMResponse> complete({
    required String systemPrompt,
    required String userPrompt,
    bool jsonMode = true,
    int maxTokens = 1024,
    double temperature = 0.3,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final body = jsonEncode({
        'model': _model,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userPrompt},
        ],
        'stream': false,
        'options': {
          'num_predict': maxTokens,
          'temperature': temperature,
        },
        if (jsonMode) 'format': 'json',
      });

      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/chat'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(const Duration(seconds: 120)); // Ollama can be slow

      sw.stop();
      _reachable = true;

      if (response.statusCode != 200) {
        return LLMResponse(
          text: '',
          provider: name,
          latency: sw.elapsed,
          error: 'HTTP ${response.statusCode}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final text = data['message']?['content'] as String? ?? '';

      Map<String, dynamic>? parsed;
      if (jsonMode && text.isNotEmpty) {
        try {
          parsed = jsonDecode(text) as Map<String, dynamic>;
        } catch (_) {}
      }

      return LLMResponse(
        text: text,
        json: parsed,
        provider: name,
        latency: sw.elapsed,
      );
    } catch (e) {
      sw.stop();
      _reachable = false;
      return LLMResponse(
        text: '',
        provider: name,
        latency: sw.elapsed,
        error: e.toString(),
      );
    }
  }

  @override
  Future<bool> ping() async {
    try {
      final r = await http
          .get(Uri.parse('$_baseUrl/api/tags'))
          .timeout(const Duration(seconds: 5));
      _reachable = r.statusCode == 200;
      return _reachable;
    } catch (_) {
      _reachable = false;
      return false;
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// GEMINI PROVIDER — Google, free tier
// ═════════════════════════════════════════════════════════════════════════════

class GeminiProvider extends LLMProvider {
  static const _defaultModel = 'gemini-2.0-flash';

  String? _apiKey;
  final String _model;

  GeminiProvider({String? apiKey, String model = _defaultModel})
      : _apiKey = apiKey,
        _model = model;

  @override
  String get name => 'Gemini';

  @override
  bool get isAvailable => _apiKey != null && _apiKey!.isNotEmpty;

  void setApiKey(String key) => _apiKey = key;

  @override
  Future<LLMResponse> complete({
    required String systemPrompt,
    required String userPrompt,
    bool jsonMode = true,
    int maxTokens = 1024,
    double temperature = 0.3,
  }) async {
    if (!isAvailable) {
      return LLMResponse(
          text: '',
          provider: name,
          latency: Duration.zero,
          error: 'No API key');
    }

    final sw = Stopwatch()..start();
    try {
      final url =
          'https://generativelanguage.googleapis.com/v1beta/models/$_model:generateContent?key=$_apiKey';

      final body = jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': '$systemPrompt\n\n$userPrompt'}
            ]
          }
        ],
        'generationConfig': {
          'maxOutputTokens': maxTokens,
          'temperature': temperature,
          if (jsonMode) 'responseMimeType': 'application/json',
        },
      });

      final response = await http
          .post(Uri.parse(url),
              headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 30));

      sw.stop();

      if (response.statusCode != 200) {
        return LLMResponse(
          text: '',
          provider: name,
          latency: sw.elapsed,
          error:
              'HTTP ${response.statusCode}: ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final text = (data['candidates'] as List?)?.firstOrNull?['content']
              ?['parts']?[0]?['text'] as String? ??
          '';

      final usage = data['usageMetadata'] as Map<String, dynamic>?;

      Map<String, dynamic>? parsed;
      if (jsonMode && text.isNotEmpty) {
        try {
          parsed = jsonDecode(text) as Map<String, dynamic>;
        } catch (_) {}
      }

      return LLMResponse(
        text: text,
        json: parsed,
        provider: name,
        latency: sw.elapsed,
        promptTokens: usage?['promptTokenCount'] as int?,
        completionTokens: usage?['candidatesTokenCount'] as int?,
      );
    } catch (e) {
      sw.stop();
      return LLMResponse(
          text: '', provider: name, latency: sw.elapsed, error: e.toString());
    }
  }

  @override
  Future<bool> ping() async {
    try {
      final r = await complete(
        systemPrompt: 'Reply with {"status":"ok"}',
        userPrompt: 'ping',
        maxTokens: 10,
      );
      return r.isSuccess;
    } catch (_) {
      return false;
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// DEEPSEEK PROVIDER — Cheap cloud
// ═════════════════════════════════════════════════════════════════════════════

class DeepSeekProvider extends LLMProvider {
  static const _baseUrl = 'https://api.deepseek.com/v1/chat/completions';
  static const _defaultModel = 'deepseek-chat';

  String? _apiKey;
  final String _model;

  DeepSeekProvider({String? apiKey, String model = _defaultModel})
      : _apiKey = apiKey,
        _model = model;

  @override
  String get name => 'DeepSeek';

  @override
  bool get isAvailable => _apiKey != null && _apiKey!.isNotEmpty;

  void setApiKey(String key) => _apiKey = key;

  @override
  Future<LLMResponse> complete({
    required String systemPrompt,
    required String userPrompt,
    bool jsonMode = true,
    int maxTokens = 1024,
    double temperature = 0.3,
  }) async {
    if (!isAvailable) {
      return LLMResponse(
          text: '',
          provider: name,
          latency: Duration.zero,
          error: 'No API key');
    }

    final sw = Stopwatch()..start();
    try {
      final body = jsonEncode({
        'model': _model,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userPrompt},
        ],
        'max_tokens': maxTokens,
        'temperature': temperature,
        if (jsonMode) 'response_format': {'type': 'json_object'},
      });

      final response = await http
          .post(
            Uri.parse(_baseUrl),
            headers: {
              'Authorization': 'Bearer $_apiKey',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 30));

      sw.stop();

      if (response.statusCode != 200) {
        return LLMResponse(
          text: '',
          provider: name,
          latency: sw.elapsed,
          error: 'HTTP ${response.statusCode}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final text = (data['choices'] as List?)?.firstOrNull?['message']
              ?['content'] as String? ??
          '';
      final usage = data['usage'] as Map<String, dynamic>?;

      Map<String, dynamic>? parsed;
      if (jsonMode && text.isNotEmpty) {
        try {
          parsed = jsonDecode(text) as Map<String, dynamic>;
        } catch (_) {}
      }

      return LLMResponse(
        text: text,
        json: parsed,
        provider: name,
        latency: sw.elapsed,
        promptTokens: usage?['prompt_tokens'] as int?,
        completionTokens: usage?['completion_tokens'] as int?,
      );
    } catch (e) {
      sw.stop();
      return LLMResponse(
          text: '', provider: name, latency: sw.elapsed, error: e.toString());
    }
  }

  @override
  Future<bool> ping() async {
    try {
      final r = await complete(
        systemPrompt: 'Reply with {"status":"ok"}',
        userPrompt: 'ping',
        maxTokens: 10,
      );
      return r.isSuccess;
    } catch (_) {
      return false;
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// OPENAI-COMPATIBLE PROVIDER — OpenAI, Claude, Mistral (all use same format)
// ═════════════════════════════════════════════════════════════════════════════

class OpenAICompatibleProvider extends LLMProvider {
  final String _name;
  final String _baseUrl;
  final String _model;
  String? _apiKey;
  final bool _isLocal;
  bool _localReachable = false;

  OpenAICompatibleProvider({
    required String name,
    required String baseUrl,
    required String model,
    String? apiKey,
    bool isLocal = false,
  })  : _name = name,
        _baseUrl = baseUrl,
        _model = model,
        _apiKey = apiKey,
        _isLocal = isLocal;

  /// OpenAI GPT-4o-mini (cheap, good)
  factory OpenAICompatibleProvider.openai({String? apiKey}) =>
      OpenAICompatibleProvider(
        name: 'OpenAI',
        baseUrl: 'https://api.openai.com/v1/chat/completions',
        model: 'gpt-4o-mini',
        apiKey: apiKey,
      );

  /// Anthropic Claude via OpenAI-compatible proxy
  /// Note: Claude native API has different format — use this for compatibility.
  factory OpenAICompatibleProvider.claude({String? apiKey}) =>
      OpenAICompatibleProvider(
        name: 'Claude',
        baseUrl: 'https://api.anthropic.com/v1/messages',
        model: 'claude-sonnet-4-20250514',
        apiKey: apiKey,
      );

  /// Local LLM server (LM Studio, Ollama /v1, llama.cpp server)
  /// No API key needed — just base URL and model name.
  /// No limits. No internet. Your own brain.
  /// Available only after a successful ping.
  factory OpenAICompatibleProvider.local({
    String baseUrl = 'http://localhost:1234/v1/chat/completions',
    String model = 'local-model',
  }) =>
      OpenAICompatibleProvider(
        name: 'LocalLLM',
        baseUrl: baseUrl,
        model: model,
        apiKey: 'local',
        isLocal: true, // ping-based availability, short timeout
      );

  /// Mistral (free tier available)
  factory OpenAICompatibleProvider.mistral({String? apiKey}) =>
      OpenAICompatibleProvider(
        name: 'Mistral',
        baseUrl: 'https://api.mistral.ai/v1/chat/completions',
        model: 'mistral-small-latest',
        apiKey: apiKey,
      );

  /// Cerebras (free tier: 1M tokens/day, ultra-fast inference)
  factory OpenAICompatibleProvider.cerebras({String? apiKey}) =>
      OpenAICompatibleProvider(
        name: 'Cerebras',
        baseUrl: 'https://api.cerebras.ai/v1/chat/completions',
        model: 'gpt-oss-120b',
        apiKey: apiKey,
      );

  /// OpenRouter (free tier: 200 req/day, auto-selects free model)
  factory OpenAICompatibleProvider.openRouter({String? apiKey}) =>
      OpenAICompatibleProvider(
        name: 'OpenRouter',
        baseUrl: 'https://openrouter.ai/api/v1/chat/completions',
        model: 'meta-llama/llama-3.3-70b-instruct:free',
        apiKey: apiKey,
      );

  @override
  String get name => _name;

  @override
  bool get isAvailable =>
      _isLocal ? _localReachable : (_apiKey != null && _apiKey!.isNotEmpty);

  void setApiKey(String key) => _apiKey = key;

  @override
  Future<LLMResponse> complete({
    required String systemPrompt,
    required String userPrompt,
    bool jsonMode = true,
    int maxTokens = 1024,
    double temperature = 0.3,
  }) async {
    // For cloud providers: check API key. For local: always attempt (ping sets reachable).
    if (!_isLocal && !isAvailable) {
      return LLMResponse(
          text: '',
          provider: name,
          latency: Duration.zero,
          error: 'No API key');
    }

    final sw = Stopwatch()..start();
    try {
      // Claude has a different API format
      final isClaudeNative = _name == 'Claude';

      final Map<String, String> headers;
      final String body;

      if (isClaudeNative) {
        headers = {
          'x-api-key': _apiKey!,
          'anthropic-version': '2023-06-01',
          'Content-Type': 'application/json',
        };
        body = jsonEncode({
          'model': _model,
          'max_tokens': maxTokens,
          'system': systemPrompt,
          'messages': [
            {'role': 'user', 'content': userPrompt},
          ],
        });
      } else {
        // Local servers don't need Authorization header
        headers = _isLocal
            ? {'Content-Type': 'application/json'}
            : {
                'Authorization': 'Bearer $_apiKey',
                'Content-Type': 'application/json',
              };
        body = jsonEncode({
          'model': _model,
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': userPrompt},
          ],
          'max_tokens': maxTokens,
          'temperature': temperature,
          // Don't send response_format to local LLMs — many don't support it
          // and return schema objects instead of actual content
          if (jsonMode && !_isLocal) 'response_format': {'type': 'json_object'},
        });
      }

      final timeout = _isLocal
          ? const Duration(
              seconds: 15) // Fast fail if local is too slow (fallback to cloud)
          : const Duration(seconds: 60);

      final response = await http
          .post(Uri.parse(_baseUrl), headers: headers, body: body)
          .timeout(timeout);

      sw.stop();

      if (response.statusCode != 200) {
        if (_isLocal) _localReachable = false;
        return LLMResponse(
          text: '',
          provider: name,
          latency: sw.elapsed,
          error:
              'HTTP ${response.statusCode}: ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      String text;
      int? promptTok;
      int? completionTok;

      if (isClaudeNative) {
        text =
            (data['content'] as List?)?.firstOrNull?['text'] as String? ?? '';
        final usage = data['usage'] as Map<String, dynamic>?;
        promptTok = usage?['input_tokens'] as int?;
        completionTok = usage?['output_tokens'] as int?;
      } else {
        text = (data['choices'] as List?)?.firstOrNull?['message']?['content']
                as String? ??
            '';
        final usage = data['usage'] as Map<String, dynamic>?;
        promptTok = usage?['prompt_tokens'] as int?;
        completionTok = usage?['completion_tokens'] as int?;
      }

      Map<String, dynamic>? parsed;
      if (jsonMode && text.isNotEmpty) {
        try {
          parsed = jsonDecode(text) as Map<String, dynamic>;
        } catch (_) {}
      }

      // Mark local server as reachable on success
      if (_isLocal) _localReachable = true;

      return LLMResponse(
        text: text,
        json: parsed,
        provider: name,
        latency: sw.elapsed,
        promptTokens: promptTok,
        completionTokens: completionTok,
      );
    } catch (e) {
      sw.stop();
      if (_isLocal) _localReachable = false;
      return LLMResponse(
          text: '', provider: name, latency: sw.elapsed, error: e.toString());
    }
  }

  @override
  Future<bool> ping() async {
    // For local servers: use GET /v1/models (instant, no generation).
    // A real chat completion can take 60-90s on slow hardware — useless as ping.
    if (_isLocal) {
      try {
        // Derive /v1/models URL from /v1/chat/completions
        final modelsUrl =
            _baseUrl.replaceAll(RegExp(r'/chat/completions.*'), '/models');
        final r = await http
            .get(Uri.parse(modelsUrl))
            .timeout(const Duration(seconds: 5));

        if (r.statusCode == 200) {
          final json = jsonDecode(r.body) as Map<String, dynamic>;
          final data = json['data'] as List<dynamic>? ?? [];
          final hasModel = data.any((m) => (m as Map)['id'] == _model);

          _localReachable = hasModel;
        } else {
          _localReachable = false;
        }
        return _localReachable;
      } catch (_) {
        _localReachable = false;
        return false;
      }
    }

    // Cloud providers: lightweight chat completion ping
    try {
      final r = await complete(
        systemPrompt: 'Reply with {"status":"ok"}',
        userPrompt: 'ping',
        maxTokens: 10,
      );
      return r.isSuccess;
    } catch (_) {
      return false;
    }
  }
}
