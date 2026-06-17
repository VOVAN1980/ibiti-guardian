import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';

class VibrantOrbWidget extends StatefulWidget {
  final double size;
  final bool isThinking;
  final bool isSpeaking;
  final Color? baseColor;

  const VibrantOrbWidget({
    super.key,
    this.size = 200,
    this.isThinking = false,
    this.isSpeaking = false,
    this.baseColor,
  });

  @override
  State<VibrantOrbWidget> createState() => _VibrantOrbWidgetState();
}

class _VibrantOrbWidgetState extends State<VibrantOrbWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.baseColor ?? GuardianColors.accent;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 1. Static Outer Glow
              Container(
                width: widget.size * 0.8,
                height: widget.size * 0.8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: color.withOpacity(0.2),
                      blurRadius: 40,
                      spreadRadius: 10,
                    ),
                  ],
                ),
              ),
              // 2. The Living Blob Painter
              CustomPaint(
                size: Size(widget.size, widget.size),
                painter: _OrbPainter(
                  time: _controller.value,
                  color: color,
                  isThinking: widget.isThinking,
                  isSpeaking: widget.isSpeaking,
                ),
              ),
              // 3. Inner Core Highlight
              Container(
                width: widget.size * 0.15,
                height: widget.size * 0.15,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Colors.white.withOpacity(0.8),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _OrbPainter extends CustomPainter {
  final double time;
  final Color color;
  final bool isThinking;
  final bool isSpeaking;

  _OrbPainter({
    required this.time,
    required this.color,
    required this.isThinking,
    required this.isSpeaking,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 3.5;

    // We draw multiple layers with different offsets to create depth
    _drawBlob(canvas, center, radius, 0, 0.4);
    _drawBlob(canvas, center, radius * 0.8, 1.5, 0.3);
    _drawBlob(canvas, center, radius * 0.6, 3.0, 0.2);
  }

  void _drawBlob(Canvas canvas, Offset center, double radius, double timeOffset,
      double opacity) {
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          color.withOpacity(opacity),
          color.withOpacity(0.0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius * 1.5));

    final path = Path();
    const segments = 120; // More segments for smoother high-frequency noise
    final speed = isThinking ? 3.0 : 1.0;

    // High-frequency "vibration" noise for speaking state
    final vibration = isSpeaking
        ? (math.sin(time * 60) * 4.0 + math.cos(time * 45) * 2.0)
        : 0.0;
    final baseAmplitude = isSpeaking ? 10.0 : 4.0;
    final amplitude = baseAmplitude + vibration;

    // Wave movement
    final t = (time + timeOffset) * 2 * math.pi;

    for (int i = 0; i <= segments; i++) {
      final angle = (i / segments) * 2 * math.pi;

      // Complex noise-like movement using multiple sines
      // Added more layers of harmonics for "living" feel
      double distortion = math.sin(angle * 3 + t * speed) * amplitude +
          math.cos(angle * 2 - t * speed * 0.5) * (amplitude * 0.5);

      if (isSpeaking) {
        // Add rapid micro-oscillations for "voice" texture
        distortion += math.sin(angle * 12 + t * 20) * 2.0;
      }

      final r = radius + distortion;
      final x = center.dx + r * math.cos(angle);
      final y = center.dy + r * math.sin(angle);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();

    // Add blur to edges
    canvas.drawPath(
        path, paint..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12));

    // Core stroke for definition
    final strokePaint = Paint()
      ..color = color.withOpacity(opacity * 2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant _OrbPainter oldDelegate) => true;
}
