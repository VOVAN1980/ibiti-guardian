import 'package:ibiti_guardian/services/settings/settings_service.dart';

/// The assistant has two voices, chosen in Settings: a male one (cedar) and a
/// female one (marin). In Russian the assistant speaks about itself in the
/// grammatical gender of the chosen voice («я проверил» / «я проверила»).
class AiVoice {
  AiVoice._();

  static const String male = 'cedar';
  static const String female = 'marin';
  static const List<String> all = [male, female];

  /// Voices of older builds that sound female; every other id maps to male.
  static const Set<String> _femaleIds = {
    'marin', 'coral', 'shimmer', 'sage', 'nova', 'alloy',
  };

  /// Maps any saved voice id (older builds offered 11) to [male] or [female].
  static String normalize(String? id) =>
      _femaleIds.contains((id ?? '').trim().toLowerCase()) ? female : male;

  /// The voice chosen in Settings.
  static String get current =>
      normalize(SettingsService.instance.settings.preferredAiVoiceId);

  static bool get isFemale => current == female;

  /// Picks the Russian form for the current voice: [m] masculine, [f] feminine.
  static String ru(String m, String f) => isFemale ? f : m;
}
