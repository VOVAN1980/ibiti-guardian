import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/audit_log_service.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';

import 'package:ibiti_guardian/services/settings/settings_service.dart';

/// Chain-aware description for the receive modal.
String _receiveHelpText(String chainKey, String networkName) {
  final lang =
      SettingsService.instance.settings.languageCode.trim().toLowerCase();
  final isRu = lang.startsWith('ru');

  switch (chainKey) {
    case 'solana':
      return isRu
          ? 'Пополните ваш Solana-кошелёк, отправив SOL или поддерживаемые SPL-токены на адрес ниже.'
          : 'Fund your Solana wallet by sending SOL or supported SPL tokens to the address below.';
    case 'tron':
      return isRu
          ? 'Пополните ваш Tron-кошелёк, отправив TRX или поддерживаемые TRC-20 токены на адрес ниже.'
          : 'Fund your Tron wallet by sending TRX or supported TRC-20 tokens to the address below.';
    default:
      final nativeSymbol =
          PrivyChainRegistry.getChain(chainKey).nativeSymbol ?? 'ETH';
      return isRu
          ? 'Пополните ваш $networkName-кошелёк, отправив $nativeSymbol или поддерживаемые токены на адрес ниже.'
          : 'Fund your $networkName wallet by sending $nativeSymbol or supported tokens to the address below.';
  }
}

/// Receive funds: QR and copy always track [IBITIVaultService.instance.activeAddress] live
/// (no stale snapshot from when the sheet was opened).
class WalletReceiveModal extends StatelessWidget {
  const WalletReceiveModal({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const WalletReceiveModal(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    final vault = IBITIVaultService.instance;

    return ListenableBuilder(
      listenable: vault,
      builder: (context, _) {
        final address = vault.activeAddress;
        final chain = PrivyChainRegistry.getChain(vault.chainKey);
        if (address.isEmpty) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                t.t('walletReceiveNoAddress',
                    {'default': 'Wallet address not ready'}),
                style: GuardianTextStyles.bodySecondary,
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        return SafeArea(
          bottom: true,
          top: false,
          child: Container(
            decoration: const BoxDecoration(
              color: GuardianColors.background,
              borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
              border:
                  Border(top: BorderSide(color: GuardianColors.glassBorder)),
            ),
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: GuardianColors.glassBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  t.t('walletReceiveMenu', {'default': 'Receive Assets'}),
                  style: GuardianTextStyles.headline.copyWith(fontSize: 24),
                ),
                const SizedBox(height: 8),
                Text(
                  _receiveHelpText(vault.chainKey, chain.displayName),
                  textAlign: TextAlign.center,
                  style: GuardianTextStyles.bodySecondary,
                ),
                const SizedBox(height: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: GuardianColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'Network: ${chain.displayName}',
                    style: GuardianTextStyles.caption.copyWith(
                      color: GuardianColors.accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Only send assets on ${chain.displayName} to this address.',
                  textAlign: TextAlign.center,
                  style: GuardianTextStyles.caption.copyWith(
                    color: GuardianColors.warning,
                  ),
                ),
                const SizedBox(height: 32),
                Container(
                  width: 200,
                  height: 200,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Center(
                    child: QrImageView(
                      data: address,
                      version: QrVersions.auto,
                      size: 168.0,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: GuardianColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: GuardianColors.glassBorder),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          address,
                          style: GuardianTextStyles.caption
                              .copyWith(fontFamily: 'monospace'),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy,
                            color: GuardianColors.accent, size: 20),
                        onPressed: () {
                          final live = IBITIVaultService.instance.activeAddress;
                          Clipboard.setData(ClipboardData(text: live));
                          AuditLogService.instance.recordAddressCopy(
                            address: live,
                            networkLabel: chain.displayName,
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(t.t('walletCopySuccess',
                                  {'default': 'Address copied'})),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        );
      },
    );
  }
}
