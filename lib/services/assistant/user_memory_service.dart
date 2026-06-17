import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ibiti_guardian/models/user_memory.dart';

// ─── User Memory Service ───────────────────────────────────────────────────────
//
// Stores and retrieves the user's personal AI memory:
//  - Personal Vocabulary (slang → normalized meaning)
//  - Voice Macros (trigger phrase → action chain)
//  - User Preferences (soft defaults)
//
// Persistence: SharedPreferences (JSON-encoded lists/maps).
// Privacy: All data stays **on-device**. Nothing is transmitted.
// Security: Memory can influence understanding and suggestions,
//           but NEVER grants new permissions or bypasses limits.

class UserMemoryService {
  UserMemoryService._();
  static final instance = UserMemoryService._();

  static const _log = GuardianLogger('UserMemory');

  static const _vocabKey = 'user_memory_vocab';
  static const _macrosKey = 'user_memory_macros';
  static const _prefsKey = 'user_memory_prefs';

  final List<VocabEntry> _vocab = [];
  final List<VoiceMacro> _macros = [];
  UserPreferences _preferences = UserPreferences();

  /// Notify listeners when memory changes (for future UI).
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  // ── Initialization ──────────────────────────────────────────────────────────

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _loadVocab(prefs);
      _loadMacros(prefs);
      _loadPreferences(prefs);
      _ensureDefaultMacros();
    } catch (e) {
      _log.e('Init error', e);
    }
  }

  // ── Personal Vocabulary ─────────────────────────────────────────────────────

  List<VocabEntry> get allVocab => List.unmodifiable(_vocab);

  /// Add a vocabulary entry. Returns true if saved successfully.
  Future<bool> addVocab({
    required String phrase,
    required String normalizedMeaning,
    VocabSource source = VocabSource.userExplicit,
  }) async {
    final cleaned = phrase.toLowerCase().trim();
    if (cleaned.isEmpty || normalizedMeaning.trim().isEmpty) return false;

    // Remove existing entry with same phrase (update).
    _vocab.removeWhere((v) => v.phrase == cleaned);

    _vocab.add(VocabEntry(
      phrase: cleaned,
      normalizedMeaning: normalizedMeaning.trim(),
      source: source,
      createdAt: DateTime.now(),
    ));

    await _saveVocab();
    _bump();
    return true;
  }

  /// Remove a vocabulary entry by phrase.
  Future<void> removeVocab(String phrase) async {
    _vocab.removeWhere((v) => v.phrase == phrase.toLowerCase().trim());
    await _saveVocab();
    _bump();
  }

  /// Expand input using personal vocabulary.
  ///
  /// If the input contains a known phrase, replaces it with its normalized
  /// meaning. Returns the original input if no match found.
  ///
  /// Example: "сделай котлету" → "сделай buy using all available USDT"
  String expandVocab(String input) {
    var result = input;
    final lower = input.toLowerCase();
    for (final entry in _vocab) {
      if (lower.contains(entry.phrase)) {
        // Replace the slang phrase with its normalized meaning.
        // Use case-insensitive replacement.
        final idx = lower.indexOf(entry.phrase);
        result = result.substring(0, idx) +
            entry.normalizedMeaning +
            result.substring(idx + entry.phrase.length);
        break; // Only one expansion per input to avoid chaos.
      }
    }
    return result;
  }

  // ── Voice Macros ────────────────────────────────────────────────────────────

  List<VoiceMacro> get allMacros => List.unmodifiable(_macros);

  /// Check if input matches a macro trigger phrase.
  /// Returns the macro if matched, null otherwise.
  VoiceMacro? matchMacro(String input) {
    final cleaned = input.toLowerCase().trim();
    for (final macro in _macros) {
      if (cleaned == macro.triggerPhrase.toLowerCase().trim()) {
        return macro;
      }
    }
    return null;
  }

  /// Add or update a voice macro.
  Future<bool> addMacro(VoiceMacro macro) async {
    if (macro.triggerPhrase.trim().isEmpty || macro.actions.isEmpty) {
      return false;
    }
    // Remove existing macro with same trigger.
    _macros.removeWhere((m) =>
        m.triggerPhrase.toLowerCase() == macro.triggerPhrase.toLowerCase());
    _macros.add(macro);
    await _saveMacros();
    _bump();
    return true;
  }

  /// Remove a macro by trigger phrase.
  Future<void> removeMacro(String triggerPhrase) async {
    _macros.removeWhere(
        (m) => m.triggerPhrase.toLowerCase() == triggerPhrase.toLowerCase());
    await _saveMacros();
    _bump();
  }

  // ── User Preferences ────────────────────────────────────────────────────────

  UserPreferences get preferences => _preferences;

  Future<void> updatePreference(String key, dynamic value) async {
    switch (key) {
      case 'preferredStablecoin':
        _preferences.preferredStablecoin = value as String?;
        break;
      case 'preferredVenue':
        _preferences.preferredVenue = value as String?;
        break;
      case 'preferredNetwork':
        _preferences.preferredNetwork = value as String?;
        break;
      case 'reviewStyle':
        _preferences.reviewStyle = value as String? ?? 'concise';
        break;
      case 'showPlanBeforeExecute':
        _preferences.showPlanBeforeExecute = value as bool? ?? true;
        break;
      default:
        return;
    }
    await _savePreferences();
    _bump();
  }

  // ── Personal Context Builder ────────────────────────────────────────────────

  /// Builds a compact context block for injection into the AI system prompt.
  ///
  /// This is what makes the AI "aware" of the user's personal vocabulary,
  /// preferences, and habits. Injected as hidden context, never shown to user.
  String buildPersonalContext() {
    final buf = StringBuffer();

    if (_vocab.isNotEmpty) {
      buf.writeln('[User Personal Vocabulary]');
      for (final v in _vocab) {
        buf.writeln('  "${v.phrase}" = "${v.normalizedMeaning}"');
      }
    }

    if (_macros.isNotEmpty) {
      buf.writeln('[User Voice Macros]');
      for (final m in _macros) {
        buf.writeln('  "${m.triggerPhrase}" → ${m.description}');
      }
    }

    final p = _preferences;
    final hasPrefs = p.preferredStablecoin != null ||
        p.preferredVenue != null ||
        p.preferredNetwork != null;
    if (hasPrefs) {
      buf.writeln('[User Preferences]');
      if (p.preferredStablecoin != null) {
        buf.writeln('  Preferred stablecoin: ${p.preferredStablecoin}');
      }
      if (p.preferredVenue != null) {
        buf.writeln('  Preferred venue: ${p.preferredVenue}');
      }
      if (p.preferredNetwork != null) {
        buf.writeln('  Preferred network: ${p.preferredNetwork}');
      }
      buf.writeln('  Review style: ${p.reviewStyle}');
    }

    return buf.toString().trim();
  }

  // ── Memory Info (for "what do you remember about me?" queries) ──────────

  /// Returns a human-readable summary of all stored memory.
  String describeMemory(String lang) {
    if (_vocab.isEmpty && _macros.isEmpty) {
      return lang == 'ru'
          ? 'У меня пока нет личных правил. Вы можете научить меня, сказав: «Запомни: когда я говорю X, это значит Y».'
          : 'I have no personal rules yet. You can teach me by saying: "Remember: when I say X, it means Y".';
    }

    final buf = StringBuffer();
    if (lang == 'ru') {
      buf.writeln('Вот что я помню о вас:');
      if (_vocab.isNotEmpty) {
        buf.writeln('\n**Личный словарь:**');
        for (final v in _vocab) {
          buf.writeln('• «${v.phrase}» → ${v.normalizedMeaning}');
        }
      }
      if (_macros.where((m) => !isDefaultMacro(m)).isNotEmpty) {
        buf.writeln('\n**Голосовые макросы:**');
        for (final m in _macros.where((m) => !isDefaultMacro(m))) {
          buf.writeln('• «${m.triggerPhrase}» → ${m.description}');
        }
      }
    } else {
      buf.writeln('Here is what I remember about you:');
      if (_vocab.isNotEmpty) {
        buf.writeln('\n**Personal vocabulary:**');
        for (final v in _vocab) {
          buf.writeln('• "${v.phrase}" → ${v.normalizedMeaning}');
        }
      }
      if (_macros.where((m) => !isDefaultMacro(m)).isNotEmpty) {
        buf.writeln('\n**Voice macros:**');
        for (final m in _macros.where((m) => !isDefaultMacro(m))) {
          buf.writeln('• "${m.triggerPhrase}" → ${m.description}');
        }
      }
    }
    return buf.toString().trim();
  }

  // ── Clear All ───────────────────────────────────────────────────────────────

  Future<void> clearAll() async {
    _vocab.clear();
    _macros.clear();
    _preferences = UserPreferences();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_vocabKey);
    await prefs.remove(_macrosKey);
    await prefs.remove(_prefsKey);
    _ensureDefaultMacros();
    _bump();
  }

  // ── Private: Persistence ────────────────────────────────────────────────────

  void _loadVocab(SharedPreferences prefs) {
    final raw = prefs.getString(_vocabKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      _vocab.clear();
      _vocab.addAll(
          list.map((e) => VocabEntry.fromJson(e as Map<String, dynamic>)));
    } catch (e) {
      _log.e('Vocab load error', e);
    }
  }

  Future<void> _saveVocab() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _vocabKey, jsonEncode(_vocab.map((v) => v.toJson()).toList()));
  }

  void _loadMacros(SharedPreferences prefs) {
    final raw = prefs.getString(_macrosKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      _macros.clear();
      _macros.addAll(
          list.map((e) => VoiceMacro.fromJson(e as Map<String, dynamic>)));
    } catch (e) {
      _log.e('Macros load error', e);
    }
  }

  Future<void> _saveMacros() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _macrosKey, jsonEncode(_macros.map((m) => m.toJson()).toList()));
  }

  void _loadPreferences(SharedPreferences prefs) {
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      _preferences =
          UserPreferences.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      _log.e('Prefs load error', e);
    }
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(_preferences.toJson()));
  }

  void _bump() => revision.value++;

  // ── Default Macros ──────────────────────────────────────────────────────────

  static const _defaultTriggers = {'эвакуация', 'разведка'};

  /// Whether this macro is a built-in default.
  bool isDefaultMacro(VoiceMacro m) =>
      _defaultTriggers.contains(m.triggerPhrase.toLowerCase());

  void _ensureDefaultMacros() {
    final existing = _macros.map((m) => m.triggerPhrase.toLowerCase()).toSet();

    if (!existing.contains('эвакуация')) {
      _macros.add(VoiceMacro(
        triggerPhrase: 'эвакуация',
        description: 'Panic → отозвать все разрешения → переключить на Manual',
        actions: const [
          MacroAction(type: MacroActionType.openModal, target: 'panic'),
          MacroAction(
              type: MacroActionType.executeAction, target: 'revoke_all'),
          MacroAction(type: MacroActionType.switchMode, target: 'manual'),
        ],
        requiresConfirmation: true,
        isRisky: true,
        createdAt: DateTime(2025, 1, 1),
      ));
    }

    if (!existing.contains('разведка')) {
      _macros.add(VoiceMacro(
        triggerPhrase: 'разведка',
        description: 'Сканировать рынок → показать топ-сигналы',
        actions: const [
          MacroAction(type: MacroActionType.navigate, target: 'market'),
        ],
        requiresConfirmation: false,
        isRisky: false,
        createdAt: DateTime(2025, 1, 1),
      ));
    }
  }
}
