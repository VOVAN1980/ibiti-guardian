import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';
import 'package:ibiti_guardian/widgets/ai_core_widget.dart';
import 'package:ibiti_guardian/widgets/hyper_orb_painter.dart';
import 'package:ibiti_guardian/services/voice/tts_service.dart';
import 'package:ibiti_guardian/services/voice/voice_turn_controller.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/widgets/voice_waveform_widget.dart';
import 'package:ibiti_guardian/services/localization_service.dart';

class AssistantVoiceScreen extends StatefulWidget {
  final VoidCallback onOpenChat;
  const AssistantVoiceScreen({super.key, required this.onOpenChat});
  @override
  State<AssistantVoiceScreen> createState() => _AssistantVoiceScreenState();
}

class _AssistantVoiceScreenState extends State<AssistantVoiceScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final _voice = VoiceTurnController.instance;
  final _aiControl = AiControlService.instance;

  double _soundLevel = 0.0;
  double _wavePhase = 0.0;
  Timer? _wavePulseTimer;
  StreamSubscription<double>? _ampSub;

  // Mouth animation — synced to actual TTS audio playback, 320ms cycle.
  late final AnimationController _mouthCtrl;

  // Blink animation for the mic-button mascot.
  late final AnimationController _blinkCtrl;
  Timer? _blinkTimer;



  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _voice.addListener(_onStateChanged);
    _aiControl.addListener(_onModeChanged);
    TtsService.instance.isSpeaking.addListener(_onTtsSpeakingChanged);

    _mouthCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );

    // Blink: quick close/open for mic button mascot
    _blinkCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _scheduleBlink();

    _wavePulseTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (!mounted) return;
      setState(() => _wavePhase += 0.24);
    });

    _ampSub = _voice.amplitude.listen((level) {
      if (mounted) setState(() => _soundLevel = level);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Cancel ANY active turn when the app goes to background.
    // This covers recording, transcribing, thinking, and speaking —
    // so we never get TTS audio playing into silence after the user
    // minimizes the app.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      if (_voice.state != VoiceTurnState.idle) {
        _voice.cancel();
        const log = GuardianLogger('VoiceScreen');
        log.d('App backgrounded — active turn cancelled');
      }
      // End voice session on background.
      if (_voice.isSessionActive) {
        _voice.endSession();
      }
    }
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  void _onModeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _wavePulseTimer?.cancel();
    _ampSub?.cancel();
    _mouthCtrl.dispose();
    _blinkCtrl.dispose();
    _blinkTimer?.cancel();
    _voice.removeListener(_onStateChanged);
    _aiControl.removeListener(_onModeChanged);
    TtsService.instance.isSpeaking.removeListener(_onTtsSpeakingChanged);
    // No disconnect needed — VoiceTurnController has no persistent connection.
    super.dispose();
  }

  /// Mouth sync driven by actual TTS audio playback.
  void _onTtsSpeakingChanged() {
    if (!mounted) return;
    final talking = TtsService.instance.isSpeaking.value;
    if (talking) {
      if (!_mouthCtrl.isAnimating) _mouthCtrl.repeat(reverse: true);
    } else {
      if (_mouthCtrl.isAnimating) {
        _mouthCtrl.stop();
        _mouthCtrl.value = 0.0;
      }
    }
    setState(() {});
  }

  // ── Blink scheduling ──────────────────────────────────────────────────────────

  void _scheduleBlink() {
    // Random interval: 2–5 seconds between blinks
    final delayMs = 2000 + (DateTime.now().microsecondsSinceEpoch % 3000);
    _blinkTimer?.cancel();
    _blinkTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      _blinkCtrl.forward().then((_) {
        if (!mounted) return;
        _blinkCtrl.reverse().then((_) {
          if (!mounted) return;
          // 25% chance: double-blink for natural feel
          final doDouble = (DateTime.now().millisecondsSinceEpoch % 4) == 0;
          if (doDouble) {
            Future.delayed(const Duration(milliseconds: 200), () {
              if (!mounted) return;
              _blinkCtrl.forward().then((_) {
                if (mounted) {
                  _blinkCtrl.reverse().then((_) {
                    if (mounted) _scheduleBlink();
                  });
                }
              });
            });
          } else {
            _scheduleBlink();
          }
        });
      });
    });
  }

  // ── Tap-to-Toggle handler ──────────────────────────────────────────────────────
  // Tap 1: start recording.  Tap 2: stop & process.

  void _onMicTap() {
    if (_voice.state == VoiceTurnState.recording) {
      // ── Second tap: stop recording → pipeline runs automatically ──
      HapticFeedback.selectionClick();
      _voice.stopRecording();
      return;
    }
    if (!_voice.canStartRecording) return;
    // ── First tap: start recording ──
    HapticFeedback.mediumImpact();
    if (!_voice.isSessionActive) _voice.startSession();
    _voice.startRecording();
  }

  void _onButtonCancel() {
    if (_voice.state == VoiceTurnState.recording) {
      _voice.cancel();
    }
  }

  /// Tap while speaking → stop playback immediately.
  void _onTapDuringPlayback() {
    if (_voice.state == VoiceTurnState.speaking) {
      HapticFeedback.heavyImpact();
      _voice.cancel();
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final isLandscape = media.orientation == Orientation.landscape;

    return Scaffold(
      backgroundColor: GuardianColors.background,
      body: SafeArea(
        child: isLandscape
            ? _buildLandscapeLayout(context)
            : _buildPortraitLayout(context),
      ),
    );
  }

  Widget _buildPortraitLayout(BuildContext context) {
    final t = LocalizationProvider.of(context);
    final media = MediaQuery.of(context);
    final availableHeight = media.size.height - media.padding.top - media.padding.bottom;

    // Scale orb size dynamically based on the actual available safe height
    final double orbSize;
    if (availableHeight < 680) {
      orbSize = 180.0;
    } else if (availableHeight < 780) {
      orbSize = 220.0;
    } else {
      orbSize = 270.0;
    }

    // Mic button total height ≈ 92 (button) + 12 (gap) + 16 (label) = ~120
    final micZoneHeight = 32 + media.padding.bottom + 120;
    return Stack(
      children: [
        Column(
          children: [
            _buildHeader(t),
            const Spacer(flex: 1),
            _buildOrb(size: orbSize),
            const SizedBox(height: 16),
            _buildStatusLabel(),
            const SizedBox(height: 8),
            _buildWaveform(),
            const Spacer(flex: 2),
            SizedBox(height: micZoneHeight),
          ],
        ),
        Positioned(
          bottom: 32 + media.padding.bottom,
          left: 0,
          right: 0,
          child: _buildMicButton(),
        ),
      ],
    );
  }

  Widget _buildLandscapeLayout(BuildContext context) {
    final t = LocalizationProvider.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    flex: 5,
                    child: Center(child: _buildOrb(size: 150)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    flex: 6,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildHeader(t, compact: true),
                        const SizedBox(height: 10),
                        _buildStatusLabel(compact: true),
                        const SizedBox(height: 10),
                        _buildWaveform(compact: true),
                        const SizedBox(height: 14),
                        _buildMicButton(compact: true),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Sub-widgets ───────────────────────────────────────────────────────────────

  Widget _buildHeader(LocalizationService t, {bool compact = false}) {
    final mode = _aiControl.settings.mode;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 24,
        vertical: compact ? 4 : 16,
      ),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              'IBITI Guardian',
              style: GuardianTextStyles.caption.copyWith(
                color: GuardianColors.accent,
                letterSpacing: compact ? 3.0 : 4.0,
                fontWeight: FontWeight.w900,
                fontSize: compact ? 11 : null,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: compact ? 2 : 4),
            Text(
              t.t('assistantNeuralOperator'),
              style: GuardianTextStyles.headline.copyWith(
                fontSize: compact ? 18 : 24,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: compact ? 6 : 10),
            _buildModeBadge(mode, compact: compact),
            if (_voice.isSessionActive) ...[
              SizedBox(height: compact ? 4 : 6),
              _buildSessionIndicator(compact: compact),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildModeBadge(AiMode mode, {bool compact = false}) {
    final t = LocalizationService.instance;
    final Color badgeColor;
    final String label;
    final IconData icon;
    switch (mode) {
      case AiMode.manual:
        badgeColor = const Color(0xFFF59E0B);
        label = t.t('aiControlModeManual').toUpperCase();
        icon = Icons.visibility_outlined;
        break;
      case AiMode.guarded:
        badgeColor = const Color(0xFF22C55E);
        label = t.t('aiControlModeGuarded').toUpperCase();
        icon = Icons.shield_outlined;
        break;
      case AiMode.fullAutonomy:
        badgeColor = const Color(0xFF60A5FA);
        label = t.t('aiControlModeFullAutonomy').toUpperCase();
        icon = Icons.bolt_outlined;
        break;
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: Container(
        key: ValueKey(mode),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 14,
          vertical: compact ? 4 : 6,
        ),
        decoration: BoxDecoration(
          color: badgeColor.withOpacity(0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: badgeColor.withOpacity(0.5), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: compact ? 11 : 13, color: badgeColor),
            SizedBox(width: compact ? 5 : 7),
            Text(
              label,
              style: TextStyle(
                color: badgeColor,
                fontSize: compact ? 10 : 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionIndicator({bool compact = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFF22C55E),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          'SESSION',
          style: TextStyle(
            color: const Color(0xFF22C55E),
            fontSize: compact ? 9 : 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () {
            HapticFeedback.lightImpact();
            _voice.endSession();
          },
          child: Icon(
            Icons.close,
            size: compact ? 14 : 16,
            color: Colors.white38,
          ),
        ),
      ],
    );
  }

  Widget _buildStatusLabel({bool compact = false}) {
    final t = LocalizationService.instance;
    final s = _voice.state;

    String label;
    Color color = GuardianColors.accent;

    switch (s) {
      case VoiceTurnState.idle:
        return SizedBox(height: compact ? 24 : 32);
      case VoiceTurnState.recording:
        label = '${t.t('voiceStatusListening').toUpperCase()} ●';
        color = Colors.redAccent;
        break;
      case VoiceTurnState.transcribing:
        label = '${t.t('voiceStatusTranscribing').toUpperCase()}…';
        break;
      case VoiceTurnState.thinking:
        label = '${t.t('voiceStatusThinking').toUpperCase()}…';
        break;
      case VoiceTurnState.speaking:
        label = '${t.t('voiceStatusResponding').toUpperCase()}…';
        break;
      case VoiceTurnState.error:
        label =
            _voice.errorMessage?.toUpperCase() ?? t.t('error').toUpperCase();
        color = GuardianColors.danger;
        break;
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: Container(
        key: ValueKey(s),
        margin: EdgeInsets.symmetric(horizontal: compact ? 12 : 32),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 16,
          vertical: compact ? 6 : 8,
        ),
        decoration: BoxDecoration(
          color: color.withOpacity(0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.45), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (s == VoiceTurnState.transcribing ||
                s == VoiceTurnState.thinking)
              SizedBox(
                width: compact ? 8 : 10,
                height: compact ? 8 : 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
            if (s == VoiceTurnState.recording || s == VoiceTurnState.speaking)
              Icon(
                s == VoiceTurnState.recording
                    ? Icons.mic
                    : Icons.volume_up_outlined,
                size: compact ? 11 : 13,
                color: color,
              ),
            if (s == VoiceTurnState.error)
              Icon(Icons.error_outline, size: compact ? 11 : 13, color: color),
            SizedBox(width: compact ? 6 : 8),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: compact ? 11 : 12,
                  letterSpacing: 0.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrb({required double size}) {
    final s = _voice.state;
    AICoreState orbState = AICoreState.idle;
    if (s == VoiceTurnState.recording) orbState = AICoreState.safe;
    if (s == VoiceTurnState.speaking) orbState = AICoreState.speaking;
    if (s == VoiceTurnState.thinking || s == VoiceTurnState.transcribing) {
      orbState = AICoreState.thinking;
    }
    return Center(
      child: AICoreWidget(
        size: size,
        state: orbState,
        soundLevel: _soundLevel,
      ),
    );
  }

  Widget _buildWaveform({bool compact = false}) {
    final s = _voice.state;
    final isActive = s != VoiceTurnState.idle && s != VoiceTurnState.error;
    final isSpeaking = s == VoiceTurnState.speaking;
    final isRecording = s == VoiceTurnState.recording;
    final isProcessing =
        s == VoiceTurnState.thinking || s == VoiceTurnState.transcribing;

    final pulse = ((math.sin(_wavePhase) + 1) / 2).clamp(0.0, 1.0);
    final fallback = isRecording
        ? (0.08 + pulse * 0.08)
        : isSpeaking
            ? (0.08 + pulse * 0.06)
            : isProcessing
                ? (0.05 + pulse * 0.04)
                : 0.0;

    final level = math.max(_soundLevel, fallback).clamp(0.0, 1.0);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 48),
      child: AnimatedOpacity(
        opacity: isActive ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 300),
        child: Center(
          child: VoiceWaveformWidget(
            isActive: isActive,
            soundLevel: level,
            width: compact ? 100 : 132,
            height: compact ? 18 : 26,
            isAssistantSpeaking: isSpeaking,
          ),
        ),
      ),
    );
  }



  Widget _buildMicButton({bool compact = false}) {
    final s = _voice.state;
    final isRecording = s == VoiceTurnState.recording;
    final isBusy =
        s == VoiceTurnState.transcribing || s == VoiceTurnState.thinking;
    final isSpeaking = s == VoiceTurnState.speaking;

    final t = LocalizationService.instance;
    final String label = isRecording
        ? t.t('voiceRelease').toUpperCase()
        : isBusy
            ? '${t.t('voiceProcessing').toUpperCase()}…'
            : isSpeaking
                ? t.t('voiceTapToStop').toUpperCase()
                : t.t('voiceHold').toUpperCase();

    final buttonSize = compact ? 72.0 : 96.0;

    // Mood color: green idle, red recording, blue speaking, dim busy
    final Color moodColor = isRecording
        ? const Color(0xFFFF3344)
        : isSpeaking
            ? const Color(0xFF4488FF)
            : isBusy
                ? const Color(0xFF888888)
                : const Color(0xFF22C55E);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: isSpeaking
                ? _onTapDuringPlayback
                : isBusy
                    ? null
                    : _onMicTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              width: buttonSize,
              height: buttonSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: moodColor.withOpacity(isRecording ? 0.55 : 0.30),
                    blurRadius: isRecording ? 28 : 16,
                    spreadRadius: isRecording ? 4 : 1,
                  ),
                ],
              ),
              child: isBusy
                  ? Center(
                      child: SizedBox(
                        width: buttonSize * 0.6,
                        height: buttonSize * 0.6,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor: AlwaysStoppedAnimation<Color>(moodColor),
                        ),
                      ),
                    )
                  : AnimatedBuilder(
                      animation: Listenable.merge([_mouthCtrl, _blinkCtrl]),
                      builder: (_, __) => CustomPaint(
                        size: Size(buttonSize, buttonSize),
                        painter: HyperOrbPainter(
                          blinkProgress: _blinkCtrl.value,
                          breathProgress: _wavePhase * 0.3,
                          moodColor: moodColor,
                          showMic: !TtsService.instance.isSpeaking.value,
                          isDragging: false,
                          isSpeaking: TtsService.instance.isSpeaking.value,
                          mouthOpenProgress: _mouthCtrl.value,
                        ),
                      ),
                    ),
            ),
          ),
          SizedBox(height: compact ? 6 : 12),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: Text(
              label,
              key: ValueKey(label),
              style: GuardianTextStyles.caption.copyWith(
                color: Colors.white.withOpacity(0.84),
                fontSize: compact ? 10 : 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
