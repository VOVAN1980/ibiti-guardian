import 'package:flutter/material.dart';
import 'package:ibiti_guardian/screens/vault/vault_unlock_screen.dart';
import 'package:ibiti_guardian/screens/security/policy_limits_screen.dart';
import 'package:ibiti_guardian/screens/security/ai_memory_screen.dart';
import 'package:ibiti_guardian/services/alerts/notification_service.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/assistant/user_memory_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AIControlScreen — поведение и разрешения AI.
//
// Этот экран управляет:
//   • Режимом AI («Советник» / «Ручной» / «Автономный»;
//     в коде AiMode.manual / guarded / fullAutonomy)
//   • «Подтверждать действия ИИ ПИН-кодом» (только в «Автономном»)
//   • Разрешёнными действиями
//   • Временем жизни разрешений (TTL)
//   • Экстренными кнопками безопасности
//
// Лимиты и мандат → Политика
// ─────────────────────────────────────────────────────────────────────────────

class AIControlScreen extends StatefulWidget {
  const AIControlScreen({super.key});

  @override
  State<AIControlScreen> createState() => _AIControlScreenState();
}

class _AIControlScreenState extends State<AIControlScreen> {
  late AiControlService _service;

  @override
  void initState() {
    super.initState();
    _service = AiControlService.instance;
    _service.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  // ── Formatters ─────────────────────────────────────────────────────────────

  String _formatAiMode(AiMode mode) {
    final l = LocalizationService.instance;
    return switch (mode) {
      AiMode.manual => l.t('aiControlModeManual'),
      AiMode.guarded => l.t('aiControlModeGuarded'),
      AiMode.fullAutonomy => l.t('aiControlModeFullAutonomy'),
    };
  }

  String _formatAction(AiAction action) {
    final l = LocalizationService.instance;
    return switch (action) {
      AiAction.openWindows => l.t('aiActionOpenWindows'),
      AiAction.closeWindows => l.t('aiActionCloseWindows'),
      AiAction.revoke => l.t('aiActionRevoke'),
      AiAction.send => l.t('aiActionSend'),
      AiAction.swap => l.t('aiActionSwap'),
      AiAction.approve => l.t('aiActionApprove'),
      AiAction.policyUpdate => l.t('aiActionPolicyUpdate'),
      AiAction.contactPayments => l.t('aiActionContactPayments'),
      AiAction.scheduledActions => l.t('aiActionScheduled'),
    };
  }

  String _formatDuration(AiPermissionDuration dur) {
    final l = LocalizationService.instance;
    return switch (dur) {
      AiPermissionDuration.oneHour => l.t('aiControlTtlOneHour'),
      AiPermissionDuration.oneDay => l.t('aiControlTtlOneDay'),
      AiPermissionDuration.oneWeek => l.t('aiControlTtlOneWeek'),
      AiPermissionDuration.untilRevoked => l.t('aiControlTtlUntilRevoked'),
    };
  }

  String _formatExpiry(DateTime? expiry) {
    final l = LocalizationService.instance;
    if (expiry == null) return l.t('policyNoExpiry');
    final diff = expiry.difference(DateTime.now());
    if (diff.isNegative) return l.t('policyExpired');
    if (diff.inHours > 24)
      return l.t('policyExpiryDays', {'days': diff.inDays});
    return l.t('policyExpiryHours', {'hours': diff.inHours});
  }

  /// Giving the AI more power needs PIN/biometrics; taking it away does not.
  Future<bool> _authorizeLoosening() async {
    if (!mounted) return false;
    return VaultUnlockScreen.requireAuth(context, forceSetup: true);
  }

  Future<void> _toggleAction(AiAction action, AiControlSettings s) async {
    final enable = !s.allowedActions.contains(action);
    if (enable && !await _authorizeLoosening()) return;
    await _service.toggleAction(action, enable);
  }

  // ── «Подтверждать действия ИИ ПИН-кодом» ───────────────────────────────────

  bool _pinToggleBusy = false;

  /// ON is free. OFF: PIN / biometrics must be set up, then a warning, a
  /// notification-permission check (the «ИИ выполнил» notification is the
  /// only report then) and the PIN / biometrics.
  Future<void> _onAiPinConfirmChanged(bool on) async {
    if (on) {
      await _service.setAiPinConfirm(true);
      return;
    }
    if (_pinToggleBusy) return;
    setState(() => _pinToggleBusy = true);
    try {
      final l = LocalizationService.instance;
      final vault = IBITIVaultService.instance.state;
      final hasAuth =
          (vault?.pinEnabled ?? false) || (vault?.biometricsEnabled ?? false);
      if (!hasAuth) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text(l.t('aiPinConfirmNeedsPin', {
            'default': 'Set up a PIN or biometrics first (Settings → '
                'Security). Without it, PIN confirmation of AI actions '
                'cannot be turned off.'
          })),
        ));
        return;
      }

      if (!await _confirmPinOffWarning()) return;

      var notificationsOn = await NotificationService.instance
          .isPermissionGranted();
      if (!notificationsOn) {
        notificationsOn = await NotificationService.instance.requestPermission();
      }
      if (!mounted) return;
      if (!notificationsOn && !await _confirmWithoutNotifications()) return;

      if (!await _authorizeLoosening()) return;
      // The mode may have changed while the dialogs were open.
      if (_service.settings.mode != AiMode.fullAutonomy) return;
      await _service.setAiPinConfirm(false);
    } finally {
      if (mounted) setState(() => _pinToggleBusy = false);
    }
  }

  Future<bool> _confirmPinOffWarning() async {
    if (!mounted) return false;
    final l = LocalizationService.instance;
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: GuardianColors.surface,
            title: Row(children: [
              const Icon(Icons.warning_amber_rounded,
                  color: GuardianColors.warning, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.t('aiPinConfirmOffWarnTitle',
                      {'default': 'Let the AI act without your PIN?'}),
                  style: GuardianTextStyles.headline.copyWith(fontSize: 18),
                ),
              ),
            ]),
            content: Text(
              l.t('aiPinConfirmOffWarnBody', {
                'default': 'In «Autonomous» mode the AI will place orders, '
                    'swaps and sends by itself, without the card and the PIN. '
                    'It still stays within the daily limit, the «AI Mandate» '
                    'and EPK, and sends only to trusted addresses; a new '
                    'address or an unknown price still asks for your PIN. '
                    'After each action you get the «AI did: …» notification.'
              }),
              style: GuardianTextStyles.bodySecondary,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l.t('policyEditCancel', {'default': 'Cancel'})),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: GuardianColors.warning),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(
                    l.t('aiPinConfirmOffAction', {'default': 'Turn off'})),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<bool> _confirmWithoutNotifications() async {
    if (!mounted) return false;
    final l = LocalizationService.instance;
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: GuardianColors.surface,
            title: Text(
              l.t('aiPinConfirmNotifOffTitle',
                  {'default': 'Notifications are off'}),
              style: GuardianTextStyles.headline.copyWith(fontSize: 18),
            ),
            content: Text(
              l.t('aiPinConfirmNotifOffBody', {
                'default': 'Android blocks notifications for the app, so you '
                    'will not get «AI did: …» after the AI acts. Turn them on '
                    'in Android settings → Apps → Guardian → Notifications. '
                    'Every AI action is still written to the audit log.'
              }),
              style: GuardianTextStyles.bodySecondary,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l.t('policyEditCancel', {'default': 'Cancel'})),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: GuardianColors.warning),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l.t('aiPinConfirmNotifOffContinue',
                    {'default': 'Continue anyway'})),
              ),
            ],
          ),
        ) ??
        false;
  }

  Widget _pinConfirmCard(AiControlSettings s) {
    final l = LocalizationService.instance;
    final on = s.aiPinConfirm;
    return _card([
      SwitchListTile(
        key: const ValueKey('aiPinConfirmSwitch'),
        value: on,
        onChanged: _pinToggleBusy ? null : _onAiPinConfirmChanged,
        activeThumbColor: GuardianColors.accent,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        secondary: Icon(
          on ? Icons.lock_outline : Icons.lock_open_outlined,
          color: on ? GuardianColors.success : GuardianColors.warning,
        ),
        title: Text(
          l.t('aiPinConfirmTitle',
              {'default': 'Confirm AI actions with PIN'}),
          style: GuardianTextStyles.bodyPrimary
              .copyWith(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            on
                ? l.t('aiPinConfirmOnDesc', {
                    'default': 'The AI shows a card (what, amount, fee) and '
                        'asks for your PIN before each action.'
                  })
                : l.t('aiPinConfirmOffDesc', {
                    'default': 'The AI acts by itself — within the daily '
                        'limit, «AI Mandate» and EPK, and only to trusted '
                        'addresses. You get a notification after each action.'
                  }),
            style: GuardianTextStyles.bodySecondary.copyWith(
                fontSize: 12, color: GuardianColors.textSecondary),
          ),
        ),
      ),
    ]);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = _service.settings;

    return Scaffold(
      backgroundColor: GuardianColors.background,
      appBar: AppBar(
        title: Text(LocalizationService.instance.t('aiControlTitle'),
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
                MaterialPageRoute(builder: (_) => const PolicyLimitsScreen()),
              ),
            ),
            const SizedBox(height: 24),

            // ── AI Status ─────────────────────────────────────────────────
            _sectionHeader(LocalizationService.instance.t('aiControlStatus')),
            _card([
              _row(
                  LocalizationService.instance.t('aiControlStatus'),
                  s.isActive
                      ? LocalizationService.instance.t('aiControlActive')
                      : LocalizationService.instance.t('aiControlInactive'),
                  valueColor: s.isActive
                      ? GuardianColors.success
                      : GuardianColors.textSecondary),
              _divider(),
              _row(LocalizationService.instance.t('aiControlCurrentMode'),
                  _formatAiMode(s.mode)),
              _divider(),
              _row(LocalizationService.instance.t('aiControlActionsCount'),
                  '${s.allowedActions.length}'),
              _divider(),
              _row(LocalizationService.instance.t('aiControlTtl'),
                  _formatExpiry(s.permissionsExpiry)),
              if (s.mode == AiMode.fullAutonomy) ...[
                _divider(),
                _row(
                    LocalizationService.instance.t(
                        'aiPinStatusRow', {'default': 'PIN for AI actions'}),
                    s.aiPinConfirm
                        ? LocalizationService.instance
                            .t('aiPinStatusOn', {'default': 'On'})
                        : LocalizationService.instance
                            .t('aiPinStatusOff', {'default': 'Off'}),
                    valueColor: s.aiPinConfirm
                        ? GuardianColors.success
                        : GuardianColors.warning),
              ],
            ]),
            const SizedBox(height: 20),

            // ── AI Mode selector ───────────────────────────────────────────
            _sectionHeader(
                LocalizationService.instance.t('aiControlModeSection')),
            _card(AiMode.values
                .map((mode) => _checkRow(
                      _formatAiMode(mode),
                      s.mode == mode,
                      onTap: () async {
                        // Any raise (Manual → Guarded → Full Autonomy) needs PIN.
                        if (mode.index > s.mode.index &&
                            !await _authorizeLoosening()) {
                          return;
                        }
                        await _service.updateMode(mode);
                      },
                    ))
                .toList()),
            const SizedBox(height: 12),
            _card([
              _modeInfo(LocalizationService.instance.t('aiControlModeManual'),
                  LocalizationService.instance.t('aiControlModeManualDesc'),
                  active: s.mode == AiMode.manual),
              _modeInfo(LocalizationService.instance.t('aiControlModeGuarded'),
                  LocalizationService.instance.t('aiControlModeGuardedDesc'),
                  active: s.mode == AiMode.guarded),
              _modeInfo(
                  LocalizationService.instance.t('aiControlModeFullAutonomy'),
                  LocalizationService.instance.t('aiControlModeFullDesc'),
                  active: s.mode == AiMode.fullAutonomy),
              _modeInfo(
                  '⚖️ Law', LocalizationService.instance.t('aiControlModeLaw'),
                  active: true, isLaw: true),
            ]),
            // «Подтверждать действия ИИ ПИН-кодом»: only in «Автономный».
            if (s.mode == AiMode.fullAutonomy) ...[
              const SizedBox(height: 12),
              _pinConfirmCard(s),
            ],
            const SizedBox(height: 20),

            // ── Allowed Actions ───────────────────────────────────────────
            _sectionHeader(
                LocalizationService.instance.t('aiControlAllowedActions')),
            // Group 1: UI window control
            _subLabel(LocalizationService.instance.t('aiActionGroupUiControl')),
            _card([
              AiAction.openWindows,
              AiAction.closeWindows,
            ].map((action) {
              final locked = _isActionLocked(s.mode, action);
              return _checkRow(
                _formatAction(action),
                s.allowedActions.contains(action),
                locked: locked,
                onTap: locked
                    ? () {}
                    : () => _toggleAction(action, s),
              );
            }).toList()),
            const SizedBox(height: 12),
            // Group 2: Execution actions
            _subLabel(LocalizationService.instance.t('aiActionGroupExecution')),
            _card([
              AiAction.revoke,
              AiAction.send,
              AiAction.swap,
              AiAction.approve,
              AiAction.policyUpdate,
              AiAction.contactPayments,
              AiAction.scheduledActions,
            ].map((action) {
              final locked = _isActionLocked(s.mode, action);
              return _checkRow(
                _formatAction(action),
                s.allowedActions.contains(action),
                locked: locked,
                onTap: locked
                    ? () {}
                    : () => _toggleAction(action, s),
              );
            }).toList()),
            const SizedBox(height: 20),

            // ── Permission TTL ─────────────────────────────────────────────
            _sectionHeader(
                LocalizationService.instance.t('aiControlPermissionTtl')),
            _card(AiPermissionDuration.values
                .map((dur) => _checkRow(
                      _formatDuration(dur),
                      s.duration == dur,
                      onTap: () async {
                        // A longer permission window loosens control.
                        if (dur.index > s.duration.index &&
                            !await _authorizeLoosening()) {
                          return;
                        }
                        await _service.updateDuration(dur);
                      },
                    ))
                .toList()),
            const SizedBox(height: 20),

            // ── AI Memory ──────────────────────────────────────────────────
            _sectionHeader(LocalizationService.instance.t('memorySection')),
            _MemoryCard(
              onOpen: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AiMemoryScreen()),
              ),
            ),
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
                  leading: const Icon(Icons.stop_circle_outlined,
                      color: GuardianColors.danger),
                  title: Text(LocalizationService.instance.t('aiControlStopAi'),
                      style: GuardianTextStyles.bodyPrimary
                          .copyWith(color: GuardianColors.danger)),
                  subtitle: Text(
                      LocalizationService.instance.t('aiControlStopAiDesc'),
                      style: GuardianTextStyles.bodySecondary
                          .copyWith(fontSize: 12)),
                  onTap: () => _service.emergencyStop(),
                ),
                Divider(
                    height: 1, color: GuardianColors.danger.withOpacity(0.15)),
                ListTile(
                  leading: const Icon(Icons.block_outlined,
                      color: GuardianColors.danger),
                  title: Text(
                      LocalizationService.instance.t('aiControlRevokeAll'),
                      style: GuardianTextStyles.bodyPrimary
                          .copyWith(color: GuardianColors.danger)),
                  subtitle: Text(
                      LocalizationService.instance.t('aiControlRevokeAllDesc'),
                      style: GuardianTextStyles.bodySecondary
                          .copyWith(fontSize: 12)),
                  onTap: () {
                    for (final action in AiAction.values) {
                      _service.toggleAction(action, false);
                    }
                  },
                ),
                Divider(
                    height: 1, color: GuardianColors.danger.withOpacity(0.15)),
                ListTile(
                  leading: const Icon(Icons.arrow_downward_rounded,
                      color: GuardianColors.danger),
                  title: Text(
                      LocalizationService.instance
                          .t('aiControlDowngradeManual'),
                      style: GuardianTextStyles.bodyPrimary
                          .copyWith(color: GuardianColors.danger)),
                  subtitle: Text(
                      LocalizationService.instance
                          .t('aiControlDowngradeManualDesc'),
                      style: GuardianTextStyles.bodySecondary
                          .copyWith(fontSize: 12)),
                  onTap: () => _service.updateMode(AiMode.manual),
                ),
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

  Widget _subLabel(String title) => Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 6, top: 2),
        child: Text(title,
            style: GuardianTextStyles.caption.copyWith(
                color: GuardianColors.textSecondary.withOpacity(0.6),
                fontSize: 11,
                fontWeight: FontWeight.w500)),
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

  /// Returns true if [action] cannot be toggled in [mode].
  /// Mirrors AiControlService._ceilingFor() logic.
  bool _isActionLocked(AiMode mode, AiAction action) {
    if (mode == AiMode.manual) return true; // Manual: all locked off
    if (mode == AiMode.guarded) {
      // Guarded ceiling: everything except scheduled & policyUpdate.
      // approve = ERC-20 token approval preparation, NOT autonomous signing.
      const guardedCeiling = [
        AiAction.openWindows,
        AiAction.closeWindows,
        AiAction.revoke,
        AiAction.send,
        AiAction.swap,
        AiAction.approve,
        AiAction.contactPayments,
      ];
      return !guardedCeiling.contains(action);
    }
    return false; // FullAutonomy: everything unlocked
  }

  Widget _checkRow(String label, bool isChecked,
          {required VoidCallback onTap, bool locked = false}) =>
      InkWell(
        onTap: locked ? null : onTap,
        borderRadius: BorderRadius.circular(8),
        child: Opacity(
          opacity: locked ? 0.35 : 1.0,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(label,
                      style: GuardianTextStyles.bodyPrimary
                          .copyWith(fontSize: 15)),
                ),
                if (locked)
                  const Icon(Icons.lock_outline,
                      color: GuardianColors.textSecondary, size: 18)
                else
                  Icon(isChecked ? Icons.check_circle : Icons.circle_outlined,
                      color: isChecked
                          ? GuardianColors.primary
                          : GuardianColors.textSecondary.withOpacity(0.3),
                      size: 22),
              ],
            ),
          ),
        ),
      );

  Widget _modeInfo(String title, String text,
      {bool active = false, bool isLaw = false}) {
    final color = isLaw
        ? GuardianColors.warning
        : active
            ? GuardianColors.accent
            : GuardianColors.textSecondary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(color: GuardianColors.border.withOpacity(0.25))),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (active)
          Container(
            width: 3,
            height: 36,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(2)),
          ),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: GuardianTextStyles.bodyPrimary.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: active ? color : GuardianColors.textPrimary)),
            const SizedBox(height: 3),
            Text(text,
                style: GuardianTextStyles.bodySecondary.copyWith(
                    fontSize: 12, color: GuardianColors.textSecondary)),
          ]),
        ),
      ]),
    );
  }
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
              Text(LocalizationService.instance.t('aiControlRoleCard'),
                  style: GuardianTextStyles.caption.copyWith(
                      color: GuardianColors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 12)),
              Text(LocalizationService.instance.t('aiControlRoleCardSub'),
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

class _MemoryCard extends StatelessWidget {
  final VoidCallback onOpen;
  const _MemoryCard({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final l = LocalizationService.instance;
    final memory = UserMemoryService.instance;
    final vocabCount = memory.allVocab.length;
    final macroCount = memory.allMacros.length;

    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              GuardianColors.accent.withOpacity(0.08),
              GuardianColors.primary.withOpacity(0.04),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: GuardianColors.accent.withOpacity(0.25)),
        ),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: GuardianColors.accent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.psychology_outlined,
                color: GuardianColors.accent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.t('memoryCardTitle'),
                  style: GuardianTextStyles.bodyPrimary
                      .copyWith(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 2),
              Text(
                l.t('memoryCardSub', {
                  'vocab': vocabCount.toString(),
                  'macros': macroCount.toString(),
                }),
                style: GuardianTextStyles.caption.copyWith(
                    color: GuardianColors.textSecondary, fontSize: 11),
              ),
            ]),
          ),
          const Icon(Icons.arrow_forward_ios_rounded,
              size: 13, color: GuardianColors.textSecondary),
        ]),
      ),
    );
  }
}
