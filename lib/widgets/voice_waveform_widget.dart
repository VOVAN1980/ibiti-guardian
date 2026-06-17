import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';

class VoiceWaveformWidget extends StatefulWidget {
  final bool isActive;
  final double soundLevel;
  final Color color;
  final double width;
  final double height;
  final bool isAssistantSpeaking;

  const VoiceWaveformWidget({
    super.key,
    this.isActive = false,
    this.soundLevel = 0.0,
    this.color = GuardianColors.accent,
    this.width = 132,
    this.height = 24,
    this.isAssistantSpeaking = false,
  });

  @override
  State<VoiceWaveformWidget> createState() => _VoiceWaveformWidgetState();
}

class _VoiceWaveformWidgetState extends State<VoiceWaveformWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _smoothedLevel = 0.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.isActive) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant VoiceWaveformWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive != oldWidget.isActive) {
      if (widget.isActive) {
        _controller.repeat();
      } else {
        _controller.stop();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _smoothedLevel = _smoothedLevel * 0.58 + widget.soundLevel * 0.42;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return CustomPaint(
          size: Size(widget.width, widget.height),
          painter: _VoiceBarsPainter(
            animationValue: _controller.value,
            isActive: widget.isActive,
            soundLevel: _smoothedLevel.clamp(0.0, 1.0),
            color: widget.color,
            isAssistantSpeaking: widget.isAssistantSpeaking,
          ),
        );
      },
    );
  }
}

class _VoiceBarsPainter extends CustomPainter {
  final double animationValue;
  final bool isActive;
  final double soundLevel;
  final Color color;
  final bool isAssistantSpeaking;

  _VoiceBarsPainter({
    required this.animationValue,
    required this.isActive,
    required this.soundLevel,
    required this.color,
    required this.isAssistantSpeaking,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!isActive) return;

    const barCount = 9;
    final centerY = size.height / 2;
    final spacing = size.width / (barCount - 1);
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3;
    final speakingColor = isAssistantSpeaking ? const Color(0xFF66D0FF) : color;
    final responseBoost = isAssistantSpeaking ? 1.25 : 1.0;

    for (int i = 0; i < barCount; i++) {
      final distanceFromCenter = (i - (barCount - 1) / 2).abs();
      final centerWeight = 1 - (distanceFromCenter / ((barCount - 1) / 2));
      final pulse =
          (math.sin(animationValue * math.pi * 2.2 + i * 0.55) + 1) / 2;

      // Edges stay almost still, middle bars react strongly to the voice.
      final halfHeight = 1.8 +
          centerWeight *
              (3.5 + soundLevel * 24 * responseBoost) *
              (0.30 + pulse * 0.70);

      final x = i * spacing;
      canvas.drawLine(
        Offset(x, centerY - halfHeight),
        Offset(x, centerY + halfHeight),
        paint..color = speakingColor.withOpacity(0.34 + centerWeight * 0.60),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VoiceBarsPainter oldDelegate) {
    return animationValue != oldDelegate.animationValue ||
        isActive != oldDelegate.isActive ||
        soundLevel != oldDelegate.soundLevel ||
        color != oldDelegate.color ||
        isAssistantSpeaking != oldDelegate.isAssistantSpeaking;
  }
}
