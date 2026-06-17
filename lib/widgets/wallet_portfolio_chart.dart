import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

enum PortfolioChartRange { d1, d7, m1, m3 }

class WalletPortfolioChartCard extends StatefulWidget {
  final double totalUsd;

  const WalletPortfolioChartCard({super.key, required this.totalUsd});

  @override
  State<WalletPortfolioChartCard> createState() =>
      _WalletPortfolioChartCardState();
}

class _WalletPortfolioChartCardState extends State<WalletPortfolioChartCard> {
  PortfolioChartRange _range = PortfolioChartRange.d7;

  List<double> get _points => _generatePoints(widget.totalUsd, _range);

  double get _startValue => _points.isEmpty ? 0 : _points.first;
  double get _endValue => _points.isEmpty ? 0 : _points.last;
  double get _delta => _endValue - _startValue;
  double get _deltaPct => _startValue <= 0 ? 0 : (_delta / _startValue) * 100;

  @override
  Widget build(BuildContext context) {
    final positive = _delta >= 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 22),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Portfolio', style: GuardianTextStyles.titleMedium),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: (positive
                          ? GuardianColors.success
                          : GuardianColors.danger)
                      .withOpacity(0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${positive ? '+' : ''}${_deltaPct.toStringAsFixed(2)}%',
                  style: GuardianTextStyles.caption.copyWith(
                    color: positive
                        ? GuardianColors.success
                        : GuardianColors.danger,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${positive ? '+' : ''}\$${_delta.abs().toStringAsFixed(2)}',
            style: GuardianTextStyles.bodySecondary,
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 140,
            child: CustomPaint(
              painter: _PortfolioChartPainter(
                values: _points,
                color:
                    positive ? GuardianColors.success : GuardianColors.accent,
              ),
              child: const SizedBox.expand(),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: PortfolioChartRange.values.map((range) {
              final selected = _range == range;
              final label = switch (range) {
                PortfolioChartRange.d1 => '24H',
                PortfolioChartRange.d7 => '7D',
                PortfolioChartRange.m1 => '1M',
                PortfolioChartRange.m3 => '3M',
              };
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => setState(() => _range = range),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: selected
                          ? GuardianColors.accent
                          : GuardianColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      label,
                      style: GuardianTextStyles.caption.copyWith(
                        color: selected
                            ? GuardianColors.background
                            : GuardianColors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  List<double> _generatePoints(double total, PortfolioChartRange range) {
    final pointCount = switch (range) {
      PortfolioChartRange.d1 => 24,
      PortfolioChartRange.d7 => 28,
      PortfolioChartRange.m1 => 30,
      PortfolioChartRange.m3 => 36,
    };
    final seed = total <= 0 ? 1250.0 : total;
    final amplitude = math.max(seed * 0.06, 10);
    return List.generate(pointCount, (index) {
      final x = index / math.max(pointCount - 1, 1);
      final drift = math.sin(x * math.pi * 1.6) * amplitude;
      final pulse = math.cos(x * math.pi * 5.3) * amplitude * 0.22;
      final trend = (x - 0.45) * amplitude * 0.8;
      return math.max(0, seed + drift + pulse + trend);
    });
  }
}

class _PortfolioChartPainter extends CustomPainter {
  final List<double> values;
  final Color color;

  _PortfolioChartPainter({required this.values, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;

    final minValue = values.reduce(math.min);
    final maxValue = values.reduce(math.max);
    final safeRange =
        (maxValue - minValue).abs() < 0.0001 ? 1.0 : maxValue - minValue;

    final path = Path();
    final fillPath = Path();

    for (var i = 0; i < values.length; i++) {
      final x = (i / (values.length - 1)) * size.width;
      final normalized = (values[i] - minValue) / safeRange;
      final y = size.height - (normalized * (size.height - 10)) - 6;
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }

    fillPath
      ..lineTo(size.width, size.height)
      ..close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withOpacity(0.28),
          color.withOpacity(0.02),
        ],
      ).createShader(Offset.zero & size);

    final linePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final glowPaint = Paint()
      ..color = color.withOpacity(0.24)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _PortfolioChartPainter oldDelegate) {
    return oldDelegate.values != values || oldDelegate.color != color;
  }
}
