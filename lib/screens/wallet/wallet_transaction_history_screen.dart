import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/models/on_chain_tx.dart';
import 'package:ibiti_guardian/models/tx_status.dart';
import 'package:ibiti_guardian/screens/wallet/tx_detail_screen.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_order_history_store.dart';
import 'package:ibiti_guardian/services/execution/tx_registry.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/history/tx_history_service.dart';
import 'package:ibiti_guardian/services/history/tx_history_merge.dart';
import 'package:ibiti_guardian/services/history/tx_spam_filter.dart';
import 'package:ibiti_guardian/services/adapters/portfolio_adapter.dart';
import 'package:ibiti_guardian/services/market/token_registry_service.dart';
import 'package:ibiti_guardian/services/wallet/token_manager_service.dart';
import 'package:ibiti_guardian/services/wallet/wallet_settings_service.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

enum _TxFilter { all, sent, received, approvals, swaps, exchange }

/// One row of the common history: an on-chain transaction or an exchange
/// (CEX) order.
sealed class _HistoryRow {
  const _HistoryRow();
}

class _TxRow extends _HistoryRow {
  const _TxRow(this.tx);
  final OnChainTx tx;
}

class _OrderRow extends _HistoryRow {
  const _OrderRow(this.order);
  final ExchangeOrderRecord order;
}

class WalletTransactionHistoryScreen extends StatefulWidget {
  final String? walletAddress;

  /// An entry to open right away: an exchange order id
  /// ([ExchangeOrderRecord.id] or the exchange's order id) or a transaction
  /// hash. The «ИИ выполнил: …» notification passes it.
  final String? focusId;

  const WalletTransactionHistoryScreen({
    super.key,
    this.walletAddress,
    this.focusId,
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
  bool _focusHandled = false;
  bool _ordersLoaded = false;

  /// Exchange orders belong to the common history, not to the history of
  /// one card address.
  bool get _showOrders => widget.walletAddress == null;

  @override
  void initState() {
    super.initState();
    if (_showOrders) {
      ExchangeOrderHistoryStore.instance.addListener(_onOrdersChanged);
      ExchangeOrderHistoryStore.instance.ensureLoaded().whenComplete(() {
        if (!mounted) return;
        setState(() => _ordersLoaded = true);
        _tryFocus();
      });
    } else {
      _ordersLoaded = true;
    }
    _loadHistory();
  }

  @override
  void dispose() {
    if (_showOrders) {
      ExchangeOrderHistoryStore.instance.removeListener(_onOrdersChanged);
    }
    super.dispose();
  }

  void _onOrdersChanged() {
    if (mounted) setState(() {});
  }

  /// Opens [WalletTransactionHistoryScreen.focusId] once it is known: an
  /// exchange order right after the orders are read, a transaction after
  /// the on-chain history loaded.
  void _tryFocus() {
    if (_focusHandled || !mounted) return;
    final id = widget.focusId?.trim() ?? '';
    if (id.isEmpty) {
      _focusHandled = true;
      return;
    }
    final order =
        _showOrders ? ExchangeOrderHistoryStore.instance.byId(id) : null;
    if (order != null) {
      _focusHandled = true;
      setState(() => _filter = _TxFilter.exchange);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ExchangeOrderSheet.show(context, order);
      });
      return;
    }
    final lower = id.toLowerCase();
    for (final tx in _txns) {
      if (tx.hash.toLowerCase() == lower) {
        _focusHandled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TxDetailScreen(tx: tx, walletAddress: _address),
            ),
          );
        });
        return;
      }
    }
    // Not found once both lists are in (e.g. a transaction still pending:
    // it is in the pending strip above the list).
    if (_ordersLoaded && !_isLoading) _focusHandled = true;
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
      final page = await TxHistoryService.fetch(
        address: _address,
        chainKey: _chainKey,
      );
      if (mounted) {
        setState(() {
          _txns = mergeHistoryPages(const [], page.transactions);
          _nextCursor = page.nextCursor;
          _isLoading = false;
        });
        _tryFocus();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
        _tryFocus();
      }
    }
  }

  Future<void> _loadMore() async {
    if (_nextCursor == null || _isLoadingMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final page = await TxHistoryService.fetch(
        address: _address,
        chainKey: _chainKey,
        cursor: _nextCursor,
      );
      if (mounted) {
        setState(() {
          _txns = mergeHistoryPages(_txns, page.transactions);
          _nextCursor = page.nextCursor;
          _isLoadingMore = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  /// History without spam airdrops and zero-amount "address poisoning"
  /// transfers while the wallet's spam filter (Wallet settings) is on.
  List<OnChainTx> get _visible {
    if (!WalletSettingsService.instance.spamFilter) return _txns;
    final chainKey = _chainKey;
    final chainId = PrivyChainRegistry.getChain(chainKey).evmChainId;
    final custom = TokenManagerService.instance.customTokens
        .where((c) => chainId == null || c.chainId == chainId)
        .map((c) => c.address.toLowerCase())
        .toSet();
    final sentTokens = {
      for (final t in _txns)
        if (t.type == OnChainTxType.send &&
            t.value > 0 &&
            (t.contractAddress ?? '').isNotEmpty)
          t.contractAddress!.toLowerCase(),
    };
    bool known(String contract) =>
        custom.contains(contract) ||
        PortfolioAdapter.isCoreToken(chainKey, contract) ||
        TokenRegistryService.instance
                .resolveBuiltInAddress(contract, chainKey)
                .address !=
            null;
    return _txns
        .where((t) => !TxSpamFilter.isSpam(t,
            isKnownToken: known, sentTokens: sentTokens))
        .toList();
  }

  List<OnChainTx> get _filtered {
    final txns = _visible;
    switch (_filter) {
      case _TxFilter.all:
        return txns;
      case _TxFilter.sent:
        return txns.where((t) => t.type == OnChainTxType.send).toList();
      case _TxFilter.received:
        return txns.where((t) => t.type == OnChainTxType.receive).toList();
      case _TxFilter.approvals:
        return txns.where((t) => t.type == OnChainTxType.approval).toList();
      case _TxFilter.swaps:
        return txns.where((t) => t.type == OnChainTxType.swap).toList();
      case _TxFilter.exchange:
        return const [];
    }
  }

  List<ExchangeOrderRecord> get _orders =>
      _showOrders ? ExchangeOrderHistoryStore.instance.orders : const [];

  /// The rows on screen, newest first. "All" puts exchange orders among
  /// the transactions by time; while older on-chain pages are not loaded,
  /// older orders wait for them so the list stays in order.
  List<_HistoryRow> get _rows {
    if (_filter == _TxFilter.exchange) {
      return [for (final o in _orders) _OrderRow(o)];
    }
    final txs = _filtered;
    if (_filter != _TxFilter.all) return [for (final t in txs) _TxRow(t)];

    var orders = _orders;
    if (_nextCursor != null && txs.isNotEmpty) {
      final oldest = txs.last.blockTimestamp;
      orders = orders.where((o) => !o.time.isBefore(oldest)).toList();
    }
    final rows = <_HistoryRow>[];
    var i = 0;
    for (final tx in txs) {
      while (i < orders.length &&
          !orders[i].time.isBefore(tx.blockTimestamp)) {
        rows.add(_OrderRow(orders[i++]));
      }
      rows.add(_TxRow(tx));
    }
    while (i < orders.length) {
      rows.add(_OrderRow(orders[i++]));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows; // computed once per build, not per row
    final ordersOnly = _filter == _TxFilter.exchange;
    final hasMore = !ordersOnly && _nextCursor != null;
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
            showExchange: _showOrders,
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

          // ── On-chain history + exchange orders ────────────────────────
          Expanded(
            child: (_isLoading && !ordersOnly)
                ? const Center(child: CircularProgressIndicator())
                : (_error != null && !ordersOnly)
                    ? _ErrorState(
                        error: _error!,
                        onRetry: () => _loadHistory(reset: true))
                    : rows.isEmpty && !hasMore
                        ? _EmptyState(filter: _filter)
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                            itemCount: rows.length + (hasMore ? 1 : 0),
                            itemBuilder: (context, idx) {
                              if (idx == rows.length) {
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
                              final row = rows[idx];
                              if (row is _OrderRow) {
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: GestureDetector(
                                    onTap: () => _ExchangeOrderSheet.show(
                                        context, row.order),
                                    child:
                                        _ExchangeOrderTile(order: row.order),
                                  ),
                                );
                              }
                              final tx = (row as _TxRow).tx;
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
  final bool showExchange;
  final ValueChanged<_TxFilter> onChanged;

  const _FilterRow({
    required this.current,
    required this.onChanged,
    this.showExchange = true,
  });

  @override
  Widget build(BuildContext context) {
    final t = LocalizationService.instance;
    final filters = [
      (_TxFilter.all, t.t('txFilterAll')),
      (_TxFilter.sent, t.t('txFilterSent')),
      (_TxFilter.received, t.t('txFilterReceived')),
      (_TxFilter.approvals, t.t('txFilterApprovals')),
      (_TxFilter.swaps, t.t('txFilterSwaps')),
      if (showExchange)
        (_TxFilter.exchange, t.t('txFilterExchange', {'default': 'Exchange'})),
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
                      _subtitleText(),
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
    final t = LocalizationService.instance;
    final token = tx.tokenSymbol ?? t.t('txRowFunds');
    if (tx.type == OnChainTxType.swap) {
      return t.t('txRowSwapped', {
        'sell': tx.sellSymbol ?? '?',
        'buy': tx.buySymbol ?? '?',
      });
    }
    return switch (tx.type) {
      OnChainTxType.send => t.t('txRowSent', {'token': token}),
      OnChainTxType.receive => t.t('txRowReceived', {'token': token}),
      OnChainTxType.approval => t.t('txRowApproval'),
      OnChainTxType.swap => t.t('txRowSwap'), // unreachable
      OnChainTxType.other => t.t('txRowTransaction'),
    };
  }

  String _subtitleText() {
    if (tx.type == OnChainTxType.swap) {
      return '${tx.sellSymbol ?? '?'} → ${tx.buySymbol ?? '?'}';
    }
    final t = LocalizationService.instance;
    final addr = tx.type == OnChainTxType.receive ? tx.from : tx.to;
    final short = addr.length > 12
        ? '${addr.substring(0, 6)}...${addr.substring(addr.length - 4)}'
        : addr;
    return switch (tx.type) {
      OnChainTxType.send => t.t('txSubTo', {'address': short}),
      OnChainTxType.receive => t.t('txSubFrom', {'address': short}),
      OnChainTxType.approval => t.t('txSubSpender', {'address': short}),
      OnChainTxType.swap => t.t('txSubViaContract'), // unreachable
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
    final l = LocalizationService.instance;
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return l.t('txAgoNow');
    if (diff.inMinutes < 60) return l.t('txAgoMinutes', {'n': diff.inMinutes});
    if (diff.inHours < 24) return l.t('txAgoHours', {'n': diff.inHours});
    if (diff.inDays < 30) return l.t('txAgoDays', {'n': diff.inDays});
    return '${t.day}.${t.month.toString().padLeft(2, '0')}.${t.year}';
  }
}

// ── Exchange order tile («Биржа») ─────────────────────────────────────────────

String _exchangeName(String id) {
  switch (id.toLowerCase()) {
    case 'mexc':
      return 'MEXC';
    case 'binance':
      return 'Binance';
    case 'gateio':
    case 'gate.io':
      return 'Gate.io';
    case 'okx':
      return 'OKX';
    default:
      return id.toUpperCase();
  }
}

String _fmtQty(double v) {
  if (v == 0) return '0';
  final digits = v.abs() >= 1 ? 4 : 8;
  var s = v.toStringAsFixed(digits);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  return s;
}

String _fmtMoney(double v) => v.toStringAsFixed(2);

class _ExchangeOrderTile extends StatelessWidget {
  final ExchangeOrderRecord order;
  const _ExchangeOrderTile({required this.order});

  @override
  Widget build(BuildContext context) {
    final t = LocalizationService.instance;
    final failed = order.isFailed;
    final color = failed
        ? GuardianColors.danger
        : (order.isBuy ? GuardianColors.success : GuardianColors.accent);
    final symbol = order.symbol;
    final title = order.isBuy
        ? t.t('txExchangeBought',
            {'token': symbol, 'default': 'Bought $symbol'})
        : t.t('txExchangeSold', {'token': symbol, 'default': 'Sold $symbol'});
    final coins = '${order.isBuy ? '+' : '-'}${_fmtQty(order.coinQty)} $symbol';
    final value = '≈ ${_fmtMoney(order.valueQuote)} ${order.quote}';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: GuardianColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: failed
                ? GuardianColors.danger.withOpacity(0.3)
                : color.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.show_chart_rounded,
                    color: color, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GuardianTextStyles.bodyPrimary
                          .copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _Badge(
                          text: t.t('txExchangeLabel',
                              {'default': 'Exchange'}),
                          color: GuardianColors.warning,
                        ),
                        if (order.isAi)
                          _Badge(
                            text: t.t('txExchangeByAi', {'default': 'AI'}),
                            color: GuardianColors.accent,
                          ),
                        Text(
                          '${_exchangeName(order.exchange)} · '
                          '$symbol/${order.quote}',
                          style: GuardianTextStyles.caption,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (!failed)
                    Text(
                      coins,
                      style: GuardianTextStyles.bodyPrimary.copyWith(
                        color: order.isBuy
                            ? GuardianColors.success
                            : Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  Text(
                    failed
                        ? (order.isBuy
                            ? '${_fmtMoney(order.amount)} ${order.quote}'
                            : '${_fmtQty(order.amount)} $symbol')
                        : value,
                    style: GuardianTextStyles.caption,
                  ),
                  Text(
                    _agoText(order.time),
                    style: GuardianTextStyles.caption,
                  ),
                ],
              ),
            ],
          ),
          if (failed) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: GuardianColors.danger.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                  t.t('txExchangeFailed', {'default': 'Order failed'}),
                  style: GuardianTextStyles.caption
                      .copyWith(color: GuardianColors.danger)),
            ),
          ],
        ],
      ),
    );
  }
}

String _agoText(DateTime t) {
  final l = LocalizationService.instance;
  final diff = DateTime.now().difference(t);
  if (diff.inSeconds < 60) return l.t('txAgoNow');
  if (diff.inMinutes < 60) return l.t('txAgoMinutes', {'n': diff.inMinutes});
  if (diff.inHours < 24) return l.t('txAgoHours', {'n': diff.inHours});
  if (diff.inDays < 30) return l.t('txAgoDays', {'n': diff.inDays});
  return '${t.day}.${t.month.toString().padLeft(2, '0')}.${t.year}';
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: GuardianTextStyles.caption.copyWith(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Details of one exchange order (tap on the row, or the «ИИ выполнил»
/// notification).
class _ExchangeOrderSheet extends StatelessWidget {
  final ExchangeOrderRecord order;
  const _ExchangeOrderSheet({required this.order});

  static Future<void> show(BuildContext context, ExchangeOrderRecord order) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ExchangeOrderSheet(order: order),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = LocalizationService.instance;
    final symbol = order.symbol;
    final status = switch (order.status) {
      ExchangeOrderRecord.statusFilled =>
        t.t('txExchangeStatusFilled', {'default': 'Filled'}),
      ExchangeOrderRecord.statusFailed =>
        t.t('txExchangeStatusFailed', {'default': 'Failed'}),
      _ => t.t('txExchangeStatusPlaced', {'default': 'Placed'}),
    };
    final time = order.time.toLocal();
    final timeText = '${time.day.toString().padLeft(2, '0')}.'
        '${time.month.toString().padLeft(2, '0')}.${time.year} '
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';

    final rows = <(String, String)>[
      (t.t('txExchangeLabel', {'default': 'Exchange'}),
          _exchangeName(order.exchange)),
      (t.t('txExchangePair', {'default': 'Pair'}), '$symbol/${order.quote}'),
      (
        t.t('txExchangeType', {'default': 'Type'}),
        order.isBuy
            ? t.t('txExchangeSideBuy', {'default': 'Buy (market)'})
            : t.t('txExchangeSideSell', {'default': 'Sell (market)'}),
      ),
      if (order.isBuy)
        (t.t('txExchangeSpent', {'default': 'Spent'}),
            '${_fmtMoney(order.amount)} ${order.quote}')
      else
        (t.t('txExchangeSoldAmount', {'default': 'Sold'}),
            '${_fmtQty(order.amount)} $symbol'),
      if (!order.isFailed)
        (t.t('txExchangeFilled', {'default': 'Filled'}),
            '${_fmtQty(order.coinQty)} $symbol'),
      if (order.price > 0)
        (t.t('txExchangePrice', {'default': 'Price'}),
            '${_fmtQty(order.price)} ${order.quote}'),
      (t.t('txExchangeStatus', {'default': 'Status'}), status),
      (
        t.t('txExchangePlacedBy', {'default': 'Placed by'}),
        order.isAi
            ? t.t('txExchangeByAiLong', {'default': 'AI'})
            : t.t('txExchangeByUser', {'default': 'You'}),
      ),
      (t.t('txExchangeTime', {'default': 'Time'}), timeText),
      if (order.isFailed && (order.error ?? '').isNotEmpty)
        (t.t('txExchangeReason', {'default': 'Reason'}), order.error!),
    ];

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        decoration: const BoxDecoration(
          color: GuardianColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                t.t('txExchangeDetailTitle', {'default': 'Exchange order'}),
                style: GuardianTextStyles.titleMedium,
              ),
              const SizedBox(height: 16),
              for (final (label, value) in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(label,
                            style: GuardianTextStyles.caption
                                .copyWith(color: Colors.white54)),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        flex: 2,
                        child: Text(
                          value,
                          textAlign: TextAlign.end,
                          style: GuardianTextStyles.bodySecondary
                              .copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              if ((order.orderId ?? '').isNotEmpty)
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () async {
                    await Clipboard.setData(
                        ClipboardData(text: order.orderId!));
                    if (!context.mounted) return;
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
                      content: Text(t.t('txExchangeIdCopied',
                          {'default': 'Order ID copied'})),
                      behavior: SnackBarBehavior.floating,
                    ));
                  },
                  child: Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: GuardianColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Text(
                          '${t.t('txExchangeOrderId', {'default': 'Order ID'})}: ',
                          style: GuardianTextStyles.caption,
                        ),
                        Expanded(
                          child: Text(
                            order.orderId!,
                            overflow: TextOverflow.ellipsis,
                            style: GuardianTextStyles.caption
                                .copyWith(fontFamily: 'monospace'),
                          ),
                        ),
                        const Icon(Icons.copy_rounded,
                            size: 14, color: GuardianColors.textTertiary),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: GuardianColors.surfaceElevated,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  t.t('txExchangeClose', {'default': 'Close'}),
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
                  ? LocalizationService.instance.t('txEmptyTitle')
                  : LocalizationService.instance.t('txEmptyFilteredTitle'),
              style: GuardianTextStyles.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              filter == _TxFilter.all
                  ? LocalizationService.instance.t('txEmptyBody')
                  : LocalizationService.instance.t('txEmptyFilteredBody'),
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
