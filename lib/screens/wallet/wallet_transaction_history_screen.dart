import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/models/on_chain_tx.dart';
import 'package:ibiti_guardian/models/tx_status.dart';
import 'package:ibiti_guardian/screens/wallet/tx_detail_screen.dart';
import 'package:ibiti_guardian/services/execution/tx_registry.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/moralis/moralis_tx_history_service.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

enum _TxFilter { all, sent, received, approvals, swaps }

class WalletTransactionHistoryScreen extends StatefulWidget {
  final String? walletAddress;

  const WalletTransactionHistoryScreen({
    super.key,
    this.walletAddress,
  });

  @override
  State<WalletTransactionHistoryScreen> createState() =>
      _WalletTransactionHistoryScreenState();
}

class _WalletTransactionHistoryScreenState
    extends State<WalletTransactionHistoryScreen> {
  List<OnChainTx> _txns = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  String? _nextCursor;
  String? _error;
  _TxFilter _filter = _TxFilter.all;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  String get _address =>
      widget.walletAddress ?? IBITIVaultService.instance.activeAddress;

  String get _chainKey => IBITIVaultService.instance.chainKey;

  Future<void> _loadHistory({bool reset = false}) async {
    if (reset) {
      setState(() {
        _txns = [];
        _nextCursor = null;
        _isLoading = true;
        _error = null;
      });
    } else {
      setState(() => _isLoading = true);
    }

    try {
      final page = await MoralisTxHistoryService.fetch(
        address: _address,
        chainKey: _chainKey,
      );
      if (mounted) {
        setState(() {
          _txns = page.transactions;
          _nextCursor = page.nextCursor;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_nextCursor == null || _isLoadingMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final page = await MoralisTxHistoryService.fetch(
        address: _address,
        chainKey: _chainKey,
        cursor: _nextCursor,
      );
      if (mounted) {
        setState(() {
          _txns.addAll(page.transactions);
          _nextCursor = page.nextCursor;
          _isLoadingMore = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  List<OnChainTx> get _filtered {
    switch (_filter) {
      case _TxFilter.all:
        return _txns;
      case _TxFilter.sent:
        return _txns.where((t) => t.type == OnChainTxType.send).toList();
      case _TxFilter.received:
        return _txns.where((t) => t.type == OnChainTxType.receive).toList();
      case _TxFilter.approvals:
        return _txns.where((t) => t.type == OnChainTxType.approval).toList();
      case _TxFilter.swaps:
        return _txns.where((t) => t.type == OnChainTxType.swap).toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GuardianColors.background,
      appBar: AppBar(
        backgroundColor: GuardianColors.background,
        elevation: 0,
        title: Text(LocalizationService.instance.t('txHistoryTitle'),
            style: GuardianTextStyles.headline),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
            onPressed: () => _loadHistory(reset: true),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Filter tabs ───────────────────────────────────────────────
          _FilterRow(
            current: _filter,
            onChanged: (f) => setState(() => _filter = f),
          ),

          // ── Pending Guardian TxRegistry items (overlay) ───────────────
          ListenableBuilder(
            listenable: TxRegistry.instance,
            builder: (context, _) {
              final pending = TxRegistry.instance.history
                  .where((e) =>
                      !e.isTerminal &&
                      (widget.walletAddress == null ||
                          e.walletAddress?.toLowerCase() ==
                              _address.toLowerCase()))
                  .toList()
                  .reversed
                  .toList();
              if (pending.isEmpty) return const SizedBox.shrink();
              return Container(
                color: GuardianColors.warning.withOpacity(0.08),
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(LocalizationService.instance.t('txHistoryPending'),
                        style: GuardianTextStyles.caption.copyWith(
                            color: GuardianColors.warning,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    ...pending.map((e) => _PendingTile(event: e)),
                  ],
                ),
              );
            },
          ),

          // ── On-chain history ──────────────────────────────────────────
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _ErrorState(
                        error: _error!,
                        onRetry: () => _loadHistory(reset: true))
                    : _filtered.isEmpty
                        ? _EmptyState(filter: _filter)
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                            itemCount: _filtered.length +
                                (_nextCursor != null ? 1 : 0),
                            itemBuilder: (context, idx) {
                              if (idx == _filtered.length) {
                                // Load more button
                                return Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: _isLoadingMore
                                      ? const Center(
                                          child: CircularProgressIndicator())
                                      : OutlinedButton(
                                          onPressed: _loadMore,
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor:
                                                GuardianColors.accent,
                                            side: const BorderSide(
                                                color: GuardianColors.accent),
                                          ),
                                          child: Text(LocalizationService
                                              .instance
                                              .t('txHistoryLoadMore')),
                                        ),
                                );
                              }
                              final tx = _filtered[idx];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: GestureDetector(
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => TxDetailScreen(
                                          tx: tx,
                                          walletAddress: _address,
                                        ),
                                      ),
                                    );
                                  },
                                  child: _OnChainTile(
                                      tx: tx, walletAddress: _address),
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}

// ── Filter row ────────────────────────────────────────────────────────────────

class _FilterRow extends StatelessWidget {
  final _TxFilter current;
  final ValueChanged<_TxFilter> onChanged;

  const _FilterRow({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final filters = [
      (_TxFilter.all, 'All'),
      (_TxFilter.sent, 'Sent'),
      (_TxFilter.received, 'Received'),
      (_TxFilter.approvals, 'Approvals'),
      (_TxFilter.swaps, 'Swaps'),
    ];

    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        itemCount: filters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final (filter, label) = filters[i];
          final isActive = filter == current;
          return GestureDetector(
            onTap: () => onChanged(filter),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: isActive
                    ? GuardianColors.accent
                    : GuardianColors.surfaceElevated,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                label,
                style: GuardianTextStyles.caption.copyWith(
                  color: isActive
                      ? GuardianColors.background
                      : GuardianColors.textSecondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── On-chain tile ─────────────────────────────────────────────────────────────

class _OnChainTile extends StatelessWidget {
  final OnChainTx tx;
  final String walletAddress;

  const _OnChainTile({required this.tx, required this.walletAddress});

  @override
  Widget build(BuildContext context) {
    final (color, icon) = _typeStyle();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: GuardianColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: tx.isSuccess
                ? color.withOpacity(0.2)
                : GuardianColors.danger.withOpacity(0.3)),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.06),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Icon
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _titleText(),
                      style: GuardianTextStyles.bodyPrimary
                          .copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tx.summary ?? _subtitleText(),
                      style: GuardianTextStyles.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (tx.value > 0 || tx.tokenSymbol != null)
                    Text(
                      _amountText(),
                      style: GuardianTextStyles.bodyPrimary.copyWith(
                        color: (tx.type == OnChainTxType.receive ||
                                tx.type == OnChainTxType.swap)
                            ? GuardianColors.success
                            : Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  Text(
                    _timeAgo(tx.blockTimestamp),
                    style: GuardianTextStyles.caption,
                  ),
                ],
              ),
            ],
          ),

          if (!tx.isSuccess) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: GuardianColors.danger.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(LocalizationService.instance.t('txHistoryFailed'),
                  style: GuardianTextStyles.caption
                      .copyWith(color: GuardianColors.danger)),
            ),
          ],

          const SizedBox(height: 10),
          // Hash row
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: tx.hash));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content:
                    Text(LocalizationService.instance.t('txHistoryHashCopied')),
                behavior: SnackBarBehavior.floating,
              ));
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: GuardianColors.surfaceElevated,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Text(
                    tx.shortHash,
                    style: GuardianTextStyles.caption
                        .copyWith(fontFamily: 'monospace'),
                  ),
                  const Spacer(),
                  const Icon(Icons.copy_rounded,
                      size: 14, color: GuardianColors.textTertiary),
                ],
              ),
            ),
          ),
        ],
      ),
    );
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

  String _titleText() {
    if (tx.type == OnChainTxType.swap) {
      final sell = tx.sellSymbol ?? '?';
      final buy = tx.buySymbol ?? '?';
      return 'Swapped $sell → $buy';
    }
    return switch (tx.type) {
      OnChainTxType.send => 'Sent ${tx.tokenSymbol ?? 'funds'}',
      OnChainTxType.receive => 'Received ${tx.tokenSymbol ?? 'funds'}',
      OnChainTxType.approval => 'Token approval',
      OnChainTxType.swap => 'Swap', // unreachable
      OnChainTxType.other => 'Transaction',
    };
  }

  String _subtitleText() {
    if (tx.type == OnChainTxType.swap) {
      return '${tx.sellSymbol ?? '?'} → ${tx.buySymbol ?? '?'}';
    }
    final addr = tx.type == OnChainTxType.receive ? tx.from : tx.to;
    final short = addr.length > 12
        ? '${addr.substring(0, 6)}...${addr.substring(addr.length - 4)}'
        : addr;
    return switch (tx.type) {
      OnChainTxType.send => 'To $short',
      OnChainTxType.receive => 'From $short',
      OnChainTxType.approval => 'Spender: $short',
      OnChainTxType.swap => 'Via smart contract', // unreachable
      OnChainTxType.other => short,
    };
  }

  String _amountText() {
    // Swaps: show the incoming (buy) side
    if (tx.type == OnChainTxType.swap && tx.buySymbol != null) {
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

  String _timeAgo(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 30) return '${diff.inDays}d ago';
    return '${t.day}/${t.month}/${t.year}';
  }
}

// ── Pending tx tile (from TxRegistry) ─────────────────────────────────────────

class _PendingTile extends StatelessWidget {
  final TxStatusEvent event;
  const _PendingTile({required this.event});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: GuardianColors.warning,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              event.operationLabel ?? event.statusLabel,
              style: GuardianTextStyles.caption.copyWith(
                color: GuardianColors.warning,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            '${event.txHash.substring(0, 8)}...',
            style: GuardianTextStyles.caption.copyWith(fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}

// ── Empty & Error states ──────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final _TxFilter filter;
  const _EmptyState({required this.filter});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.history_rounded,
                color: GuardianColors.textTertiary, size: 52),
            const SizedBox(height: 16),
            Text(
              filter == _TxFilter.all
                  ? 'No transactions yet'
                  : 'No ${filter.name} transactions found',
              style: GuardianTextStyles.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              filter == _TxFilter.all
                  ? 'Your on-chain activity will appear here.'
                  : 'Try selecting a different filter.',
              textAlign: TextAlign.center,
              style: GuardianTextStyles.bodySecondary,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorState({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded,
                color: GuardianColors.textTertiary, size: 52),
            const SizedBox(height: 16),
            Text(LocalizationService.instance.t('txHistoryLoadError'),
                style: GuardianTextStyles.titleMedium),
            const SizedBox(height: 8),
            Text(error,
                textAlign: TextAlign.center,
                style: GuardianTextStyles.bodySecondary,
                maxLines: 3,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(LocalizationService.instance.t('btnRetry')),
            ),
          ],
        ),
      ),
    );
  }
}
