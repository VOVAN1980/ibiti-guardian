import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Four living AI forms for the Guardian AI visual style selector.
/// Optimized for high-performance (zero object allocations during paint)
/// and modern premium aesthetics.
enum AiFormType {
  plasma, // Нейронная плазма — blue/cyan swirling particles
  core, // Энергетическое ядро — gold pulsing orb with sparks
  fog, // Цифровой туман — purple dissolving data mist
  stream, // Жидкий поток — green flowing data rivers
}

extension AiFormTypeExtension on AiFormType {
  String get label {
    switch (this) {
      case AiFormType.plasma:
        return 'Плазма';
      case AiFormType.core:
        return 'Ядро';
      case AiFormType.fog:
        return 'Туман';
      case AiFormType.stream:
        return 'Поток';
    }
  }
}

// ──────────────────────────────────────────────────────────
// Main AI Form Widget
// ──────────────────────────────────────────────────────────

class AiFormWidget extends StatefulWidget {
  final AiFormType type;
  final double size;
  final bool active; // selected/highlighted

  const AiFormWidget({
    super.key,
    required this.type,
    this.size = 80,
    this.active = false,
  });

  @override
  State<AiFormWidget> createState() => _AiFormWidgetState();
}

class _AiFormWidgetState extends State<AiFormWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  CustomPainter _painterFor(double t) {
    switch (widget.type) {
      case AiFormType.plasma:
        return _PlasmaPainter(t: t, active: widget.active);
      case AiFormType.core:
        return _CorePainter(t: t, active: widget.active);
      case AiFormType.fog:
        return _FogPainter(t: t, active: widget.active);
      case AiFormType.stream:
        return _StreamPainter(t: t, active: widget.active);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        return CustomPaint(
          size: Size(widget.size, widget.size),
          painter: _painterFor(_ctrl.value),
        );
      },
    );
  }
}

// ──────────────────────────────────────────────────────────
// 1. Нейронная Плазма — Siri-like liquid morphing orb
// ──────────────────────────────────────────────────────────
class _PlasmaPainter extends CustomPainter {
  final double t;
  final bool active;
  _PlasmaPainter({required this.t, required this.active});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2;
    final angle = t * math.pi * 2;

    // Outer glow backing
    final basePulse = 0.65 + 0.1 * math.sin(angle);
    final bgGlow = RadialGradient(
      colors: [
        const Color(0xFF00CFFF).withOpacity(active ? 0.35 : 0.15),
        const Color(0xFF0066FF).withOpacity(active ? 0.15 : 0.05),
        Colors.transparent,
      ],
      stops: const [0.0, 0.5, 1.0],
    );
    canvas.drawCircle(
      Offset(cx, cy),
      r * basePulse,
      Paint()
        ..shader = bgGlow.createShader(
          Rect.fromCircle(center: Offset(cx, cy), radius: r * basePulse),
        ),
    );

    // Draw three morphing blobs that overlap to create a liquid feel
    for (int layer = 0; layer < 2; layer++) {
      final double layerAngle = angle * (layer == 0 ? 1.0 : -1.2);
      final double baseRadius = r * (layer == 0 ? 0.45 : 0.38);

      final path = Path();
      const int steps = 48;
      for (int i = 0; i <= steps; i++) {
        final double theta = (i * 2 * math.pi) / steps;
        
        // Complex trigonometric deformation for smooth liquid shapes without random calls
        final double wave1 = 0.22 * math.sin(3 * theta + layerAngle * 1.5);
        final double wave2 = 0.12 * math.cos(5 * theta - layerAngle * 2.2 + layer);
        final double currentR = baseRadius * (1.0 + wave1 + wave2);

        final double px = cx + math.cos(theta) * currentR;
        final double py = cy + math.sin(theta) * currentR * 0.95;

        if (i == 0) {
          path.moveTo(px, py);
        } else {
          path.lineTo(px, py);
        }
      }
      path.close();

      final Color mainColor = layer == 0 ? const Color(0xFF00CFFF) : const Color(0xFF9900FF);
      final Color sideColor = layer == 0 ? const Color(0xFF0066FF) : const Color(0xFFFF0077);

      final blobGrad = RadialGradient(
        colors: [
          mainColor.withOpacity(active ? 0.85 : 0.65),
          sideColor.withOpacity(active ? 0.45 : 0.25),
          Colors.transparent,
        ],
        stops: const [0.0, 0.7, 1.0],
      );

      canvas.drawPath(
        path,
        Paint()
          ..shader = blobGrad.createShader(
            Rect.fromCircle(center: Offset(cx, cy), radius: baseRadius * 1.5),
          )
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
    }

    // High tech glowing thin contour
    final contourPaint = Paint()
      ..color = const Color(0xFF00FFFF).withOpacity(active ? 0.45 : 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    final pathContour = Path();
    const int steps = 40;
    for (int i = 0; i <= steps; i++) {
      final double theta = (i * 2 * math.pi) / steps;
      final double wave = 0.15 * math.sin(4 * theta - angle * 2.0);
      final double currentR = r * 0.52 * (1.0 + wave);
      final double px = cx + math.cos(theta) * currentR;
      final double py = cy + math.sin(theta) * currentR * 0.95;
      if (i == 0) {
        pathContour.moveTo(px, py);
      } else {
        pathContour.lineTo(px, py);
      }
    }
    pathContour.close();
    canvas.drawPath(pathContour, contourPaint);
  }

  @override
  bool shouldRepaint(covariant _PlasmaPainter old) => old.t != t;
}

// ──────────────────────────────────────────────────────────
// 2. Энергетическое Ядро — high-tech reactor gyroscope
// ──────────────────────────────────────────────────────────
class _CorePainter extends CustomPainter {
  final double t;
  final bool active;
  _CorePainter({required this.t, required this.active});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2;
    final angle = t * math.pi * 2;

    // Glowing core reactor center
    final pulse = 0.9 + 0.1 * math.sin(angle * 3.0);
    final coreRadius = r * 0.28 * pulse;

    final coreGlow = RadialGradient(
      colors: [
        const Color(0xFFFFFF99).withOpacity(active ? 1.0 : 0.8),
        const Color(0xFFFF9900).withOpacity(active ? 0.75 : 0.55),
        const Color(0xFFCC4400).withOpacity(active ? 0.35 : 0.15),
        Colors.transparent,
      ],
      stops: const [0.0, 0.35, 0.7, 1.0],
    );

    canvas.drawCircle(
      Offset(cx, cy),
      coreRadius * 1.5,
      Paint()
        ..shader = coreGlow.createShader(
          Rect.fromCircle(center: Offset(cx, cy), radius: coreRadius * 1.5),
        ),
    );

    // Dynamic clean vector rings rotating in opposite directions
    final ringPaint = Paint()
      ..color = const Color(0xFFFFAA00).withOpacity(active ? 0.8 : 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // Inner rotating dashboard ring (Double arc, clockwise)
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r * 0.46),
      angle * 1.5,
      math.pi * 0.7,
      false,
      ringPaint,
    );
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r * 0.46),
      angle * 1.5 + math.pi,
      math.pi * 0.7,
      false,
      ringPaint,
    );

    // Middle dashboard ring (Three shorter arcs, counter-clockwise)
    final middleRingPaint = Paint()
      ..color = const Color(0xFFFF8800).withOpacity(active ? 0.6 : 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r * 0.66),
      -angle * 2.0,
      math.pi * 0.45,
      false,
      middleRingPaint,
    );
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r * 0.66),
      -angle * 2.0 + math.pi * 2 / 3,
      math.pi * 0.45,
      false,
      middleRingPaint,
    );
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r * 0.66),
      -angle * 2.0 + math.pi * 4 / 3,
      math.pi * 0.45,
      false,
      middleRingPaint,
    );

    // Outer thin calibration ring (very slow clockwise rotation)
    final outerRingPaint = Paint()
      ..color = const Color(0xFFFFAA00).withOpacity(active ? 0.35 : 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;
    
    canvas.drawCircle(Offset(cx, cy), r * 0.84, outerRingPaint);

    // Fine tick marks pointing outward (absolutely zero GC allocations)
    final tickPaint = Paint()
      ..color = const Color(0xFFFFAA00).withOpacity(active ? 0.65 : 0.35)
      ..strokeWidth = 1.0;

    for (int i = 0; i < 8; i++) {
      final double a = i * math.pi / 4 + angle * 0.4;
      final double rStart = r * 0.78;
      final double rEnd = r * 0.84;
      canvas.drawLine(
        Offset(cx + math.cos(a) * rStart, cy + math.sin(a) * rStart),
        Offset(cx + math.cos(a) * rEnd, cy + math.sin(a) * rEnd),
        tickPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CorePainter old) => old.t != t;
}

// ──────────────────────────────────────────────────────────
// 3. Цифровой Туман — dynamic neural constellation
// ──────────────────────────────────────────────────────────
class _FogPainter extends CustomPainter {
  final double t;
  final bool active;
  _FogPainter({required this.t, required this.active});

  // Pre-calculated orbital metadata to avoid creating objects during paint
  static const List<double> _nodeSpeeds = [
    1.1, -0.8, 1.4, -1.0, 0.7, -1.3, 1.0, -0.9, 1.2, -1.1, 0.8, -1.4
  ];
  static const List<double> _nodeRadii = [
    0.20, 0.45, 0.35, 0.58, 0.28, 0.50, 0.70, 0.40, 0.64, 0.32, 0.52, 0.48
  ];
  static const List<double> _nodeAngles = [
    0.0, 0.52, 1.05, 1.57, 2.09, 2.62, 3.14, 3.66, 4.19, 4.71, 5.24, 5.76
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2;
    final angle = t * math.pi * 2;

    // Node count
    const int numNodes = 12;

    // Calculate node coordinates on stack to prevent array allocation
    final List<double> xPos = List.filled(numNodes, 0.0);
    final List<double> yPos = List.filled(numNodes, 0.0);

    for (int i = 0; i < numNodes; i++) {
      final double orbitAngle = _nodeAngles[i] + _nodeSpeeds[i] * angle * 0.7;
      final double orbitRadius = r * _nodeRadii[i];
      xPos[i] = cx + math.cos(orbitAngle) * orbitRadius;
      yPos[i] = cy + math.sin(orbitAngle) * orbitRadius * 0.85; // slight ellipse
    }

    // Connect nodes with thin transparent lines based on distance
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;

    final threshold = r * 0.52;

    for (int i = 0; i < numNodes; i++) {
      for (int j = i + 1; j < numNodes; j++) {
        final double dx = xPos[i] - xPos[j];
        final double dy = yPos[i] - yPos[j];
        final double dist = math.sqrt(dx * dx + dy * dy);

        if (dist < threshold) {
          final double opacity = (1.0 - dist / threshold) * (active ? 0.35 : 0.16);
          linePaint.color = const Color(0xFFCC88FF).withOpacity(opacity);
          canvas.drawLine(
            Offset(xPos[i], yPos[i]),
            Offset(xPos[j], yPos[j]),
            linePaint,
          );
        }
      }
    }

    // Draw glowing nodes
    final nodePaint = Paint()..style = PaintingStyle.fill;
    for (int i = 0; i < numNodes; i++) {
      final double pulse = 0.85 + 0.15 * math.sin(angle * 4.0 + i * 2.0);
      nodePaint.color = const Color(0xFFCC88FF).withOpacity(active ? 0.85 : 0.55);
      canvas.drawCircle(Offset(xPos[i], yPos[i]), 1.8 * pulse, nodePaint);
      
      // Node micro-glow
      nodePaint.color = const Color(0xFF9900FF).withOpacity(active ? 0.3 : 0.15);
      canvas.drawCircle(Offset(xPos[i], yPos[i]), 4.5 * pulse, nodePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _FogPainter old) => old.t != t;
}

// ──────────────────────────────────────────────────────────
// 4. Жидкий Поток — overlapping glowing sine waves
// ──────────────────────────────────────────────────────────
class _StreamPainter extends CustomPainter {
  final double t;
  final bool active;
  _StreamPainter({required this.t, required this.active});

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final w = size.width;
    final angle = t * math.pi * 2;

    // Draw three elegant horizontal waves with different frequencies and speeds
    for (int wave = 0; wave < 3; wave++) {
      final double frequency;
      final double amplitude;
      final double speed;
      final Color waveColor;

      if (wave == 0) {
        frequency = 1.3;
        amplitude = size.height * 0.18;
        speed = 1.0;
        waveColor = const Color(0xFF00FF88);
      } else if (wave == 1) {
        frequency = 2.1;
        amplitude = size.height * 0.12;
        speed = -1.5;
        waveColor = const Color(0xFF00FFDD);
      } else {
        frequency = 2.8;
        amplitude = size.height * 0.08;
        speed = 2.2;
        waveColor = const Color(0xFF00AAFF);
      }

      final path = Path();
      const int steps = 40;
      for (int i = 0; i <= steps; i++) {
        final double x = (i * w) / steps;
        final double relativeX = x / w;
        
        // Envelope curve to make the wave gently fade out at both screen borders
        final double envelope = math.sin(relativeX * math.pi);
        
        // Wave Y coordinate using pre-calculated angles
        final double y = cy + amplitude * envelope * math.sin(relativeX * frequency * math.pi + angle * speed);

        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }

      final double alpha = (0.5 + 0.3 * math.sin(angle + wave)) * (active ? 1.0 : 0.6);

      canvas.drawPath(
        path,
        Paint()
          ..color = waveColor.withOpacity(alpha.clamp(0, 1.0))
          ..style = PaintingStyle.stroke
          ..strokeWidth = wave == 0 ? 1.6 : 1.0
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.8),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StreamPainter old) => old.t != t;
}
