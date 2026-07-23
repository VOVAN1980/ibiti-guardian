import 'package:flutter/material.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/screens/security/policy_limits_screen.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

// ─────────────────────────────────────────────────────────────────────────────
// EPKControlScreen — статус исполнения и on-chain защита.
//
// Этот экран показывает:
//   • Текущий статус EPK (active / paused / local)
//   • Validators on-chain
//   • On-chain агент
//   • Журнал операций
//   • Экстренные on-chain кнопки
//
// Лимиты → Политика
// ─────────────────────────────────────────────────────────────────────────────

class EPKControlScreen extends StatefulWidget {
  const EPKControlScreen({super.key});

  @override
  State<EPKControlScreen> createState() => _EPKControlScreenState();
}

// Backward-compatible alias
class EpkControlScreen extends StatelessWidget {
  const EpkControlScreen({super.key});

  @override
  Widget build(BuildContext context) => const EPKControlScreen();
}

class _EPKControlScreenState extends State<EPKControlScreen> {
  late final EPKPolicyManager _epkService;
  late final PolicyProfileStore _policyStore;

  @override
  void initState() {
    super.initState();
    _epkService = EPKPolicyManager.instance;
    _policyStore = PolicyProfileStore.instance;
    _epkService.addListener(_rebuild);
    _policyStore.addListener(_rebuild);
    AiControlService.instance.addListener(_rebuild);
    _policyStore.load();
    _epkService.refreshPolicy();
  }

  @override
  void dispose() {
    _epkService.removeListener(_rebuild);
    _policyStore.removeListener(_rebuild);
    AiControlService.instance.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  // ── Formatters ─────────────────────────────────────────────────────────────

  String _fmtExpiry(DateTime? expiry) {
    final l = LocalizationService.instance;
    if (expiry == null) return l.t('policyNoExpiry');
    final diff = expiry.difference(DateTime.now());
    if (diff.isNegative) return l.t('policyExpired');
    if (diff.inHours > 24)
      return l.t('policyExpiryDays', {'days': diff.inDays});
    return l.t('policyExpiryHours', {'hours': diff.inHours});
  }

  String _fmtEpkMode(EPKExecutionMode mode) => switch (mode) {
        EPKExecutionMode.local => 'Local protected',
        EPKExecutionMode.guarded => 'Guarded confirm',
        EPKExecutionMode.onChainEpk => 'On-chain EPK',
        EPKExecutionMode.fallback => 'Fallback',
      };

  String _fmtAddr(String address) {
    if (address.isEmpty) return 'Not initialized';
    if (address.length <= 12) return address;
    return '${address.substring(0, 6)}...${address.substring(address.length - 4)}';
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final epk = _epkService.state;
    final profile = _policyStore.current;
    final vaultAddress = IBITIVaultService.instance.activeAddress;
    final ai = AiControlService.instance.settings;

    return Scaffold(
      backgroundColor: GuardianColors.background,
      appBar: AppBar(
        title: Text(LocalizationService.instance.t('epkControlTitle'),
            style: GuardianTextStyles.headline.copyWith(fontSize: 20)),
        backgroundColor: GuardianColors.background,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              color: GuardianColors.textPrimary, size: 24),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Role card ──────────────────────────────────────────────────
            _RoleCard(
              onGoToPolicy: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const PolicyLimitsScreen())),
            ),
            const SizedBox(height: 24),

            // ── EPK Status ─────────────────────────────────────────────────
            _sectionHeader(LocalizationService.instance.t('epkStatusSection')),
            _card([
              _row(
                  LocalizationService.instance.t('aiControlStatus'),
                  epk.isActive
                      ? LocalizationService.instance.t('epkStatusActive')
                      : LocalizationService.instance.t('epkStatusPaused'),
                  valueColor: epk.isActive
                      ? GuardianColors.success
                      : GuardianColors.warning),
              _divider(),
              _row(
                  LocalizationService.instance.t('epkDeployedOnChain'),
                  epk.isDeployed
                      ? LocalizationService.instance.t('epkDeployedOnChain')
                      : LocalizationService.instance.t('epkDeployedLocal')),
              _divider(),
              _row(LocalizationService.instance.t('securityExecutionMode'),
                  _fmtEpkMode(epk.executionMode)),
              _divider(),
              _row(LocalizationService.instance.t('epkChain'), epk.chain),
              _divider(),
              _row(
                  LocalizationService.instance.t('epkPolicyId'),
                  epk.policyId ??
                      LocalizationService.instance.t('epkPolicyIdNotSet')),
              _divider(),
              _row(LocalizationService.instance.t('epkVaultAddress'),
                  _fmtAddr(vaultAddress)),
            ]),
            const SizedBox(height: 16),
            // EPK action chips
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                _actionChip(
                  label: LocalizationService.instance.t('epkRefresh'),
                  color: GuardianColors.accent,
                  onTap: _epkService.refreshPolicy,
                ),
                _actionChip(
                  label: epk.isDeployed
                      ? (epk.isActive
                          ? LocalizationService.instance.t('epkPauseBtn')
                          : LocalizationService.instance.t('epkResumeBtn'))
                      : LocalizationService.instance.t('epkCreateBtn'),
                  color: epk.isActive
                      ? GuardianColors.warning
                      : GuardianColors.success,
                  onTap: () => epk.isDeployed
                      ? (epk.isActive
                          ? _epkService.emergencyPause()
                          : _epkService.resumeProtection())
                      : _epkService.createPolicy(),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // ── Validators ─────────────────────────────────────────────────
            _sectionHeader(LocalizationService.instance.t('epkValidators')),
            _card([
              _checkRow('SpendLimitValidator', epk.hasSpendLimitValidator),
              _divider(),
              _checkRow('TargetSelectorGuard', epk.hasTargetSelectorGuard),
              _divider(),
              _checkRow('ThreatFeedBlocklistValidator',
                  epk.hasThreatFeedBlocklistValidator),
              _divider(),
              _checkRow('CompositeValidator', epk.hasCompositeValidator),
              _divider(),
              _row(
                  LocalizationService.instance.t('aiControlStatus'),
                  epk.isActive
                      ? LocalizationService.instance.t('epkOnline')
                      : LocalizationService.instance.t('epkOffline'),
                  valueColor: epk.isActive
                      ? GuardianColors.success
                      : GuardianColors.danger),
            ]),
            const SizedBox(height: 20),

            // ── Policy application (read-only summary) ─────────────────────
            _sectionHeader(LocalizationService.instance.t('epkAppliedPolicy')),
            _card([
              _row(
                  'AI Mode',
                  switch (ai.mode) {
                    AiMode.manual =>
                      LocalizationService.instance.t('aiControlModeManual'),
                    AiMode.guarded =>
                      LocalizationService.instance.t('aiControlModeGuarded'),
                    AiMode.fullAutonomy => LocalizationService.instance
                        .t('aiControlModeFullAutonomy'),
                  }),
              _divider(),
              _row(LocalizationService.instance.t('epkTrustedContracts'),
                  '${profile.trustedContracts.length}'),
              _divider(),
              _row(LocalizationService.instance.t('epkTrustedAddresses'),
                  '${profile.trustedAddresses.length}'),
              _divider(),
              _row(
                  LocalizationService.instance.t('epkUnknownContracts'),
                  profile.allowUnknownContracts
                      ? LocalizationService.instance.t('epkAllowed')
                      : LocalizationService.instance.t('epkBlocked'),
                  valueColor: profile.allowUnknownContracts
                      ? GuardianColors.warning
                      : GuardianColors.success),
            ]),
            const SizedBox(height: 20),

            // ── On-chain agent ─────────────────────────────────────────────
            _sectionHeader(LocalizationService.instance.t('epkOnChainAgent')),
            _card([
              _row(
                  LocalizationService.instance.t('epkAgentAddress'),
                  epk.agentAddress == null
                      ? LocalizationService.instance.t('epkAgentNotAssigned')
                      : _fmtAddr(epk.agentAddress!)),
              _divider(),
              _row(LocalizationService.instance.t('epkAgentScope'),
                  epk.agentScope),
              _divider(),
              _row(LocalizationService.instance.t('epkAgentTtl'),
                  _fmtExpiry(epk.agentExpiry)),
            ]),
            const SizedBox(height: 20),

            // ── Operation log ──────────────────────────────────────────────
            _sectionHeader(LocalizationService.instance.t('epkOpLog')),
            _card([
              _row(LocalizationService.instance.t('epkLastAction'),
                  epk.lastAction),
              _divider(),
              _row(LocalizationService.instance.t('epkLastBlock'),
                  epk.lastBlock),
              _divider(),
              _row(LocalizationService.instance.t('epkPanicEvents'),
                  '${epk.panicEventsCount}',
                  valueColor: epk.panicEventsCount > 0
                      ? GuardianColors.danger
                      : GuardianColors.textSecondary),
            ]),
            const SizedBox(height: 32),

            // ── DANGEROUS ZONE ─────────────────────────────────────────────
            _dangerHeader(),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: GuardianColors.danger.withOpacity(0.07),
                borderRadius: BorderRadius.circular(16),
                border:
                    Border.all(color: GuardianColors.danger.withOpacity(0.3)),
              ),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(children: [
                ListTile(
                  leading: const Icon(Icons.pause_circle_outline,
                      color: GuardianColors.danger),
                  title: Text(LocalizationService.instance.t('epkPauseAction'),
                      style: GuardianTextStyles.bodyPrimary
                          .copyWith(color: GuardianColors.danger)),
                  subtitle: Text(
                      LocalizationService.instance.t('epkPauseActionDesc'),
                      style: GuardianTextStyles.bodySecondary
                          .copyWith(fontSize: 12)),
                  onTap: () => _epkService.emergencyPause(),
                ),
                if (epk.agentAddress != null) ...[
                  Divider(
                      height: 1,
                      color: GuardianColors.danger.withOpacity(0.15)),
                  ListTile(
                    leading: const Icon(Icons.person_off_outlined,
                        color: GuardianColors.danger),
                    title: Text(
                        LocalizationService.instance.t('epkRevokeAgent'),
                        style: GuardianTextStyles.bodyPrimary
                            .copyWith(color: GuardianColors.danger)),
                    subtitle: Text(
                        LocalizationService.instance.t('epkRevokeAgentDesc'),
                        style: GuardianTextStyles.bodySecondary
                            .copyWith(fontSize: 12)),
                    onTap: () => _epkService.revokeAgent(),
                  ),
                ],
              ]),
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }

  // ── Widgets ────────────────────────────────────────────────────────────────

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(title.toUpperCase(),
            style: GuardianTextStyles.caption.copyWith(
                color: GuardianColors.textSecondary,
                letterSpacing: 1.3,
                fontWeight: FontWeight.w700,
                fontSize: 11)),
      );

  Widget _dangerHeader() => Text(
      LocalizationService.instance.t('policyDangerZoneTitle').toUpperCase(),
      style: GuardianTextStyles.caption.copyWith(
          color: GuardianColors.danger,
          letterSpacing: 1.3,
          fontWeight: FontWeight.w700,
          fontSize: 11));

  Widget _card(List<Widget> items) => Container(
        decoration: BoxDecoration(
          color: GuardianColors.surface.withOpacity(0.5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: GuardianColors.border.withOpacity(0.4)),
        ),
        child: Column(children: items),
      );

  Widget _divider() => Divider(
      height: 1,
      indent: 16,
      endIndent: 16,
      color: GuardianColors.border.withOpacity(0.3));

  Widget _row(String label, String value, {Color? valueColor}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(children: [
          Expanded(
              flex: 2,
              child: Text(label,
                  style:
                      GuardianTextStyles.bodyPrimary.copyWith(fontSize: 14))),
          const SizedBox(width: 8),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GuardianTextStyles.bodySecondary.copyWith(
                    color: valueColor ?? GuardianColors.textSecondary,
                    fontSize: 14)),
          ),
        ]),
      );

  Widget _checkRow(String label, bool isActive) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: GuardianTextStyles.bodyPrimary.copyWith(fontSize: 14)),
            Icon(
              isActive ? Icons.check_circle : Icons.circle_outlined,
              color: isActive
                  ? GuardianColors.primary
                  : GuardianColors.textSecondary.withOpacity(0.3),
              size: 20,
            ),
          ],
        ),
      );

  Widget _actionChip({
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) =>
      OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color.withOpacity(0.4)),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        child: Text(label),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Compact role card
// ─────────────────────────────────────────────────────────────────────────────

class _RoleCard extends StatelessWidget {
  final VoidCallback onGoToPolicy;
  const _RoleCard({required this.onGoToPolicy});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onGoToPolicy,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: GuardianColors.surface.withOpacity(0.6),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: GuardianColors.border.withOpacity(0.4)),
        ),
        child: Row(children: [
          const Icon(Icons.policy_outlined,
              color: GuardianColors.accent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(LocalizationService.instance.t('epkRoleCard'),
                  style: GuardianTextStyles.caption.copyWith(
                      color: GuardianColors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 12)),
              Text(LocalizationService.instance.t('epkRoleCardSub'),
                  style: GuardianTextStyles.caption.copyWith(
                      color: GuardianColors.textSecondary, fontSize: 11)),
            ]),
          ),
          const Icon(Icons.arrow_forward_ios_rounded,
              size: 13, color: GuardianColors.textSecondary),
        ]),
      ),
    );
  }
}
