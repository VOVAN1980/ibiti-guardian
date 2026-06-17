import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';
import 'package:ibiti_guardian/widgets/guardian_glass_card.dart';
import 'package:ibiti_guardian/screens/security/guardian_flow_controller.dart';
import 'package:ibiti_guardian/models/approval.dart';
import 'package:ibiti_guardian/services/transaction_queue.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';
import 'package:ibiti_guardian/config/chains.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';

// TODO(refactor): GOD WIDGET — 1630 lines. Decompose into:
//   • _ApprovalPanel (approval request cards + confirm/reject)
//   • _SecurityStatusStrip (EPK / AI status at a glance)
//   • _PanicPanel (emergency stop actions)
//   • _GuardianHistory (recent guardian actions log)
// TODO(localization): still has hardcoded Russian strings — wire LocalizationProvider.of(context).t(key)
// ────────────────────────────────────────────────────────────────────────────
// GuardianControlScreen
// Прямоугольная панель 2x2: Safe/Panic, AI Control, Policy/Limits, EPK Control
// ────────────────────────────────────────────────────────────────────────────

class GuardianControlScreen extends StatefulWidget {
  const GuardianControlScreen({super.key});

  /// Called by AI assistant
  static Future<void> showAiModal(
    BuildContext context, {
    required String mode,
  }) {
    final opMode = mode == 'panic' ? GuardianMode.panic : GuardianMode.safe;
    return _openLiveModal(context, opMode, triggeredByAi: true);
  }

  @override
  State<GuardianControlScreen> createState() => _GuardianControlScreenState();
}

Future<void> _openLiveModal(
  BuildContext context,
  GuardianMode mode, {
  bool triggeredByAi = false,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    isDismissible: false,
    enableDrag: false,
    builder: (sheetContext) => _LiveSecurityModal(
      mode: mode,
      triggeredByAi: triggeredByAi,
    ),
  );
}

class _GuardianControlScreenState extends State<GuardianControlScreen> {
  bool _isLaunching = false;

  Future<void> _launch(GuardianMode mode) async {
    if (_isLaunching) return;
    setState(() => _isLaunching = true);

    await _openLiveModal(context, mode);

    if (mounted) {
      setState(() => _isLaunching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    return Scaffold(
      backgroundColor: GuardianColors.background,
      appBar: AppBar(
        title: Text(t.t('guardianCommandCenter', {'default': 'Safe/Panik'}),
            style: GuardianTextStyles.headline.copyWith(fontSize: 24)),
        backgroundColor: GuardianColors.background,
        elevation: 0,
        centerTitle: true,
        leading: Navigator.canPop(context)
            ? IconButton(
                icon: const Icon(Icons.arrow_back_ios_new,
                    color: GuardianColors.textPrimary, size: 24),
                onPressed: () => Navigator.pop(context),
              )
            : null,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        height: 140,
                        child: _CommandWideItem(
                          title: t.t('guardianSafeReview', {'default': 'Safe'}),
                          icon: Icons.shield_outlined,
                          color: GuardianColors.success,
                          isLaunching: _isLaunching,
                          onTap: () => _launch(GuardianMode.safe),
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 140,
                        child: _CommandWideItem(
                          title:
                              t.t('guardianPanicRevoke', {'default': 'Panik'}),
                          icon: Icons.emergency,
                          color: GuardianColors.danger,
                          isLaunching: _isLaunching,
                          onTap: () => _launch(GuardianMode.panic),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommandWideItem extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final bool isLaunching;
  final VoidCallback onTap;

  const _CommandWideItem({
    required this.title,
    required this.icon,
    required this.color,
    required this.isLaunching,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = isLaunching ? color.withOpacity(0.5) : color;
    return GestureDetector(
      onTap: isLaunching ? null : onTap,
      child: AnimatedOpacity(
        opacity: isLaunching ? 0.6 : 1.0,
        duration: const Duration(milliseconds: 300),
        child: GuardianGlassCard(
          padding: EdgeInsets.zero,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                  color: effectiveColor.withOpacity(0.5), width: 1.5),
              gradient: LinearGradient(
                colors: [
                  effectiveColor.withOpacity(0.15),
                  effectiveColor.withOpacity(0.02)
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: effectiveColor.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 48, color: effectiveColor),
                ),
                const SizedBox(width: 24),
                Text(
                  title,
                  style: GuardianTextStyles.headline.copyWith(
                    color: effectiveColor,
                    fontSize: 22,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// LIVE SECURITY MODAL (Strict Controller Based)
// ═══════════════════════════════════════════════════════════════════════════════

class _LiveSecurityModal extends StatefulWidget {
  final GuardianMode mode;
  final bool triggeredByAi;

  const _LiveSecurityModal({
    required this.mode,
    this.triggeredByAi = false,
  });

  @override
  State<_LiveSecurityModal> createState() => _LiveSecurityModalState();
}

class _LiveSecurityModalState extends State<_LiveSecurityModal>
    with TickerProviderStateMixin {
  late GuardianFlowController _controller;
  late AnimationController _pulseCtrl;
  bool _showSafeList = false;
  int _visualStep = 0;
  bool _isCatchingUp = false;

  @override
  void initState() {
    super.initState();
    _controller = GuardianFlowController();
    _controller.addListener(_updateVisualStep);
    _controller.open(widget.mode);
    // React to AI mode changes that happen while the modal is open.
    // E.g. if voice command changes mode → button label/state rebuilds.
    AiControlService.instance.addListener(_onAiModeChanged);

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
  }

  void _onAiModeChanged() {
    if (mounted) setState(() {});
  }

  void _updateVisualStep() {
    final target = _currentStepIndex;
    if (target > _visualStep) {
      _catchUpVisualStep();
    } else if (target < _visualStep) {
      if (mounted) setState(() => _visualStep = target);
    }
  }

  Future<void> _catchUpVisualStep() async {
    if (_isCatchingUp) return;
    _isCatchingUp = true;
    while (_visualStep < _currentStepIndex && mounted) {
      await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted) break;
      setState(() => _visualStep++);
    }
    _isCatchingUp = false;
  }

  @override
  void dispose() {
    _controller.removeListener(_updateVisualStep);
    AiControlService.instance.removeListener(_onAiModeChanged);
    _pulseCtrl.dispose();
    _controller.dispose();
    super.dispose();
  }

  String _modeLabel(BuildContext context) {
    final t = LocalizationProvider.of(context);
    return widget.mode == GuardianMode.safe
        ? t.t('guardianSafeReview', {'default': 'Safe'})
        : t.t('guardianPanicRevoke', {'default': 'Panik'});
  }

  Color get _modeColor => widget.mode == GuardianMode.safe
      ? GuardianColors.success
      : GuardianColors.danger;
  IconData get _modeIcon => widget.mode == GuardianMode.safe
      ? Icons.shield_outlined
      : Icons.emergency_outlined;

  String _aiModeLabel(BuildContext context) {
    final t = LocalizationProvider.of(context);
    final mode = AiControlService.instance.settings.mode;
    return switch (mode) {
      AiMode.manual => t.t('aiControlModeManual'),
      AiMode.guarded => t.t('aiControlModeGuarded'),
      AiMode.fullAutonomy => t.t('aiControlModeFullAutonomy'),
    };
  }

  bool get _isAiManualMode =>
      widget.triggeredByAi &&
      AiControlService.instance.settings.mode == AiMode.manual;

  bool get _isAiGuardedMode =>
      widget.triggeredByAi &&
      AiControlService.instance.settings.mode == AiMode.guarded;

  List<String> _stepLabels(BuildContext context) {
    final t = LocalizationProvider.of(context);
    final s = _controller.model.scenario;
    if (widget.mode == GuardianMode.safe) {
      if (s == GuardianScenario.safeNoRisk) {
        return [
          t.t('guardianStepScan', {'default': 'Scan Wallet'}),
          t.t('guardianStepAnalyze', {'default': 'Analyze Security'}),
          t.t('guardianStepNoRisks', {'default': 'No Risks'}),
          t.t('guardianStepNoAction', {'default': 'No Action'}),
          t.t('guardianStepComplete', {'default': 'Complete'})
        ];
      } else {
        return [
          t.t('guardianStepScan', {'default': 'Scan Wallet'}),
          t.t('guardianStepAnalyze', {'default': 'Analyze Security'}),
          t.t('guardianStepReviewRisks', {'default': 'Review Risks'}),
          t.t('guardianStepRevokeSelected', {'default': 'Revoke Selected'}),
          t.t('guardianStepComplete', {'default': 'Complete'})
        ];
      }
    } else {
      if (s == GuardianScenario.panicNoCritical) {
        return [
          t.t('guardianStepScan', {'default': 'Scan Wallet'}),
          t.t('guardianStepDetectCritical', {'default': 'Detect Critical'}),
          t.t('guardianStepNoCriticals', {'default': 'No Criticals'}),
          t.t('guardianStepNoAction', {'default': 'No Action'}),
          t.t('guardianStepComplete', {'default': 'Complete'})
        ];
      } else {
        return [
          t.t('guardianStepScan', {'default': 'Scan Wallet'}),
          t.t('guardianStepDetectCritical', {'default': 'Detect Critical'}),
          t.t('guardianStepEmergencyRevoke', {'default': 'Emergency Revoke'}),
          t.t('guardianStepConfirm', {'default': 'Confirm'}),
          t.t('guardianStepComplete', {'default': 'Complete'})
        ];
      }
    }
  }

  int get _currentStepIndex {
    final state = _controller.model.state;
    if (widget.mode == GuardianMode.safe) {
      switch (state) {
        case GuardianFlowState.idle:
        case GuardianFlowState.scanning:
          return 0;
        case GuardianFlowState.analyzing:
          return 1;
        case GuardianFlowState.readyReview:
          return 2;
        case GuardianFlowState.readyNoAction:
          return 4;
        case GuardianFlowState.queuePrepared:
        case GuardianFlowState.waitingWallet:
        case GuardianFlowState.executing:
          return 3;
        case GuardianFlowState.completed:
        case GuardianFlowState.failed:
          return 4;
      }
    } else {
      switch (state) {
        case GuardianFlowState.idle:
        case GuardianFlowState.scanning:
          return 0;
        case GuardianFlowState.analyzing:
          return 1;
        case GuardianFlowState.readyReview:
          return 2;
        case GuardianFlowState.readyNoAction:
          return 4;
        case GuardianFlowState.queuePrepared:
        case GuardianFlowState.executing:
          return 2;
        case GuardianFlowState.waitingWallet:
          return 3;
        case GuardianFlowState.completed:
        case GuardianFlowState.failed:
          return 4;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => _buildLayout(),
    );
  }

  Widget _buildLayout() {
    final height = MediaQuery.of(context).size.height;
    return Container(
      height: height * 0.94,
      decoration: const BoxDecoration(
        color: GuardianColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        children: [
          _buildHeader(),
          _buildPhaseBar(),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: _buildBody(),
            ),
          ),
          _buildBottomAction(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final t = LocalizationProvider.of(context);
    final state = _controller.model.state;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 20),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _modeColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(_modeIcon, color: _modeColor, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _modeLabel(context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            GuardianTextStyles.headline.copyWith(fontSize: 24),
                      ),
                    ),
                    if (widget.triggeredByAi) ...[
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: GuardianColors.accent.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text('AI · ${_aiModeLabel(context)}',
                            style: GuardianTextStyles.titleMedium.copyWith(
                                color: GuardianColors.accent,
                                fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                    widget.mode == GuardianMode.safe
                        ? t.t('guardianSafeDesc', {
                            'default':
                                'Safe mode checks wallet permissions before any revoke action'
                          })
                        : t.t('guardianPanicDesc', {
                            'default':
                                'Panik mode scans for dangerous permissions and urgent threats'
                          }),
                    style: GuardianTextStyles.bodySecondary
                        .copyWith(fontSize: 14)),
              ],
            ),
          ),
          if (state != GuardianFlowState.queuePrepared &&
              state != GuardianFlowState.executing &&
              state != GuardianFlowState.waitingWallet)
            IconButton(
              icon: const Icon(Icons.close,
                  color: GuardianColors.textSecondary, size: 28),
              onPressed: () => Navigator.pop(context),
            ),
        ],
      ),
    );
  }

  Widget _buildPhaseBar() {
    final phases = _stepLabels(context);
    final idx = _visualStep;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        children: List.generate(phases.length, (i) {
          final isDone = i <= idx;
          final isActive = i == idx;
          return Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      Container(
                        height: 4,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          color: GuardianColors.glassBorder,
                        ),
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0.0, end: isDone ? 1.0 : 0.0),
                          duration: const Duration(milliseconds: 800),
                          curve: Curves.easeOutQuad,
                          builder: (_, value, __) => FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: value,
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4),
                                color: _modeColor,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        phases[i],
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GuardianTextStyles.caption.copyWith(
                          color: isDone
                              ? _modeColor
                              : GuardianColors.textSecondary,
                          fontWeight:
                              isActive ? FontWeight.bold : FontWeight.w500,
                          fontSize: 10,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
                if (i < phases.length - 1) const SizedBox(width: 6),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildBody() {
    final state = _controller.model.state;
    final vIdx = _visualStep;

    // UI matches the VISUAL progress, not the underlying true state.
    if (state == GuardianFlowState.readyNoAction && vIdx < 4) {
      final t = LocalizationProvider.of(context);
      final customText = vIdx == 2
          ? t.t('guardianVerifying', {'default': 'Verifying permissions...'})
          : t.t('guardianFinalizing', {'default': 'Finalizing scan...'});
      return _buildScanningBlock(isScanning: false, customText: customText);
    }

    if (state == GuardianFlowState.readyReview && vIdx < 2) {
      return _buildScanningBlock(isScanning: false);
    }

    if (vIdx <= 1) {
      return _buildScanningBlock(isScanning: vIdx == 0);
    }

    if (state == GuardianFlowState.readyNoAction ||
        state == GuardianFlowState.completed) {
      if (vIdx >= 4) return _buildReadyNoAction();
    }

    if (state == GuardianFlowState.readyReview) {
      if (vIdx >= 2) return _buildReadyReview();
    }

    return _buildExecutingPhase();
  }

  // ── Bottom Action ──────────────────────────────────────────────────────────

  Widget _buildBottomAction() {
    final t = LocalizationProvider.of(context);
    final state = _controller.model.state;
    final m = _controller.model;
    final vIdx = _visualStep;

    if (state == GuardianFlowState.readyNoAction && vIdx < 4) {
      return const SizedBox.shrink();
    }
    if (state == GuardianFlowState.readyReview && vIdx < 2) {
      return const SizedBox.shrink();
    }

    if (state == GuardianFlowState.readyNoAction ||
        state == GuardianFlowState.completed) {
      final btnText = widget.mode == GuardianMode.safe
          ? t.t('guardianSafeBtnOk', {'default': "Great, I'm Safe"})
          : t.t('guardianPanicBtnOk', {'default': "OK, No Threats"});
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: GuardianColors.success,
              padding: const EdgeInsets.symmetric(vertical: 20),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
            onPressed: () => Navigator.pop(context),
            child: Text(btnText,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18)),
          ),
        ),
      );
    }

    if (state == GuardianFlowState.failed) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: GuardianColors.danger,
              padding: const EdgeInsets.symmetric(vertical: 20),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
            onPressed: () => _controller.open(widget.mode), // Retry
            child: Text(t.t('guardianBtnRetry', {'default': 'Try Again'}),
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18)),
          ),
        ),
      );
    }

    if (state == GuardianFlowState.readyReview) {
      final bool manualReviewOnly = _isAiManualMode;
      final bool guardedReview = _isAiGuardedMode;
      final btnColor = manualReviewOnly
          ? GuardianColors.glassBorder
          : (m.hasActionableItems ? _modeColor : GuardianColors.glassBorder);
      final btnText = manualReviewOnly
          ? t.t('guardianBtnManualReview')
          : guardedReview
              ? (widget.mode == GuardianMode.safe
                  ? t.t('guardianBtnGuardedSafe',
                      {'count': m.selected.length.toString()})
                  : t.t('guardianBtnGuardedPanic',
                      {'count': m.critical.length.toString()}))
              : widget.mode == GuardianMode.safe
                  ? t.t('guardianBtnRevokeSelected',
                      {'count': m.selected.length.toString()})
                  : t.t('guardianBtnRevokeCritical',
                      {'count': m.critical.length.toString()});

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: btnColor,
              padding: const EdgeInsets.symmetric(vertical: 20),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
            onPressed: manualReviewOnly
                ? null
                : (m.hasActionableItems
                    ? () => _controller.confirmAction()
                    : null),
            child: Text(btnText,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18)),
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  // ── States ─────────────────────────────────────────────────────────────────

  Widget _buildError() {
    final t = LocalizationProvider.of(context);
    final err = _controller.model.error ??
        t.t('guardianErrUnknown', {'default': 'Unknown fatal error'});
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline,
                color: GuardianColors.danger, size: 64),
            const SizedBox(height: 20),
            Text(
                t.t('guardianErrFailedTitle',
                    {'default': 'Scan or operation failed'}),
                style: GuardianTextStyles.headline.copyWith(fontSize: 28)),
            const SizedBox(height: 12),
            Text(err,
                style: GuardianTextStyles.bodySecondary.copyWith(fontSize: 16),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Widget _buildScanningBlock({required bool isScanning, String? customText}) {
    final t = LocalizationProvider.of(context);
    final count = _controller.model.scannedCount;

    String mainText;
    if (customText != null) {
      mainText = customText;
    } else {
      mainText = isScanning
          ? (widget.mode == GuardianMode.safe
              ? t.t(
                  'guardianScanContracts', {'default': 'Scanning contracts...'})
              : t.t('guardianScanPanic',
                  {'default': 'Scanning for dangerous permissions...'}))
          : (widget.mode == GuardianMode.safe
              ? t.t('guardianAnalyzePerms',
                  {'default': 'Analyzing permissions...'})
              : t.t('guardianAnalyzePanic',
                  {'default': 'Tracing deep risks...'}));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(
              child: Column(
                children: [
                  const Spacer(
                      flex: 2), // Raised: top spacer is smaller than bottom
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.0, end: 1.0),
                    duration: const Duration(milliseconds: 800),
                    curve: Curves.elasticOut,
                    builder: (context, value, child) =>
                        Transform.scale(scale: value, child: child),
                    child: Container(
                      padding: const EdgeInsets.all(32),
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _modeColor.withOpacity(0.1)),
                      child: Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _modeColor.withOpacity(0.2),
                          boxShadow: [
                            BoxShadow(
                                color: _modeColor.withOpacity(0.3),
                                blurRadius: 40,
                                spreadRadius: 10)
                          ],
                        ),
                        child: AnimatedBuilder(
                          animation: _pulseCtrl,
                          builder: (context, child) {
                            double offset = 0;
                            if (widget.mode == GuardianMode.panic) {
                              // Glitch jitter for Panic mode
                              offset = (math.Random().nextDouble() - 0.5) *
                                  4 *
                                  _pulseCtrl.value;
                            }
                            return Transform.translate(
                              offset: Offset(offset, -offset),
                              child: Transform.rotate(
                                angle: _pulseCtrl.value * 2 * math.pi,
                                child: Icon(_modeIcon,
                                    color: _modeColor, size: 54),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 48),
                  Text(
                    mainText,
                    style: GuardianTextStyles.headline
                        .copyWith(fontSize: 26, letterSpacing: -0.5),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  if (!isScanning || count > 0)
                    TweenAnimationBuilder<int>(
                      tween: IntTween(begin: 0, end: count),
                      duration: const Duration(milliseconds: 1000),
                      curve: Curves.easeOutQuad,
                      builder: (_, value, __) => Text(
                          t.t('guardianDetectedApprovals', {
                            'count': value.toString(),
                            'default': 'Detected {count} approvals'
                          }),
                          style: GuardianTextStyles.bodySecondary.copyWith(
                              fontSize: 18, color: _modeColor.withOpacity(0.8)),
                          textAlign: TextAlign.center),
                    ),
                  const Spacer(
                      flex: 3), // Bottom space is larger to keep it "raised"
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildReadyNoAction() {
    final t = LocalizationProvider.of(context);
    final count = _controller.model.scannedCount;
    final isSafeMode = widget.mode == GuardianMode.safe;

    String headline;
    String subheadline;

    if (count == 0) {
      headline =
          t.t('guardianResNoApprovalsTitle', {'default': 'No approvals found'});
      subheadline = t.t('guardianResNoApprovalsDesc',
          {'default': "We couldn't find any active approvals."});
    } else if (isSafeMode) {
      headline = t.t('guardianResSafeTitle',
          {'default': 'Your wallet permissions are safe.'});
      subheadline =
          t.t('guardianResSafeDesc', {'default': 'No risky approvals found.'});
    } else {
      headline = t.t('guardianResNoDrainTitle',
          {'default': 'No immediate drain threats detected.'});
      subheadline = t.t('guardianResNoDrainDesc',
          {'default': 'No contracts can instantly drain your wallet.'});
    }

    final description = isSafeMode
        ? t.t('guardianResCheckSafe', {
            'default':
                'We checked all smart contracts that can access your funds.'
          })
        : t.t('guardianResCheckPanic', {
            'default':
                'We checked for contracts that can drain your wallet instantly.'
          });

    String chainName;
    try {
      chainName = ChainConfig.getChainName(WalletAdapter.instance.chainId);
    } on StateError {
      chainName = WalletAdapter.instance.chainKey.toUpperCase();
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: GuardianColors.success.withOpacity(0.15)),
              child: const Icon(Icons.verified,
                  color: GuardianColors.success, size: 80),
            ),
            const SizedBox(height: 32),
            Text(headline,
                style: GuardianTextStyles.headline.copyWith(fontSize: 24),
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(subheadline,
                style: GuardianTextStyles.headline
                    .copyWith(fontSize: 20, color: GuardianColors.success),
                textAlign: TextAlign.center),
            const SizedBox(height: 20),
            Text(description,
                style: GuardianTextStyles.bodySecondary.copyWith(fontSize: 14),
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(
                t.t('guardianCheckedContracts', {
                  'count': count.toString(),
                  'chain': chainName,
                }),
                style: GuardianTextStyles.bodyPrimary
                    .copyWith(fontSize: 16, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center),
            if (count > 0) ...[
              const SizedBox(height: 24),
              Row(
                children: [
                  _BigStatChip(
                      label: t.t('guardianStatScanned'),
                      value: count,
                      color: GuardianColors.info),
                  const SizedBox(width: 12),
                  _BigStatChip(
                      label: t.t('guardianStatCritical'),
                      value: 0,
                      color: GuardianColors.danger),
                  const SizedBox(width: 12),
                  _BigStatChip(
                      label: t.t('guardianStatWarnings'),
                      value: _controller.model.warningCount,
                      color: GuardianColors.warning),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildReadyReview() {
    final m = _controller.model;
    final selectedKeys =
        m.selected.map((s) => '${s.spenderAddress}-${s.token}').toSet();

    final t = LocalizationProvider.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Row(
            children: [
              _BigStatChip(
                  label: t.t('guardianStatScanned'),
                  value: m.scannedCount,
                  color: GuardianColors.info),
              const SizedBox(width: 12),
              _BigStatChip(
                  label: t.t('guardianStatCritical'),
                  value: m.criticalCount,
                  color: GuardianColors.danger),
              const SizedBox(width: 12),
              _BigStatChip(
                  label: t.t('guardianStatWarnings'),
                  value: m.warningCount,
                  color: GuardianColors.warning),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            children: [
              if (m.critical.isNotEmpty) ...[
                Text(
                    LocalizationService.instance.t('guardianCriticalRisks',
                        {'count': m.critical.length.toString()}),
                    style: GuardianTextStyles.titleMedium
                        .copyWith(color: GuardianColors.danger, fontSize: 16)),
                const SizedBox(height: 12),
                ...m.critical
                    .map((a) => _buildResultCard(a, true, selectedKeys)),
                const SizedBox(height: 24),
              ],
              if (widget.mode == GuardianMode.safe) ...[
                if (m.warnings.isNotEmpty) ...[
                  Text(
                      LocalizationService.instance.t('guardianWarnings',
                          {'count': '${m.warnings.length}'}),
                      style: GuardianTextStyles.titleMedium.copyWith(
                          color: GuardianColors.warning, fontSize: 16)),
                  const SizedBox(height: 12),
                  ...m.warnings
                      .map((a) => _buildResultCard(a, true, selectedKeys)),
                  const SizedBox(height: 24),
                ],
                if (m.safe.isNotEmpty) ...[
                  GestureDetector(
                    onTap: () => setState(() => _showSafeList = !_showSafeList),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                          color: GuardianColors.surfaceElevated,
                          borderRadius: BorderRadius.circular(16)),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                              LocalizationService.instance.t(
                                  'guardianSafeContracts',
                                  {'count': m.safe.length.toString()}),
                              style: GuardianTextStyles.titleMedium.copyWith(
                                  color: GuardianColors.success, fontSize: 16)),
                          Icon(
                              _showSafeList
                                  ? Icons.keyboard_arrow_up
                                  : Icons.keyboard_arrow_down,
                              color: GuardianColors.textSecondary),
                        ],
                      ),
                    ),
                  ),
                  if (_showSafeList) ...[
                    const SizedBox(height: 12),
                    ...m.safe
                        .map((a) => _buildResultCard(a, false, selectedKeys)),
                  ],
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  _HumanRiskDetail _mapRisk(ApprovalData a, GuardianFlowController ctrl) {
    final loc = LocalizationService.instance;
    if (ctrl.isCritical(a)) {
      return _HumanRiskDetail(
        reason: loc.t('riskDetailCriticalReason'),
        impact: loc.t('riskDetailCriticalImpact'),
        recommendation: loc.t('riskDetailCriticalRecommendation'),
      );
    } else if (ctrl.isWarning(a)) {
      return _HumanRiskDetail(
        reason: loc.t('riskDetailWarningReason'),
        impact: loc.t('riskDetailWarningImpact'),
        recommendation: loc.t('riskDetailWarningRecommendation'),
      );
    } else {
      return _HumanRiskDetail(
        reason: loc.t('riskDetailSafeReason'),
        impact: loc.t('riskDetailSafeImpact'),
        recommendation: loc.t('riskDetailSafeRecommendation'),
      );
    }
  }

  Widget _buildResultCard(
      ApprovalData a, bool allowToggle, Set<String> selectedKeys) {
    final detail = _mapRisk(a, _controller);
    final group = _controller.isCritical(a)
        ? "Critical"
        : (_controller.isWarning(a) ? "Warning" : "Safe");
    final symbol = a.tokenSymbol ?? a.token.substring(0, 8);
    final shortSpender =
        '${a.spenderAddress.substring(0, 6)}…${a.spenderAddress.substring(a.spenderAddress.length - 4)}';

    final isSelected = selectedKeys.contains('${a.spenderAddress}-${a.token}');

    Color groupColor;
    IconData groupIcon;
    if (group == "Critical") {
      groupColor = GuardianColors.danger;
      groupIcon = Icons.gpp_bad;
    } else if (group == "Warning") {
      groupColor = GuardianColors.warning;
      groupIcon = Icons.warning_amber_rounded;
    } else {
      groupColor = GuardianColors.success;
      groupIcon = Icons.shield;
    }

    return GestureDetector(
      onTap: () => _showRiskDetailsSheet(a, detail, group),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: GuardianColors.surfaceElevated,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: allowToggle && isSelected
                  ? GuardianColors.success
                  : groupColor.withOpacity(0.3),
              width: 1.5),
        ),
        child: Row(
          children: [
            if (allowToggle && widget.mode == GuardianMode.safe) ...[
              GestureDetector(
                onTap: () => _controller.toggleSelection(a),
                child: Icon(
                    isSelected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: isSelected
                        ? GuardianColors.success
                        : GuardianColors.textSecondary,
                    size: 28),
              ),
              const SizedBox(width: 16),
            ],
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: groupColor.withOpacity(0.15), shape: BoxShape.circle),
              child: Icon(groupIcon, color: groupColor, size: 20),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(symbol,
                      style:
                          GuardianTextStyles.headline.copyWith(fontSize: 18)),
                  const SizedBox(height: 4),
                  Text(
                      LocalizationService.instance
                          .t('guardianSpender', {'addr': shortSpender}),
                      style: GuardianTextStyles.caption.copyWith(
                          fontFamily: 'monospace',
                          color: GuardianColors.textSecondary,
                          fontSize: 12)),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                  color: groupColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8)),
              child: Text(group.toUpperCase(),
                  style: GuardianTextStyles.caption.copyWith(
                      color: groupColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }

  void _showRiskDetailsSheet(
      ApprovalData a, _HumanRiskDetail detail, String group) {
    Color groupColor;
    if (group == "Critical") {
      groupColor = GuardianColors.danger;
    } else if (group == "Warning") {
      groupColor = GuardianColors.warning;
    } else {
      groupColor = GuardianColors.success;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: GuardianColors.surfaceElevated,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        final t = LocalizationProvider.of(ctx);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(t.t('guardianInsightsTitle'),
                        style:
                            GuardianTextStyles.headline.copyWith(fontSize: 22)),
                    IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(ctx)),
                  ],
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                      color: GuardianColors.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: GuardianColors.glassBorder)),
                  child: Column(
                    children: [
                      Row(children: [
                        SizedBox(
                            width: 80,
                            child: Text(t.t('guardianInsightToken'),
                                style: const TextStyle(
                                    color: GuardianColors.textSecondary))),
                        Expanded(
                            child: Text(
                                a.tokenSymbol ?? a.token.substring(0, 8),
                                style: const TextStyle(
                                    color: GuardianColors.textPrimary,
                                    fontWeight: FontWeight.bold)))
                      ]),
                      const SizedBox(height: 8),
                      Row(children: [
                        SizedBox(
                            width: 80,
                            child: Text(t.t('guardianInsightSpender'),
                                style: const TextStyle(
                                    color: GuardianColors.textSecondary))),
                        Expanded(
                            child: Text(a.spenderAddress,
                                style: const TextStyle(
                                    color: GuardianColors.textSecondary,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'monospace')))
                      ]),
                      const SizedBox(height: 16),
                      const Divider(color: GuardianColors.glassBorder),
                      const SizedBox(height: 16),
                      Row(children: [
                        Text(
                            LocalizationService.instance.t('guardianRiskLevel'),
                            style: const TextStyle(
                                color: GuardianColors.textSecondary)),
                        const SizedBox(width: 8),
                        Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                                color: groupColor.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(8)),
                            child: Text(group.toUpperCase(),
                                style: GuardianTextStyles.caption.copyWith(
                                    color: groupColor,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 11)))
                      ]),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _ExplanationBlock(
                    title: t.t('guardianInsightReason'),
                    text: detail.reason,
                    icon: Icons.info_outline,
                    color: GuardianColors.info),
                const SizedBox(height: 16),
                _ExplanationBlock(
                    title: t.t('guardianInsightImpact'),
                    text: detail.impact,
                    icon: Icons.warning_amber_rounded,
                    color: GuardianColors.warning),
                const SizedBox(height: 16),
                _ExplanationBlock(
                    title: t.t('guardianInsightRecommendation'),
                    text: detail.recommendation,
                    icon: Icons.shield_outlined,
                    color: GuardianColors.success),
                const SizedBox(height: 32),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: GuardianColors.surface,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: const BorderSide(
                              color: GuardianColors.glassBorder))),
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(t.t('guardianInsightGotIt'),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildExecutingPhase() {
    final m = _controller.model;
    final p = m.progress;
    final percent = p?.percent ?? 0.0;
    final isWaiting = m.state == GuardianFlowState.waitingWallet;

    final t = LocalizationProvider.of(context);
    String headerText = '';
    if (m.state == GuardianFlowState.queuePrepared) {
      headerText = t.t('guardianExecPreparing');
    } else if (isWaiting) {
      headerText = t.t('guardianExecWaitingWallet');
    } else {
      headerText = p != null
          ? t.t('guardianExecRevoking', {
              'completed': p.completed.toString(),
              'total': p.total.toString()
            })
          : t.t('guardianExecRevokingAuth');
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 20),
          Center(
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 140,
                  height: 140,
                  child: CircularProgressIndicator(
                      value: p == null ? null : percent,
                      strokeWidth: 8,
                      backgroundColor: GuardianColors.glassBorder,
                      color: _modeColor),
                ),
                Text(p == null ? '…' : '${(percent * 100).toInt()}%',
                    style: GuardianTextStyles.headline.copyWith(fontSize: 32)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(headerText,
              style: GuardianTextStyles.headline.copyWith(fontSize: 22),
              textAlign: TextAlign.center),
          if (isWaiting)
            Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                      color: GuardianColors.warning.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: GuardianColors.warning)),
                  child: Row(
                    children: [
                      const Icon(Icons.account_balance_wallet,
                          color: GuardianColors.warning),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Text(t.t('guardianExecApproveWallet'),
                              style: GuardianTextStyles.bodyPrimary)),
                    ],
                  ),
                )),
          const SizedBox(height: 48),
          Text(t.t('guardianExecLiveLog'),
              style: GuardianTextStyles.titleMedium.copyWith(fontSize: 18)),
          const SizedBox(height: 16),
          if (p == null && isWaiting)
            _JobLogItem(
                status: RevokeJobStatus.waitingWallet,
                symbol: t.t('guardianExecSystemQueue'),
                label: t.t('guardianExecAwaitingSignature')),
          if (p == null && !isWaiting && TransactionQueue().currentJobs.isEmpty)
            Text(t.t('guardianExecNoTxStarted'),
                style: GuardianTextStyles.bodySecondary
                    .copyWith(fontStyle: FontStyle.italic)),
          ...TransactionQueue().currentJobs.map((job) => _JobLogItem(
              status: job.status,
              symbol: job.approval.tokenSymbol ??
                  job.approval.token.substring(0, 8),
              label: _statusLabel(job.status))),
        ],
      ),
    );
  }

  String _statusLabel(RevokeJobStatus s) {
    final t = LocalizationService.instance;
    switch (s) {
      case RevokeJobStatus.pending:
        return t.t('guardianJobQueued');
      case RevokeJobStatus.waitingWallet:
        return t.t('guardianJobAwaitingWallet');
      case RevokeJobStatus.submitted:
        return t.t('guardianJobSent');
      case RevokeJobStatus.confirmed:
        return t.t('guardianJobConfirmed');
      case RevokeJobStatus.failed:
        return t.t('guardianJobFailed');
    }
  }

  Widget _buildExecutionCompletePhase() {
    final t = LocalizationService.instance;
    final p = _controller.model.progress;
    final success = p?.successCount ?? 0;
    final failed = p?.failedCount ?? 0;
    final allOk = failed == 0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 20),
          Center(
            child: Container(
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: allOk
                      ? GuardianColors.success.withOpacity(0.15)
                      : GuardianColors.warning.withOpacity(0.15)),
              child: Icon(allOk ? Icons.shield : Icons.warning_amber_rounded,
                  color:
                      allOk ? GuardianColors.success : GuardianColors.warning,
                  size: 80),
            ),
          ),
          const SizedBox(height: 32),
          Text(
              allOk
                  ? (widget.mode == GuardianMode.safe
                      ? t.t('guardianCompleteReviewTitle')
                      : t.t('guardianCompleteRevokeTitle'))
                  : t.t('guardianCompleteWithErrors'),
              style: GuardianTextStyles.headline.copyWith(fontSize: 28),
              textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Text(
              allOk
                  ? t.t('guardianCompleteOkBody')
                  : t.t('guardianCompleteErrorBody'),
              style: GuardianTextStyles.bodySecondary.copyWith(fontSize: 16),
              textAlign: TextAlign.center),
          const SizedBox(height: 40),
          Row(
            children: [
              _BigStatChip(
                  label: t.t('guardianStatRevoked'),
                  value: success,
                  color: GuardianColors.success),
              if (failed > 0) ...[
                const SizedBox(width: 12),
                _BigStatChip(
                    label: t.t('guardianStatFailed'),
                    value: failed,
                    color: GuardianColors.danger),
              ],
            ],
          ),
          const SizedBox(height: 40),
          Text(t.t('guardianFinalReport'),
              style: GuardianTextStyles.titleMedium.copyWith(fontSize: 18)),
          const SizedBox(height: 16),
          if (TransactionQueue().currentJobs.isEmpty)
            Text(t.t('guardianNoRevokeRequired'),
                style: GuardianTextStyles.bodySecondary
                    .copyWith(fontStyle: FontStyle.italic))
          else
            ...TransactionQueue().currentJobs.map((job) => _JobLogItem(
                status: job.status,
                symbol: job.approval.tokenSymbol ??
                    job.approval.token.substring(0, 8),
                label: _statusLabel(job.status),
                showDetail: true,
                job: job)),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// WIDGETS
// ═══════════════════════════════════════════════════════════════════════════════

class _BigStatChip extends StatelessWidget {
  final String label;
  final int value;
  final Color color;

  const _BigStatChip(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
            color: GuardianColors.surfaceElevated,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withOpacity(0.3), width: 1.5)),
        child: Column(
          children: [
            Text('$value',
                style: GuardianTextStyles.headline
                    .copyWith(color: color, fontSize: 32)),
            const SizedBox(height: 4),
            Text(label,
                style: GuardianTextStyles.titleMedium.copyWith(
                    color: GuardianColors.textSecondary, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _ExplanationBlock extends StatelessWidget {
  final String title;
  final String text;
  final IconData icon;
  final Color color;

  const _ExplanationBlock(
      {required this.title,
      required this.text,
      required this.icon,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: GuardianColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.3))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: GuardianTextStyles.titleMedium
                        .copyWith(color: color, fontSize: 16)),
                const SizedBox(height: 6),
                Text(text,
                    style: GuardianTextStyles.bodyPrimary
                        .copyWith(fontSize: 15, height: 1.4)),
              ],
            ),
          )
        ],
      ),
    );
  }
}

class _JobLogItem extends StatelessWidget {
  final RevokeJobStatus status;
  final String symbol;
  final String label;
  final bool showDetail;
  final RevokeJob? job;

  const _JobLogItem(
      {required this.status,
      required this.symbol,
      required this.label,
      this.showDetail = false,
      this.job});

  @override
  Widget build(BuildContext context) {
    IconData icon;
    Color color;
    switch (status) {
      case RevokeJobStatus.pending:
        icon = Icons.hourglass_empty;
        color = GuardianColors.textSecondary;
        break;
      case RevokeJobStatus.waitingWallet:
        icon = Icons.account_balance_wallet_outlined;
        color = GuardianColors.warning;
        break;
      case RevokeJobStatus.submitted:
        icon = Icons.check_circle;
        color = GuardianColors.success;
        break;
      case RevokeJobStatus.confirmed:
        icon = Icons.verified;
        color = GuardianColors.success;
        break;
      case RevokeJobStatus.failed:
        icon = Icons.cancel;
        color = GuardianColors.danger;
        break;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
          color: GuardianColors.surfaceElevated,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.3), width: 1.5)),
      child: Row(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(symbol,
                    style:
                        GuardianTextStyles.titleMedium.copyWith(fontSize: 16)),
                if (showDetail && job?.txHash != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('tx: ${job!.txHash!.substring(0, 10)}…',
                          style: GuardianTextStyles.caption.copyWith(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: GuardianColors.textSecondary))),
                if (showDetail && job?.error != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(job!.error!,
                          style: GuardianTextStyles.caption.copyWith(
                              color: GuardianColors.danger, fontSize: 12),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
          Text(label,
              style: GuardianTextStyles.titleMedium.copyWith(color: color)),
        ],
      ),
    );
  }
}

class _HumanRiskDetail {
  final String reason;
  final String impact;
  final String recommendation;

  const _HumanRiskDetail({
    required this.reason,
    required this.impact,
    required this.recommendation,
  });
}
