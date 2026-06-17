import 'package:flutter/material.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/models/transaction_explanation.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/rpc_simulation_result.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/policy/guardian_policy_engine.dart';

/// Phase 7 Premium Banking-Grade Signature Preview Card.
class TransactionPreviewCard extends StatefulWidget {
  final TransactionRequest transaction;
  final TransactionExplanation explanation;
  final PolicyResult policyResult;
  final RpcSimulationResult rpcResult;
  final ExecutionPath executionPath;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const TransactionPreviewCard({
    super.key,
    required this.transaction,
    required this.explanation,
    required this.policyResult,
    required this.rpcResult,
    required this.executionPath,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<TransactionPreviewCard> createState() => _TransactionPreviewCardState();
}

class _TransactionPreviewCardState extends State<TransactionPreviewCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _scaleAnim;
  bool _isExpanded = false;
  bool _acknowledgedRisk = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 350));
    _scaleAnim =
        CurvedAnimation(parent: _animController, curve: Curves.easeOutBack);
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Color _headerColor() {
    if (widget.policyResult.blocked || !widget.rpcResult.success) {
      return GuardianColors.danger;
    }
    switch (widget.policyResult.severity) {
      case PolicySeverity.danger:
        return GuardianColors.danger;
      case PolicySeverity.warning:
        return GuardianColors.warning;
      case PolicySeverity.info:
      case PolicySeverity.safe:
        return GuardianColors.success;
    }
  }

  IconData _headerIcon() {
    if (widget.policyResult.blocked) return Icons.gpp_bad_rounded;
    if (!widget.rpcResult.success) return Icons.running_with_errors_rounded;
    switch (widget.policyResult.severity) {
      case PolicySeverity.danger:
        return Icons.warning_rounded;
      case PolicySeverity.warning:
        return Icons.info_outline_rounded;
      case PolicySeverity.info:
      case PolicySeverity.safe:
        return Icons.verified_user_rounded;
    }
  }

  String _headerText() {
    final loc = LocalizationService.instance;
    if (widget.policyResult.blocked) return loc.t('txPreviewBlocked');
    if (!widget.rpcResult.success) return loc.t('txPreviewNetworkFailure');
    switch (widget.policyResult.severity) {
      case PolicySeverity.danger:
        return loc.t('txPreviewCriticalRisk');
      case PolicySeverity.warning:
        return loc.t('txPreviewReviewRequired');
      case PolicySeverity.info:
      case PolicySeverity.safe:
        return loc.t('txPreviewSafeProfile');
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _headerColor();

    return ScaleTransition(
      scale: _scaleAnim,
      child: Container(
        decoration: BoxDecoration(
          color: GuardianColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.5), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: color.withOpacity(0.2),
              blurRadius: 24,
              spreadRadius: 2,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Safe / Danger Header Banner
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(14),
                    topRight: Radius.circular(14)),
              ),
              child: Row(
                children: [
                  Icon(_headerIcon(), color: color, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _headerText(),
                      style: GuardianTextStyles.titleMedium
                          .copyWith(color: color, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),

            Flexible(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildRequestRow(),
                      const SizedBox(height: 20),
                      _buildRiskBadges(),
                      const SizedBox(height: 20),
                      _buildHumanReadableSections(),
                      const SizedBox(height: 16),
                      _buildExpandableExplain(color),
                      const SizedBox(height: 24),
                      if (_requiresEnhancedConfirmation) ...[
                        _buildRiskAcknowledgement(),
                        const SizedBox(height: 16),
                      ],
                      if (!widget.policyResult.blocked && widget.rpcResult.success)
                        _buildPrimaryAction(),
                      if (!widget.policyResult.blocked && widget.rpcResult.success)
                        const SizedBox(height: 12),
                      _buildCancelAction(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRequestRow() {
    final loc = LocalizationService.instance;
    final amountLabel = widget.transaction.amount == null
        ? 'Unknown'
        : '${widget.transaction.amount} ${widget.transaction.tokenSymbol ?? ''}'
            .trim();
    final feeLabel = _formatFee(widget.rpcResult.estimatedGas);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.explanation.headline,
            style: GuardianTextStyles.headline.copyWith(fontSize: 22)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: GuardianColors.surfaceElevated,
            borderRadius: BorderRadius.circular(12),
            border:
                Border.all(color: GuardianColors.glassBorder.withOpacity(0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv(loc.t('txPreviewFrom'), widget.transaction.fromAddress,
                  mono: true),
              _kv(
                widget.transaction.spenderAddress != null
                    ? loc.t('txPreviewSpender')
                    : loc.t('txPreviewTo'),
                widget.transaction.spenderAddress ??
                    widget.transaction.toAddress,
                mono: true,
              ),
              _kv(loc.t('txPreviewChain'), widget.transaction.networkLabel),
              _kv(loc.t('txPreviewToken'),
                  widget.transaction.tokenSymbol ?? loc.t('txPreviewNative')),
              _kv(loc.t('txPreviewAmount'), amountLabel),
              _kv(loc.t('txPreviewFee'), feeLabel),
            ],
          ),
        ),
      ],
    );
  }

  Widget _kv(String label, String value, {bool mono = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 58,
            child: Text(
              '$label:',
              style: GuardianTextStyles.caption.copyWith(
                color: GuardianColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: GuardianTextStyles.bodySecondary.copyWith(
                fontFamily: mono ? 'monospace' : null,
                fontSize: mono ? 13 : 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatFee(String? raw) {
    if (raw == null || raw.isEmpty) return 'Unknown';
    if (raw.startsWith('0x')) {
      final parsed = int.tryParse(raw.substring(2), radix: 16);
      if (parsed != null) return '$parsed gas';
    }
    return raw;
  }

  Widget _buildRiskBadges() {
    final loc = LocalizationService.instance;
    final List<Widget> badges = [];

    // Path Badge
    Color pathColor = GuardianColors.info;
    String pathText = loc.t('txPreviewProtectedExecution');
    IconData pathIcon = Icons.shield;

    if (widget.executionPath == ExecutionPath.epkProtected) {
      pathColor = GuardianColors.success;
      pathText = loc.t('txPreviewEpkSecured');
      pathIcon = Icons.lock_person;
    } else if (widget.executionPath == ExecutionPath.fallback) {
      pathColor = GuardianColors.warning;
      pathText = loc.t('txPreviewStandardPath');
      pathIcon = Icons.report_problem;
    }

    badges.add(_Badge(color: pathColor, icon: pathIcon, text: pathText));

    // Dynamic Risk Factor Badges based on Explainer
    for (String warning in widget.explanation.warnings) {
      if (warning.toLowerCase().contains('unverified') ||
          warning.toLowerCase().contains('unknown')) {
        badges.add(_Badge(
            color: GuardianColors.warning,
            icon: Icons.help_outline,
            text: loc.t('txPreviewUnknownContract')));
      } else if (warning.toLowerCase().contains('unlimited')) {
        badges.add(_Badge(
            color: GuardianColors.danger,
            icon: Icons.all_inclusive,
            text: loc.t('txPreviewUnlimitedTrust')));
      } else {
        badges.add(_Badge(
            color: GuardianColors.glassBorder,
            icon: Icons.flag,
            text: loc.t('txPreviewRiskFactor')));
      }
    }

    if (badges.isEmpty) {
      badges.add(_Badge(
          color: GuardianColors.success,
          icon: Icons.verified,
          text: loc.t('txPreviewCleanProfile')));
    }

    return Wrap(spacing: 8, runSpacing: 8, children: badges);
  }

  Widget _buildExpandableExplain(Color accent) {
    return InkWell(
      onTap: () => setState(() => _isExpanded = !_isExpanded),
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: GuardianColors.surfaceElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: _isExpanded
                  ? accent.withOpacity(0.5)
                  : GuardianColors.glassBorder.withOpacity(0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.psychology_outlined,
                    color: GuardianColors.textSecondary, size: 18),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(widget.explanation.riskSummary,
                        style: GuardianTextStyles.bodyPrimary
                            .copyWith(fontWeight: FontWeight.bold))),
                Icon(
                    _isExpanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    color: GuardianColors.textSecondary),
              ],
            ),
            if (_isExpanded) ...[
              const SizedBox(height: 12),
              const Divider(color: GuardianColors.glassBorder),
              const SizedBox(height: 12),
              Text(widget.explanation.detail,
                  style: GuardianTextStyles.caption.copyWith(height: 1.5)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHumanReadableSections() {
    final loc = LocalizationService.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _infoPanel(
          title: loc.t('txPreviewWhatSigning'),
          icon: Icons.edit_note_rounded,
          body: widget.explanation.signingExplanation,
        ),
        const SizedBox(height: 12),
        _infoPanel(
          title: loc.t('txPreviewExpectedOutcome'),
          icon: Icons.route_rounded,
          body: widget.explanation.expectedOutcome,
        ),
        const SizedBox(height: 12),
        _infoPanel(
          title: loc.t('txPreviewSimulation'),
          icon: Icons.science_outlined,
          body: widget.explanation.simulationSummary,
        ),
      ],
    );
  }

  Widget _infoPanel({
    required String title,
    required IconData icon,
    required String body,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: GuardianColors.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: GuardianColors.glassBorder.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: GuardianColors.textSecondary),
              const SizedBox(width: 8),
              Text(
                title,
                style: GuardianTextStyles.bodyPrimary.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: GuardianTextStyles.caption.copyWith(height: 1.45),
          ),
        ],
      ),
    );
  }

  bool get _requiresEnhancedConfirmation {
    if (widget.policyResult.blocked || !widget.rpcResult.success) return false;
    if (widget.transaction.isUnlimitedApproval) return true;
    if (widget.explanation.warnings.isNotEmpty) return true;
    return widget.policyResult.severity == PolicySeverity.warning ||
        widget.policyResult.severity == PolicySeverity.danger;
  }

  Widget _buildRiskAcknowledgement() {
    final loc = LocalizationService.instance;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: GuardianColors.warning.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: GuardianColors.warning.withOpacity(0.28)),
      ),
      child: CheckboxListTile(
        value: _acknowledgedRisk,
        onChanged: (value) =>
            setState(() => _acknowledgedRisk = value ?? false),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        activeColor: GuardianColors.warning,
        title: Text(
          loc.t('txPreviewRiskAckTitle'),
          style: GuardianTextStyles.bodyPrimary.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          loc.t('txPreviewRiskAckSubtitle'),
          style: GuardianTextStyles.caption,
        ),
      ),
    );
  }

  Widget _buildPrimaryAction() {
    return InkWell(
      onTap: _requiresEnhancedConfirmation && !_acknowledgedRisk
          ? null
          : widget.onConfirm,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: _requiresEnhancedConfirmation && !_acknowledgedRisk
              ? GuardianColors.textSecondary
              : GuardianColors.accent,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
                color: (_requiresEnhancedConfirmation && !_acknowledgedRisk
                        ? GuardianColors.textSecondary
                        : GuardianColors.accent)
                    .withOpacity(0.3),
                blurRadius: 16,
                offset: const Offset(0, 4)),
          ],
        ),
        alignment: Alignment.center,
        child: Text(LocalizationService.instance.t('txPreviewConfirmExecution'),
            style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildCancelAction() {
    return InkWell(
      onTap: widget.onCancel,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: GuardianColors.glassBorder),
        ),
        alignment: Alignment.center,
        child: Text(LocalizationService.instance.t('txPreviewRejectCancel'),
            style: const TextStyle(
                color: GuardianColors.textSecondary,
                fontSize: 16,
                fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String text;

  const _Badge({required this.color, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(text,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
