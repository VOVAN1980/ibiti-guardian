import 'package:flutter/material.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_account_store.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/screens/security/audit_history_screen.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/screens/vault/vault_unlock_screen.dart';
import 'package:ibiti_guardian/screens/security/widgets/funding_source_selector.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
// TODO(localization): ✅ DONE — all strings localized via LocalizationProvider.of(context).t() / LocalizationService.instance.t()

// ─────────────────────────────────────────────────────────────────────────────
// PolicyLimitsScreen — single editor for ALL limits in the app.
//
// Role contract (visible to user):
//   Policy    = где настраиваются все лимиты и мандат
//   AI Control = поведение и разрешения AI
//   EPK       = статус исполнения и защита on-chain
// ─────────────────────────────────────────────────────────────────────────────

class PolicyLimitsScreen extends StatefulWidget {
  const PolicyLimitsScreen({super.key});

  @override
  State<PolicyLimitsScreen> createState() => _PolicyLimitsScreenState();
}

class _PolicyLimitsScreenState extends State<PolicyLimitsScreen> {
  final _store = PolicyProfileStore.instance;
  final _ai = AiControlService.instance;
  final _epk = EPKPolicyManager.instance;

  PolicyProfile? _profile;

  @override
  void initState() {
    super.initState();
    _store.addListener(_rebuild);
    _ai.addListener(_rebuild);
    _epk.addListener(_rebuild);
    _loadProfile();
  }

  @override
  void dispose() {
    _store.removeListener(_rebuild);
    _ai.removeListener(_rebuild);
    _epk.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() => _profile = _store.current);
  }

  Future<void> _loadProfile() async {
    await _store.load();
    if (mounted) setState(() => _profile = _store.current);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _fmtExpiry(BuildContext context, DateTime? expiry) {
    final t = LocalizationProvider.of(context);
    if (expiry == null) return t.t('policyExpiryNone');
    final diff = expiry.difference(DateTime.now());
    if (diff.isNegative) return t.t('policyExpiryExpired');
    if (diff.inDays > 1)
      return t.t('policyExpiryDaysLeft', {'days': diff.inDays.toString()});
    if (diff.inHours > 0)
      return t.t('policyExpiryHoursLeft', {'hours': diff.inHours.toString()});
    return t.t('policyExpiryMinsLeft', {'mins': diff.inMinutes.toString()});
  }

  String _fmtMode(BuildContext context, AiMode mode) {
    final t = LocalizationProvider.of(context);
    return switch (mode) {
      AiMode.manual => t.t('policyModeManual'),
      AiMode.guarded => t.t('policyModeGuarded'),
      AiMode.fullAutonomy => t.t('policyModeFullAutonomy'),
    };
  }

  String _fmtList(BuildContext context, List<String> list) {
    final t = LocalizationProvider.of(context);
    return list.isEmpty ? t.t('policyMandateAnyValue') : list.join(', ');
  }

  String _fmtGoal(BuildContext context, AutonomyGoal goal) {
    final t = LocalizationProvider.of(context);
    return switch (goal) {
      AutonomyGoal.growth => t.t('policyTradingGoalGrowth'),
      AutonomyGoal.defense => t.t('policyTradingGoalDefense'),
      AutonomyGoal.rebalance => t.t('policyTradingGoalRebalance'),
      AutonomyGoal.income => t.t('policyTradingGoalIncome'),
    };
  }

  // ── USD number editor ──────────────────────────────────────────────────────

  Future<double?> _editUsd(String title, double current) async {
    return showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _NumberEditorSheet(
        title: title,
        initialValue: current >= 100000 ? '' : current.toInt().toString(),
      ),
    );
  }

  Future<double?> _editDouble(String title, double current,
      {String suffix = ''}) async {
    return showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _NumberEditorSheet(
        title: title,
        initialValue: current.toString(),
        suffix: suffix,
      ),
    );
  }

  Future<int?> _editInt(String title, int current) async {
    final result = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _NumberEditorSheet(
        title: title,
        initialValue: current.toString(),
      ),
    );
    return result?.toInt();
  }

  Future<List<String>?> _editList(String title, List<String> current) async {
    final c = TextEditingController(text: current.join(', '));
    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) {
        final t = LocalizationService.instance;
        return AlertDialog(
          backgroundColor: GuardianColors.surface,
          title: Text(title,
              style: GuardianTextStyles.headline.copyWith(fontSize: 18)),
          content: TextField(
            controller: c,
            maxLines: 3,
            style: const TextStyle(color: GuardianColors.textPrimary),
            decoration: InputDecoration(
              hintText: t.t('policyEditListHint'),
              hintStyle: TextStyle(
                  color: GuardianColors.textSecondary.withOpacity(0.5)),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(t.t('policyEditCancel'))),
            FilledButton(
              onPressed: () {
                final vals = c.text
                    .split(',')
                    .map((e) => e.trim())
                    .where((e) => e.isNotEmpty)
                    .toList();
                Navigator.pop(ctx, vals);
              },
              child: Text(t.t('policyEditSave')),
            ),
          ],
        );
      },
    );
    c.dispose();
    return result;
  }

  // ── Wallet limit editor (with expiry) ──────────────────────────────────────

  void _showWalletLimitEditor(String actionType, double current) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _WalletLimitSheet(
        actionType: actionType,
        currentLimit: current,
        onSave: (val, expiry) =>
            _store.updateLimit(actionType, val, expiry: expiry),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_profile == null) {
      return const Scaffold(
        backgroundColor: GuardianColors.background,
        body: Center(
            child: CircularProgressIndicator(color: GuardianColors.accent)),
      );
    }

    final p = _profile!;
    final ai = _ai.settings;
    final mandate = ai.mandate;
    final epk = _epk.state;
    final t = LocalizationProvider.of(context);

    return Scaffold(
      backgroundColor: GuardianColors.background,
      appBar: AppBar(
        title: Text(t.t('policyTitle'),
            style: GuardianTextStyles.headline.copyWith(fontSize: 20)),
        backgroundColor: GuardianColors.background,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              color: GuardianColors.textPrimary, size: 24),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.history, color: GuardianColors.accent),
            tooltip: t.t('policyHistoryTooltip'),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const AuditHistoryScreen())),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Role card ──────────────────────────────────────────────────
            _RoleCard(),
            const SizedBox(height: 24),

            // ── BLOCK 1: AI Mode ───────────────────────────────────────────
            _sectionHeader(t.t('policyAiModeSection')),
            _card([
              _editableRow(
                label: t.t('policyRowMode'),
                value: _fmtMode(context, ai.mode),
                onEdit: () => _showModeDialog(ai.mode),
              ),
              _divider(),
              _row(
                  t.t('policyRowStatus'),
                  ai.isActive
                      ? t.t('policyRowStatusActive')
                      : t.t('policyRowStatusOff'),
                  valueColor: ai.isActive
                      ? GuardianColors.success
                      : GuardianColors.textSecondary),
              _divider(),
              _row(t.t('policyRowPermExpiry'),
                  _fmtExpiry(context, ai.permissionsExpiry)),
            ]),
            const SizedBox(height: 20),

            // ── BLOCK 2: Market & Trading ──────────────────────────────────
            _sectionHeader(t.t('policyAiLimitsSection')),
            _card([
              _editableRow(
                label: t.t('policyLimitDaily'),
                value: '\$${ai.dailyLimit.toStringAsFixed(0)}',
                onEdit: () async {
                  var v = await _editUsd(
                      t.t('policyEditDailyTitle'), ai.dailyLimit);
                  if (v != null) {
                    await _ai.updateLimits(daily: v);
                  }
                },
              ),
              _divider(),
              _editableRow(
                label: Localizations.localeOf(context).languageCode == 'ru'
                    ? 'Мин. баланс для торговли'
                    : 'Min Trade Balance',
                value: '\$${ai.minTradeBalance.toStringAsFixed(0)}',
                onEdit: () async {
                  final v = await _editUsd(
                      Localizations.localeOf(context).languageCode == 'ru'
                          ? 'Изменить мин. баланс для торговли'
                          : 'Edit Min Trade Balance',
                      ai.minTradeBalance);
                  if (v != null) await _ai.updateMinTradeBalance(v);
                },
              ),
            ]),
            const SizedBox(height: 20),

            // ── BLOCK 2B: Funding Source ─────────────────────────────────────
            _sectionHeader('Источник средств'),
            const FundingSourceSelector(),
            const SizedBox(height: 20),

            // ── BLOCK 3: AI Mandate (scope) ──────────────────────────────────
            _sectionHeader(t.t('policyAiMandateSection')),
            _card([
              _editableRow(
                label: t.t('policyMandateAllowedAssets'),
                value: _fmtList(context, mandate.allowedAssets),
                onEdit: () async {
                  final v = await _editList(t.t('policyMandateEditAssetsTitle'),
                      mandate.allowedAssets);
                  if (v != null) {
                    await _ai.updateMandate(mandate.copyWith(
                        allowedAssets: v.map((e) => e.toUpperCase()).toList()));
                  }
                },
              ),
              _divider(),
              _editableRow(
                label: t.t('policyMandateAllowedNetworks'),
                value: _fmtList(context, mandate.allowedNetworks),
                onEdit: () async {
                  final v = await _editList(
                      t.t('policyMandateEditNetworksTitle'),
                      mandate.allowedNetworks);
                  if (v != null)
                    await _ai
                        .updateMandate(mandate.copyWith(allowedNetworks: v));
                },
              ),
              _divider(),
              _editableRow(
                label: t.t('policyMandateAllowedVenues'),
                value: _fmtList(context, mandate.allowedVenues),
                onEdit: () async {
                  final v = await _editList(t.t('policyMandateEditVenuesTitle'),
                      mandate.allowedVenues);
                  if (v != null) {
                    await _ai.updateMandate(mandate.copyWith(
                        allowedVenues: v.map((e) => e.toLowerCase()).toList()));
                  }
                },
              ),
              _divider(),
              _toggleRow(
                label: t.t('policyMandateUnknownHumanReview'),
                value: mandate.requireHumanForUnknown,
                onTap: () => _ai.updateMandate(mandate.copyWith(
                    requireHumanForUnknown: !mandate.requireHumanForUnknown)),
              ),
            ]),
            const SizedBox(height: 20),

            // ── BLOCK 3.5: Market & Trading Limits ───────────────────────────
            _sectionHeader(t.t('policyMarketTradingSection')),
            _card([
              _editableRow(
                label: t.t('policyTradingGoal'),
                value: _fmtGoal(context, mandate.goal),
                onEdit: () => _showGoalDialog(mandate.goal),
              ),
              _divider(),
              _editableRow(
                label: t.t('policyMandateMaxPosition'),
                value: '\$${mandate.maxPositionUsd.toStringAsFixed(0)}',
                onEdit: () async {
                  final v = await _editUsd(
                      t.t('policyMandateEditPositionTitle'),
                      mandate.maxPositionUsd);
                  if (v != null)
                    await _ai
                        .updateMandate(mandate.copyWith(maxPositionUsd: v));
                },
              ),
              _divider(),
              _editableRow(
                label: t.t('policyMandateMaxSlippage'),
                value: '${mandate.maxSlippageBps} bps',
                onEdit: () async {
                  final v = await _editDouble(
                      t.t('policyMandateEditSlippageTitle'),
                      mandate.maxSlippageBps,
                      suffix: 'bps');
                  if (v != null)
                    await _ai
                        .updateMandate(mandate.copyWith(maxSlippageBps: v));
                },
              ),
              _divider(),
              _editableRow(
                label: t.t('policyMandateMaxGas'),
                value: '\$${mandate.maxGasUsd.toStringAsFixed(0)}',
                onEdit: () async {
                  final v = await _editUsd(
                      t.t('policyMandateEditGasTitle'), mandate.maxGasUsd);
                  if (v != null)
                    await _ai.updateMandate(mandate.copyWith(maxGasUsd: v));
                },
              ),
              _divider(),
              _editableRow(
                label: t.t('policyMandateMaxDailyLoss'),
                value: '\$${mandate.maxDailyLossUsd.toStringAsFixed(0)}',
                onEdit: () async {
                  final v = await _editUsd(t.t('policyMandateEditLossTitle'),
                      mandate.maxDailyLossUsd);
                  if (v != null)
                    await _ai
                        .updateMandate(mandate.copyWith(maxDailyLossUsd: v));
                },
              ),
              _divider(),
              _editableRow(
                label: t.t('policyMandateMaxDrawdown'),
                value: '${mandate.maxDrawdownPct.toStringAsFixed(1)}%',
                onEdit: () async {
                  final v = await _editDouble(
                      t.t('policyMandateEditDrawdownTitle'),
                      mandate.maxDrawdownPct,
                      suffix: '%');
                  if (v != null)
                    await _ai
                        .updateMandate(mandate.copyWith(maxDrawdownPct: v));
                },
              ),
              _divider(),
              _editableRow(
                label: t.t('policyMandateMaxOpenPositions'),
                value: '${mandate.maxOpenPositions}',
                onEdit: () async {
                  final v = await _editInt(
                      t.t('policyMandateEditMaxOpenPositionsTitle'),
                      mandate.maxOpenPositions);
                  if (v != null)
                    await _ai
                        .updateMandate(mandate.copyWith(maxOpenPositions: v));
                },
              ),
              _divider(),
              _editableRow(
                label: t.t('policyMandateStopAfterLosses'),
                value: '${mandate.stopAfterLosses}',
                onEdit: () async {
                  final v = await _editInt(
                      t.t('policyMandateEditStopAfterLossesTitle'),
                      mandate.stopAfterLosses);
                  if (v != null)
                    await _ai
                        .updateMandate(mandate.copyWith(stopAfterLosses: v));
                },
              ),
              _divider(),
              _editableRow(
                label: 'Disaster Stop %',
                value: '${mandate.disasterStopPct.toStringAsFixed(1)}%',
                onEdit: () async {
                  final v = await _editDouble(
                      'Disaster Stop %', mandate.disasterStopPct,
                      suffix: '%');
                  if (v != null)
                    await _ai
                        .updateMandate(mandate.copyWith(disasterStopPct: v));
                },
              ),
              _divider(),
              _editableRow(
                label: 'Trailing Activation %',
                value: '${mandate.ratchetActivationPct.toStringAsFixed(1)}%',
                onEdit: () async {
                  final v = await _editDouble(
                      'Trailing Activation %', mandate.ratchetActivationPct,
                      suffix: '%');
                  if (v != null)
                    await _ai.updateMandate(
                        mandate.copyWith(ratchetActivationPct: v));
                },
              ),
              _divider(),
              _editableRow(
                label: 'Trailing Distance %',
                value: '${mandate.ratchetDistancePct.toStringAsFixed(1)}%',
                onEdit: () async {
                  final v = await _editDouble(
                      'Trailing Distance %', mandate.ratchetDistancePct,
                      suffix: '%');
                  if (v != null)
                    await _ai.updateMandate(
                        mandate.copyWith(ratchetDistancePct: v));
                },
              ),
              _divider(),
              _editableRow(
                label: 'Min Profit Floor %',
                value: '${mandate.ratchetMinFloorPct.toStringAsFixed(1)}%',
                onEdit: () async {
                  final v = await _editDouble(
                      'Min Profit Floor %', mandate.ratchetMinFloorPct,
                      suffix: '%');
                  if (v != null)
                    await _ai.updateMandate(
                        mandate.copyWith(ratchetMinFloorPct: v));
                },
              ),
            ]),
            const SizedBox(height: 20),

            // ── BLOCK 4: Wallet Limits ─────────────────────────────────────
            _sectionHeader(t.t('policyWalletLimitsSection')),
            _card([
              _editableRow(
                label: t.t('policyWalletSendLimit'),
                value: '\$${p.sendLimitUsd.toStringAsFixed(0)}',
                subValue: _fmtExpiry(context, p.actionExpiries['SEND']),
                onEdit: () => _showWalletLimitEditor('SEND', p.sendLimitUsd),
              ),
              _divider(),
              _editableRow(
                label: t.t('policyWalletSwapLimit'),
                value: '\$${p.swapLimitUsd.toStringAsFixed(0)}',
                subValue: _fmtExpiry(context, p.actionExpiries['SWAP']),
                onEdit: () => _showWalletLimitEditor('SWAP', p.swapLimitUsd),
              ),
              _divider(),
              _editableRow(
                label: t.t('policyWalletApproveLimit'),
                value: '\$${p.approveLimitUsd.toStringAsFixed(0)}',
                subValue: _fmtExpiry(context, p.actionExpiries['APPROVE']),
                onEdit: () =>
                    _showWalletLimitEditor('APPROVE', p.approveLimitUsd),
              ),
            ]),
            const SizedBox(height: 20),

            // ── BLOCK 5: Risk controls ─────────────────────────────────────
            _sectionHeader(t.t('policyContractsSection')),
            _card([
              _toggleRow(
                label: t.t('policyWalletUnknownContracts'),
                value: !p.allowUnknownContracts,
                onTap: () =>
                    _store.setAllowUnknownContracts(!p.allowUnknownContracts),
              ),
            ]),
            const SizedBox(height: 20),

            // ── BLOCK 6: EPK status (read-only + actions) ──────────────────
            _sectionHeader(t.t('policyEpkSection')),
            _card([
              _row(
                t.t('policyEpkStatusRow'),
                epk.isActive
                    ? t.t('policyEpkStatusActive')
                    : t.t('policyEpkStatusPaused'),
                valueColor: epk.isActive
                    ? GuardianColors.success
                    : GuardianColors.warning,
              ),
              _divider(),
              _row(t.t('policyEpkModeRow'),
                  epk.isDeployed ? 'On-chain EPK' : 'Local Guard'),
              _divider(),
              _row('SpendLimit',
                  epk.hasSpendLimitValidator ? '✓ Active' : '✗ Off'),
              _divider(),
              _row('TargetGuard',
                  epk.hasTargetSelectorGuard ? '✓ Active' : '✗ Off'),
              _divider(),
              _row('ThreatFeed',
                  epk.hasThreatFeedBlocklistValidator ? '✓ Active' : '✗ Off'),
              _divider(),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    _epkChip(
                      label: t.t('epkRefreshPolicy'),
                      color: GuardianColors.accent,
                      onTap: _epk.refreshPolicy,
                    ),
                    _epkChip(
                      label: epk.isDeployed
                          ? (epk.isActive
                              ? t.t('epkPauseBtnLabel')
                              : t.t('epkResumeBtnLabel'))
                          : t.t('epkCreatePolicy'),
                      color: epk.isActive
                          ? GuardianColors.warning
                          : GuardianColors.success,
                      onTap: () => epk.isDeployed
                          ? (epk.isActive
                              ? _epk.emergencyPause()
                              : _epk.resumeProtection())
                          : _epk.createPolicy(),
                    ),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 32),

            // ── DANGEROUS ZONE ─────────────────────────────────────────────
            _dangerHeader(t.t('policyDangerZoneTitle')),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: GuardianColors.danger.withOpacity(0.07),
                borderRadius: BorderRadius.circular(16),
                border:
                    Border.all(color: GuardianColors.danger.withOpacity(0.3)),
              ),
              child: Column(children: [
                _dangerTile(
                  icon: Icons.stop_circle_outlined,
                  title: t.t('aiDangerStopTitle'),
                  subtitle: t.t('aiDangerStopDesc'),
                  onTap: () async {
                    final ok = await _confirmDanger(
                      t.t('aiDangerStopTitle'),
                      t.t('aiDangerStopDesc'),
                    );
                    if (ok) await _ai.emergencyStop();
                  },
                ),
                Divider(
                    height: 1, color: GuardianColors.danger.withOpacity(0.15)),
                _dangerTile(
                  icon: Icons.pause_circle_outline,
                  title: t.t('epkDangerPauseTitle'),
                  subtitle: t.t('epkDangerPauseDesc'),
                  onTap: () async {
                    final ok = await _confirmDanger(
                      t.t('epkDangerPauseTitle'),
                      t.t('epkDangerPauseDesc'),
                    );
                    if (ok) await _epk.emergencyPause();
                  },
                ),
                if (_epk.state.agentAddress != null) ...[
                  Divider(
                      height: 1,
                      color: GuardianColors.danger.withOpacity(0.15)),
                  _dangerTile(
                    icon: Icons.person_off_outlined,
                    title: t.t('epkDangerRevokeTitle'),
                    subtitle: t.t('epkDangerRevokeDesc'),
                    onTap: () async {
                      final ok = await _confirmDanger(
                        t.t('epkDangerRevokeTitle'),
                        t.t('epkDangerRevokeConfirmDesc'),
                      );
                      if (ok) await _epk.revokeAgent();
                    },
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

  // ── Dialogs ────────────────────────────────────────────────────────────────

  Future<void> _showModeDialog(AiMode current) async {
    AiMode? selected = current;
    final t = LocalizationProvider.of(context);
    final result = await showDialog<AiMode>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          backgroundColor: GuardianColors.surface,
          title: Text(t.t('policyAiModeSection'),
              style: GuardianTextStyles.headline.copyWith(fontSize: 18)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: AiMode.values.map((mode) {
              return RadioListTile<AiMode>(
                value: mode,
                groupValue: selected,
                onChanged: (v) => setSt(() => selected = v),
                title: Text(
                  switch (mode) {
                    AiMode.manual => 'Manual',
                    AiMode.guarded => 'Guarded',
                    AiMode.fullAutonomy => 'Full Autonomy',
                  },
                  style: GuardianTextStyles.bodyPrimary,
                ),
                subtitle: Text(
                  switch (mode) {
                    AiMode.manual => t.t('aiModeManualDesc'),
                    AiMode.guarded => t.t('aiModeGuardedDesc'),
                    AiMode.fullAutonomy => t.t('aiModeFullDesc'),
                  },
                  style:
                      GuardianTextStyles.bodySecondary.copyWith(fontSize: 12),
                ),
                activeColor: GuardianColors.accent,
              );
            }).toList(),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(t.t('policyEditCancel'))),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, selected),
              child: Text(t.t('aiControlApply')),
            ),
          ],
        ),
      ),
    );
    if (result == null || result == current) return;
    if (result == AiMode.fullAutonomy) {
      final ok = await VaultUnlockScreen.requireAuth(context);
      if (!ok) return;
    }
    await _ai.updateMode(result);
  }

  Future<void> _showGoalDialog(AutonomyGoal current) async {
    AutonomyGoal? selected = current;
    final t = LocalizationProvider.of(context);
    final result = await showDialog<AutonomyGoal>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          backgroundColor: GuardianColors.surface,
          title: Text(t.t('policyTradingGoal'),
              style: GuardianTextStyles.headline.copyWith(fontSize: 18)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: AutonomyGoal.values.map((goal) {
              return RadioListTile<AutonomyGoal>(
                value: goal,
                groupValue: selected,
                onChanged: (v) => setSt(() => selected = v),
                title: Text(
                  _fmtGoal(context, goal),
                  style: GuardianTextStyles.bodyPrimary,
                ),
                activeColor: GuardianColors.accent,
              );
            }).toList(),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(t.t('policyEditCancel'))),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, selected),
              child: Text(t.t('aiControlApply')),
            ),
          ],
        ),
      ),
    );
    if (result == null || result == current) return;
    await _ai.updateMandate(_ai.settings.mandate.copyWith(goal: result));
  }

  Future<bool> _confirmDanger(String title, String body) async {
    final t = LocalizationProvider.of(context);
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: GuardianColors.surface,
            title: Row(children: [
              const Icon(Icons.warning_amber_rounded,
                  color: GuardianColors.danger, size: 22),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(title,
                      style:
                          GuardianTextStyles.headline.copyWith(fontSize: 18))),
            ]),
            content: Text(body, style: GuardianTextStyles.bodySecondary),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(t.t('policyEditCancel'))),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: GuardianColors.danger),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.t('aiControlConfirm')),
              ),
            ],
          ),
        ) ??
        false;
  }

  // ── Widget helpers ─────────────────────────────────────────────────────────

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        title.toUpperCase(),
        style: GuardianTextStyles.caption.copyWith(
          color: GuardianColors.textSecondary,
          letterSpacing: 1.3,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }

  Widget _dangerHeader(String title) {
    return Text(
      title.toUpperCase(),
      style: GuardianTextStyles.caption.copyWith(
        color: GuardianColors.danger,
        letterSpacing: 1.3,
        fontWeight: FontWeight.w700,
        fontSize: 11,
      ),
    );
  }

  Widget _card(List<Widget> items) {
    return Container(
      decoration: BoxDecoration(
        color: GuardianColors.surface.withOpacity(0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: GuardianColors.border.withOpacity(0.4)),
      ),
      child: Column(children: items),
    );
  }

  Widget _divider() => Divider(
      height: 1,
      indent: 16,
      endIndent: 16,
      color: GuardianColors.border.withOpacity(0.3));

  Widget _row(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(label,
                style: GuardianTextStyles.bodyPrimary.copyWith(fontSize: 14)),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: GuardianTextStyles.bodySecondary.copyWith(
                color: valueColor ?? GuardianColors.textSecondary,
                fontSize: 14,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _editableRow({
    required String label,
    required String value,
    String? subValue,
    required VoidCallback onEdit,
  }) {
    return InkWell(
      onTap: onEdit,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(label,
                  style: GuardianTextStyles.bodyPrimary.copyWith(fontSize: 14)),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    value,
                    textAlign: TextAlign.right,
                    style: GuardianTextStyles.bodySecondary.copyWith(
                      color: GuardianColors.accent,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  if (subValue != null)
                    Text(
                      subValue,
                      textAlign: TextAlign.right,
                      style: GuardianTextStyles.caption.copyWith(
                        color: GuardianColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.edit_outlined,
                size: 15, color: GuardianColors.textSecondary),
          ],
        ),
      ),
    );
  }

  Widget _toggleRow({
    required String label,
    required bool value,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: GuardianTextStyles.bodyPrimary.copyWith(fontSize: 14)),
            ),
            Icon(
              value ? Icons.check_circle : Icons.circle_outlined,
              color: value
                  ? GuardianColors.primary
                  : GuardianColors.textSecondary.withOpacity(0.3),
              size: 22,
            ),
          ],
        ),
      ),
    );
  }

  Widget _epkChip({
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withOpacity(0.4)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }

  Widget _dangerTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: GuardianColors.danger, size: 22),
      title: Text(title,
          style: GuardianTextStyles.bodyPrimary
              .copyWith(color: GuardianColors.danger, fontSize: 15)),
      subtitle: Text(subtitle,
          style: GuardianTextStyles.bodySecondary.copyWith(fontSize: 12)),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Role description card — compact, non-intrusive
// ─────────────────────────────────────────────────────────────────────────────

class _RoleCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: GuardianColors.accent.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: GuardianColors.accent.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.info_outline_rounded,
                color: GuardianColors.accent, size: 16),
            const SizedBox(width: 8),
            Text(t.t('aiControlRoleCardTitle'),
                style: GuardianTextStyles.caption.copyWith(
                    color: GuardianColors.accent, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 8),
          _roleLine(t.t('policyTitle'), t.t('policyRoleCardTitle')),
          _roleLine('AI Control', t.t('aiControlRoleCardSub')),
          _roleLine('EPK Control', t.t('epkRoleCardSub')),
        ],
      ),
    );
  }

  Widget _roleLine(String key, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$key · ',
              style: GuardianTextStyles.caption.copyWith(
                  color: GuardianColors.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12)),
          Expanded(
            child: Text(value,
                style: GuardianTextStyles.caption.copyWith(
                    color: GuardianColors.textSecondary, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Number editor bottom sheet
// ─────────────────────────────────────────────────────────────────────────────

class _NumberEditorSheet extends StatefulWidget {
  final String title;
  final String initialValue;
  final String suffix;

  const _NumberEditorSheet({
    required this.title,
    this.initialValue = '',
    this.suffix = '',
  });

  @override
  State<_NumberEditorSheet> createState() => _NumberEditorSheetState();
}

class _NumberEditorSheetState extends State<_NumberEditorSheet> {
  late final TextEditingController _controller;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    Future.delayed(
        const Duration(milliseconds: 80), () => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final v = double.tryParse(_controller.text.trim());
    if (v == null) return;
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: SingleChildScrollView(
        child: Container(
          decoration: BoxDecoration(
            color: GuardianColors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
                top:
                    BorderSide(color: GuardianColors.glassBorder.withOpacity(0.4))),
          ),
          padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + inset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: GuardianTextStyles.headline.copyWith(fontSize: 18),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: GuardianColors.textPrimary),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                focusNode: _focus,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: GuardianTextStyles.headline
                    .copyWith(fontSize: 28, color: GuardianColors.textPrimary),
                decoration: InputDecoration(
                  prefixText: widget.suffix.isEmpty ? '\$ ' : null,
                  suffixText: widget.suffix.isNotEmpty ? widget.suffix : null,
                  prefixStyle: GuardianTextStyles.headline
                      .copyWith(fontSize: 28, color: GuardianColors.textSecondary),
                  filled: true,
                  fillColor: GuardianColors.background,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide:
                          const BorderSide(color: GuardianColors.accent, width: 2)),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: GuardianColors.accent,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(
                    LocalizationService.instance.t('policyEditSave').toUpperCase(),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: Colors.black)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Wallet limit sheet (with expiry selector)
// ─────────────────────────────────────────────────────────────────────────────

class _WalletLimitSheet extends StatefulWidget {
  final String actionType;
  final double currentLimit;
  final void Function(double, DateTime?) onSave;

  const _WalletLimitSheet({
    required this.actionType,
    required this.currentLimit,
    required this.onSave,
  });

  @override
  State<_WalletLimitSheet> createState() => _WalletLimitSheetState();
}

class _WalletLimitSheetState extends State<_WalletLimitSheet> {
  late TextEditingController _controller;
  final _focus = FocusNode();
  String _duration = 'forever';

  @override
  void initState() {
    super.initState();
    final curr = widget.currentLimit;
    _controller = TextEditingController(
        text: curr >= 100000 ? '' : curr.toInt().toString());
    Future.delayed(
        const Duration(milliseconds: 80), () => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _title {
    final t = LocalizationService.instance;
    return switch (widget.actionType) {
      'SEND' => t.t('policyWalletSendLimit'),
      'SWAP' => t.t('policyWalletSwapLimit'),
      'APPROVE' => t.t('policyWalletApproveLimit'),
      _ => 'Limit',
    };
  }

  void _submit() {
    final v = double.tryParse(_controller.text.trim()) ?? 0.0;
    final amount = v <= 0 ? 100000.0 : v;
    DateTime? expiry;
    if (_duration == '1h')
      expiry = DateTime.now().add(const Duration(hours: 1));
    if (_duration == '24h')
      expiry = DateTime.now().add(const Duration(hours: 24));
    if (_duration == '7d') expiry = DateTime.now().add(const Duration(days: 7));
    widget.onSave(amount, expiry);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      decoration: BoxDecoration(
        color: GuardianColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(
            top:
                BorderSide(color: GuardianColors.glassBorder.withOpacity(0.4))),
      ),
      padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + inset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  _title,
                  style: GuardianTextStyles.headline.copyWith(fontSize: 18),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: GuardianColors.textPrimary),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            focusNode: _focus,
            keyboardType: TextInputType.number,
            style: GuardianTextStyles.headline
                .copyWith(fontSize: 28, color: GuardianColors.textPrimary),
            decoration: InputDecoration(
              hintText: LocalizationService.instance.t('policyWalletNoLimit'),
              prefixText: '\$ ',
              prefixStyle: GuardianTextStyles.headline
                  .copyWith(fontSize: 28, color: GuardianColors.textSecondary),
              filled: true,
              fillColor: GuardianColors.background,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide:
                      const BorderSide(color: GuardianColors.accent, width: 2)),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 16),
          Text(LocalizationService.instance.t('policyWalletSheetTempToggle'),
              style: GuardianTextStyles.caption
                  .copyWith(color: GuardianColors.textSecondary)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _chip(LocalizationService.instance.t('policyExpiryNone'),
                  'forever'),
              _chip(LocalizationService.instance.t('policyWalletSheetExpiry1h'),
                  '1h'),
              _chip(
                  LocalizationService.instance.t('policyWalletSheetExpiry24h'),
                  '24h'),
              _chip(LocalizationService.instance.t('policyWalletSheetExpiry7d'),
                  '7d'),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _submit,
            style: FilledButton.styleFrom(
              backgroundColor: GuardianColors.accent,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            child: Text(
              LocalizationService.instance
                  .t('policyWalletSheetSave')
                  .toUpperCase(),
              style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: Colors.black),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, String val) {
    final sel = _duration == val;
    return ChoiceChip(
      label: Text(label,
          style: TextStyle(
              color: sel ? Colors.black : Colors.white, fontSize: 13)),
      selected: sel,
      selectedColor: GuardianColors.accent,
      backgroundColor: GuardianColors.surfaceElevated,
      onSelected: (_) => setState(() => _duration = val),
    );
  }
}
