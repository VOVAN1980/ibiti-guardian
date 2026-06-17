import 'package:flutter/material.dart';
import 'package:ibiti_guardian/models/trading_plan.dart';
import 'package:ibiti_guardian/screens/wallet/components/wallet_swap_modal.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/utils/price_formatter.dart';

// ─── Active Plan Card ──────────────────────────────────────────────────────────

/// Block 3 (NEW): Shows the most recently built [TradingPlan].
///
/// Displays key trade parameters (direction, asset, entry, target, stop, size,
/// risk) and provides Execute/Cancel actions. Only visible when a plan exists.
class ActivePlanCard extends StatelessWidget {
  final TradingPlan plan;
  final VoidCallback? onDismiss;

  const ActivePlanCard({
    super.key,
    required this.plan,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = LocalizationService.instance;
    final dirLabel = switch (plan.direction) {
      TradingDirection.buy => l.t('planDirBuy'),
      TradingDirection.sell => l.t('planDirSell'),
      TradingDirection.swap => l.t('planDirSwap'),
      TradingDirection.swing => l.t('planDirSwing'),
    };
    final dirColor = switch (plan.direction) {
      TradingDirection.buy => Colors.greenAccent.shade400,
      TradingDirection.sell => Colors.redAccent,
      TradingDirection.swap => Colors.cyan,
      TradingDirection.swing => Colors.amber.shade400,
    };
    final riskColor = switch (plan.riskLevel) {
      TradingRisk.low => Colors.greenAccent.shade400,
      TradingRisk.medium => Colors.amber.shade400,
      TradingRisk.high => Colors.orange.shade400,
      TradingRisk.excessive => Colors.redAccent,
    };
    final riskLabel = switch (plan.riskLevel) {
      TradingRisk.low => l.t('planRiskLow'),
      TradingRisk.medium => l.t('planRiskMedium'),
      TradingRisk.high => l.t('planRiskHigh'),
      TradingRisk.excessive => l.t('planRiskExcessive'),
    };

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: dirColor.withOpacity(0.4),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header: direction badge + asset + dismiss ─────────────────
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: dirColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  dirLabel,
                  style: TextStyle(
                    color: dirColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                plan.asset.symbol,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: riskColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  riskLabel,
                  style: TextStyle(
                    color: riskColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: onDismiss,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.close_rounded,
                      size: 16,
                      color: theme.colorScheme.onSurface.withOpacity(0.4)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── Trade parameters grid ────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: _PlanParam(
                  label: l.t('planParamEntry'),
                  value: '\$${_fmt(plan.entryPrice)}',
                ),
              ),
              if (plan.targetPrice != null)
                Expanded(
                  child: _PlanParam(
                    label: l.t('planParamTarget'),
                    value: '\$${_fmt(plan.targetPrice!)}',
                    valueColor: Colors.greenAccent.shade400,
                  ),
                ),
              if (plan.stopLossPrice != null)
                Expanded(
                  child: _PlanParam(
                    label: l.t('planParamStop'),
                    value: '\$${_fmt(plan.stopLossPrice!)}',
                    valueColor: Colors.redAccent,
                  ),
                ),
              Expanded(
                child: _PlanParam(
                  label: l.t('planParamSize'),
                  value: '\$${plan.suggestedSizeUsd.toStringAsFixed(0)}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // ── Thesis ───────────────────────────────────────────────────
          Text(
            plan.thesis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withOpacity(0.6),
              height: 1.35,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),

          // ── Venue + route ────────────────────────────────────────────
          const SizedBox(height: 6),
          Text(
            plan.routeNote,
            style: TextStyle(
              color: theme.colorScheme.onSurface.withOpacity(0.4),
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 12),

          // ── Action buttons ───────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close_rounded, size: 14),
                  label: Text(l.t('planBtnCancel')),
                  style: OutlinedButton.styleFrom(
                    foregroundColor:
                        theme.colorScheme.onSurface.withOpacity(0.5),
                    side: BorderSide(
                      color: theme.colorScheme.onSurface.withOpacity(0.15),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed:
                      plan.executableByAi ? () => _executeSwap(context) : null,
                  icon: const Icon(Icons.flash_on_rounded, size: 16),
                  label: Text(plan.executableByAi
                      ? l.t('planBtnExecute')
                      : l.t('planBtnBlocked')),
                  style: FilledButton.styleFrom(
                    backgroundColor: dirColor,
                    foregroundColor: Colors.black,
                    disabledBackgroundColor:
                        theme.colorScheme.onSurface.withOpacity(0.08),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ],
          ),

          // ── Block reason ─────────────────────────────────────────────
          if (!plan.executableByAi && plan.blockReason != null) ...[
            const SizedBox(height: 6),
            Text(
              plan.blockReason!,
              style: TextStyle(
                color: Colors.orange.shade400.withOpacity(0.7),
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _executeSwap(BuildContext context) {
    final match = VaultPortfolioListener.instance.summary?.allAssets
        .where((a) => a.symbol.toLowerCase() == plan.asset.symbol.toLowerCase())
        .firstOrNull;
    if (plan.direction == TradingDirection.sell) {
      WalletSwapModal.show(context, initialFromAsset: match);
    } else {
      WalletSwapModal.show(context, initialToAsset: match);
    }
  }

  static String _fmt(double p) => PriceFormatter.price(p);
}

// ─── Plan Parameter chip ───────────────────────────────────────────────────────

class _PlanParam extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _PlanParam({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: theme.colorScheme.onSurface.withOpacity(0.4),
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? theme.colorScheme.onSurface,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
