import 'package:flutter/material.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/screens/wallet/wallet_token_management_screen.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/wallet/token_manager_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

class TokenManagementSheet extends StatelessWidget {
  final WalletAsset asset;

  const TokenManagementSheet({super.key, required this.asset});

  static void show(BuildContext context, {required WalletAsset asset}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      builder: (_) => TokenManagementSheet(asset: asset),
    );
  }

  String get _tokenId {
    final chain =
        asset.chainKey.isNotEmpty ? asset.chainKey : '${asset.chainId}';
    return '$chain:${asset.address}'.toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final manager = TokenManagerService.instance;
    final isPinned = manager.isPinned(_tokenId);
    final isHidden = manager.isHidden(_tokenId);

    return Container(
      decoration: const BoxDecoration(
        color: GuardianColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: GuardianColors.glassBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                asset.symbol,
                style: GuardianTextStyles.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                asset.name,
                style: GuardianTextStyles.bodySecondary,
              ),
              const SizedBox(height: 18),
              _TokenActionTile(
                icon:
                    isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
                title: isPinned
                    ? LocalizationService.instance.t('tokenMgmtUnpin')
                    : LocalizationService.instance.t('tokenMgmtPin'),
                subtitle:
                    LocalizationService.instance.t('tokenMgmtPinSubtitle'),
                onTap: () async {
                  await manager.togglePinned(_tokenId);
                  if (context.mounted) Navigator.pop(context);
                },
              ),
              _TokenActionTile(
                icon: isHidden
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_rounded,
                title: isHidden
                    ? LocalizationService.instance.t('tokenMgmtUnhide')
                    : LocalizationService.instance.t('tokenMgmtHide'),
                subtitle:
                    LocalizationService.instance.t('tokenMgmtHideSubtitle'),
                onTap: () async {
                  await manager.toggleHidden(_tokenId);
                  if (context.mounted) Navigator.pop(context);
                },
              ),
              _TokenActionTile(
                icon: Icons.tune_rounded,
                title: LocalizationService.instance.t('tokenMgmtManage'),
                subtitle:
                    LocalizationService.instance.t('tokenMgmtManageSubtitle'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const WalletTokenManagementScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TokenActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _TokenActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: GuardianColors.glassBorder),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
      title: Text(title, style: GuardianTextStyles.bodyPrimary),
      subtitle: Text(subtitle, style: GuardianTextStyles.caption),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: GuardianColors.textTertiary,
      ),
      onTap: onTap,
    );
  }
}
