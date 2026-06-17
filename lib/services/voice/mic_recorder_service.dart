import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Records audio from the microphone to a temp file,
/// then reads it into memory on stop.
///
/// Usage:
///   await recorder.start();
///   final bytes = await recorder.stop();  // Uint8List (aac/m4a)
///
/// [amplitude] streams 0.0–1.0 normalised level for waveform visualisation.
class MicRecorderService {
  static const _log = GuardianLogger('MicRecorder');

  final AudioRecorder _recorder = AudioRecorder();
  final StreamController<double> _ampController =
      StreamController<double>.broadcast();
  Timer? _ampTimer;
  String? _tempPath;
  bool _isRecording = false;

  Stream<double> get amplitude => _ampController.stream;
  bool get isRecording => _isRecording;

  /// Returns true if the app has microphone permission.
  Future<bool> hasPermission() => _recorder.hasPermission();

  /// Start recording. Throws [Exception] if permission denied.
  Future<void> start() async {
    if (_isRecording) return;
    if (!await _recorder.hasPermission()) {
      throw Exception('Microphone permission denied');
    }

    // Write to a temp file — only approach that works reliably on iOS/Android.
    final dir = await getTemporaryDirectory();
    _tempPath = '${dir.path}/guardian_voice_turn.m4a';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 16000, // 16 kHz — Whisper's native rate
        numChannels: 1, // mono
      ),
      path: _tempPath!,
    );

    _isRecording = true;
    _startAmplitudePolling();
    _log.d('Recording started');
  }

  /// Stop recording and return the audio bytes.
  /// Returns null if no data was captured.
  Future<Uint8List?> stop() async {
    if (!_isRecording) return null;
    _stopAmplitudePolling();
    _isRecording = false;

    try {
      final path = await _recorder.stop();
      if (path == null) return null;

      final file = File(path);
      if (!await file.exists()) return null;

      final bytes = await file.readAsBytes();
      _log.d('Captured ${bytes.length} bytes');

      // Clean up temp file.
      try {
        await file.delete();
      } catch (e) {
        _log.d('temp file cleanup: $e');
      }

      return bytes;
    } catch (e) {
      _log.e('stop() error', e);
      return null;
    }
  }

  /// Cancel recording and discard any captured audio.
  Future<void> cancel() async {
    if (!_isRecording) return;
    _stopAmplitudePolling();
    _isRecording = false;
    try {
      await _recorder.cancel();
      if (_tempPath != null) {
        final file = File(_tempPath!);
        if (await file.exists()) await file.delete();
      }
    } catch (e) {
      _log.w('cancel cleanup failed', e);
    }
    _log.d('Cancelled');
  }

  void _startAmplitudePolling() {
    _ampTimer?.cancel();
    _ampTimer = Timer.periodic(const Duration(milliseconds: 60), (_) async {
      if (!_isRecording) return;
      try {
        final amp = await _recorder.getAmplitude();
        // amp.current is dBFS: 0 = max, ~-60 = silence.
        final normalised = ((amp.current + 60.0) / 60.0).clamp(0.0, 1.0);
        _ampController.add(normalised);
      } catch (_) {/* amplitude polling — normal if recorder already stopped */}
    });
  }

  void _stopAmplitudePolling() {
    _ampTimer?.cancel();
    _ampTimer = null;
    _ampController.add(0.0);
  }

  void dispose() {
    _stopAmplitudePolling();
    _ampController.close();
    _recorder.dispose();
  }
}
