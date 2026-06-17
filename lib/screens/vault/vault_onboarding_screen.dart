import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/screens/vault/components/privy_auth_modal.dart';

// ────────────────────────────────────────────────────────────────────────────
// VaultOnboardingPlaceholder — используется BootScreen для роутинга.
// Это просто alias на реальный VaultOnboardingScreen.
// ────────────────────────────────────────────────────────────────────────────
class VaultOnboardingPlaceholder extends StatelessWidget {
  const VaultOnboardingPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const VaultOnboardingScreen();
  }
}

// ────────────────────────────────────────────────────────────────────────────
// VaultOnboardingScreen
//
// Три слайда:
//   1. Что такое IBITI Vault
//   2. EPK защита — что это значит для пользователя
//   3. CTA — Google / Apple login
// ────────────────────────────────────────────────────────────────────────────
class VaultOnboardingScreen extends StatefulWidget {
  const VaultOnboardingScreen({super.key});

  @override
  State<VaultOnboardingScreen> createState() => _VaultOnboardingScreenState();
}

class _VaultOnboardingScreenState extends State<VaultOnboardingScreen> {
  final PageController _controller = PageController();
  int _currentPage = 0;
  final bool _isLoading = false;

  List<_OnboardingSlide> _getSlides(BuildContext context) {
    final t = LocalizationProvider.of(context);
    return [
      _OnboardingSlide(
        icon: Icons.account_balance_wallet_rounded,
        iconColor: const Color(0xFF6C63FF),
        title: t.t('onboardVaultTitle'),
        subtitle: t.t('onboardVaultSubtitle'),
        body: t.t('onboardVaultBody'),
      ),
      _OnboardingSlide(
        icon: Icons.verified_user_rounded,
        iconColor: const Color(0xFF00D4AA),
        title: t.t('onboardEPKTitle'),
        subtitle: t.t('onboardEPKSubtitle'),
        body: t.t('onboardEPKBody'),
      ),
      _OnboardingSlide(
        icon: Icons.bolt_rounded,
        iconColor: const Color(0xFFFFB347),
        title: t.t('onboardReadyTitle'),
        subtitle: t.t('onboardReadySubtitle'),
        body: t.t('onboardReadyBody'),
      ),
    ];
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next(BuildContext context) {
    if (_currentPage < _getSlides(context).length - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  void _showLoginOptions() {
    showPrivyLoginModal(context);
  }

  @override
  Widget build(BuildContext context) {
    final slides = _getSlides(context);
    final isLastSlide = _currentPage == slides.length - 1;

    return Scaffold(
      backgroundColor: GuardianColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // ── Slides ──────────────────────────────────────────────────────
            Expanded(
              child: PageView.builder(
                controller: _controller,
                onPageChanged: (i) => setState(() => _currentPage = i),
                itemCount: slides.length,
                itemBuilder: (context, i) {
                  return _SlideView(slide: slides[i]);
                },
              ),
            ),

            // ── Page Indicators ─────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(slides.length, (i) {
                final active = i == _currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: active ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: active
                        ? GuardianColors.accent
                        : GuardianColors.accent.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),

            const SizedBox(height: 32),

            // ── Actions ─────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: isLastSlide
                  ? _buildAuthButtons(context)
                  : _buildNextButton(context),
            ),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildNextButton(BuildContext context) {
    final t = LocalizationProvider.of(context);
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: () => _next(context),
        style: ElevatedButton.styleFrom(
          backgroundColor: GuardianColors.accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
        ),
        child: Text(
          t.t('onboardNextBtn'),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _buildAuthButtons(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: GuardianColors.accent),
      );
    }

    final t = LocalizationProvider.of(context);
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton(
            onPressed: _showLoginOptions,
            style: ElevatedButton.styleFrom(
              backgroundColor: GuardianColors.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: Text(t.t('onboardLoginBtn'),
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    )
        .animate()
        .fadeIn(duration: 400.ms)
        .slideY(begin: 0.2, end: 0, duration: 400.ms);
  }
}

// ────────────────────────────────────────────────────────────────────────────
// _OnboardingSlide — модель одного слайда
// ────────────────────────────────────────────────────────────────────────────
class _OnboardingSlide {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final String body;

  const _OnboardingSlide({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.body,
  });
}

class _SlideView extends StatelessWidget {
  final _OnboardingSlide slide;
  const _SlideView({required this.slide});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Icon glow container
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: slide.iconColor.withOpacity(0.12),
              boxShadow: [
                BoxShadow(
                  color: slide.iconColor.withOpacity(0.25),
                  blurRadius: 40,
                  spreadRadius: 8,
                ),
              ],
            ),
            child: Icon(slide.icon, size: 56, color: slide.iconColor),
          )
              .animate()
              .fadeIn(duration: 500.ms)
              .scale(begin: const Offset(0.8, 0.8), end: const Offset(1, 1)),

          const SizedBox(height: 40),

          Text(
            slide.title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 2,
              color: GuardianColors.accent,
            ),
          ).animate().fadeIn(delay: 100.ms, duration: 400.ms),

          const SizedBox(height: 12),

          Text(
            slide.subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: GuardianColors.textPrimary,
              height: 1.3,
            ),
          ).animate().fadeIn(delay: 200.ms, duration: 400.ms),

          const SizedBox(height: 20),

          Text(
            slide.body,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 15,
              color: GuardianColors.textSecondary,
              height: 1.6,
            ),
          ).animate().fadeIn(delay: 300.ms, duration: 400.ms),
        ],
      ),
    );
  }
}
