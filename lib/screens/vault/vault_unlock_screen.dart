import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:local_auth/local_auth.dart';
import 'package:ibiti_guardian/app/guardian_app_shell.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

import 'package:ibiti_guardian/screens/settings/settings_screen.dart';

class VaultUnlockScreen extends StatefulWidget {
  final bool isModal;
  const VaultUnlockScreen({super.key, this.isModal = false});
  static Future<bool> requireAuth(
    BuildContext context, {
    bool forceSetup = false,
  }) async {
    final state = IBITIVaultService.instance.state;
    final pinEnabled = state?.pinEnabled ?? false;
    final bioEnabled = state?.biometricsEnabled ?? false;
    if (!pinEnabled && !bioEnabled) {
      if (forceSetup) {
        final loc = LocalizationService.instance;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: GuardianColors.surface,
            title: Row(
              children: [
                const Icon(Icons.shield_outlined, color: GuardianColors.danger, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    loc.t('securityRequiredTitle') ?? 'Security Required',
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            content: Text(
              loc.t('securityRequiredBody') ??
                  'Для отправки средств настройте PIN-код или биометрию в настройках безопасности приложения.',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(
                  loc.t('swapCancel') ?? 'Cancel',
                  style: const TextStyle(color: GuardianColors.textSecondary),
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: GuardianColors.accent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  Navigator.of(ctx).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
                },
                child: Text(
                  loc.t('configureProtection') ?? 'Настроить защиту',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        );
        return false;
      }
      return true;
    }
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const VaultUnlockScreen(isModal: true),
        fullscreenDialog: true,
      ),
    );
    return result ?? false;
  }

  @override
  State<VaultUnlockScreen> createState() => _VaultUnlockScreenState();
}

class _VaultUnlockScreenState extends State<VaultUnlockScreen> {
  final LocalAuthentication _auth = LocalAuthentication();
  bool _isAuthenticating = false;
  bool _didAttemptPrimaryBiometric = false;
  bool _isError = false;
  String _currentPin = '';
  bool _processingPin = false;
  Timer? _lockRefreshTimer;
  bool get _pinEnabled => IBITIVaultService.instance.state?.pinEnabled ?? false;
  bool get _bioEnabled =>
      IBITIVaultService.instance.state?.biometricsEnabled ?? false;
  String get _primaryMethod => IBITIVaultService.instance.primaryUnlockMethod;
  bool get _showPinPad {
    if (_primaryMethod == 'pin' && _pinEnabled) return true;
    if (_pinEnabled && _bioEnabled) return true;
    if (_pinEnabled && !_bioEnabled) return true;
    return false;
  }

  @override
  void initState() {
    super.initState();
    if (IBITIVaultService.instance.isPinLocked) {
      _lockRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tryPrimaryAuth();
    });
  }

  @override
  void dispose() {
    _lockRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _tryPrimaryAuth() async {
    if (!_bioEnabled) return;
    if (_primaryMethod != 'biometric') return;
    if (_didAttemptPrimaryBiometric) return;
    _didAttemptPrimaryBiometric = true;
    await _promptBiometric();
  }

  Future<void> _promptBiometric() async {
    if (_isAuthenticating) return;
    setState(() {
      _isAuthenticating = true;
      _isError = false;
    });
    try {
      final canCheck = await _auth.canCheckBiometrics;
      final supported = await _auth.isDeviceSupported();
      if (!canCheck || !supported) {
        setState(() => _isAuthenticating = false);
        return;
      }
      final ok = await _auth.authenticate(
        localizedReason: LocalizationService.instance.t('vaultUnlockBiometric'),
        biometricOnly: true,
      );
      if (!mounted) return;
      if (ok) {
        _unlockAndGo();
        return;
      }
      // User cancelled biometric — show feedback instead of frozen UI
      if (mounted) {
        setState(() {
          _isAuthenticating = false;
          _isError = true;
        });
      }
    } catch (e) {
      const log = GuardianLogger('VaultUnlock');
      log.e('Biometric unlock error', e);
      if (mounted) {
        setState(() => _isAuthenticating = false);
      }
    }
  }

  void _onDigit(String digit) {
    if (!_pinEnabled) return;
    if (IBITIVaultService.instance.isPinLocked) return;
    if (_isAuthenticating) return;
    if (_currentPin.length < 6) {
      setState(() {
        _currentPin += digit;
        _isError = false;
      });
      if (_currentPin.length == 6) {
        Future.delayed(const Duration(milliseconds: 150), _processFullPin);
      }
    }
  }

  void _onBackspace() {
    if (_isAuthenticating) return;
    if (_currentPin.isEmpty) return;
    setState(() {
      _currentPin = _currentPin.substring(0, _currentPin.length - 1);
      _isError = false;
    });
  }

  Future<void> _processFullPin() async {
    if (_processingPin) return;
    _processingPin = true;

    if (!_pinEnabled) {
      _processingPin = false;
      return;
    }
    setState(() => _isAuthenticating = true);
    final isValid = await IBITIVaultService.instance.verifyPin(_currentPin);
    if (!mounted) return;
    if (isValid) {
      _unlockAndGo();
    } else {
      setState(() {
        _isError = true;
        _currentPin = '';
        _isAuthenticating = false;
      });
    }
    _processingPin = false;
  }

  void _unlockAndGo() {
    IBITIVaultService.instance.unlock();
    if (!mounted) return;
    if (widget.isModal) {
      Navigator.of(context).pop(true);
    } else {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const GuardianAppShell()),
        (_) => false,
      );
    }
  }

  Future<void> _logoutAndReset() async {
    await IBITIVaultService.instance.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const GuardianAppShell()),
      (_) => false,
    );
  }

  Future<void> _showForgotPinDialog() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: GuardianColors.surface,
            title: Text(
              LocalizationService.instance.t('vaultUnlockForgotPin'),
              style: const TextStyle(color: Colors.white),
            ),
            content: Text(
              LocalizationService.instance.t('vaultUnlockForgotPinBody'),
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Continue'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await _logoutAndReset();
  }

  @override
  Widget build(BuildContext context) {
    final t = LocalizationService.instance;
    final pinLocked = IBITIVaultService.instance.isPinLocked;
    String subtitle;
    if (pinLocked) {
      subtitle = 'PIN entry is temporarily locked';
    } else if (_isError) {
      subtitle = t.t('vaultUnlockInvalidPin');
    } else if (_bioEnabled && _pinEnabled) {
      subtitle = _primaryMethod == 'pin'
          ? t.t('vaultUnlockEnterPin')
          : t.t('vaultUnlockBiometricOrPin');
    } else if (_bioEnabled) {
      subtitle = _primaryMethod == 'pin'
          ? t.t('vaultUnlockEnterPin')
          : t.t('vaultUnlockBiometricContinue');
    } else {
      subtitle = t.t('vaultUnlockEnterPin');
    }
    return Scaffold(
      backgroundColor: GuardianColors.background,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 56),
            const Icon(
              Icons.lock_rounded,
              size: 56,
              color: GuardianColors.accent,
            ).animate().fadeIn().scale(),
            const SizedBox(height: 24),
            Text(
              t.t('vaultUnlockTitle'),
              style: GuardianTextStyles.headline,
            ).animate().fadeIn(delay: 120.ms),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: GuardianTextStyles.bodySecondary.copyWith(
                color: (pinLocked || _isError)
                    ? Colors.redAccent
                    : GuardianColors.textSecondary,
              ),
            ).animate().fadeIn(delay: 200.ms),
            const SizedBox(height: 32),
            if (_pinEnabled)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(6, (index) {
                  final filled = index < _currentPin.length;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: filled
                          ? (_isError
                              ? Colors.redAccent
                              : GuardianColors.accent)
                          : GuardianColors.background,
                      border: Border.all(
                        color: filled
                            ? (_isError
                                ? Colors.redAccent
                                : GuardianColors.accent)
                            : GuardianColors.glassBorder,
                        width: 2,
                      ),
                    ),
                  );
                }),
              ),
            const SizedBox(height: 28),
            if (_bioEnabled)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _isAuthenticating ? null : _promptBiometric,
                    icon: const Icon(Icons.fingerprint_rounded),
                    label: Text(
                      _bioEnabled && _pinEnabled
                          ? t.t('vaultUnlockUseBiometricInstead')
                          : t.t('vaultUnlockUseBiometric'),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: GuardianColors.accent,
                      side: const BorderSide(color: GuardianColors.glassBorder),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ),
            if (_isAuthenticating)
              const Padding(
                padding: EdgeInsets.only(top: 20),
                child: CircularProgressIndicator(
                  color: GuardianColors.accent,
                ),
              )
            else if (_showPinPad)
              Expanded(child: _buildNumpad()),
            if (!widget.isModal)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                  children: [
                    if (pinLocked)
                      _buildLockoutBanner()
                    else if (_pinEnabled)
                      _buildForgotPinButton(),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildForgotPinButton() {
    return Column(
      children: [
        const Divider(color: GuardianColors.glassBorder, height: 1),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: _showForgotPinDialog,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: GuardianColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: GuardianColors.glassBorder),
            ),
            child: Text(
              LocalizationService.instance.t('vaultUnlockForgotPin'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: GuardianColors.accent,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          LocalizationService.instance.t('vaultUnlockResetNote'),
          style: const TextStyle(
            color: GuardianColors.textTertiary,
            fontSize: 12,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildLockoutBanner() {
    final vault = IBITIVaultService.instance;
    final remaining = vault.pinLockedUntil != null
        ? vault.pinLockedUntil!.difference(DateTime.now())
        : Duration.zero;
    final mins = remaining.inMinutes.clamp(0, 999);
    final secs = (remaining.inSeconds % 60).clamp(0, 59);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF3D1A0A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x66FF6B57)),
      ),
      child: Text(
        'PIN locked for $mins:${secs.toString().padLeft(2, '0')}',
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xFFFF9A8A),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildNumpad() {
    const keys = [
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      '',
      '0',
      '⌫',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 8, 32, 8),
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        itemCount: keys.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisExtent: 74,
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
        ),
        itemBuilder: (context, index) {
          final key = keys[index];
          if (key.isEmpty) {
            return const SizedBox.shrink();
          }
          final isBackspace = key == '⌫';
          return Material(
            color: GuardianColors.surface,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () {
                if (isBackspace) {
                  _onBackspace();
                } else {
                  _onDigit(key);
                }
              },
              child: Center(
                child: Text(
                  key,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: isBackspace ? 26 : 28,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
