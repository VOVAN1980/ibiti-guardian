import 'package:flutter/material.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/widgets/vibrant_orb_widget.dart';
import 'package:ibiti_guardian/widgets/ai_form_widget.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';

enum AICoreState {
  idle,
  thinking,
  speaking,
  listening,
  safe,
  warning,
  danger,
}

class AICoreWidget extends StatefulWidget {
  final double size;
  final AICoreState state;
  final double soundLevel; // 0.0 to 1.0

  const AICoreWidget({
    super.key,
    this.size = 280,
    this.state = AICoreState.idle,
    this.soundLevel = 0.0,
  });

  @override
  State<AICoreWidget> createState() => _AICoreWidgetState();
}

class _AICoreWidgetState extends State<AICoreWidget>
    with TickerProviderStateMixin {
  late AnimationController _mainController;
  Offset _mousePosition = Offset.zero;

  @override
  void initState() {
    super.initState();
    _mainController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _mainController.dispose();
    super.dispose();
  }

  Color? _getColorForState(AICoreState state) {
    switch (state) {
      case AICoreState.safe:
        return GuardianColors.success;
      case AICoreState.warning:
        return GuardianColors.warning;
      case AICoreState.danger:
        return GuardianColors.danger;
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance.settings;
    final color = _getColorForState(widget.state) ?? GuardianColors.accent;

    return MouseRegion(
      onHover: (event) {
        setState(() {
          _mousePosition = Offset(
            (event.localPosition.dx / widget.size - 0.5) * 20,
            (event.localPosition.dy / widget.size - 0.5) * 20,
          );
        });
      },
      onExit: (_) => setState(() => _mousePosition = Offset.zero),
      child: AnimatedBuilder(
        animation: _mainController,
        builder: (context, child) {
          // 1. Subtle look-at-user (Parallax)
          final parallaxOffset = Offset(
            _mousePosition.dx.clamp(-15, 15),
            _mousePosition.dy.clamp(-15, 15),
          );

          return SizedBox(
            width: widget.size,
            height: widget.size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Background Neural Field (The Energy Field)
                Opacity(
                  opacity: 0.5,
                  child: VibrantOrbWidget(
                    size: widget.size * 0.9,
                    isThinking: widget.state == AICoreState.thinking,
                    isSpeaking: widget.state == AICoreState.speaking,
                    baseColor: color,
                  ),
                ),

                // THE LIVING FORM (Animated AI entity)
                Transform.translate(
                  offset: parallaxOffset * 0.8,
                  child: AiFormWidget(
                    type: _aiFormFromPath(settings.selectedMascotPath),
                    size: widget.size * 0.72,
                    active: widget.state == AICoreState.speaking ||
                        widget.state == AICoreState.listening,
                  ),
                ),

                // Interactive Glow Points (Neural "Synapses")
                if (widget.state == AICoreState.listening ||
                    widget.state == AICoreState.speaking)
                  _buildActiveGlow(color),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildThinkingRipples(Color color) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size(widget.size, widget.size),
        painter: _RipplePainter(
          animationValue: _mainController.value,
          color: color,
        ),
      ),
    );
  }

  Widget _buildActiveGlow(Color color) {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            color.withOpacity(0.1),
            Colors.transparent,
          ],
        ),
      ),
    );
  }
}

/// Maps stored mascot path key → AiFormType (same logic as settings screen)
AiFormType _aiFormFromPath(String path) {
  if (path.contains('ethereal')) return AiFormType.plasma;
  if (path.contains('stealth')) return AiFormType.fog;
  if (path.contains('command')) return AiFormType.stream;
  return AiFormType.core; // default + 'core.png'
}

class _RipplePainter extends CustomPainter {
  final double animationValue;
  final Color color;

  _RipplePainter({required this.animationValue, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = color.withOpacity((1.0 - animationValue).clamp(0, 1))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawCircle(center, size.width * 0.4 * animationValue, paint);

    // Extra smaller ring
    final secondValue = (animationValue + 0.5) % 1.0;
    paint.color = color.withOpacity((1.0 - secondValue).clamp(0, 1));
    canvas.drawCircle(center, size.width * 0.4 * secondValue, paint);
  }

  @override
  bool shouldRepaint(covariant _RipplePainter oldDelegate) => true;
}
