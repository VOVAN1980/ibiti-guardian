import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Draws the Hyper Orb mascot — a glossy, glass-like green character
/// inspired by the concept art. Features:
///   • Bright neon-green glow with multiple layers
///   • Glossy body with radial gradient + strong specular highlights
///   • Large expressive anime-style eyes with big pupils + double catch-lights
///   • Cute smile (idle), animated open mouth (speaking), frown (dragging)
///   • Tiny arms with 3-finger hands + tiny legs with round feet
///   • Breath squash/stretch + blink animation
///
/// All geometry is proportional to [size] for resolution independence.
///
/// Animation inputs:
/// - [blinkProgress] 0..1 — 0 = eyes open, 1 = fully closed
/// - [breathProgress] 0..1 — drives sine-based squash/stretch cycle
/// - [moodColor] — body tint (green=idle, red=recording, blue=speaking)
/// - [isDragging] — annoyed face: squint eyes, frown, raised arms, angry brows
/// - [isSpeaking] — animated open mouth
/// - [mouthOpenProgress] 0..1 — drives mouth open amount during speaking
class HyperOrbPainter extends CustomPainter {
  final double blinkProgress;
  final double breathProgress;
  final Color moodColor;
  final bool showMic;
  final bool isDragging;
  final bool isSpeaking;
  final double mouthOpenProgress;

  HyperOrbPainter({
    required this.blinkProgress,
    required this.breathProgress,
    required this.moodColor,
    this.showMic = false,
    this.isDragging = false,
    this.isSpeaking = false,
    this.mouthOpenProgress = 0.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width * 0.38; // body radius — slightly bigger for presence

    // ── Breath squash/stretch ───────────────────────────────────────────────
    final breathSine = math.sin(breathProgress * math.pi * 2);
    final scaleX = 1.0 + breathSine * 0.018;
    final scaleY = 1.0 - breathSine * 0.022;
    final bodyCy = cy + breathSine * 1.2;

    canvas.save();
    canvas.translate(cx, bodyCy);
    canvas.scale(scaleX, scaleY);
    canvas.translate(-cx, -bodyCy);

    // ── Outer glow — multiple layers for neon effect ────────────────────────
    _drawGlow(canvas, cx, bodyCy, r);

    // ── Body — glossy glass-like sphere ─────────────────────────────────────
    _drawBody(canvas, cx, bodyCy, r);

    // ── Legs (behind body bottom) ───────────────────────────────────────────
    _drawLegs(canvas, cx, bodyCy, r);

    // ── Arms ────────────────────────────────────────────────────────────────
    _drawArms(canvas, cx, bodyCy, r, breathSine);

    // ── Eyebrows (only when annoyed) ────────────────────────────────────────
    if (isDragging) {
      _drawAngryBrows(canvas, cx, bodyCy, r);
    }

    // ── Eyes ────────────────────────────────────────────────────────────────
    _drawEyes(canvas, cx, bodyCy, r);

    // ── Mouth ───────────────────────────────────────────────────────────────
    _drawMouth(canvas, cx, bodyCy, r);

    // ── Mic icon overlay (when recording) ──────────────────────────────────
    if (showMic) {
      _drawMicIcon(canvas, cx, bodyCy, r);
    }

    canvas.restore();
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  GLOW — bright neon aura, 3 layers for depth
  // ══════════════════════════════════════════════════════════════════════════

  void _drawGlow(Canvas canvas, double cx, double cy, double r) {
    // Layer 1: wide soft glow
    final glow1 = Paint()
      ..color = moodColor.withOpacity(0.15)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 28);
    canvas.drawCircle(Offset(cx, cy), r + 14, glow1);

    // Layer 2: medium glow
    final glow2 = Paint()
      ..color = moodColor.withOpacity(0.25)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);
    canvas.drawCircle(Offset(cx, cy), r + 6, glow2);

    // Layer 3: tight bright rim
    final glow3 = Paint()
      ..color = _brighten(moodColor, 0.2).withOpacity(0.30)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawCircle(Offset(cx, cy), r + 2, glow3);
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  BODY — glossy glass sphere with multiple highlight layers
  // ══════════════════════════════════════════════════════════════════════════

  void _drawBody(Canvas canvas, double cx, double cy, double r) {
    // Main body gradient — bright center, darker edges
    final bodyPaint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.20, -0.30),
        radius: 1.0,
        colors: [
          _brighten(moodColor, 0.45),
          _brighten(moodColor, 0.15),
          moodColor,
          _darken(moodColor, 0.25),
        ],
        stops: const [0.0, 0.35, 0.65, 1.0],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r));
    canvas.drawCircle(Offset(cx, cy), r, bodyPaint);

    // Glass highlight 1 — large top-left specular
    final hl1 = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.35, -0.45),
        radius: 0.55,
        colors: [
          Colors.white.withOpacity(0.65),
          Colors.white.withOpacity(0.15),
          Colors.white.withOpacity(0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r));
    canvas.drawCircle(Offset(cx, cy), r, hl1);

    // Glass highlight 2 — small bright dot (top-left)
    final dotCx = cx - r * 0.28;
    final dotCy = cy - r * 0.32;
    final dotR = r * 0.15;
    final hl2 = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.white.withOpacity(0.80),
          Colors.white.withOpacity(0.0),
        ],
      ).createShader(
          Rect.fromCircle(center: Offset(dotCx, dotCy), radius: dotR));
    canvas.drawCircle(Offset(dotCx, dotCy), dotR, hl2);

    // Subtle bottom rim light — environmental reflection
    final rimPaint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0.2, 0.7),
        radius: 0.6,
        colors: [
          Colors.white.withOpacity(0.12),
          Colors.white.withOpacity(0.0),
        ],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r));
    canvas.drawCircle(Offset(cx, cy), r, rimPaint);
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  LEGS — chunky cartoon legs with boot-shaped feet
  // ══════════════════════════════════════════════════════════════════════════

  void _drawLegs(Canvas canvas, double cx, double cy, double r) {
    final legW = r * 0.19;
    final legH = r * 0.34;

    for (final side in [-1.0, 1.0]) {
      final lx = cx + r * 0.26 * side;
      final ly = cy + r * 0.84;

      // Leg shaft — gradient for 3D roundness
      final legPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            _darken(moodColor, 0.14),
            _darken(moodColor, 0.03),
            _darken(moodColor, 0.14),
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(
            Rect.fromCenter(center: Offset(lx, ly), width: legW, height: legH));

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(lx, ly), width: legW, height: legH),
          Radius.circular(legW / 2),
        ),
        legPaint,
      );

      // Boot-shaped foot
      final footY = ly + legH * 0.44;
      final footW = legW * 1.9;
      final footH = legW * 1.0;
      final footPaint = Paint()
        ..shader = RadialGradient(
          center: Alignment(side * 0.2, -0.3),
          radius: 1.0,
          colors: [_brighten(moodColor, 0.05), _darken(moodColor, 0.10)],
        ).createShader(Rect.fromCenter(
            center: Offset(lx + side * legW * 0.15, footY),
            width: footW,
            height: footH));

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(lx + side * legW * 0.15, footY),
            width: footW,
            height: footH,
          ),
          Radius.circular(footH * 0.45),
        ),
        footPaint,
      );

      // Tiny highlight on boot toe
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(lx + side * legW * 0.3, footY - footH * 0.12),
          width: footW * 0.30,
          height: footH * 0.22,
        ),
        Paint()..color = Colors.white.withOpacity(0.25),
      );
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  ARMS — longer cartoon arms with hand & 4 finger nubs
  // ══════════════════════════════════════════════════════════════════════════

  void _drawArms(
      Canvas canvas, double cx, double cy, double r, double breathSine) {
    final armW = r * 0.15;
    final armH = r * 0.55;

    if (isDragging) {
      _drawOneArm(canvas, cx - r * 0.88, cy - r * 0.28, armW, armH,
          -0.85 + breathSine * 0.15, true);
      _drawOneArm(canvas, cx + r * 0.88, cy - r * 0.28, armW, armH,
          0.85 - breathSine * 0.15, true);
      return;
    }

    final sway = breathSine * 0.10;
    _drawOneArm(
        canvas, cx - r * 0.92, cy - r * 0.02, armW, armH, -0.25 + sway, false);
    _drawOneArm(
        canvas, cx + r * 0.92, cy - r * 0.02, armW, armH, 0.25 - sway, false);
  }

  void _drawOneArm(Canvas canvas, double ox, double oy, double w, double h,
      double angle, bool raised) {
    canvas.save();
    canvas.translate(ox, oy);
    canvas.rotate(angle);

    final armCy = raised ? -h * 0.12 : h * 0.28;

    // Arm shaft with 3D gradient
    final armPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          _darken(moodColor, 0.14),
          _darken(moodColor, 0.02),
          _darken(moodColor, 0.14),
        ],
        stops: const [0.0, 0.40, 1.0],
      ).createShader(
          Rect.fromCenter(center: Offset(0, armCy), width: w, height: h));

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(0, armCy), width: w, height: h),
        Radius.circular(w / 2),
      ),
      armPaint,
    );

    // Highlight line on arm
    canvas.drawLine(
      Offset(w * 0.05, armCy - h * 0.3),
      Offset(w * 0.05, armCy + h * 0.15),
      Paint()
        ..color = Colors.white.withOpacity(0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.18,
    );

    // Hand circle
    final handY = raised ? -h * 0.50 : h * 0.60;
    final handR = w * 0.55;
    canvas.drawCircle(
        Offset(0, handY), handR, Paint()..color = _darken(moodColor, 0.05));

    // 4 fingers
    final dir = raised ? -1.0 : 1.0;
    _drawFingers(canvas, 0, handY + dir * handR * 0.6, w, dir);

    canvas.restore();
  }

  /// 4 tiny finger nubs. [dir] = 1.0 down, -1.0 up.
  void _drawFingers(Canvas canvas, double hx, double hy, double w, double dir) {
    final fingerPaint = Paint()..color = _darken(moodColor, 0.06);
    final fw = w * 0.20;
    final fh = w * 0.38;
    for (var i = -1.5; i <= 1.5; i += 1.0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(hx + i * w * 0.22, hy + dir * fh * 0.4),
            width: fw,
            height: fh,
          ),
          Radius.circular(fw / 2),
        ),
        fingerPaint,
      );
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  EYES — large 3D-style with dark pupils, green iris reflex, eyebrows
  // ══════════════════════════════════════════════════════════════════════════

  void _drawEyes(Canvas canvas, double cx, double cy, double r) {
    final exOff = r * 0.30;
    final eyOff = -r * 0.08;
    final ew = r * 0.30;
    final eh = r * 0.36;

    if (isDragging) {
      _drawAnnoyedEyes(canvas, cx, cy, r, exOff, eyOff, ew, eh);
      return;
    }

    final openness = 1.0 - blinkProgress * 0.92;
    final curH = eh * openness;

    for (final side in [-1.0, 1.0]) {
      final ecx = cx + exOff * side;
      final ecy = cy + eyOff;

      // Sclera — white with subtle top shadow
      final scleraPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withOpacity(0.85),
            Colors.white.withOpacity(0.98),
          ],
        ).createShader(Rect.fromCenter(
            center: Offset(ecx, ecy), width: ew * 1.18, height: curH * 1.12));
      canvas.drawOval(
        Rect.fromCenter(
            center: Offset(ecx, ecy), width: ew * 1.18, height: curH * 1.12),
        scleraPaint,
      );

      // Thin border
      canvas.drawOval(
        Rect.fromCenter(
            center: Offset(ecx, ecy), width: ew * 1.18, height: curH * 1.12),
        Paint()
          ..color = const Color(0xFF1A1A2E).withOpacity(0.25)
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.015,
      );

      // Pupil
      final pupilW = ew * 0.78;
      final pupilH = curH * 0.82;
      canvas.drawOval(
        Rect.fromCenter(
            center: Offset(ecx + side * ew * 0.02, ecy + curH * 0.03),
            width: pupilW,
            height: pupilH),
        Paint()..color = const Color(0xFF0D0D1A),
      );

      // Green iris reflex
      if (blinkProgress < 0.5) {
        canvas.drawOval(
          Rect.fromCenter(
              center: Offset(ecx, ecy + curH * 0.08),
              width: pupilW * 0.9,
              height: pupilH * 0.7),
          Paint()
            ..shader = RadialGradient(
              center: const Alignment(0.0, 0.5),
              radius: 0.8,
              colors: [
                const Color(0xFF2E7D32).withOpacity(0.45),
                Colors.transparent,
              ],
            ).createShader(Rect.fromCenter(
                center: Offset(ecx, ecy + curH * 0.08),
                width: pupilW * 0.9,
                height: pupilH * 0.7)),
        );
      }

      // Catch-lights
      if (blinkProgress < 0.3) {
        canvas.drawCircle(
          Offset(ecx + ew * 0.16 * side, ecy - eh * 0.16),
          ew * 0.20,
          Paint()..color = Colors.white,
        );
        canvas.drawCircle(
          Offset(ecx - ew * 0.12 * side, ecy + eh * 0.14),
          ew * 0.10,
          Paint()..color = Colors.white.withOpacity(0.70),
        );
      }

      // Eyebrow arc
      if (blinkProgress < 0.4) {
        final browPath = Path()
          ..moveTo(ecx - ew * 0.50, ecy - eh * 0.62)
          ..quadraticBezierTo(
              ecx, ecy - eh * 0.80, ecx + ew * 0.50, ecy - eh * 0.62);
        canvas.drawPath(
          browPath,
          Paint()
            ..color = const Color(0xFF1A1A2E).withOpacity(0.55)
            ..style = PaintingStyle.stroke
            ..strokeWidth = r * 0.04
            ..strokeCap = StrokeCap.round,
        );
      }
    }
  }

  void _drawAnnoyedEyes(Canvas canvas, double cx, double cy, double r,
      double exOff, double eyOff, double ew, double eh) {
    final squintH = eh * 0.24;
    final paint = Paint()..color = const Color(0xFF1A1A2E);
    final glint = Paint()..color = Colors.white.withOpacity(0.6);

    for (final side in [-1.0, 1.0]) {
      final ecx = cx + exOff * side;
      final ecy = cy + eyOff + eh * 0.06;
      canvas.drawOval(
        Rect.fromCenter(
            center: Offset(ecx, ecy), width: ew * 1.15, height: squintH),
        paint,
      );
      canvas.drawCircle(Offset(ecx + side * ew * 0.12, ecy - squintH * 0.1),
          ew * 0.08, glint);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  ANGRY BROWS
  // ══════════════════════════════════════════════════════════════════════════

  void _drawAngryBrows(Canvas canvas, double cx, double cy, double r) {
    final paint = Paint()
      ..color = const Color(0xFF1A1A2E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.07
      ..strokeCap = StrokeCap.round;

    final exOff = r * 0.30;
    final browY = cy - r * 0.32;
    final bw = r * 0.18;

    // Left brow: angled ↘ toward center
    canvas.drawLine(
      Offset(cx - exOff - bw, browY - r * 0.06),
      Offset(cx - exOff + bw, browY + r * 0.04),
      paint,
    );
    // Right brow: angled ↙ toward center
    canvas.drawLine(
      Offset(cx + exOff - bw, browY + r * 0.04),
      Offset(cx + exOff + bw, browY - r * 0.06),
      paint,
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  MOUTH — smile / speaking / frown
  // ══════════════════════════════════════════════════════════════════════════

  void _drawMouth(Canvas canvas, double cx, double cy, double r) {
    final mouthY = cy + r * 0.32;

    if (isDragging) {
      _drawFrown(canvas, cx, mouthY, r);
      return;
    }

    if (isSpeaking) {
      _drawSpeakingMouth(canvas, cx, mouthY, r);
      return;
    }

    _drawSmile(canvas, cx, mouthY, r);
  }

  void _drawSmile(Canvas canvas, double cx, double my, double r) {
    final paint = Paint()
      ..color = const Color(0xFF1A1A2E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.055
      ..strokeCap = StrokeCap.round;
    final w = r * 0.30;
    final path = Path()
      ..moveTo(cx - w, my)
      ..quadraticBezierTo(cx, my + r * 0.18, cx + w, my);
    canvas.drawPath(path, paint);
  }

  void _drawSpeakingMouth(Canvas canvas, double cx, double my, double r) {
    final open = mouthOpenProgress; // 0..1
    final mh = r * (0.10 + 0.22 * open); // min oval, max wide open
    final mw = r * (0.22 + 0.14 * open);

    // Dark mouth interior
    final fill = Paint()..color = const Color(0xFF0D0D1A);
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, my + r * 0.02), width: mw, height: mh),
      fill,
    );

    // Tongue hint when wide open
    if (open > 0.35) {
      final tongue = Paint()..color = const Color(0xFF3D1A4E).withOpacity(0.5);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx, my + r * 0.06),
          width: mw * 0.45,
          height: mh * 0.30,
        ),
        tongue,
      );
    }
  }

  void _drawFrown(Canvas canvas, double cx, double my, double r) {
    final paint = Paint()
      ..color = const Color(0xFF1A1A2E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.06
      ..strokeCap = StrokeCap.round;
    final w = r * 0.25;
    final fy = my + r * 0.08;
    final path = Path()
      ..moveTo(cx - w, fy)
      ..quadraticBezierTo(cx, fy - r * 0.14, cx + w, fy);
    canvas.drawPath(path, paint);
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  MIC ICON
  // ══════════════════════════════════════════════════════════════════════════

  void _drawMicIcon(Canvas canvas, double cx, double cy, double r) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    final ix = cx + r * 0.45;
    final iy = cy + r * 0.50;
    final mr = r * 0.10;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(ix, iy - mr * 0.5),
            width: mr * 1.4,
            height: mr * 2.2),
        Radius.circular(mr * 0.7),
      ),
      paint,
    );
    canvas.drawLine(
        Offset(ix, iy + mr * 0.6), Offset(ix, iy + mr * 1.3), paint);
    canvas.drawLine(Offset(ix - mr * 0.5, iy + mr * 1.3),
        Offset(ix + mr * 0.5, iy + mr * 1.3), paint);
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  COLOR HELPERS
  // ══════════════════════════════════════════════════════════════════════════

  static Color _brighten(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withLightness((hsl.lightness + amount).clamp(0.0, 1.0))
        .toColor();
  }

  static Color _darken(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withLightness((hsl.lightness - amount).clamp(0.0, 1.0))
        .toColor();
  }

  @override
  bool shouldRepaint(covariant HyperOrbPainter old) =>
      old.blinkProgress != blinkProgress ||
      old.breathProgress != breathProgress ||
      old.moodColor != moodColor ||
      old.showMic != showMic ||
      old.isDragging != isDragging ||
      old.isSpeaking != isSpeaking ||
      old.mouthOpenProgress != mouthOpenProgress;
}
