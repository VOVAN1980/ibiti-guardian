import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';

class EnergyPulsePainter extends CustomPainter {
  final double scale;
  final double intensity; // 0 to 1 for lightning activity
  final Color color;

  EnergyPulsePainter({
    required this.scale,
    required this.intensity,
    this.color = GuardianColors.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = 4.0 * scale;

    // 1. Core Glow (Radial Gradient)
    final coreGlowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.white,
          color.withOpacity(0.8),
          color.withOpacity(0.0),
        ],
        stops: const [0.0, 0.3, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: baseRadius * 4));
    canvas.drawCircle(center, baseRadius * 4, coreGlowPaint);

    // 2. The Singularity Dot
    final dotPaint = Paint()..color = Colors.white;
    canvas.drawCircle(center, baseRadius, dotPaint);

    // 3. Lightning Arcs (Erratic)
    if (intensity > 0.1) {
      final lightningPaint = Paint()
        ..color = Colors.white.withOpacity(intensity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1);

      final random = math.Random(DateTime.now().millisecondsSinceEpoch ~/ 50);

      for (int i = 0; i < 6; i++) {
        final path = Path();
        path.moveTo(center.dx, center.dy);

        double currentX = center.dx;
        double currentY = center.dy;

        final angle = i * (math.pi * 2 / 6) + (random.nextDouble() * 0.4 - 0.2);
        final distance =
            (25.0 + random.nextDouble() * 45.0) * scale * intensity;

        int segments = 6; // Refined count for 'prestige' look
        for (int j = 0; j < segments; j++) {
          final stepDist = distance / segments;
          final jitter =
              (random.nextDouble() - 0.5) * 12 * intensity; // Slightly cleaner
          currentX += math.cos(angle) * stepDist + jitter;
          currentY += math.sin(angle) * stepDist + jitter;
          path.lineTo(currentX, currentY);
        }

        canvas.drawPath(path, lightningPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant EnergyPulsePainter oldDelegate) => true;
}
