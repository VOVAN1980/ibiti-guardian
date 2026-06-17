import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/screens/wallet/wallet_space_screen.dart'
    show WalletCardModel, cardGradient;
import 'package:ibiti_guardian/screens/wallet/wallet_card_detail_screen.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';

/// All wallets grid — 2×N card grid with **real per-card balances** (P1-1).
class AllWalletsScreen extends StatelessWidget {
  final List<WalletCardModel> wallets;
  const AllWalletsScreen({super.key, required this.wallets});

  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    return Scaffold(
      backgroundColor: GuardianColors.background,
      body: _BankBg(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ────────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Row(
                  children: [
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => Navigator.of(context).pop(),
                        borderRadius: BorderRadius.circular(16),
                        child: Ink(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                                color: Colors.white.withOpacity(0.1)),
                          ),
                          child: const Icon(Icons.close_rounded,
                              color: Colors.white, size: 20),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Text(
                        t.t('walletAllWalletsTitle',
                            {'default': 'All wallets'}),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5)),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                child: Text('${wallets.length} wallets connected',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.4),
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
              ),
              const SizedBox(height: 18),

              // ── Grid ──────────────────────────────────────────────────────
              Expanded(
                child: ListenableBuilder(
                  // Rebuild whenever any per-card fetch completes (P1-1)
                  listenable: VaultPortfolioListener.instance,
                  builder: (context, _) {
                    final chainKey = IBITIVaultService.instance.chainKey;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: GridView.builder(
                        physics: const BouncingScrollPhysics(),
                        itemCount: wallets.length,
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          childAspectRatio: 0.82,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                        itemBuilder: (context, index) {
                          final w = wallets[index];
                          // Per-card real balance (P1-1)
                          final perCardSummary = VaultPortfolioListener.instance
                              .summaryForAddress(w.fullAddress, chainKey);
                          final isCardLoading = VaultPortfolioListener.instance
                              .isLoadingAddress(w.fullAddress);
                          return _WalletGridCard(
                            wallet: w,
                            tailAddress: w.fullAddress,
                            balanceSummary: perCardSummary,
                            isLoading: isCardLoading,
                            onTap: () => _openDetail(context, w),
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openDetail(BuildContext context, WalletCardModel wallet) async {
    HapticFeedback.mediumImpact();
    await IBITIVaultService.instance.setActiveEvmCard(wallet.fullAddress);
    if (!context.mounted) return;
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 420),
        reverseTransitionDuration: const Duration(milliseconds: 340),
        pageBuilder: (_, animation, __) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: WalletCardDetailScreen(wallet: wallet),
        ),
      ),
    );
  }
}

// ── Grid card ─────────────────────────────────────────────────────────────────

class _WalletGridCard extends StatefulWidget {
  final WalletCardModel wallet;
  final String tailAddress;
  final dynamic balanceSummary; // PortfolioSummary?
  final bool isLoading;
  final VoidCallback onTap;
  const _WalletGridCard({
    required this.wallet,
    required this.tailAddress,
    required this.balanceSummary,
    required this.isLoading,
    required this.onTap,
  });

  @override
  State<_WalletGridCard> createState() => _WalletGridCardState();
}

class _WalletGridCardState extends State<_WalletGridCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final balance = widget.balanceSummary?.totalBalanceUsd as double?;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 130),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            gradient: cardGradient(widget.wallet.accent),
            border: Border.all(color: Colors.white.withOpacity(0.1), width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top: tail address
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(width: 30, height: 18),
                  const Spacer(),
                  Text(WalletCardModel.shortTailFrom(widget.tailAddress),
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.45),
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ],
              ),
              const Spacer(),
              Text(widget.wallet.name,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              // Real per-card balance (P1-1)
              if (widget.isLoading || balance == null)
                _BalanceShimmer()
              else
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: Row(
                    key: ValueKey(balance),
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      const Text('\$',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w500)),
                      Text(
                        _formatBalance(balance),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatBalance(double value) {
    return value.toStringAsFixed(value >= 1000 ? 0 : 2);
  }
}

class _BalanceShimmer extends StatefulWidget {
  @override
  State<_BalanceShimmer> createState() => _BalanceShimmerState();
}

class _BalanceShimmerState extends State<_BalanceShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Container(
        width: 90,
        height: 28,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          gradient: LinearGradient(
            colors: [
              Colors.white.withOpacity(0.08),
              Colors.white.withOpacity(0.18),
              Colors.white.withOpacity(0.08),
            ],
            stops: [
              (_c.value - 0.3).clamp(0.0, 1.0),
              _c.value.clamp(0.0, 1.0),
              (_c.value + 0.3).clamp(0.0, 1.0),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Background gradient ───────────────────────────────────────────────────────

class _BankBg extends StatelessWidget {
  final Widget child;
  const _BankBg({required this.child});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF060A14), Color(0xFF0A1020), Color(0xFF000000)],
          ),
        ),
        child: child,
      );
}
