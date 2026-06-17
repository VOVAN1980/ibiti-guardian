import 'package:flutter/material.dart';
import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/market/wallet_exposure_service.dart';

// ─── Exposure Summary ──────────────────────────────────────────────────────────

/// Block 3: What do I already have?
///
/// Shows only decision-relevant data:
///  - Top non-stable positions
///  - Remaining capacity per asset
///  - Concentration warning if near/over mandate limit
///  - AI action hint: add / addCaution / hold / blocked
///
/// Does NOT show the full portfolio — that lives in the wallet screen.
class ExposureSummary extends StatelessWidget {
  final List<WalletAsset> positions;
  final AutonomyMandate mandate;

  const ExposureSummary({
    super.key,
    required this.positions,
    required this.mandate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            LocalizationService.instance.t('marketCmdMyPositions'),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 10),

          // Position rows.
          ...positions.map((pos) => _PositionRow(
                asset: pos,
                mandate: mandate,
              )),
        ],
      ),
    );
  }
}

// ─── Position Row ──────────────────────────────────────────────────────────────

class _PositionRow extends StatelessWidget {
  final WalletAsset asset;
  final AutonomyMandate mandate;

  const _PositionRow({required this.asset, required this.mandate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final exposure =
        WalletExposureService.instance.snapshotFor(asset.symbol, mandate);

    final actionColor = switch (exposure.action) {
      ExposureAction.add => Colors.greenAccent.shade400,
      ExposureAction.addCaution => Colors.amber.shade600,
      ExposureAction.hold => Colors.orange,
      ExposureAction.blockedByExposure => Colors.redAccent,
    };

    final actionLabel = switch (exposure.action) {
      ExposureAction.add => LocalizationService.instance.t('exposureCanAdd'),
      ExposureAction.addCaution =>
        LocalizationService.instance.t('exposureAddCaution'),
      ExposureAction.hold => LocalizationService.instance.t('exposureHold'),
      ExposureAction.blockedByExposure =>
        LocalizationService.instance.t('exposureBlocked'),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: exposure.isOverLimit
              ? Colors.redAccent.withOpacity(0.3)
              : Colors.transparent,
        ),
      ),
      child: Row(
        children: [
          // Symbol + value.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  asset.symbol,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '\$${asset.valueUsd.toStringAsFixed(2)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
              ],
            ),
          ),

          // Capacity + action label.
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                actionLabel,
                style: TextStyle(
                  color: actionColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (mandate.maxPositionUsd > 0 && !exposure.isOverLimit)
                Text(
                  LocalizationService.instance.t('exposureRoom', {
                    'amount': exposure.remainingCapacityUsd.toStringAsFixed(0)
                  }),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.4),
                    fontSize: 11,
                  ),
                ),
              if (exposure.isOverLimit)
                Text(
                  LocalizationService.instance.t('exposureOver', {
                    'amount':
                        (-exposure.remainingCapacityUsd).toStringAsFixed(0)
                  }),
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
