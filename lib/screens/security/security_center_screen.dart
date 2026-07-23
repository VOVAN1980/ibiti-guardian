import 'package:flutter/material.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/models/security_summary.dart';
import 'package:ibiti_guardian/screens/security/ai_control_screen.dart';
import 'package:ibiti_guardian/screens/security/epk_control_screen.dart';
import 'package:ibiti_guardian/screens/security/guardian_control_screen.dart';
import 'package:ibiti_guardian/screens/security/policy_limits_screen.dart';
import 'package:ibiti_guardian/services/adapters/security_adapter.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';
import 'package:ibiti_guardian/widgets/guardian_glass_card.dart';

class SecurityCenterScreen extends StatefulWidget {
  const SecurityCenterScreen({super.key});

  @override
  State<SecurityCenterScreen> createState() => _SecurityCenterScreenState();
}

class _SecurityCenterScreenState extends State<SecurityCenterScreen> {
  bool _isBootstrapped = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await PolicyProfileStore.instance.load();
    await EPKPolicyManager.instance.refreshPolicy();
    if (mounted) {
      setState(() => _isBootstrapped = true);
    }
  }

  String _formatPolicyMode(BuildContext context, PolicyMode mode) {
    final t = LocalizationProvider.of(context);
    return switch (mode) {
      PolicyMode.safe => t.t('securityPolicyModeSafe'),
      PolicyMode.defi => t.t('securityPolicyModeDefi'),
      PolicyMode.advanced => t.t('securityPolicyModeAdvanced'),
    };
  }

  String _formatAiMode(BuildContext context, AiMode mode) {
    final t = LocalizationProvider.of(context);
    return switch (mode) {
      AiMode.manual => t.t('aiControlModeManual'),
      AiMode.guarded => t.t('aiControlModeGuarded'),
      AiMode.fullAutonomy => t.t('aiControlModeFullAutonomy'),
    };
  }

  String _translateStatus(BuildContext context, String key) {
    final value = LocalizationProvider.of(context).t(key);
    return value == key
        ? LocalizationProvider.of(context).t('securityStatusSecured')
        : value;
  }

  String _executionHeadline(BuildContext context, EpkState state) {
    final t = LocalizationProvider.of(context);
    return switch (state.executionMode) {
      EPKExecutionMode.onChainEpk => t.t('securityExecOnChain'),
      EPKExecutionMode.local => t.t('securityExecLocal'),
      EPKExecutionMode.guarded => t.t('securityExecGuarded'),
      EPKExecutionMode.fallback => t.t('securityExecFallback'),
    };
  }

  String _executionStatus(BuildContext context, EpkState state) {
    final t = LocalizationProvider.of(context);
    if (!state.isActive) return t.t('securityExecPaused');
    if (state.isDeployed) return t.t('securityExecKernelReady');
    return t.t('securityExecLocalOnly');
  }

  Color _riskColor(SecuritySummary summary) {
    return switch (summary.status) {
      VerificationStatus.safe => GuardianColors.success,
      VerificationStatus.caution => GuardianColors.accent,
      VerificationStatus.warning => Colors.orange,
      VerificationStatus.dangerous => GuardianColors.danger,
    };
  }

  @override
  Widget build(BuildContext context) {
    final wallet = WalletAdapter.instance;
    final security = SecurityAdapter.instance;
    final store = PolicyProfileStore.instance;
    final ai = AiControlService.instance;
    final epk = EPKPolicyManager.instance;
    final t = LocalizationProvider.of(context);

    return Scaffold(
      backgroundColor: GuardianColors.background,
      appBar: AppBar(
        title: Text(
          t.t('securityCommandCenter'),
          style: GuardianTextStyles.headline,
        ),
        backgroundColor: GuardianColors.background,
        elevation: 0,
        centerTitle: false,
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([wallet, store, ai, epk]),
        builder: (context, _) {
          if (!wallet.isConnected) return _buildDisconnectedState();
          if (!_isBootstrapped) {
            return const Center(
              child: CircularProgressIndicator(color: GuardianColors.accent),
            );
          }

          return FutureBuilder<SecuritySummary>(
            future: security.getSummary(
              wallet.address,
              wallet.chainKey == 'bsc' || wallet.chainKey == 'ethereum'
                  ? wallet.chainId
                  : 56, // fallback for non-EVM chains
            ),
            builder: (context, snapshot) {
              if (!snapshot.hasData &&
                  snapshot.connectionState != ConnectionState.done) {
                return const Center(
                  child:
                      CircularProgressIndicator(color: GuardianColors.accent),
                );
              }

              final summary = snapshot.data ?? SecuritySummary.empty();
              return _buildDashboard(
                context,
                summary: summary,
                profile: store.current,
                aiSettings: ai.settings,
                epkState: epk.state,
              );
            },
          );
        },
      ),
    );
  }

  // ── Dashboard ──────────────────────────────────────────────────────────────

  Widget _buildDashboard(
    BuildContext context, {
    required SecuritySummary summary,
    required PolicyProfile profile,
    required AiControlSettings aiSettings,
    required EpkState epkState,
  }) {
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).padding.bottom + 16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _buildQuadProtection(context, summary, profile)),
              const SizedBox(width: 12),
              Expanded(child: _buildQuadAi(context, aiSettings)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _buildQuadPolicy(context, profile)),
              const SizedBox(width: 12),
              Expanded(child: _buildQuadExecution(context, epkState)),
            ],
          ),
          const SizedBox(height: 28),
          _buildTrustList(context, profile),
        ],
      ),
    );
  }

  // ── Quad: Protection ───────────────────────────────────────────────────────

  Widget _buildQuadProtection(
    BuildContext context,
    SecuritySummary summary,
    PolicyProfile profile,
  ) {
    final t = LocalizationProvider.of(context);
    final color = _riskColor(summary);
    final riskyCount = summary.riskyApprovalsCount;

    return _DashboardTile(
      icon: Icons.shield,
      iconColor: color,
      borderColor: color.withOpacity(0.35),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const GuardianControlScreen()),
      ),
      children: [
        Text(
          riskyCount == 0
              ? 'Safe/Panic'
              : t.t('securityRisksCount', {'count': riskyCount.toString()}),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GuardianTextStyles.headline.copyWith(
            fontSize: 18,
            color: color,
          ),
        ),
        const SizedBox(height: 6),
        _StatusLine(
          text: _translateStatus(context, summary.statusLabel),
          color: color,
          bold: true,
        ),
        _StatusLine(text: _formatPolicyMode(context, profile.mode)),
        const SizedBox(height: 6),
        _StatusLine(
          text: riskyCount == 0
              ? t.t('securityNoUrgentFixes')
              : t.t('securityReviewApprovals'),
          color: GuardianColors.textTertiary,
          fontSize: 11,
        ),
      ],
    );
  }

  // ── Quad: AI Core ──────────────────────────────────────────────────────────

  Widget _buildQuadAi(BuildContext context, AiControlSettings settings) {
    final t = LocalizationProvider.of(context);
    final color = settings.isActive
        ? GuardianColors.accent
        : GuardianColors.textSecondary;

    return _DashboardTile(
      icon: Icons.psychology,
      iconColor: color,
      borderColor: color.withOpacity(0.35),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const AIControlScreen()),
      ),
      children: [
        Text(
          t.t('securityAiCenter'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GuardianTextStyles.headline.copyWith(
            fontSize: 18,
            color: color,
          ),
        ),
        const SizedBox(height: 6),
        _StatusLine(
          text: settings.isActive
              ? t.t('securityAiPermissionsActive')
              : t.t('securityAiLocked'),
          color: color,
          bold: true,
        ),
        _StatusLine(
          text: t.t('securityAiActionsEnabled',
              {'count': settings.allowedActions.length.toString()}),
        ),
        _StatusLine(
          text: t.t('securityAiLimitsLine', {
            'daily': settings.dailyLimit.toStringAsFixed(0),
          }),
        ),
      ],
    );
  }

  // ── Quad: Policy ───────────────────────────────────────────────────────────

  Widget _buildQuadPolicy(BuildContext context, PolicyProfile profile) {
    final t = LocalizationProvider.of(context);
    final policyColor =
        profile.allowUnknownContracts ? Colors.orange : GuardianColors.accent;
    final ai = AiControlService.instance.settings;

    return _DashboardTile(
      icon: Icons.tune,
      iconColor: policyColor,
      borderColor: policyColor.withOpacity(0.35),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const PolicyLimitsScreen()),
      ),
      children: [
        Text(
          t.t('policyTitle'),
          style: GuardianTextStyles.headline.copyWith(
            fontSize: 18,
            color: policyColor,
          ),
        ),
        const SizedBox(height: 2),
        _StatusLine(
          text: '${t.t('securityDailySendLimit')}: \$${profile.sendLimitUsd.toInt()}',
        ),
        const SizedBox(height: 6),
        _StatusLine(
          text: t.t(
              'securityAiModeLabel', {'mode': _formatAiMode(context, ai.mode)}),
          color: policyColor,
          bold: true,
        ),
        _StatusLine(
          text: profile.allowUnknownContracts
              ? t.t('securityUnknownAllowed')
              : t.t('securityUnknownBlocked'),
          color: profile.allowUnknownContracts
              ? Colors.orange
              : GuardianColors.success,
          fontSize: 11,
        ),
      ],
    );
  }

  // ── Quad: Execution (EPK) ──────────────────────────────────────────────────

  Widget _buildQuadExecution(BuildContext context, EpkState state) {
    final t = LocalizationProvider.of(context);
    final color = state.isDeployed
        ? GuardianColors.success
        : GuardianColors.textSecondary;

    return _DashboardTile(
      icon: Icons.lock_person,
      iconColor: color,
      borderColor: color.withOpacity(0.35),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const EPKControlScreen()),
      ),
      children: [
        Text(
          _executionHeadline(context, state),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: GuardianTextStyles.headline.copyWith(
            fontSize: 16,
            color: color,
          ),
        ),
        const SizedBox(height: 6),
        _StatusLine(
          text: _executionStatus(context, state),
          color: color,
          bold: true,
        ),
        _StatusLine(
          text: t.t('securityAiLimitsLine', {
            'tx': state.perTxLimit.toStringAsFixed(0),
            'daily': state.dailyLimit.toStringAsFixed(0),
          }),
        ),
        _StatusLine(
          text: state.agentAddress == null
              ? t.t('securityAgentNotAssigned')
              : '${state.agentAddress!.substring(0, 6)}…${state.agentAddress!.substring(state.agentAddress!.length - 4)}',
          color: GuardianColors.textTertiary,
          fontSize: 11,
        ),
      ],
    );
  }

  // ── Trust List ─────────────────────────────────────────────────────────────

  Widget _buildTrustList(BuildContext context, PolicyProfile profile) {
    final t = LocalizationProvider.of(context);
    final trustedItems = <MapEntry<String, String>>[
      ...profile.trustedAddresses
          .map((item) => MapEntry(t.t('securityTrustTypeAddress'), item)),
      ...profile.trustedContracts
          .map((item) => MapEntry(t.t('securityTrustTypeContract'), item)),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.t('securityTrustedEntities'),
            style: GuardianTextStyles.titleMedium),
        const SizedBox(height: 16),
        if (trustedItems.isEmpty)
          Text(
            t.t('securityNoTrusted'),
            style: GuardianTextStyles.bodySecondary,
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: trustedItems.length,
            separatorBuilder: (_, __) =>
                const Divider(color: GuardianColors.glassBorder),
            itemBuilder: (context, i) {
              final item = trustedItems[i];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.verified,
                  color: GuardianColors.accent,
                ),
                title: Text(
                  item.value,
                  style: GuardianTextStyles.bodyPrimary.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
                subtitle: Text(
                  item.key,
                  style: GuardianTextStyles.caption,
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _buildDisconnectedState() {
    final t = LocalizationProvider.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.lock_outline,
            size: 64,
            color: GuardianColors.glassBorder,
          ),
          const SizedBox(height: 16),
          Text(
            t.t('securityWalletDisconnected'),
            style: GuardianTextStyles.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            t.t('securityConnectPrompt'),
            style: GuardianTextStyles.bodySecondary,
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// ── Reusable widgets ─────────────────────────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════════

/// Single status line inside a dashboard tile.
/// Always truncates with ellipsis to prevent overflow in narrow tiles.
class _StatusLine extends StatelessWidget {
  final String text;
  final Color? color;
  final bool bold;
  final double fontSize;

  const _StatusLine({
    required this.text,
    this.color,
    this.bold = false,
    this.fontSize = 12,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: GuardianTextStyles.caption.copyWith(
          color: color,
          fontWeight: bold ? FontWeight.bold : null,
          fontSize: fontSize,
        ),
      ),
    );
  }
}

/// Compact dashboard tile for the 2×2 Command Center grid.
/// Shows icon + key metrics only. Taps navigate to full detail screens.
class _DashboardTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color borderColor;
  final List<Widget> children;
  final VoidCallback? onTap;

  const _DashboardTile({
    required this.icon,
    required this.iconColor,
    required this.borderColor,
    required this.children,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: GuardianGlassCard(
        padding: const EdgeInsets.all(3),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor, width: 1.2),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                iconColor.withOpacity(0.12),
                Colors.white.withOpacity(0.03),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: iconColor.withOpacity(0.10),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: iconColor.withOpacity(0.14),
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(
                          color: iconColor.withOpacity(0.22),
                        ),
                      ),
                      child: Icon(icon, size: 15, color: iconColor),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.north_east_rounded,
                      size: 13,
                      color: Colors.white.withOpacity(0.45),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
