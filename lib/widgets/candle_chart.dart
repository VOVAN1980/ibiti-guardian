import 'dart:math';
import 'package:flutter/material.dart';
import 'package:ibiti_guardian/models/candle.dart';
import 'package:ibiti_guardian/services/localization_service.dart';

enum ChartStyle {
  line,
  candle,
}

class CandleChart extends StatefulWidget {
  final List<Candle> candles;
  final double height;
  final ChartStyle style;
  final bool showMinMax;
  final bool enableTouch;

  const CandleChart({
    super.key,
    required this.candles,
    this.height = 180,
    this.style = ChartStyle.candle,
    this.showMinMax = true,
    this.enableTouch = true,
  });

  @override
  State<CandleChart> createState() => _CandleChartState();
}

class _CandleChartState extends State<CandleChart> {
  double? _touchX;

  @override
  Widget build(BuildContext context) {
    if (widget.candles.length < 2) {
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
          painter: _CandleChartPainter(
            candles: widget.candles,
            style: widget.style,
            showMinMax: widget.showMinMax,
            touchX: _touchX,
          ),
        ),
      ),
    );
  }
}

class _CandleChartPainter extends CustomPainter {
  final List<Candle> candles;
  final ChartStyle style;
  final bool showMinMax;
  final double? touchX;

  _CandleChartPainter({
    required this.candles,
    required this.style,
    required this.showMinMax,
    this.touchX,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.length < 2) return;

    // 1. Calculate price range
    final minPrice = candles.map((c) => c.low).reduce(min);
    final maxPrice = candles.map((c) => c.high).reduce(max);
    double priceRange = maxPrice - minPrice;
    if (priceRange == 0) priceRange = 1.0;

    // Apply vertical padding of 5%
    final paddedMin = minPrice - priceRange * 0.05;
    final paddedMax = maxPrice + priceRange * 0.05;
    final paddedRange = paddedMax - paddedMin;

    // 2. Calculate volume range
    final maxVol = candles.map((c) => c.volume).reduce(max);

    // 3. Define canvas areas
    const rightPadding = 50.0;
    const padding =
        EdgeInsets.only(top: 20, bottom: 20, left: 0, right: rightPadding);
    final chartW = size.width - padding.left - padding.right;
    final chartH = size.height - padding.top - padding.bottom;

    double xFor(int i) => padding.left + (i / (candles.length - 1)) * chartW;
    double yFor(double price) =>
        padding.top + (1 - (price - paddedMin) / paddedRange) * chartH;

    // Draw Grid Lines & Price Labels
    const gridCount = 4;
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..strokeWidth = 1;

    for (int i = 0; i <= gridCount; i++) {
      final y = padding.top + (i / gridCount) * chartH;
      // Grid line
      canvas.drawLine(
        Offset(padding.left, y),
        Offset(size.width - padding.right, y),
        gridPaint,
      );

      // Price label
      final priceVal = paddedMax - (i / gridCount) * paddedRange;
      _drawRightLabel(
        canvas,
        size.width - padding.right + 6,
        y - 6,
        '\$${_fmtPrice(priceVal)}',
      );
    }

    if (style == ChartStyle.candle) {
      // ── Candlestick Render ──
      final candleW = (chartW / candles.length) * 0.7; // 70% width, 30% gap

      for (int i = 0; i < candles.length; i++) {
        final c = candles[i];
        final cx = xFor(i);
        final isGreen = c.close >= c.open;
        final color = isGreen ? const Color(0xFF00C853) : const Color(0xFFFF1744);

        // A. Volume Bar (drawn at bottom 20% space)
        if (maxVol > 0 && c.volume > 0) {
          final volH = chartH * 0.2;
          final volRatio = c.volume / maxVol;
          final volTop = size.height - padding.bottom - volRatio * volH;
          final volBottom = size.height - padding.bottom;
          final volLeft = cx - candleW / 2;
          final volRight = cx + candleW / 2;

          canvas.drawRect(
            Rect.fromLTRB(volLeft, volTop, volRight, volBottom),
            Paint()
              ..color = color.withValues(alpha: 0.15)
              ..style = PaintingStyle.fill,
          );
        }

        // B. Candle Wick (Shadow)
        final wickPaint = Paint()
          ..color = color
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke;

        canvas.drawLine(
          Offset(cx, yFor(c.high)),
          Offset(cx, yFor(c.low)),
          wickPaint,
        );

        // C. Candle Body
        double bodyTop = yFor(max(c.open, c.close));
        double bodyBottom = yFor(min(c.open, c.close));
        // Guarantee at least 1px height so doji is visible
        if ((bodyBottom - bodyTop).abs() < 1) {
          bodyBottom = bodyTop + 1;
        }

        final bodyLeft = cx - candleW / 2;
        final bodyRight = cx + candleW / 2;

        canvas.drawRect(
          Rect.fromLTRB(bodyLeft, bodyTop, bodyRight, bodyBottom),
          Paint()
            ..color = color
            ..style = PaintingStyle.fill,
        );
      }
    } else {
      // ── Line / Sparkline Render ──
      final path = Path();
      path.moveTo(xFor(0), yFor(candles[0].close));

      for (int i = 1; i < candles.length; i++) {
        final x0 = xFor(i - 1);
        final y0 = yFor(candles[i - 1].close);
        final x1 = xFor(i);
        final y1 = yFor(candles[i].close);
        final mx = (x0 + x1) / 2;
        path.cubicTo(mx, y0, mx, y1, x1, y1);
      }

      final isUp = candles.last.close >= candles.first.close;
      final color = isUp ? const Color(0xFF00C853) : const Color(0xFFFF1744);

      // Gradient fill
      final fillPath = Path.from(path);
      fillPath.lineTo(xFor(candles.length - 1), size.height - padding.bottom);
      fillPath.lineTo(xFor(0), size.height - padding.bottom);
      fillPath.close();

      final gradient = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: 0.2),
          color.withValues(alpha: 0.0),
        ],
      );

      canvas.drawPath(
        fillPath,
        Paint()
          ..shader = gradient.createShader(
            Rect.fromLTRB(
              padding.left,
              padding.top,
              size.width - padding.right,
              size.height - padding.bottom,
            ),
          )
          ..style = PaintingStyle.fill,
      );

      // Line path
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = 2.0
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );

      // Subtle glow
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: 0.15)
          ..strokeWidth = 6.0
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
    }

    // ── Min/Max Label Overlay ──
    if (showMinMax && style == ChartStyle.line) {
      int minIdx = 0, maxIdx = 0;
      for (int i = 1; i < candles.length; i++) {
        if (candles[i].close < candles[minIdx].close) minIdx = i;
        if (candles[i].close > candles[maxIdx].close) maxIdx = i;
      }
      final isUp = candles.last.close >= candles.first.close;
      final color = isUp ? const Color(0xFF00C853) : const Color(0xFFFF1744);

      _drawFloatingLabel(
        canvas,
        xFor(maxIdx),
        yFor(maxPrice) - 14,
        '\$${_fmtPrice(maxPrice)}',
        color.withValues(alpha: 0.7),
      );
      _drawFloatingLabel(
        canvas,
        xFor(minIdx),
        yFor(minPrice) + 6,
        '\$${_fmtPrice(minPrice)}',
        Colors.white.withValues(alpha: 0.4),
      );
    }

    // ── Interactive Crosshair Touch Overlay ──
    if (touchX != null) {
      final tx = touchX!.clamp(padding.left, size.width - padding.right);
      final idx = ((tx - padding.left) / chartW * (candles.length - 1))
          .round()
          .clamp(0, candles.length - 1);
      final px = xFor(idx);
      final c = candles[idx];
      final py = yFor(c.close);

      // Crosshair lines
      final crossPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.15)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke;

      // Vertical line
      canvas.drawLine(
        Offset(px, padding.top),
        Offset(px, size.height - padding.bottom),
        crossPaint,
      );
      // Horizontal line
      canvas.drawLine(
        Offset(padding.left, py),
        Offset(size.width - padding.right, py),
        crossPaint,
      );

      // Close dot
      final isGreen = c.close >= c.open;
      final color = isGreen ? const Color(0xFF00C853) : const Color(0xFFFF1744);
      canvas.drawCircle(Offset(px, py), 4.5, Paint()..color = color);
      canvas.drawCircle(Offset(px, py), 2.5, Paint()..color = Colors.white);

      // Draw active HUD metrics text at top left
      final hudText =
          'O: \$${_fmtPrice(c.open)}  H: \$${_fmtPrice(c.high)}  L: \$${_fmtPrice(c.low)}  C: \$${_fmtPrice(c.close)}  V: ${_fmtVol(c.volume)}';
      _drawHUD(canvas, padding.left + 5, 0, hudText);

      // Draw price tag bubble on right margin
      _drawPriceTag(
        canvas,
        size.width - padding.right,
        py,
        '\$${_fmtPrice(c.close)}',
        color,
      );
    }
  }

  void _drawRightLabel(Canvas canvas, double x, double y, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.28),
          fontSize: 9,
          fontWeight: FontWeight.w600,
          fontFamily: 'monospace',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(x, y));
  }

  void _drawFloatingLabel(
      Canvas canvas, double x, double y, String text, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(x - tp.width / 2, y));
  }

  void _drawHUD(Canvas canvas, double x, double y, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.75),
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          fontFamily: 'monospace',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(x, y));
  }

  void _drawPriceTag(
      Canvas canvas, double x, double y, String text, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.layout();

    final bubbleW = tp.width + 10;
    final bubbleH = tp.height + 6;

    final bubbleRect = Rect.fromLTWH(
      x + 4,
      y - bubbleH / 2,
      bubbleW,
      bubbleH,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(bubbleRect, const Radius.circular(4)),
      Paint()..color = color,
    );

    tp.paint(canvas, Offset(x + 9, y - tp.height / 2));
  }

  static String _fmtPrice(double p) {
    if (p >= 1000) return p.toStringAsFixed(1);
    if (p >= 1) return p.toStringAsFixed(2);
    if (p >= 0.01) return p.toStringAsFixed(4);
    return p.toStringAsFixed(6);
  }

  static String _fmtVol(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}K';
    return v.toStringAsFixed(1);
  }

  @override
  bool shouldRepaint(covariant _CandleChartPainter old) =>
      old.candles != candles ||
      old.style != style ||
      old.touchX != touchX ||
      old.showMinMax != showMinMax;
}
