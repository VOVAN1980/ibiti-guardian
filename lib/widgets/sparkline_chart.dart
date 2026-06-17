import 'dart:math';
import 'package:flutter/material.dart';
import 'package:ibiti_guardian/services/localization_service.dart';

// ─── Sparkline Chart ────────────────────────────────────────────────────────────
//
// A lightweight price chart using CustomPainter.
// Zero external dependencies.
//
// Features:
//   • Line + gradient fill
//   • Green if price went up, red if down
//   • Optional min/max labels
//   • Touch crosshair (optional)
//   • Smooth curves via cubicTo
// ─────────────────────────────────────────────────────────────────────────────────

class SparklineChart extends StatefulWidget {
  final List<double> prices;
  final double height;
  final Color? lineColor;
  final bool showMinMax;
  final bool enableTouch;

  const SparklineChart({
    super.key,
    required this.prices,
    this.height = 180,
    this.lineColor,
    this.showMinMax = true,
    this.enableTouch = true,
  });

  @override
  State<SparklineChart> createState() => _SparklineChartState();
}

class _SparklineChartState extends State<SparklineChart> {
  double? _touchX;

  @override
  Widget build(BuildContext context) {
    if (widget.prices.length < 2) {
      return SizedBox(
        height: widget.height,
        child: Center(
          child: Text(
            LocalizationService.instance
                .t('marketNoChartData', {'default': 'No chart data'}),
            style: const TextStyle(color: Colors.white24, fontSize: 13),
          ),
        ),
      );
    }

    final isUp = widget.prices.last >= widget.prices.first;
    final color = widget.lineColor ??
        (isUp ? const Color(0xFF00C853) : const Color(0xFFFF1744));

    return GestureDetector(
      onPanUpdate: widget.enableTouch
          ? (d) => setState(() => _touchX = d.localPosition.dx)
          : null,
      onPanEnd:
          widget.enableTouch ? (_) => setState(() => _touchX = null) : null,
      onPanCancel:
          widget.enableTouch ? () => setState(() => _touchX = null) : null,
      child: SizedBox(
        height: widget.height,
        child: CustomPaint(
          size: Size.infinite,
          painter: _SparklinePainter(
            prices: widget.prices,
            lineColor: color,
            showMinMax: widget.showMinMax,
            touchX: _touchX,
          ),
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> prices;
  final Color lineColor;
  final bool showMinMax;
  final double? touchX;

  _SparklinePainter({
    required this.prices,
    required this.lineColor,
    required this.showMinMax,
    this.touchX,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (prices.length < 2) return;

    final minP = prices.reduce(min);
    final maxP = prices.reduce(max);
    final range = maxP - minP;
    if (range == 0) return;

    const padding = EdgeInsets.only(top: 20, bottom: 20, left: 0, right: 0);
    final chartW = size.width - padding.left - padding.right;
    final chartH = size.height - padding.top - padding.bottom;

    double xFor(int i) => padding.left + (i / (prices.length - 1)) * chartW;
    double yFor(double price) =>
        padding.top + (1 - (price - minP) / range) * chartH;

    // ── Build path ────────────────────────────────────────────────────────
    final path = Path();
    path.moveTo(xFor(0), yFor(prices[0]));

    for (int i = 1; i < prices.length; i++) {
      final x0 = xFor(i - 1);
      final y0 = yFor(prices[i - 1]);
      final x1 = xFor(i);
      final y1 = yFor(prices[i]);
      final mx = (x0 + x1) / 2;
      path.cubicTo(mx, y0, mx, y1, x1, y1);
    }

    // ── Draw gradient fill ────────────────────────────────────────────────
    final fillPath = Path.from(path);
    fillPath.lineTo(xFor(prices.length - 1), size.height);
    fillPath.lineTo(xFor(0), size.height);
    fillPath.close();

    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        lineColor.withValues(alpha: 0.25),
        lineColor.withValues(alpha: 0.0),
      ],
    );

    final fillPaint = Paint()
      ..shader = gradient.createShader(
        Rect.fromLTWH(0, 0, size.width, size.height),
      );
    canvas.drawPath(fillPath, fillPaint);

    // ── Draw line ─────────────────────────────────────────────────────────
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, linePaint);

    // ── Draw glow ─────────────────────────────────────────────────────────
    final glowPaint = Paint()
      ..color = lineColor.withValues(alpha: 0.15)
      ..strokeWidth = 6.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawPath(path, glowPaint);

    // ── Min/Max labels ────────────────────────────────────────────────────
    if (showMinMax) {
      int minIdx = 0, maxIdx = 0;
      for (int i = 1; i < prices.length; i++) {
        if (prices[i] < prices[minIdx]) minIdx = i;
        if (prices[i] > prices[maxIdx]) maxIdx = i;
      }

      _drawLabel(canvas, xFor(maxIdx), yFor(maxP) - 14, '\$${_fmtPrice(maxP)}',
          lineColor.withValues(alpha: 0.7));
      _drawLabel(canvas, xFor(minIdx), yFor(minP) + 6, '\$${_fmtPrice(minP)}',
          Colors.white.withValues(alpha: 0.4));
    }

    // ── Touch crosshair ───────────────────────────────────────────────────
    if (touchX != null) {
      final tx = touchX!.clamp(padding.left, size.width - padding.right);
      final idx = ((tx - padding.left) / chartW * (prices.length - 1))
          .round()
          .clamp(0, prices.length - 1);
      final px = xFor(idx);
      final py = yFor(prices[idx]);

      // Vertical line
      final crossPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.2)
        ..strokeWidth = 1;
      canvas.drawLine(Offset(px, padding.top),
          Offset(px, size.height - padding.bottom), crossPaint);

      // Dot
      canvas.drawCircle(
        Offset(px, py),
        5,
        Paint()..color = lineColor,
      );
      canvas.drawCircle(
        Offset(px, py),
        3,
        Paint()..color = Colors.white,
      );

      // Price label
      _drawLabel(
          canvas, px, py - 20, '\$${_fmtPrice(prices[idx])}', Colors.white);
    }
  }

  void _drawLabel(Canvas canvas, double x, double y, String text, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(x - tp.width / 2, y));
  }

  static String _fmtPrice(double p) {
    if (p >= 1000) return p.toStringAsFixed(0);
    if (p >= 1) return p.toStringAsFixed(2);
    if (p >= 0.01) return p.toStringAsFixed(4);
    return p.toStringAsFixed(6);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.prices != prices ||
      old.touchX != touchX ||
      old.lineColor != lineColor;
}
