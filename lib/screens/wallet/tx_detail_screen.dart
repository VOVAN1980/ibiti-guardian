import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/config/chains.dart';
import 'package:ibiti_guardian/models/on_chain_tx.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';
import 'package:url_launcher/url_launcher.dart';

/// Full-screen detail view for a single on-chain transaction.
class TxDetailScreen extends StatelessWidget {
  final OnChainTx tx;
  final String walletAddress;

  const TxDetailScreen({
    super.key,
    required this.tx,
    required this.walletAddress,
  });

  static String _t(String key, [Map<String, dynamic>? args]) =>
      LocalizationService.instance.t(key, args);

  /// "0.00012300" -> "0.000123"
  static String _trim(String s) {
    if (!s.contains('.')) return s;
    final trimmed = s.replaceFirst(RegExp(r'0+$'), '');
    return trimmed.endsWith('.')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    final (color, icon) = _typeStyle();
    final explorerUrl = ChainConfig.getTxUrl(tx.chainKey, tx.hash);
    final chainName = ChainConfig.getChainNameByKey(tx.chainKey);

    return Scaffold(
      backgroundColor: GuardianColors.background,
      appBar: AppBar(
        backgroundColor: GuardianColors.background,
        elevation: 0,
        title: Text(_t('txDetailTitle'), style: GuardianTextStyles.headline),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        child: Column(
          children: [
            // ── Header card ────────────────────────────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    color.withOpacity(0.15),
                    GuardianColors.surface,
                  ],
                ),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: color.withOpacity(0.25)),
              ),
              child: Column(
                children: [
                  // Type icon
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: color.withOpacity(0.3)),
                    ),
                    child: Icon(icon, color: color, size: 28),
                  ),
                  const SizedBox(height: 14),
                  // Title
                  Text(
                    _titleText(),
                    style: GuardianTextStyles.headline.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  // Amount
                  if (tx.value > 0 || tx.tokenSymbol != null)
                    Text(
                      _amountText(),
                      style: GuardianTextStyles.titleLarge.copyWith(
                        color: tx.isIncoming
                            ? GuardianColors.success
                            : Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  const SizedBox(height: 10),
                  // Status badge
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: tx.isSuccess
                          ? GuardianColors.success.withOpacity(0.12)
                          : GuardianColors.danger.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          tx.isSuccess
                              ? Icons.check_circle_rounded
                              : Icons.cancel_rounded,
                          color: tx.isSuccess
                              ? GuardianColors.success
                              : GuardianColors.danger,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          tx.isSuccess
                              ? _t('txDetailConfirmed')
                              : _t('txDetailFailed'),
                          style: GuardianTextStyles.caption.copyWith(
                            color: tx.isSuccess
                                ? GuardianColors.success
                                : GuardianColors.danger,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // ── Swap details (if swap) ─────────────────────────────────────
            if (tx.isSwap && tx.sellSymbol != null && tx.buySymbol != null) ...[
              _DetailCard(
                children: [
                  _DetailRow(
                    label: _t('txDetailSold'),
                    value:
                        '${tx.sellValue?.toStringAsFixed(4) ?? '?'} ${tx.sellSymbol}',
                    valueColor: GuardianColors.danger,
                  ),
                  _DetailRow(
                    label: _t('txDetailBought'),
                    value:
                        '${tx.buyValue?.toStringAsFixed(4) ?? '?'} ${tx.buySymbol}',
                    valueColor: GuardianColors.success,
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],

            // ── Main details ───────────────────────────────────────────────
            _DetailCard(
              children: [
                _CopyableRow(
                  label: _t('txDetailFrom'),
                  value: tx.from,
                  context: context,
                ),
                _CopyableRow(
                  label: _t('txDetailTo'),
                  value: tx.to,
                  context: context,
                ),
                _DetailRow(
                  label: _t('txDetailNetwork'),
                  value: chainName,
                ),
                _DetailRow(
                  label: _t('txDetailTime'),
                  value: _formatDateTime(tx.blockTimestamp),
                ),
                if (tx.feeNative != null)
                  _DetailRow(
                    label: _t('txDetailFee'),
                    value:
                        '${_trim(tx.feeNative!.toStringAsFixed(8))} ${tx.feeSymbol ?? ''}'
                            .trim(),
                  )
                else if (tx.gasUsed != null)
                  _DetailRow(
                    label: 'Gas',
                    value: tx.gasUsed!,
                  ),
                if (tx.tokenName != null)
                  _DetailRow(
                    label: _t('txDetailToken'),
                    value: tx.tokenName!,
                  ),
                if (tx.contractAddress != null)
                  _CopyableRow(
                    label: _t('txDetailContract'),
                    value: tx.contractAddress!,
                    context: context,
                  ),
              ],
            ),

            const SizedBox(height: 12),

            // ── Hash card ──────────────────────────────────────────────────
            _DetailCard(
              children: [
                _CopyableRow(
                  label: _t('txDetailHash'),
                  value: tx.hash,
                  context: context,
                ),
              ],
            ),

            const SizedBox(height: 20),

            // ── Explorer button ────────────────────────────────────────────
            if (explorerUrl != null)
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: () => _openExplorer(explorerUrl),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: Text(_t('txDetailOpenExplorer')),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: GuardianColors.accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    textStyle: GuardianTextStyles.button,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openExplorer(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  String _titleText() {
    if (tx.isSwap) {
      return 'Swap ${tx.sellSymbol ?? '?'} → ${tx.buySymbol ?? '?'}';
    }
    return switch (tx.type) {
      OnChainTxType.send =>
        _t('txRowSent', {'token': tx.tokenSymbol ?? _t('txRowFunds')}),
      OnChainTxType.receive =>
        _t('txRowReceived', {'token': tx.tokenSymbol ?? _t('txRowFunds')}),
      OnChainTxType.approval => _t('txRowApproval'),
      OnChainTxType.swap => 'Swap',
      OnChainTxType.other => 'Транзакция',
    };
  }

  String _amountText() {
    if (tx.isSwap && tx.buySymbol != null) {
      return '+${(tx.buyValue ?? tx.value).toStringAsFixed(4)} ${tx.buySymbol}';
    }
    if (tx.tokenSymbol != null) {
      return '${tx.value.toStringAsFixed(4)} ${tx.tokenSymbol}';
    }
    if (tx.value > 0) {
      return tx.value.toStringAsFixed(6);
    }
    return '';
  }

  (Color, IconData) _typeStyle() {
    if (!tx.isSuccess) return (GuardianColors.danger, Icons.cancel_rounded);
    return switch (tx.type) {
      OnChainTxType.send => (GuardianColors.accent, Icons.arrow_upward_rounded),
      OnChainTxType.receive => (
          GuardianColors.success,
          Icons.arrow_downward_rounded
        ),
      OnChainTxType.approval => (
          GuardianColors.warning,
          Icons.lock_open_rounded
        ),
      OnChainTxType.swap => (const Color(0xFF9B59B6), Icons.swap_horiz_rounded),
      OnChainTxType.other => (
          GuardianColors.textSecondary,
          Icons.receipt_long_rounded
        ),
    };
  }

  String _formatDateTime(DateTime t) {
    final d = t.toLocal();
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    final s = d.second.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    final month = d.month.toString().padLeft(2, '0');
    return '$day.$month.${d.year}, $h:$m:$s';
  }
}

// ── Detail card container ────────────────────────────────────────────────────

class _DetailCard extends StatelessWidget {
  final List<Widget> children;
  const _DetailCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: GuardianColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: GuardianColors.glassBorder),
      ),
      child: Column(
        children: [
          for (int i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Divider(
                  height: 1,
                  color: GuardianColors.glassBorder.withOpacity(0.5),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// ── Simple label → value row ─────────────────────────────────────────────────

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _DetailRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 90,
          child: Text(
            label,
            style: GuardianTextStyles.caption.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: GuardianTextStyles.bodySecondary.copyWith(
              color: valueColor ?? GuardianColors.textPrimary,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

// ── Copyable address/hash row ────────────────────────────────────────────────

class _CopyableRow extends StatelessWidget {
  final String label;
  final String value;
  final BuildContext context;

  const _CopyableRow({
    required this.label,
    required this.value,
    required this.context,
  });

  String get _shortValue {
    if (value.length <= 20) return value;
    return '${value.substring(0, 10)}...${value.substring(value.length - 8)}';
  }

  @override
  Widget build(BuildContext outerContext) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 90,
          child: Text(
            label,
            style: GuardianTextStyles.caption.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: GestureDetector(
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(LocalizationService.instance
                    .t('txDetailCopied', {'label': label})),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 1),
              ));
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: GuardianColors.surfaceElevated,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      _shortValue,
                      style: GuardianTextStyles.mono.copyWith(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.copy_rounded,
                      size: 13, color: GuardianColors.textTertiary),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
