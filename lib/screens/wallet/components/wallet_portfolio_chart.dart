import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ibiti_guardian/models/portfolio_summary.dart';
import 'package:ibiti_guardian/services/wallet/wallet_portfolio_history_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

enum WalletChartRange {
  day('24H', Duration(hours: 24)),
  week('7D', Duration(days: 7)),
  month('1M', Duration(days: 30)),
  quarter('3M', Duration(days: 90));

  final String label;
  final Duration duration;
  const WalletChartRange(this.label, this.duration);
}

class WalletPortfolioChartCard extends StatefulWidget {
  final PortfolioSummary? summary;

  const WalletPortfolioChartCard({super.key, required this.summary});

  @override
  State<WalletPortfolioChartCard> createState() =>
      _WalletPortfolioChartCardState();
}

class _WalletPortfolioChartCardState extends State<WalletPortfolioChartCard> {
  WalletChartRange _range = WalletChartRange.day;

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    if (summary == null || summary.address.isEmpty) {
      return const SizedBox.shrink();
    }

    return ListenableBuilder(
      listenable: WalletPortfolioHistoryService.instance,
      builder: (context, _) {
        final history = WalletPortfolioHistoryService.instance.pointsForRange(
          summary.address,
          summary.chainKey,
          _range.duration,
        );
        final points = _buildRenderablePoints(history, summary.totalBalanceUsd);
        final first = points.first.totalUsd;
        final last = points.last.totalUsd;
        final delta = last - first;
        final deltaPct = first.abs() < 0.0001 ? 0.0 : (delta / first) * 100;
        final positive = delta >= 0;

        return Container(
          margin: const EdgeInsets.only(bottom: 22),
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
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
                  const Text(
                    'Portfolio',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const Spacer(),
                  _DeltaBadge(
                    delta: delta,
                    deltaPct: deltaPct,
                    positive: positive,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Live wallet snapshots across ${summary.networkName}',
                style: GuardianTextStyles.caption.copyWith(
                  color: Colors.white.withOpacity(0.58),
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                height: 144,
                child: CustomPaint(
                  painter: _PortfolioChartPainter(
                    points: points,
                    positive: positive,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: WalletChartRange.values.map((range) {
                  final active = range == _range;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: GestureDetector(
                        onTap: () => setState(() => _range = range),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: active
                                ? GuardianColors.accent
                                : GuardianColors.surfaceElevated,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: active
                                  ? GuardianColors.accent
                                  : GuardianColors.glassBorder,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              range.label,
                              style: GuardianTextStyles.caption.copyWith(
                                color: active
                                    ? GuardianColors.background
                                    : Colors.white.withOpacity(0.72),
                                fontWeight: FontWeight.w800,
                              ),
                            ),
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
      },
    );
  }

  List<PortfolioHistoryPoint> _buildRenderablePoints(
    List<PortfolioHistoryPoint> history,
    double currentTotalUsd,
  ) {
    if (history.length >= 2) {
      return history;
    }
    final now = DateTime.now();
    final anchors = <PortfolioHistoryPoint>[
      PortfolioHistoryPoint(
        timestamp: now.subtract(_range.duration),
        totalUsd: currentTotalUsd,
      ),
      PortfolioHistoryPoint(timestamp: now, totalUsd: currentTotalUsd),
    ];
    if (history.isEmpty) return anchors;
    return [history.first, anchors.last];
  }
}

class _DeltaBadge extends StatelessWidget {
  final double delta;
  final double deltaPct;
  final bool positive;

  const _DeltaBadge({
    required this.delta,
    required this.deltaPct,
    required this.positive,
  });

  @override
  Widget build(BuildContext context) {
    final color = positive ? GuardianColors.success : GuardianColors.warning;
    final sign = positive ? '+' : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.28)),
      ),
      child: Text(
        '$sign${deltaPct.toStringAsFixed(2)}%  ($sign\$${delta.toStringAsFixed(2)})',
        style: GuardianTextStyles.caption.copyWith(
          color: color,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _PortfolioChartPainter extends CustomPainter {
  final List<PortfolioHistoryPoint> points;
  final bool positive;

  const _PortfolioChartPainter({
    required this.points,
    required this.positive,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final values = points.map((e) => e.totalUsd).toList();
    final minValue = values.reduce(math.min);
    final maxValue = values.reduce(math.max);
    final range =
        (maxValue - minValue).abs() < 0.001 ? 1.0 : (maxValue - minValue);
    final start = points.first.timestamp.millisecondsSinceEpoch.toDouble();
    final end = points.last.timestamp.millisecondsSinceEpoch.toDouble();
    final timeRange = math.max(1.0, end - start);
    final accent = positive ? GuardianColors.success : GuardianColors.accent;

    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(0.06)
      ..strokeWidth = 1;
    for (var i = 0; i < 4; i++) {
      final y = size.height * (i / 3);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final path = Path();
    final fill = Path();

    for (var i = 0; i < points.length; i++) {
      final point = points[i];
      final x = ((point.timestamp.millisecondsSinceEpoch - start) / timeRange) *
          size.width;
      final normalizedY = (point.totalUsd - minValue) / range;
      final y = size.height - (normalizedY * (size.height - 10)) - 5;
      final offset = Offset(x, y);
      if (i == 0) {
        path.moveTo(offset.dx, offset.dy);
        fill.moveTo(offset.dx, size.height);
        fill.lineTo(offset.dx, offset.dy);
      } else {
        path.lineTo(offset.dx, offset.dy);
        fill.lineTo(offset.dx, offset.dy);
      }
    }

    fill
      ..lineTo(size.width, size.height)
      ..close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          accent.withOpacity(0.30),
          accent.withOpacity(0.02),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawPath(fill, fillPaint);

    final pathPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..shader = LinearGradient(
        colors: [accent, Colors.white],
      ).createShader(Offset.zero & size);
    canvas.drawPath(path, pathPaint);

    final last = points.last;
    final lastX =
        ((last.timestamp.millisecondsSinceEpoch - start) / timeRange) *
            size.width;
    final normalizedLastY = (last.totalUsd - minValue) / range;
    final lastY = size.height - (normalizedLastY * (size.height - 10)) - 5;
    final dotOffset = Offset(lastX, lastY);
    final glowPaint = Paint()..color = accent.withOpacity(0.22);
    canvas.drawCircle(dotOffset, 10, glowPaint);
    canvas.drawCircle(dotOffset, 4.5, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(covariant _PortfolioChartPainter oldDelegate) {
    return oldDelegate.points != points || oldDelegate.positive != positive;
  }
}
