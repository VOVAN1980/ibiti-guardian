import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

/// Service to handle string translations using a JSON-based system.
class LocalizationService {
  static final LocalizationService _instance = LocalizationService._internal();
  static LocalizationService get instance => _instance;

  LocalizationService._internal();

  /// Map to store localized strings. Defaults to empty but populated via load().
  final Map<String, String> _localizedStrings = {};

  /// Loads the JSON file for the given locale.
  /// First loads 'en' as a baseline to ensure all keys have a value.
  Future<void> load(Locale locale) async {
    // 1. Load English as baseline
    if (locale.languageCode != 'en') {
      await _loadToMap('en');
    }

    // 2. Load target locale and overlay
    await _loadToMap(locale.languageCode);
  }

  Future<void> _loadToMap(String langCode) async {
    final path = 'assets/i18n/$langCode.json';
    try {
      final jsonString = await rootBundle.loadString(path);
      final Map<String, dynamic> jsonMap = json.decode(jsonString);

      jsonMap.forEach((key, value) {
        _localizedStrings[key] = value.toString();
      });
      const log = GuardianLogger('Localization');
      log.d('Loaded: $path');
    } catch (e) {
      const log = GuardianLogger('Localization');
      log.e('Error loading $path', e);
      // If fails, we keep what we have (e.g. English baseline)
    }
  }

  /// Translates a key with optional dynamic arguments.
  /// Pass {'default': 'fallback text'} to show fallback when key is missing.
  String t(String key, [Map<String, dynamic>? args]) {
    String? found = _localizedStrings[key];

    // If key not found, use the 'default' from args as fallback
    if (found == null) {
      if (args != null && args.containsKey('default')) {
        return args['default'].toString();
      }
      return key; // last resort: show the key name
    }

    String text = found;
    if (args != null && args.isNotEmpty) {
      args.forEach((k, v) {
        if (k != 'default') {
          text = text.replaceAll('{$k}', v.toString());
        }
      });
    }

    return text;
  }
}

/// Provider to make [LocalizationService] available to the widget tree.
class LocalizationProvider extends InheritedWidget {
  final LocalizationService service;
  final Locale locale;

  const LocalizationProvider({
    super.key,
    required this.service,
    required this.locale,
    required super.child,
  });

  static LocalizationService of(BuildContext context) {
    final provider =
        context.dependOnInheritedWidgetOfExactType<LocalizationProvider>();
    return provider?.service ?? LocalizationService.instance;
  }

  @override
  bool updateShouldNotify(LocalizationProvider oldWidget) =>
      locale != oldWidget.locale || service != oldWidget.service;
}
