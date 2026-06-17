import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';
import 'package:ibiti_guardian/models/swap_execution_plan.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/policy/guardian_policy_engine.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';

/// Displays a swap quote preview with route info, price impact, fees,
/// min-received, route summary, quote freshness and approve-step warning.
///
/// Unlike [TransactionPreviewCard] (which handles a single tx),
/// this widget represents the full [SwapExecutionPlan] and drives
/// the two-step confirmation flow.
///
/// When the wallet is not connected / unlocked, the confirmation button
/// shows "Execution not available" — honest preview-only mode.
class SwapPreviewCard extends StatefulWidget {
  final SwapExecutionPlan plan;
  final ExecutionPath executionPath;
  final PolicySeverity severity;

  /// Called when the user confirms step 1 (approve) or step 2 (swap).
  /// Returns true only when the step was actually dispatched successfully.
  /// [stepIndex] is 0 for approve, 1 for swap.
  final Future<bool> Function(int stepIndex) onConfirmStep;
  final VoidCallback onCancel;

  const SwapPreviewCard({
    super.key,
    required this.plan,
    required this.executionPath,
    required this.severity,
    required this.onConfirmStep,
    required this.onCancel,
  });

  @override
  State<SwapPreviewCard> createState() => _SwapPreviewCardState();
}

class _SwapPreviewCardState extends State<SwapPreviewCard> {
  static const Duration _quoteTtl = Duration(minutes: 5);

  /// 0 = waiting for approve (if needed), 1 = waiting for swap, 2 = done
  int _currentStep = 0;

  // Quote freshness
  Timer? _freshnessTimer;
  Duration _remaining = const Duration(minutes: 5);
  bool get _isStale => _remaining.inSeconds <= 0;

  @override
  void initState() {
    super.initState();
    _currentStep = widget.plan.requiresApproval ? 0 : 1;
    _remaining = _computeRemaining();
    _startFreshnessTimer();
  }

  @override
  void dispose() {
    _freshnessTimer?.cancel();
    super.dispose();
  }

  void _startFreshnessTimer() {
    _freshnessTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _remaining = _computeRemaining();
      });
    });
  }

  Duration _computeRemaining() {
    final expiresAt = widget.plan.quote.quoteTimestamp.toUtc().add(_quoteTtl);
    final remaining = expiresAt.difference(DateTime.now().toUtc());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  Color get _headerColor {
    switch (widget.severity) {
      case PolicySeverity.danger:
        return GuardianColors.danger;
      case PolicySeverity.warning:
        return GuardianColors.warning;
      default:
        return GuardianColors.accent;
    }
  }

  /// Execution is ready when wallet is connected + vault is unlocked.
  bool get _isExecutionReady {
    final w = WalletAdapter.instance;
    return w.isConnected && w.isUnlocked;
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final quote = plan.quote;

    final expectedOutEth = quote.expectedOutputAmount.toDouble() / 1e18;
    final minOutEth = quote.minOutputAmount.toDouble() / 1e18;
    final feeEth = quote.networkFeeWei.toDouble() / 1e18;

    // Extra fields from quoteSummary (injected by ZeroXSwapProvider)
    final routeSummary =
        plan.swapStep.quoteSummary?['routeSummary']?.toString() ?? '';
    final allowanceTarget =
        plan.swapStep.quoteSummary?['allowanceTarget']?.toString() ?? '';

    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: GuardianColors.surface,
        border: Border.all(color: _headerColor.withOpacity(0.5)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ─────────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: _headerColor.withOpacity(0.12),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                Icon(Icons.swap_horiz_rounded, color: _headerColor, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'SWAP  ${plan.swapStep.tokenSymbol ?? '?'} → '
                    '${plan.swapStep.targetTokenSymbol ?? '?'}',
                    style: GuardianTextStyles.headline
                        .copyWith(color: _headerColor, fontSize: 14),
                  ),
                ),
                _FreshnessBadge(remaining: _remaining, isStale: _isStale),
                const SizedBox(width: 8),
                _StepBadge(
                  total: plan.totalSteps,
                  current: _currentStep == 0 ? 1 : 2,
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Amounts ────────────────────────────────────────────────
                _InfoRow(
                  label: 'You send',
                  value: '${plan.swapStep.amount?.toStringAsFixed(4) ?? '?'} '
                      '${plan.swapStep.tokenSymbol ?? ''}',
                ),
                _InfoRow(
                  label: 'Expected receive',
                  value: '≈ ${expectedOutEth.toStringAsFixed(6)} '
                      '${plan.swapStep.targetTokenSymbol ?? ''}',
                ),
                _InfoRow(
                  label: 'Min guaranteed',
                  value: '≥ ${minOutEth.toStringAsFixed(6)} '
                      '${plan.swapStep.targetTokenSymbol ?? ''}',
                  valueColor: GuardianColors.accent,
                ),
                _InfoRow(
                  label: 'Price impact',
                  value: '${quote.priceImpactPct.toStringAsFixed(2)}%',
                  valueColor: quote.priceImpactPct > 5
                      ? GuardianColors.danger
                      : quote.priceImpactPct > 1
                          ? GuardianColors.warning
                          : null,
                ),
                _InfoRow(
                  label: 'Network fee',
                  value: '≈ ${feeEth.toStringAsFixed(6)} native',
                ),
                _InfoRow(
                  label: 'Provider',
                  value: quote.providerName,
                ),
                if (routeSummary.isNotEmpty)
                  _InfoRow(
                    label: 'Route',
                    value: routeSummary,
                    valueColor: GuardianColors.textSecondary,
                  ),
                _InfoRow(
                  label: 'Execution path',
                  value: widget.executionPath.label,
                  valueColor: GuardianColors.accent,
                ),

                // ── Stale quote warning ────────────────────────────────────
                if (_isStale) ...[
                  const SizedBox(height: 10),
                  const _WarningBanner(
                    icon: Icons.timer_off_outlined,
                    color: GuardianColors.danger,
                    message:
                        'Quote expired. Close and request a new swap to get a fresh rate.',
                  ),
                ],

                // ── Approve warning ────────────────────────────────────────
                if (plan.requiresApproval) ...[
                  const SizedBox(height: 10),
                  _ApproveWarningBanner(
                    tokenSymbol: plan.swapStep.tokenSymbol ?? '?',
                    allowanceTarget: allowanceTarget.isNotEmpty
                        ? allowanceTarget
                        : quote.routerAddress,
                    stepDone: _currentStep > 0,
                  ),
                ],

                // ── Execution mode banner ──────────────────────────────────
                if (!_isExecutionReady) ...[
                  const SizedBox(height: 10),
                  const _WarningBanner(
                    icon: Icons.lock_outline,
                    color: GuardianColors.textSecondary,
                    message:
                        'Route found. Execution will be available once the '
                        'wallet is connected and unlocked.',
                  ),
                ],

                const SizedBox(height: 16),

                // ── Step prompt ────────────────────────────────────────────
                _buildStepPrompt(plan),

                const SizedBox(height: 12),

                // ── Action buttons ─────────────────────────────────────────
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(
                              color: GuardianColors.glassBorder),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: widget.onCancel,
                        child: Text(
                            LocalizationService.instance.t('swapCancel'),
                            style: const TextStyle(
                                color: GuardianColors.textSecondary)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: _isStale || !_isExecutionReady
                          ? _PreviewOnlyButton(
                              isStale: _isStale,
                              isExecutionReady: _isExecutionReady,
                            )
                          : ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _headerColor,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                              onPressed: () async {
                                HapticFeedback.mediumImpact();
                                final current = _currentStep == 0 ? 0 : 1;
                                final ok = await widget.onConfirmStep(current);
                                if (!mounted || !ok) return;
                                if (plan.requiresApproval &&
                                    _currentStep == 0) {
                                  setState(() => _currentStep = 1);
                                }
                              },
                              child: Text(
                                _currentStep == 0
                                    ? 'Approve ${plan.swapStep.tokenSymbol}'
                                    : 'Confirm Swap',
                              ),
                            ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepPrompt(SwapExecutionPlan plan) {
    if (_currentStep == 0) {
      return Text(
        'Step 1 of 2: Grant the router permission to spend your '
        '${plan.swapStep.tokenSymbol}. This requires a separate transaction.',
        style: GuardianTextStyles.caption
            .copyWith(color: GuardianColors.textSecondary),
      );
    }
    return Text(
      plan.requiresApproval
          ? 'Step 2 of 2: Now confirm the swap.'
          : 'Confirm the swap to proceed.',
      style: GuardianTextStyles.caption
          .copyWith(color: GuardianColors.textSecondary),
    );
  }
}

// ── Helper widgets ─────────────────────────────────────────────────────────────

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _InfoRow({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: GuardianTextStyles.caption
                  .copyWith(color: GuardianColors.textSecondary)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: GuardianTextStyles.caption.copyWith(
                color: valueColor ?? GuardianColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FreshnessBadge extends StatelessWidget {
  final Duration remaining;
  final bool isStale;

  const _FreshnessBadge({required this.remaining, required this.isStale});

  @override
  Widget build(BuildContext context) {
    final mins = remaining.inMinutes;
    final secs = remaining.inSeconds % 60;
    final label =
        isStale ? 'EXPIRED' : '$mins:${secs.toString().padLeft(2, '0')}';
    final color = isStale
        ? GuardianColors.danger
        : remaining.inSeconds < 60
            ? GuardianColors.warning
            : GuardianColors.textSecondary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        border: Border.all(color: color.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_outlined, size: 11, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style:
                GuardianTextStyles.caption.copyWith(fontSize: 10, color: color),
          ),
        ],
      ),
    );
  }
}

class _StepBadge extends StatelessWidget {
  final int total;
  final int current;

  const _StepBadge({required this.total, required this.current});

  @override
  Widget build(BuildContext context) {
    if (total <= 1) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: GuardianColors.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$current / $total',
        style: GuardianTextStyles.caption.copyWith(fontSize: 11),
      ),
    );
  }
}

class _WarningBanner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String message;

  const _WarningBanner(
      {required this.icon, required this.color, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07),
        border: Border.all(color: color.withOpacity(0.25)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: GuardianTextStyles.caption.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _ApproveWarningBanner extends StatelessWidget {
  final String tokenSymbol;
  final String allowanceTarget;
  final bool stepDone;

  const _ApproveWarningBanner({
    required this.tokenSymbol,
    required this.allowanceTarget,
    required this.stepDone,
  });

  @override
  Widget build(BuildContext context) {
    final shortAddr = allowanceTarget.length > 10
        ? '${allowanceTarget.substring(0, 6)}...${allowanceTarget.substring(allowanceTarget.length - 4)}'
        : allowanceTarget;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: GuardianColors.warning.withOpacity(0.08),
        border: Border.all(color: GuardianColors.warning.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            stepDone ? Icons.check_circle_outline : Icons.info_outline,
            size: 15,
            color: stepDone ? GuardianColors.accent : GuardianColors.warning,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              stepDone
                  ? '$tokenSymbol approval granted ✓'
                  : 'Approval required: grant 0x AllowanceHolder ($shortAddr) '
                      'permission to spend your $tokenSymbol.',
              style: GuardianTextStyles.caption.copyWith(
                color:
                    stepDone ? GuardianColors.accent : GuardianColors.warning,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewOnlyButton extends StatelessWidget {
  final bool isStale;
  final bool isExecutionReady;

  const _PreviewOnlyButton(
      {required this.isStale, required this.isExecutionReady});

  @override
  Widget build(BuildContext context) {
    final label = isStale ? 'Quote Expired' : 'Wallet Not Ready';
    final icon = isStale ? Icons.timer_off_outlined : Icons.lock_outline;

    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: GuardianColors.surfaceElevated,
        foregroundColor: GuardianColors.textSecondary,
        disabledBackgroundColor: GuardianColors.surfaceElevated,
        disabledForegroundColor: GuardianColors.textSecondary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        elevation: 0,
      ),
      onPressed: null, // always disabled
      icon: Icon(icon, size: 15),
      label: Text(label, style: const TextStyle(fontSize: 13)),
    );
  }
}
