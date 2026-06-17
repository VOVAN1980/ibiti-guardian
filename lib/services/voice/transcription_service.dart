import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/services/assistant/api_key_provider.dart';

/// Thrown when Whisper API returns 429 after all retries.
class SttRateLimitException implements Exception {
  const SttRateLimitException();
  @override
  String toString() => 'Whisper API rate limit (429) after retries';
}

/// Sends recorded audio to OpenAI Whisper (gpt-4o-mini-transcribe)
/// and returns the recognised text.
///
/// Cost: ~$0.003 / minute of audio.
class TranscriptionService {
  TranscriptionService._();
  static final instance = TranscriptionService._();

  static const _log = GuardianLogger('STT');

  static const _endpoint = 'https://api.openai.com/v1/audio/transcriptions';
  static const _model = 'gpt-4o-mini-transcribe';

  /// Transcribe [audioBytes] (m4a/aac format from MicRecorderService).
  /// [languageCode] hint speeds up Whisper (e.g. 'ru', 'en').
  /// Returns the transcript text, or null on failure.
  Future<String?> transcribe(Uint8List audioBytes,
      {String? languageCode}) async {
    final apiKey = await ApiKeyProvider.getOpenAiKey();
    if (apiKey == null) {
      _log.w('No API key available');
      return null;
    }

    // Detect language from settings if not explicitly provided.
    final lang = languageCode ??
        SettingsService.instance.settings.languageCode
            .trim()
            .toLowerCase()
            .split('_')
            .first;

    _log.d('Uploading ${audioBytes.length}B to Whisper (lang=$lang)');

    try {
      final request = http.MultipartRequest('POST', Uri.parse(_endpoint))
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..fields['model'] = _model
        ..fields['response_format'] = 'text'
        ..fields['language'] = lang
        ..files.add(http.MultipartFile.fromBytes(
          'file',
          audioBytes,
          filename: 'audio.m4a',
        ));

      final streamed =
          await request.send().timeout(const Duration(seconds: 30));
      final body = await streamed.stream.bytesToString();

      if (streamed.statusCode == 200) {
        final transcript = body.trim();
        _log.d('Transcript received');
        return transcript.isEmpty ? null : transcript;
      } else if (streamed.statusCode == 429) {
        _log.w('HTTP 429 — rate limited, retrying...');
        // Retry with backoff: 1s, 3s
        for (final delay in const [1, 3]) {
          await Future<void>.delayed(Duration(seconds: delay));
          final retryReq = http.MultipartRequest('POST', Uri.parse(_endpoint))
            ..headers['Authorization'] = 'Bearer $apiKey'
            ..fields['model'] = _model
            ..fields['response_format'] = 'text'
            ..fields['language'] = lang
            ..files.add(http.MultipartFile.fromBytes(
              'file',
              audioBytes,
              filename: 'audio.m4a',
            ));
          final retryRes = await retryReq.send().timeout(const Duration(seconds: 30));
          final retryBody = await retryRes.stream.bytesToString();
          if (retryRes.statusCode == 200) {
            final transcript = retryBody.trim();
            _log.d('Transcript received after retry');
            return transcript.isEmpty ? null : transcript;
          }
          if (retryRes.statusCode != 429) {
            _log.e('HTTP ${retryRes.statusCode} on retry');
            return null;
          }
          _log.w('Still 429, waiting ${delay}s more...');
        }
        // All retries exhausted
        _log.e('429 persists after retries');
        throw const SttRateLimitException();
      } else {
        _log.e('HTTP ${streamed.statusCode}');
        return null;
      }
    } catch (e) {
      if (e is SttRateLimitException) rethrow;
      _log.e('Exception', e);
      return null;
    }
  }
}
