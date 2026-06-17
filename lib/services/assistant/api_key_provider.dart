import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

/// Single source of truth for the OpenAI API key.
///
/// Resolves in order:
///   1. User-provided key from SettingsService
///   2. Bundled key from assets/secrets/openai.json (dev only)
///
/// Used by: OpenAIChatService, TtsService, TranscriptionService.
/// This eliminates 3 duplicated _getApiKey() implementations.
class ApiKeyProvider {
  ApiKeyProvider._();
  static const _log = GuardianLogger('ApiKey');

  /// Returns the OpenAI API key, or null if none is available.
  static Future<String?> getOpenAiKey() async {
    String? key = SettingsService.instance.settings.openaiApiKey;
    if (key != null && key.isNotEmpty) return key;

    // Fallback: bundled asset (dev/testing only — NEVER ship to production).
    try {
      final s = await rootBundle.loadString('secrets/openai.json');
      key = (jsonDecode(s) as Map<String, dynamic>)['apiKey'] as String?;
    } catch (e) {
      _log.d('bundled key fallback: $e');
    }

    return (key != null && key.isNotEmpty) ? key : null;
  }
}
