import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/services/voice/tts_service.dart';
import 'package:ibiti_guardian/services/voice/voice_turn_controller.dart';
import 'package:ibiti_guardian/widgets/hyper_orb_painter.dart';

/// A floating, draggable **Hyper Orb** mascot that lives in an [Overlay].
///
/// When [isVisible] is true and a voice session is active, the Orb
/// appears in the bottom-right corner (or wherever the user dragged it).
/// The user can tap-hold to record, and the Orb reflects the current
/// [VoiceTurnState] with color and animation.
///
/// **Visual:** Green character with eyes, mouth, arms, legs, glow,
/// idle breathing and blink animation. Replaces the old flat circle.
///
/// **Lifecycle:** Created once by [GuardianAppShell], never removed.
/// Visibility is controlled entirely through [Opacity] + [IgnorePointer]
/// to avoid flicker on tab transitions.
class FloatingMicBubble extends StatefulWidget {
  final bool isVisible;

  /// Optional initial position for the bubble (e.g. from long-press location).
  /// If null, defaults to bottom-right corner.
  final Offset? initialPosition;

  const FloatingMicBubble({
    super.key,
    required this.isVisible,
    this.initialPosition,
  });

  @override
  State<FloatingMicBubble> createState() => _FloatingMicBubbleState();
}

class _FloatingMicBubbleState extends State<FloatingMicBubble>
    with TickerProviderStateMixin {
  final _voice = VoiceTurnController.instance;

  // ── Position ─────────────────────────────────────────────────────────────────
  // Default: bottom-right. Updated by drag gestures.
  Offset? _position;
  static const double _size = 72.0; // large enough for character readability
  static const double _margin = 16.0;

  // ── Drag state ──────────────────────────────────────────────────────────────
  Offset? _dragStartPosition;
  Offset? _pointerStartPos;
  bool _isDragMode = false;

  // ── Long-press dismiss ───────────────────────────────────────────────────
  Timer? _longPressTimer;
  bool _isPopping = false;
  bool _dismissedLocally = false;

  // ── Idle breath animation ──────────────────────────────────────────────────
  late final AnimationController _breathCtrl;

  // ── Blink animation ────────────────────────────────────────────────────────
  late final AnimationController _blinkCtrl;
  Timer? _blinkTimer;

  // ── Pulse animation (recording/speaking) ───────────────────────────────────
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  // ── Mouth animation (speaking) ─────────────────────────────────────────────
  late final AnimationController _mouthCtrl;

  // ── Pop dismiss animation ───────────────────────────────────────────────
  late final AnimationController _popCtrl;

  @override
  void initState() {
    super.initState();
    _voice.addListener(_onVoiceChanged);
    TtsService.instance.isSpeaking.addListener(_onTtsSpeakingChanged);

    // Breath: slow continuous idle animation
    _breathCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat();

    // Blink: quick close/open — faster for snappy feel
    _blinkCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _scheduleBlink();

    // Pulse: scale up/down during recording/speaking
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _pulseAnim = Tween<double>(begin: 1.0, end: 1.12).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    // Mouth: oscillates 0→1→0 when AI is speaking
    _mouthCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );

    // Pop: scale 1→1.3→0 over 400ms
    _popCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _popCtrl.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() {
          _isPopping = false;
          _dismissedLocally = true;
        });
        // End voice session after pop completes
        if (_voice.isSessionActive) {
          _voice.endSession();
        }
      }
    });
  }

  void _scheduleBlink() {
    // Truly random interval: 2–5 seconds between blinks
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
                if (mounted)
                  _blinkCtrl.reverse().then((_) {
                    if (mounted) _scheduleBlink();
                  });
              });
            });
          } else {
            _scheduleBlink();
          }
        });
      });
    });
  }

  @override
  void didUpdateWidget(covariant FloatingMicBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When initialPosition changes (long-press at new location) AND bubble
    // is becoming visible, adopt that position.
    if (widget.initialPosition != null &&
        widget.initialPosition != oldWidget.initialPosition &&
        widget.isVisible) {
      _position = widget.initialPosition;
    }
    // Reset local dismiss when parent makes us visible again
    // (user invoked AI/voice after dismissing Orb).
    if (widget.isVisible && !oldWidget.isVisible && _dismissedLocally) {
      _dismissedLocally = false;
      _popCtrl.reset();
    }
  }

  @override
  void dispose() {
    _voice.removeListener(_onVoiceChanged);
    TtsService.instance.isSpeaking.removeListener(_onTtsSpeakingChanged);
    _breathCtrl.dispose();
    _blinkCtrl.dispose();
    _blinkTimer?.cancel();
    _pulseCtrl.dispose();
    _mouthCtrl.dispose();
    _popCtrl.dispose();
    _longPressTimer?.cancel();
    super.dispose();
  }

  void _onVoiceChanged() {
    if (mounted) setState(() {});
  }

  /// Mouth sync driven by actual TTS audio playback, not voice turn state.
  void _onTtsSpeakingChanged() {
    if (!mounted) return;
    final talking = TtsService.instance.isSpeaking.value;
    if (talking) {
      if (!_mouthCtrl.isAnimating) {
        _mouthCtrl.repeat(reverse: true);
      }
    } else {
      if (_mouthCtrl.isAnimating) {
        _mouthCtrl.stop();
        _mouthCtrl.value = 0.0;
      }
    }
    setState(() {});
  }

  // ── Default position (bottom-right, above bottom nav) ────────────────────
  Offset _defaultPosition(BuildContext context) {
    final mq = MediaQuery.of(context);
    final bottomInset = mq.viewInsets.bottom; // keyboard height
    final bottomPadding = mq.padding.bottom;
    // Place above bottom nav (≈80dp) or keyboard, whichever is taller.
    final bottomOffset =
        bottomInset > 0 ? bottomInset + _margin : bottomPadding + 80 + _margin;
    return Offset(
      mq.size.width - _size - _margin,
      mq.size.height - _size - bottomOffset,
    );
  }

  /// Clamp position to screen bounds, accounting for keyboard.
  Offset _clampPosition(Offset pos, BuildContext context) {
    final mq = MediaQuery.of(context);
    final bottomInset = mq.viewInsets.bottom;
    final maxX = mq.size.width - _size - 4;
    final maxY = mq.size.height -
        _size -
        (bottomInset > 0 ? bottomInset + 8 : mq.padding.bottom + 8);
    final minY = mq.padding.top + 4;
    return Offset(
      pos.dx.clamp(4, maxX),
      pos.dy.clamp(minY, maxY),
    );
  }



  // ── Visual properties by state ───────────────────────────────────────────
  Color _orbColor() {
    switch (_voice.state) {
      case VoiceTurnState.recording:
        return const Color(0xFFEF4444); // red
      case VoiceTurnState.transcribing:
      case VoiceTurnState.thinking:
        return const Color(0xFFF59E0B); // amber
      case VoiceTurnState.speaking:
        return const Color(0xFF3B82F6); // blue
      case VoiceTurnState.error:
        return const Color(0xFFEF4444).withOpacity(0.7);
      case VoiceTurnState.idle:
        return const Color(0xFF22C55E); // green
    }
  }

  double _idleOpacity() {
    return _voice.state == VoiceTurnState.idle ? 0.85 : 1.0;
  }

  bool _shouldPulse() {
    return _voice.state == VoiceTurnState.recording ||
        _voice.state == VoiceTurnState.speaking;
  }

  bool _showMic() {
    return _voice.state == VoiceTurnState.recording;
  }

  @override
  Widget build(BuildContext context) {
    // Compute effective position: if user dragged, clamp to current bounds
    // (accounts for keyboard). If no drag yet, use default position.
    final pos = _position ?? _defaultPosition(context);
    final clamped = _clampPosition(pos, context);

    return Positioned(
      left: clamped.dx,
      top: clamped.dy,
      child: IgnorePointer(
        ignoring: !widget.isVisible || _dismissedLocally,
        child: AnimatedOpacity(
          opacity:
              (widget.isVisible && !_dismissedLocally) ? _idleOpacity() : 0.0,
          duration: const Duration(milliseconds: 250),
          child: _isPopping ? _buildPoppingOrb() : _buildOrb(),
        ),
      ),
    );
  }

  Widget _buildOrb() {
    final color = _orbColor();
    final pulse = _shouldPulse();

    // Raw Listener — bypasses gesture arena entirely.
    // Tap (no drag) = toggle recording. Drag = reposition.
    // Zero delay, no recognizer competition.
    Widget orb = Listener(
      onPointerDown: (event) {
        _dragStartPosition = _position ?? _defaultPosition(context);
        _pointerStartPos = event.position;
        _isDragMode = false;

        if (_voice.state == VoiceTurnState.speaking) {
          HapticFeedback.heavyImpact();
          _voice.cancel();
          return;
        }

        if (_voice.state == VoiceTurnState.recording) {
          // Second tap: stop and send
          HapticFeedback.selectionClick();
          _voice.stopRecording();
        } else if (_voice.canStartRecording) {
          // First tap: start recording
          HapticFeedback.mediumImpact();
          if (!_voice.isSessionActive) _voice.startSession();
          _voice.startRecording();
        }

        // Start long-press timer (750ms) for pop dismiss
        _longPressTimer?.cancel();
        _longPressTimer = Timer(const Duration(milliseconds: 750), () {
          if (!mounted || _isDragMode) return;
          HapticFeedback.heavyImpact();
          _triggerPopDismiss();
        });
      },
      onPointerMove: (event) {
        if (_pointerStartPos == null) return;
        final delta = event.position - _pointerStartPos!;
        if (delta.distance > 15) {
          if (!_isDragMode) {
            _isDragMode = true;
            _longPressTimer?.cancel();
            if (_voice.state == VoiceTurnState.recording) {
              _voice.cancel();
            }
          }
          setState(() {
            _position = _clampPosition(
              Offset(
                _dragStartPosition!.dx + delta.dx,
                _dragStartPosition!.dy + delta.dy,
              ),
              context,
            );
          });
        }
      },
      onPointerUp: (_) {
        _longPressTimer?.cancel();
        _isDragMode = false;
        _dragStartPosition = null;
        _pointerStartPos = null;
      },
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: Listenable.merge([_breathCtrl, _blinkCtrl, _mouthCtrl]),
          builder: (_, __) => CustomPaint(
            size: const Size(_size, _size),
            painter: HyperOrbPainter(
              blinkProgress: _blinkCtrl.value,
              breathProgress: _breathCtrl.value,
              moodColor: color,
              showMic: _showMic(),
              isDragging: _isDragMode,
              isSpeaking: TtsService.instance.isSpeaking.value,
              mouthOpenProgress: _mouthCtrl.value,
            ),
          ),
        ),
      ),
    );

    if (pulse) {
      return AnimatedBuilder(
        animation: _pulseAnim,
        builder: (_, child) => Transform.scale(
          scale: _pulseAnim.value,
          child: child,
        ),
        child: orb,
      );
    }

    return orb;
  }

  /// Pop animation widget: scale 1→1.3→0 with fade.
  Widget _buildPoppingOrb() {
    return AnimatedBuilder(
      animation: _popCtrl,
      builder: (_, __) {
        // 0→0.3: scale up to 1.3, 0.3→1.0: shrink to 0
        final t = _popCtrl.value;
        double scale;
        double opacity;
        if (t < 0.3) {
          scale = 1.0 + (t / 0.3) * 0.3; // 1.0 → 1.3
          opacity = 1.0;
        } else {
          scale = 1.3 * (1.0 - (t - 0.3) / 0.7); // 1.3 → 0
          opacity = 1.0 - (t - 0.3) / 0.7; // 1.0 → 0
        }
        return Transform.scale(
          scale: scale.clamp(0.0, 2.0),
          child: Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: CustomPaint(
              size: const Size(_size, _size),
              painter: HyperOrbPainter(
                blinkProgress: 0.0,
                breathProgress: 0.0,
                moodColor: const Color(0xFF22C55E),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Trigger the pop/bubble-burst dismiss animation.
  void _triggerPopDismiss() {
    if (_isPopping || _dismissedLocally) return;
    // Cancel any active recording/playback
    if (_voice.state == VoiceTurnState.recording) {
      _voice.cancel();
    } else if (_voice.state == VoiceTurnState.speaking) {
      _voice.cancel();
    }
    setState(() => _isPopping = true);
    _popCtrl.forward(from: 0.0);
  }
}
