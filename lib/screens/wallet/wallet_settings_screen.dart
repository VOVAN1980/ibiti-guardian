import 'package:flutter/material.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/screens/wallet/wallet_token_management_screen.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/services/wallet/token_manager_service.dart';
import 'package:ibiti_guardian/services/wallet/wallet_settings_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

class WalletSettingsScreen extends StatefulWidget {
  const WalletSettingsScreen({super.key});

  @override
  State<WalletSettingsScreen> createState() => _WalletSettingsScreenState();
}

class _WalletSettingsScreenState extends State<WalletSettingsScreen> {
  WalletSettingsService get _settings => WalletSettingsService.instance;

  void _openManageTokens() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const WalletTokenManagementScreen()),
    );
  }

  Future<void> _setDefaultNetwork(String displayName) async {
    await _settings.update(defaultNetwork: displayName);
    final chain = PrivyChainRegistry.supportedChains.cast<dynamic>().firstWhere(
        (c) => c != null && c.displayName == displayName,
        orElse: () => null);
    if (chain != null &&
        IBITIVaultService.instance.hasAddressForChain(chain.chainKey)) {
      await IBITIVaultService.instance.setActiveChain(chain.chainKey);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    return Scaffold(
      backgroundColor: GuardianColors.background,
      appBar: AppBar(
        backgroundColor: GuardianColors.background,
        elevation: 0,
        title: Text(
          t.t('walletSettingsScreenTitle', {'default': 'Настройки кошелька'}),
          style: GuardianTextStyles.headline,
        ),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          _settings,
          TokenManagerService.instance,
        ]),
        builder: (context, _) {
          final s = _settings.state;
          final hiddenCount = TokenManagerService.instance.hidden.length;
          final customCount = TokenManagerService.instance.customTokens.length;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _SectionHeader(
                  title:
                      t.t('walletSettingsDisplay', {'default': 'Отображение'})),
              _SettingsCard(children: [
                _DropdownRow(
                  icon: Icons.attach_money_rounded,
                  label: t.t('walletSettingsCurrency', {'default': 'Валюта'}),
                  value: s.currency,
                  options: const ['USD', 'EUR', 'GBP', 'BTC', 'ETH'],
                  onChanged: (v) => _settings.update(currency: v),
                ),
                const Divider(color: GuardianColors.glassBorder, height: 1),
                _SwitchRow(
                  icon: Icons.visibility_rounded,
                  label: t.t('walletSettingsShowBalance',
                      {'default': 'Показывать баланс'}),
                  value: s.balanceVisible,
                  onChanged: (v) => _settings.update(balanceVisible: v),
                ),
              ]),
              const SizedBox(height: 16),
              _SectionHeader(
                  title: t.t('walletSettingsTokenFilters',
                      {'default': 'Фильтры токенов'})),
              _SettingsCard(children: [
                _SwitchRow(
                  icon: Icons.filter_alt_rounded,
                  label: t.t('walletSettingsHideZero',
                      {'default': 'Скрывать нулевые токены'}),
                  value: s.hideZeroBalance,
                  onChanged: (v) => _settings.update(hideZeroBalance: v),
                ),
                const Divider(color: GuardianColors.glassBorder, height: 1),
                _SwitchRow(
                  icon: Icons.security_rounded,
                  label: t.t('walletSettingsSpamFilter',
                      {'default': 'Фильтр спам-токенов'}),
                  subtitle: t.t('walletSettingsSpamFilterSub',
                      {'default': 'Скрывать токены дешевле \$0.01'}),
                  value: s.spamFilter,
                  onChanged: (v) => _settings.update(spamFilter: v),
                ),
                const Divider(color: GuardianColors.glassBorder, height: 1),
                _ActionRow(
                  icon: Icons.token_rounded,
                  label: t.t('walletSettingsManageTokens',
                      {'default': 'Управление токенами'}),
                  subtitle:
                      '$customCount custom imported • $hiddenCount hidden',
                  onTap: _openManageTokens,
                ),
              ]),
              const SizedBox(height: 16),
              _SectionHeader(
                  title: t.t(
                      'walletSettingsSecurity', {'default': 'Безопасность'})),
              _SettingsCard(children: [
                _SwitchRow(
                  icon: Icons.fingerprint_rounded,
                  label: t.t('walletSettingsBiometric',
                      {'default': 'Биометрия для отправки'}),
                  subtitle: t.t('walletSettingsBiometricSub', {
                    'default': 'Требовать Face ID / отпечаток перед отправкой'
                  }),
                  value: s.requireBioForSend,
                  onChanged: (v) => _settings.update(requireBioForSend: v),
                ),
              ]),
              const SizedBox(height: 16),
              _SectionHeader(
                  title: t.t('walletSettingsGas', {'default': 'Газ'})),
              _SettingsCard(children: [
                _DropdownRow(
                  icon: Icons.local_gas_station_rounded,
                  label: t.t('walletSettingsGasTier',
                      {'default': 'Предпочтительный уровень газа'}),
                  value: s.gasTier,
                  options: const ['Standard', 'Fast', 'Aggressive'],
                  onChanged: (v) => _settings.update(gasTier: v),
                ),
              ]),
              const SizedBox(height: 16),
              _SectionHeader(
                  title: t.t('walletSettingsNetworkDefaults',
                      {'default': 'Сети по умолчанию'})),
              _SettingsCard(children: [
                _DropdownRow(
                  icon: Icons.hub_rounded,
                  label: t.t('walletSettingsDefaultNetwork',
                      {'default': 'Сеть по умолчанию при открытии'}),
                  value: s.defaultNetwork,
                  options: [
                    for (final chain in PrivyChainRegistry.supportedChains)
                      chain.displayName
                  ],
                  onChanged: _setDefaultNetwork,
                ),
              ]),
              const SizedBox(height: 16),
              _SectionHeader(
                  title: t.t('walletSettingsBackup',
                      {'default': 'Резервное копирование'})),
              _SettingsCard(children: [
                _StatusRow(
                  icon: Icons.verified_user_rounded,
                  label: t.t('walletSettingsRecoveryStatus',
                      {'default': 'Статус восстановления Vault'}),
                  value: t.t('walletSettingsRecoveryProtected',
                      {'default': 'Защищено IBITI Vault'}),
                ),
                const Divider(color: GuardianColors.glassBorder, height: 1),
                _StatusRow(
                  icon: Icons.notifications_active_outlined,
                  label: t.t('walletSettingsBackupReminder',
                      {'default': 'Напоминание о резервной копии'}),
                  value: t.t('walletSettingsEnabled', {'default': 'Включено'}),
                ),
              ]),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(
          title.toUpperCase(),
          style: GuardianTextStyles.caption.copyWith(
            color: GuardianColors.textSecondary,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
      );
}

class _SettingsCard extends StatelessWidget {
  final List<Widget> children;
  const _SettingsCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: GuardianColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: GuardianColors.glassBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _SwitchRow({
    required this.icon,
    required this.label,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: GuardianColors.textSecondary, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: GuardianTextStyles.bodyPrimary),
                if (subtitle != null)
                  Text(subtitle!, style: GuardianTextStyles.caption),
              ],
            ),
          ),
          Switch(
              value: value,
              onChanged: onChanged,
              activeColor: GuardianColors.accent),
        ],
      ),
    );
  }
}

class _DropdownRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;
  const _DropdownRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: GuardianColors.textSecondary, size: 22),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: GuardianTextStyles.bodyPrimary)),
          DropdownButton<String>(
            value: value,
            dropdownColor: GuardianColors.surface,
            underline: const SizedBox(),
            items: options
                .map((o) => DropdownMenuItem<String>(
                      value: o,
                      child: Text(
                        o,
                        style: GuardianTextStyles.bodyPrimary
                            .copyWith(color: GuardianColors.accent),
                      ),
                    ))
                .toList(),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _StatusRow(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(icon, color: GuardianColors.textSecondary, size: 22),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: GuardianTextStyles.bodyPrimary)),
          Text(
            value,
            style: GuardianTextStyles.caption.copyWith(
              color: GuardianColors.accent,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;
  const _ActionRow(
      {required this.icon,
      required this.label,
      this.subtitle,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Icon(icon, color: GuardianColors.textSecondary, size: 22),
      title: Text(label, style: GuardianTextStyles.bodyPrimary),
      subtitle: subtitle != null
          ? Text(subtitle!, style: GuardianTextStyles.caption)
          : null,
      trailing: const Icon(Icons.chevron_right_rounded,
          color: GuardianColors.textTertiary),
      onTap: onTap,
    );
  }
}
