import 'package:flutter/material.dart';
import 'package:ibiti_guardian/app/guardian_app_shell.dart';
import 'package:ibiti_guardian/screens/vault/components/privy_auth_modal.dart';
import 'package:ibiti_guardian/screens/vault/vault_unlock_screen.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';

/// Shown at startup instead of the PIN screen when the wallet exists locally
/// but its Privy session has expired — signing needs a fresh sign-in with the
/// account that owns the wallet.
class PrivyReauthScreen extends StatefulWidget {
  const PrivyReauthScreen({super.key});

  @override
  State<PrivyReauthScreen> createState() => _PrivyReauthScreenState();
}

class _PrivyReauthScreenState extends State<PrivyReauthScreen> {
  Future<void> _signIn() async {
    final ok = await showPrivyReauthModal(context);
    if (!ok || !mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const GuardianAppShell()),
    );
  }

  /// View-only until sign-in: same PIN/biometric gate as a normal start.
  void _later() {
    final vault = IBITIVaultService.instance;
    final needsUnlock =
        ((vault.state?.biometricsEnabled ?? false) || vault.pinEnabled) &&
            !vault.isUnlocked;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) =>
            needsUnlock ? const VaultUnlockScreen() : const GuardianAppShell(),
      ),
    );
  }

  String _maskedWallet() {
    final address = IBITIVaultService.instance.evmAddress ?? '';
    if (address.length < 12) return address;
    return '${address.substring(0, 6)}…${address.substring(address.length - 4)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GuardianColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock_clock_rounded,
                  size: 56, color: GuardianColors.accent),
              const SizedBox(height: 24),
              const Text(
                'Сессия истекла',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Text(
                'Чтобы подписывать транзакции кошелька ${_maskedWallet()}, '
                'войдите тем же аккаунтом Google или email, через который '
                'создавали кошелёк.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: GuardianColors.textSecondary, fontSize: 15),
              ),
              const SizedBox(height: 36),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: GuardianColors.background,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999)),
                  ),
                  onPressed: _signIn,
                  child: const Text('Войти',
                      style:
                          TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: GuardianColors.glassBorder),
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999)),
                  ),
                  onPressed: _later,
                  child: const Text('Позже — только просмотр',
                      style:
                          TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
