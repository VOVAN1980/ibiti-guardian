import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/models/on_chain_tx.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/services/moralis/moralis_tx_history_service.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/screens/wallet/components/wallet_send_modal.dart';
import 'package:ibiti_guardian/screens/wallet/components/wallet_receive_modal.dart';
import 'package:ibiti_guardian/screens/wallet/components/wallet_swap_modal.dart';

/// Token logo URL map — shared across the app.
const Map<String, String> tokenLogoUrls = {
  'ETH': 'https://cryptologos.cc/logos/ethereum-eth-logo.png',
  'BNB': 'https://cryptologos.cc/logos/bnb-bnb-logo.png',
  'SOL': 'https://cryptologos.cc/logos/solana-sol-logo.png',
  'TRX': 'https://cryptologos.cc/logos/tron-trx-logo.png',
  'POL': 'https://cryptologos.cc/logos/polygon-matic-logo.png',
  'MATIC': 'https://cryptologos.cc/logos/polygon-matic-logo.png',
  'ARB': 'https://cryptologos.cc/logos/arbitrum-arb-logo.png',
  'USDT': 'https://cryptologos.cc/logos/tether-usdt-logo.png',
  'USDC': 'https://cryptologos.cc/logos/usd-coin-usdc-logo.png',
  'BTC': 'https://cryptologos.cc/logos/bitcoin-btc-logo.png',
  // IBITI uses fallback letter icon — no remote logo
  'DOGE': 'https://cryptologos.cc/logos/dogecoin-doge-logo.png',
  'ADA': 'https://cryptologos.cc/logos/cardano-ada-logo.png',
  'DOT': 'https://cryptologos.cc/logos/polkadot-new-dot-logo.png',
  'AVAX': 'https://cryptologos.cc/logos/avalanche-avax-logo.png',
  'OP': 'https://cryptologos.cc/logos/optimism-ethereum-op-logo.png',
};

/// Maps chainId to human-readable chain name.
String _chainDisplayName(int chainId, {String chainKey = ''}) {
  if (chainKey == 'solana') return 'Solana';
  if (chainKey == 'tron') return 'Tron';
  const map = {
    1: 'Ethereum',
    56: 'BNB Smart Chain',
    137: 'Polygon',
    42161: 'Arbitrum One',
    10: 'Optimism',
    8453: 'Base',
    43114: 'Avalanche C-Chain',
    250: 'Fantom',
  };
  return map[chainId] ?? 'Chain $chainId';
}

/// Full-screen token detail page — MetaMask-style.
/// Clean layout: Icon → Balance → Price → Action buttons.
/// Contract address and token info are in the ⋮ menu.
class TokenDetailScreen extends StatefulWidget {
  final WalletAsset asset;
  const TokenDetailScreen({super.key, required this.asset});

  @override
  State<TokenDetailScreen> createState() => _TokenDetailScreenState();
}

class _TokenDetailScreenState extends State<TokenDetailScreen> {
  List<OnChainTx> _txns = [];
  bool _isLoading = true;

  WalletAsset get asset => widget.asset;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() => _isLoading = true);
    try {
      final addr = IBITIVaultService.instance.activeAddress;
      final chainKey = IBITIVaultService.instance.chainKey;
      final page = await MoralisTxHistoryService.fetch(
        address: addr,
        chainKey: chainKey,
      );
      if (mounted) {
        // Filter to only this token's transactions
        final sym = asset.symbol.toUpperCase();
        final filtered = page.transactions.where((tx) {
          final txSym = tx.tokenSymbol?.toUpperCase() ?? '';
          // Include if primary token matches OR if this token appears
          // on either side of a swap (buy or sell).
          if (txSym == sym || txSym.isEmpty) return true;
          if (tx.type == OnChainTxType.swap) {
            final buy = tx.buySymbol?.toUpperCase() ?? '';
            final sell = tx.sellSymbol?.toUpperCase() ?? '';
            if (buy == sym || sell == sym) return true;
          }
          return false;
        }).toList();
        setState(() {
          _txns = filtered;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showTokenInfo(BuildContext context) {
    final t = LocalizationService.instance;
    final isNative = asset.isNative || asset.address == 'native';
    final contractAddr = isNative ? null : asset.address;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141820),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Title
              Row(
                children: [
                  const Icon(Icons.info_outline_rounded,
                      color: GuardianColors.accent, size: 22),
                  const SizedBox(width: 10),
                  Text(
                    t.t('walletTokenInfo', {'default': 'Token Info'}),
                    style: GuardianTextStyles.headline.copyWith(fontSize: 18),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Name
              _InfoRow(
                label: t.t('walletTokenName', {'default': 'Name'}),
                value: asset.name,
              ),
              const SizedBox(height: 12),

              // Symbol
              _InfoRow(
                label: t.t('walletTokenSymbol', {'default': 'Symbol'}),
                value: asset.symbol,
              ),
              const SizedBox(height: 12),

              // Decimals
              _InfoRow(
                label: t.t('walletTokenDecimals', {'default': 'Decimals'}),
                value: '${asset.decimals}',
              ),
              const SizedBox(height: 12),

              // Network
              _InfoRow(
                label: t.t('walletTokenNetwork', {'default': 'Network'}),
                value:
                    _chainDisplayName(asset.chainId, chainKey: asset.chainKey),
              ),
              const SizedBox(height: 12),

              // Contract Address
              Text(
                isNative
                    ? t.t('walletNativeAsset', {'default': 'Native Asset'})
                    : t.t('walletContractAddress',
                        {'default': 'Contract Address'}),
                style: TextStyle(
                  color: Colors.white.withOpacity(0.45),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              if (isNative)
                Text(
                  '${asset.symbol} — native gas token',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.6),
                    fontSize: 14,
                  ),
                )
              else
                InkWell(
                  onTap: () {
                    if (contractAddr != null) {
                      Clipboard.setData(ClipboardData(text: contractAddr));
                      Navigator.of(sheetCtx).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Contract address copied'),
                          behavior: SnackBarBehavior.floating,
                          duration: Duration(seconds: 1),
                        ),
                      );
                    }
                  },
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.04),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white.withOpacity(0.08)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            contractAddr ?? '',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.7),
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(Icons.copy_rounded,
                            color: GuardianColors.accent.withOpacity(0.6),
                            size: 18),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = LocalizationService.instance;
    final chain =
        PrivyChainRegistry.getChain(IBITIVaultService.instance.chainKey);
    final logoUrl = asset.logoUrl ?? tokenLogoUrls[asset.symbol.toUpperCase()];

    return Scaffold(
      backgroundColor: const Color(0xFF05070B),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── App Bar ──
          SliverAppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            pinned: true,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded,
                  color: Colors.white, size: 20),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Text(asset.symbol,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
            centerTitle: true,
            actions: [
              IconButton(
                icon: Icon(Icons.more_vert_rounded,
                    color: Colors.white.withOpacity(0.5)),
                onPressed: () => _showTokenInfo(context),
              ),
            ],
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const SizedBox(height: 20),

                  // ── Token Icon ──
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withOpacity(0.06),
                      border: Border.all(
                          color: Colors.white.withOpacity(0.1), width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: GuardianColors.accent.withOpacity(0.15),
                          blurRadius: 24,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: logoUrl != null
                          ? Image.network(
                              logoUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  _FallbackIcon(symbol: asset.symbol),
                            )
                          : _FallbackIcon(symbol: asset.symbol),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Token Name + Network ──
                  Text(asset.name,
                      style: GuardianTextStyles.headline
                          .copyWith(fontSize: 24, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      _chainDisplayName(asset.chainId,
                          chainKey: asset.chainKey),
                      style: TextStyle(
                        color: GuardianColors.accent.withOpacity(0.9),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),

                  // ── Balance (large, centered like MetaMask) ──
                  Text(
                    '${asset.balance.toStringAsFixed(4)} ${asset.symbol}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '\$${asset.valueUsd.toStringAsFixed(2)}',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.45),
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 36),

                  // ── Action Buttons ──
                  Row(
                    children: [
                      Expanded(
                        child: _ActionButton(
                          icon: Icons.arrow_upward_rounded,
                          label: t.t('walletSendMenu', {'default': 'Send'}),
                          color: const Color(0xFFFF4444),
                          onTap: () {
                            Navigator.of(context).pop();
                            WalletSendModal.show(context, initialAsset: asset);
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _ActionButton(
                          icon: Icons.arrow_downward_rounded,
                          label:
                              t.t('walletReceiveBtn', {'default': 'Receive'}),
                          color: const Color(0xFF00CC66),
                          onTap: () {
                            Navigator.of(context).pop();
                            WalletReceiveModal.show(context);
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _ActionButton(
                          icon: Icons.swap_horiz_rounded,
                          label: t.t('walletSwapMenu', {'default': 'Swap'}),
                          color: const Color(0xFF4488FF),
                          onTap: () {
                            if (chain.canSwap) {
                              Navigator.of(context).pop();
                              WalletSwapModal.show(context,
                                  initialFromAsset: asset);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 36),

                  // ── Activity ──
                  Row(
                    children: [
                      Text(
                        t.t('walletActivity', {'default': 'Activity'}),
                        style:
                            GuardianTextStyles.headline.copyWith(fontSize: 18),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => _loadHistory(),
                        child: Icon(Icons.refresh_rounded,
                            color: Colors.white.withOpacity(0.4), size: 20),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),

          // ── Transaction list ──
          if (_isLoading)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_txns.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.history_rounded,
                        color: Colors.white.withOpacity(0.15), size: 48),
                    const SizedBox(height: 12),
                    Text(
                      t.t('walletNoActivity', {'default': 'No activity yet'}),
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.4),
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, idx) {
                    final tx = _txns[idx];
                    return _TxTile(tx: tx, currentSymbol: asset.symbol);
                  },
                  childCount: _txns.length,
                ),
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }
}

/// Compact transaction tile for the token detail activity list.
class _TxTile extends StatelessWidget {
  final OnChainTx tx;
  final String? currentSymbol;
  const _TxTile({required this.tx, this.currentSymbol});

  void _showDetail(BuildContext context) {
    final t = LocalizationService.instance;
    final (color, icon) = _typeStyle();
    final fromShort = _shortAddr(tx.from);
    final toShort = _shortAddr(tx.to);
    final vault = IBITIVaultService.instance;
    final isFromMe = tx.from.toLowerCase() == vault.activeAddress.toLowerCase();

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D1117),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Title row
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: color, size: 20),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_titleText(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            )),
                        const SizedBox(height: 2),
                        Text(
                          _formatDate(tx.blockTimestamp),
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.4),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon:
                        const Icon(Icons.close_rounded, color: Colors.white54),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Status
              _DetailRow(
                label: t.t('txDetailStatus', {'default': 'Status'}),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: tx.isSuccess
                            ? GuardianColors.success
                            : GuardianColors.danger,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      tx.isSuccess
                          ? t.t('txDetailConfirmed', {'default': 'Confirmed'})
                          : t.t('txDetailFailed', {'default': 'Failed'}),
                      style: TextStyle(
                        color: tx.isSuccess
                            ? GuardianColors.success
                            : GuardianColors.danger,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),

              const Divider(color: Colors.white12, height: 28),

              // From → To
              Text(t.t('txDetailFromTo', {'default': 'From → To'}),
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.4),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  )),
              const SizedBox(height: 10),
              Row(
                children: [
                  _AddressChip(
                    label: isFromMe ? 'Account 1' : fromShort,
                    color: GuardianColors.accent,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Icon(Icons.arrow_forward_rounded,
                        color: Colors.white.withOpacity(0.3), size: 18),
                  ),
                  _AddressChip(
                    label: !isFromMe ? 'Account 1' : toShort,
                    color: const Color(0xFF00CC66),
                  ),
                ],
              ),

              const Divider(color: Colors.white12, height: 28),

              // Transaction details
              Text(t.t('txDetailTransaction', {'default': 'Transaction'}),
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.4),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  )),
              const SizedBox(height: 12),

              if (tx.value > 0 || tx.tokenSymbol != null)
                _DetailRow(
                  label: t.t('txDetailAmount', {'default': 'Amount'}),
                  value: _amountText(),
                ),
              if (tx.gasUsed != null) ...[
                const SizedBox(height: 8),
                _DetailRow(
                  label: t.t('txDetailGas', {'default': 'Gas used'}),
                  value: tx.gasUsed!,
                ),
              ],

              const Divider(color: Colors.white12, height: 28),

              // Hash — tap to copy
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: tx.hash));
                  Navigator.of(ctx).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Transaction hash copied'),
                      behavior: SnackBarBehavior.floating,
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
                child: Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withOpacity(0.08)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.tag_rounded,
                          color: Colors.white.withOpacity(0.3), size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          tx.hash,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.copy_rounded,
                          color: GuardianColors.accent.withOpacity(0.6),
                          size: 16),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final (color, icon) = _typeStyle();
    final addr = tx.type == OnChainTxType.receive ? tx.from : tx.to;
    final short = tx.type == OnChainTxType.swap
        ? '${tx.sellSymbol ?? '?'} → ${tx.buySymbol ?? '?'}'
        : _shortAddr(addr);

    return GestureDetector(
      onTap: () => _showDetail(context),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
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
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    short,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.4),
                      fontSize: 12,
                    ),
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
                    style: TextStyle(
                      color: _amountColor(),
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                Text(
                  _timeAgo(tx.blockTimestamp),
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.35),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _shortAddr(String addr) {
    if (addr.length > 12) {
      return '${addr.substring(0, 6)}...${addr.substring(addr.length - 4)}';
    }
    return addr;
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

  /// Is the current token the buy (incoming) side of the swap?
  bool get _isSwapBuySide {
    if (tx.type != OnChainTxType.swap || currentSymbol == null) return true;
    return currentSymbol!.toUpperCase() != (tx.sellSymbol?.toUpperCase() ?? '');
  }

  Color _amountColor() {
    if (tx.type == OnChainTxType.receive) return GuardianColors.success;
    if (tx.type == OnChainTxType.swap) {
      return _isSwapBuySide ? GuardianColors.success : Colors.white;
    }
    return Colors.white;
  }

  String _titleText() {
    if (tx.type == OnChainTxType.swap) {
      final sell = tx.sellSymbol ?? '?';
      final buy = tx.buySymbol ?? '?';
      return 'Swapped $sell → $buy';
    }
    return switch (tx.type) {
      OnChainTxType.send => 'Sent ${tx.tokenSymbol ?? ''}',
      OnChainTxType.receive => 'Received ${tx.tokenSymbol ?? ''}',
      OnChainTxType.approval => 'Approval',
      OnChainTxType.swap => 'Swap', // unreachable, handled above
      OnChainTxType.other => 'Transaction',
    };
  }

  String _amountText() {
    if (tx.type == OnChainTxType.swap) {
      if (_isSwapBuySide && tx.buySymbol != null) {
        return '+${(tx.buyValue ?? tx.value).toStringAsFixed(4)} ${tx.buySymbol}';
      }
      if (!_isSwapBuySide && tx.sellSymbol != null) {
        return '-${(tx.sellValue ?? tx.value).toStringAsFixed(4)} ${tx.sellSymbol}';
      }
      // Fallback: show buy side
      if (tx.buySymbol != null) {
        return '+${(tx.buyValue ?? tx.value).toStringAsFixed(4)} ${tx.buySymbol}';
      }
    }
    if (tx.tokenSymbol != null) {
      return '${tx.type == OnChainTxType.receive ? '+' : '-'}${tx.value.toStringAsFixed(4)} ${tx.tokenSymbol}';
    }
    if (tx.value > 0) return tx.value.toStringAsFixed(6);
    return '';
  }

  String _timeAgo(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 30) return '${diff.inDays}d';
    return '${t.day}/${t.month}/${t.year}';
  }

  String _formatDate(DateTime dt) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }
}

/// Detail row label + value.
class _DetailRow extends StatelessWidget {
  final String label;
  final String? value;
  final Widget? child;
  const _DetailRow({required this.label, this.value, this.child});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
              fontSize: 13,
            )),
        child ??
            Text(value ?? '',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                )),
      ],
    );
  }
}

/// Address chip for From/To display.
class _AddressChip extends StatelessWidget {
  final String label;
  final Color color;
  const _AddressChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.account_circle_rounded, color: color, size: 16),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              )),
        ],
      ),
    );
  }
}

/// Info row for the token info bottom sheet.
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.45),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            )),
        const Spacer(),
        Text(value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            )),
      ],
    );
  }
}

/// Glassy info card container.
class _InfoCard extends StatelessWidget {
  final List<Widget> children;
  const _InfoCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

/// Action button (Send / Receive / Swap).
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: 100,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withOpacity(0.2)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.18),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(height: 8),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fallback icon when no logo URL is available.
class _FallbackIcon extends StatelessWidget {
  final String symbol;
  const _FallbackIcon({required this.symbol});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white.withOpacity(0.06),
      child: Center(
        child: Text(
          symbol.isNotEmpty ? symbol.substring(0, 1) : '?',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}
