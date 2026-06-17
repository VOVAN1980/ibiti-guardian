import 'package:ibiti_guardian/services/security/ai_control_service.dart';

// ─── Personal AI Memory Data Models ────────────────────────────────────────────

/// How a vocabulary entry was created.
enum VocabSource {
  /// User explicitly said "запомни: X = Y"
  userExplicit,

  /// User corrected the AI multiple times
  userCorrection,

  /// System inferred (low confidence, soft)
  systemInferred,
}

/// A single learned personal vocabulary entry.
///
/// Example: "котлета" → "купить на весь доступный USDT"
class VocabEntry {
  final String phrase;
  final String normalizedMeaning;
  final VocabSource source;
  final DateTime createdAt;

  const VocabEntry({
    required this.phrase,
    required this.normalizedMeaning,
    required this.source,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'phrase': phrase,
        'normalizedMeaning': normalizedMeaning,
        'source': source.name,
        'createdAt': createdAt.toIso8601String(),
      };

  factory VocabEntry.fromJson(Map<String, dynamic> json) => VocabEntry(
        phrase: json['phrase'] as String,
        normalizedMeaning: json['normalizedMeaning'] as String,
        source: VocabSource.values.firstWhere(
          (e) => e.name == json['source'],
          orElse: () => VocabSource.userExplicit,
        ),
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}

// ─── Voice Macros ──────────────────────────────────────────────────────────────

/// Type of action a macro step can perform.
enum MacroActionType {
  /// Navigate to a tab (target: 'market', 'wallet', 'ai', etc.)
  navigate,

  /// Open a modal (target: 'panic', 'safe', 'wallet_swap', etc.)
  openModal,

  /// Switch AI mode (target: 'manual', 'guarded', 'fullAutonomy')
  switchMode,

  /// Execute a named action (target: 'revoke_all', 'scan_risks', etc.)
  executeAction,
}

/// A single step within a voice macro.
class MacroAction {
  final MacroActionType type;
  final String target;
  final Map<String, dynamic>? payload;

  const MacroAction({
    required this.type,
    required this.target,
    this.payload,
  });

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'target': target,
        if (payload != null) 'payload': payload,
      };

  factory MacroAction.fromJson(Map<String, dynamic> json) => MacroAction(
        type: MacroActionType.values.firstWhere(
          (e) => e.name == json['type'],
          orElse: () => MacroActionType.executeAction,
        ),
        target: json['target'] as String,
        payload: json['payload'] as Map<String, dynamic>?,
      );
}

/// A voice macro — deterministic trigger phrase → action chain.
///
/// Unlike vocabulary (which rewrites input for the AI), macros
/// **bypass the AI entirely** and execute a fixed sequence of actions.
///
/// Example: "эвакуация" → [openModal:panic, executeAction:revoke_all, switchMode:manual]
class VoiceMacro {
  final String triggerPhrase;
  final String description;
  final List<MacroAction> actions;
  final bool requiresConfirmation;
  final Set<AiMode> allowedModes;
  final bool isRisky;
  final DateTime createdAt;

  const VoiceMacro({
    required this.triggerPhrase,
    required this.description,
    required this.actions,
    this.requiresConfirmation = false,
    this.allowedModes = const {
      AiMode.manual,
      AiMode.guarded,
      AiMode.fullAutonomy
    },
    this.isRisky = false,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'triggerPhrase': triggerPhrase,
        'description': description,
        'actions': actions.map((a) => a.toJson()).toList(),
        'requiresConfirmation': requiresConfirmation,
        'allowedModes': allowedModes.map((m) => m.name).toList(),
        'isRisky': isRisky,
        'createdAt': createdAt.toIso8601String(),
      };

  factory VoiceMacro.fromJson(Map<String, dynamic> json) => VoiceMacro(
        triggerPhrase: json['triggerPhrase'] as String,
        description: json['description'] as String,
        actions: (json['actions'] as List<dynamic>)
            .map((a) => MacroAction.fromJson(a as Map<String, dynamic>))
            .toList(),
        requiresConfirmation: json['requiresConfirmation'] as bool? ?? false,
        allowedModes: (json['allowedModes'] as List<dynamic>?)
                ?.map((m) => AiMode.values.firstWhere(
                      (e) => e.name == m,
                      orElse: () => AiMode.guarded,
                    ))
                .toSet() ??
            {AiMode.manual, AiMode.guarded, AiMode.fullAutonomy},
        isRisky: json['isRisky'] as bool? ?? false,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}

// ─── User Preferences ──────────────────────────────────────────────────────────

/// Soft user defaults — influences AI suggestions and pre-fills.
/// Never overrides policy, limits, or mandate.
class UserPreferences {
  String? preferredStablecoin;
  String? preferredVenue;
  String? preferredNetwork;

  /// 'concise' or 'detailed'
  String reviewStyle;

  /// Always show plan before execute
  bool showPlanBeforeExecute;

  UserPreferences({
    this.preferredStablecoin,
    this.preferredVenue,
    this.preferredNetwork,
    this.reviewStyle = 'concise',
    this.showPlanBeforeExecute = true,
  });

  Map<String, dynamic> toJson() => {
        'preferredStablecoin': preferredStablecoin,
        'preferredVenue': preferredVenue,
        'preferredNetwork': preferredNetwork,
        'reviewStyle': reviewStyle,
        'showPlanBeforeExecute': showPlanBeforeExecute,
      };

  factory UserPreferences.fromJson(Map<String, dynamic> json) =>
      UserPreferences(
        preferredStablecoin: json['preferredStablecoin'] as String?,
        preferredVenue: json['preferredVenue'] as String?,
        preferredNetwork: json['preferredNetwork'] as String?,
        reviewStyle: json['reviewStyle'] as String? ?? 'concise',
        showPlanBeforeExecute: json['showPlanBeforeExecute'] as bool? ?? true,
      );
}
