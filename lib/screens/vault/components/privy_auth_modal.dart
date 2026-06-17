import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/app/guardian_app_shell.dart';

Future<void> showPrivyLoginModal(BuildContext context) async {
  return showDialog(
    context: context,
    useSafeArea: true,
    builder: (context) => const _PrivyAuthModal(),
  );
}

class _PrivyAuthModal extends StatefulWidget {
  const _PrivyAuthModal();

  @override
  State<_PrivyAuthModal> createState() => _PrivyAuthModalState();
}

class _PrivyAuthModalState extends State<_PrivyAuthModal> {
  bool _isEmailMode = false;
  bool _isVerifyMode = false;
  bool _isLoading = false;

  final _emailController = TextEditingController();
  final _codeController = TextEditingController();

  Future<void> _handleEmailSubmit() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) return;

    setState(() => _isLoading = true);
    final ok = await IBITIVaultService.instance.sendEmailCode(email);
    if (!mounted) return;
    setState(() => _isLoading = false);

    if (ok) {
      setState(() => _isVerifyMode = true);
    } else {
      _showError('Не удалось отправить код на email.');
    }
  }

  Future<void> _handleCodeSubmit() async {
    final code = _codeController.text.trim();
    final email = _emailController.text.trim();
    if (code.isEmpty) return;

    setState(() => _isLoading = true);
    final ok = await IBITIVaultService.instance
        .loginWithEmailCode(email: email, code: code);
    if (!mounted) return;
    setState(() => _isLoading = false);

    if (ok) {
      final nav = Navigator.of(context, rootNavigator: true);
      Navigator.of(context).pop(); // Close modal
      nav.pushReplacement(
        MaterialPageRoute(builder: (_) => const GuardianAppShell()),
      );
    } else {
      _showError('Недействительный код подтверждения.');
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: const Color(0xFFFF3B30)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            elevation: 0,
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxWidth: 400),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              decoration: BoxDecoration(
                color: const Color(0xFF131315),
                borderRadius: BorderRadius.circular(32),
                border: Border.all(
                    color: GuardianColors.glassBorder.withOpacity(0.5)),
                boxShadow: [
                  BoxShadow(
                    color: GuardianColors.accent.withOpacity(0.12),
                    blurRadius: 60,
                    spreadRadius: -10,
                  ),
                ],
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.bolt_rounded,
                            size: 48, color: GuardianColors.accent)
                        .animate()
                        .scale(duration: 400.ms, curve: Curves.easeOutBack),
                    const SizedBox(height: 16),
                    Text(
                      LocalizationService.instance.t('privyAuthTitle'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 32),
                    if (_isLoading)
                      const SizedBox(
                        height: 150,
                        child: Center(
                            child: CircularProgressIndicator(
                                color: GuardianColors.accent)),
                      )
                    else if (_isVerifyMode)
                      _buildVerifyView()
                    else if (_isEmailMode)
                      _buildEmailInputView()
                    else
                      _buildSocialOptionsView(),
                    const SizedBox(height: 32),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                            LocalizationService.instance
                                .t('privyAuthProtectedBy'),
                            style: const TextStyle(
                                color: GuardianColors.textTertiary,
                                fontSize: 12)),
                        Text('privy',
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.9),
                                fontSize: 14,
                                fontWeight: FontWeight.bold)),
                      ],
                    )
                  ],
                ),
              ),
            ))
        .animate()
        .fadeIn(duration: 300.ms, curve: Curves.easeOut)
        .scale(
            begin: const Offset(0.95, 0.95),
            duration: 400.ms,
            curve: Curves.easeOutBack);
  }

  Widget _buildSocialOptionsView() {
    return Column(
      children: [
        _buildSocialButton(
          label: LocalizationService.instance.t('privyAuthGoogle'),
          icon: Icons.g_mobiledata_rounded,
          onTap: () async {
            const log = GuardianLogger('PrivyAuth');
            log.d('Google login click');
            try {
              log.d('Google login start');
              setState(() => _isLoading = true);

              // Вызов реального метода логина через SDK
              final ok = await IBITIVaultService.instance.loginWithGoogle();

              if (!mounted) return;
              setState(() => _isLoading = false);

              if (ok) {
                log.d('Google login success');
                final nav = Navigator.of(context, rootNavigator: true);
                Navigator.of(context).pop();
                nav.pushReplacement(
                  MaterialPageRoute(builder: (_) => const GuardianAppShell()),
                );
              } else {
                _showError(
                    'Не удалось войти через Google. Попробуйте еще раз.');
              }
            } on PlatformException catch (e) {
              if (!mounted) return;
              setState(() => _isLoading = false);
              log.e('PlatformException code=${e.code}', e);
              // stacktrace suppressed in production
              _showError('Ошибка платформы: ${e.message}');
            } catch (e) {
              if (!mounted) return;
              setState(() => _isLoading = false);
              log.e('Google login error', e);
              _showError('Неизвестная ошибка: $e');
            }
          },
        ).animate().fadeIn(delay: 100.ms),
        _buildSocialButton(
          label: LocalizationService.instance.t('privyAuthApple'),
          icon: Icons.apple_rounded,
          onTap: () {
            _showError(
                LocalizationService.instance.t('privyAuthAppleNotConfigured'));
          },
        ).animate().fadeIn(delay: 150.ms),
        const SizedBox(height: 12),
        _buildSocialButton(
          label: LocalizationService.instance.t('privyAuthEmail'),
          icon: Icons.email_outlined,
          onTap: () => setState(() => _isEmailMode = true),
        ).animate().fadeIn(delay: 200.ms),
      ],
    );
  }

  Widget _buildEmailInputView() {
    return Column(
      children: [
        TextField(
          controller: _emailController,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'your@email.com',
            hintStyle: const TextStyle(color: GuardianColors.textTertiary),
            filled: true,
            fillColor: const Color(0xFF1E1E20),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton(
            onPressed: _handleEmailSubmit,
            style: ElevatedButton.styleFrom(
              backgroundColor: GuardianColors.accent,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
            child: Text(LocalizationService.instance.t('privyAuthSendCode'),
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16)),
          ),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => setState(() => _isEmailMode = false),
          child: Text(LocalizationService.instance.t('privyAuthBackToOptions'),
              style: const TextStyle(color: GuardianColors.textSecondary)),
        )
      ],
    ).animate().fadeIn();
  }

  Widget _buildVerifyView() {
    return Column(
      children: [
        Text(
          LocalizationService.instance
              .t('privyAuthCodeSent', {'email': _emailController.text}),
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: GuardianColors.textSecondary, fontSize: 14),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _codeController,
          autofocus: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              letterSpacing: 8,
              fontWeight: FontWeight.bold),
          decoration: InputDecoration(
            hintText: '000000',
            hintStyle: const TextStyle(color: GuardianColors.textTertiary),
            filled: true,
            fillColor: const Color(0xFF1E1E20),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton(
            onPressed: _handleCodeSubmit,
            style: ElevatedButton.styleFrom(
              backgroundColor: GuardianColors.accent,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
            child: const Text('Verify',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16)),
          ),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => setState(() => _isVerifyMode = false),
          child: Text(LocalizationService.instance.t('privyAuthWrongEmail'),
              style: const TextStyle(color: GuardianColors.textSecondary)),
        )
      ],
    ).animate().fadeIn();
  }

  Widget _buildSocialButton(
      {required String label,
      required IconData icon,
      required VoidCallback onTap}) {
    return Material(
      color: const Color(0xFF1E1E20),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(
            children: [
              Icon(icon, color: Colors.white, size: 24),
              const SizedBox(width: 16),
              Text(
                label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
