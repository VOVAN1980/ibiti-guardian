import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/screens/wallet/wallet_space_screen.dart'
    show
        WalletCardModel,
        cardGradient,
        cardBorderGradient,
        cardInnerStrokeColor,
        CardAccent;
import 'package:ibiti_guardian/services/audit_log_service.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/screens/wallet/components/wallet_receive_modal.dart';
import 'package:ibiti_guardian/screens/wallet/all_wallets_screen.dart';
import 'package:ibiti_guardian/screens/wallet/wallet_address_book_screen.dart';
import 'package:ibiti_guardian/screens/market_command/market_command_screen.dart';
import 'package:ibiti_guardian/screens/wallet/wallet_settings_screen.dart';
import 'package:ibiti_guardian/screens/wallet/wallet_transaction_history_screen.dart';

/// Full card detail screen — opens via Hero animation from the main wallet.
/// Shows full address, copy/share options, and wallet settings sections.
class WalletCardDetailScreen extends StatelessWidget {
  final WalletCardModel wallet;
  final VoidCallback? onAddCard;
  const WalletCardDetailScreen(
      {super.key, required this.wallet, this.onAddCard});

  List<WalletCardModel> _walletsFromVault(IBITIVaultService vault) {
    const accentOrder = [
      CardAccent.black,
      CardAccent.silver,
      CardAccent.gold,
      CardAccent.platinum,
    ];
    final addresses = vault.evmCardAddresses.isNotEmpty
        ? vault.evmCardAddresses
        : [vault.activeAddress].where((e) => e.isNotEmpty).toList();
    final wallets = <WalletCardModel>[];
    for (var i = 0; i < addresses.length && i < accentOrder.length; i++) {
      final accent = accentOrder[i];
      wallets.add(
        WalletCardModel(
          id: 'card_$i',
          name: switch (accent) {
            CardAccent.black => 'Card Black',
            CardAccent.silver => 'Card Silver',
            CardAccent.gold => 'Card Gold',
            CardAccent.platinum => 'Card Platinum',
          },
          fullAddress: addresses[i],
          accent: accent,
          isPrimary: i == 0,
        ),
      );
    }
    return wallets;
  }

  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    final vault = IBITIVaultService.instance;

    return ListenableBuilder(
      listenable: vault,
      builder: (context, _) {
        final effectiveWallet = wallet;

        return Scaffold(
          backgroundColor: GuardianColors.background,
          body: _BankBg(
            child: SafeArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 32),
                children: [
                  // ── Top bar ──────────────────────────────────────────────────
                  Row(
                    children: [
                      _GlassBtn(
                        icon: Icons.arrow_back_ios_new_rounded,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                      const Spacer(),
                      _ThreeDotsMenu(wallet: effectiveWallet),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // ── Expanded card (Hero) ──────────────────────────────────────
                  Hero(
                    tag: 'wallet_card_${wallet.id}',
                    child: Material(
                      color: Colors.transparent,
                      child: _ExpandedCard(wallet: effectiveWallet),
                    ),
                  ),
                  const SizedBox(height: 28),

                  // ── Wallet actions ────────────────────────────────────────────
                  _OptionsSection(
                    title: t.t('shellWallet', {'default': 'Wallet'}),
                    items: [
                      _OptionItem(
                        icon: Icons.add_card_rounded,
                        label: t.t('walletAddCardMenu',
                            {'default': 'Issue virtual card'}),
                        subtitle: t.t('dashboardPro', {'default': 'PRO'}),
                        onTap: () {
                          if (onAddCard != null) {
                            onAddCard!();
                          }
                        },
                      ),
                      _OptionItem(
                        icon: Icons.qr_code_rounded,
                        label: t.t(
                            'walletReceiveMenu', {'default': 'Receive funds'}),
                        subtitle:
                            t.t('walletShowQr', {'default': 'Show QR code'}),
                        onTap: () => WalletReceiveModal.show(context),
                      ),
                      _OptionItem(
                        icon: Icons.import_contacts_rounded,
                        label: t.t('walletSettingsAddressBook', {
                          'default': 'Address book',
                        }),
                        subtitle: t.t('walletAddressBookSubtitle', {
                          'default':
                              'Saved recipients and trusted wallet addresses',
                        }),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const WalletAddressBookScreen(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  _OptionsSection(
                    title: t.t('walletMoreActions', {'default': 'Wallet hub'}),
                    items: [
                      _OptionItem(
                        icon: Icons.wallet_outlined,
                        label: t.t('walletAllWalletsTitle',
                            {'default': 'All wallets'}),
                        subtitle: t.t('walletAllWalletsSubtitle',
                            {'default': 'All cards and wallet addresses'}),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => AllWalletsScreen(
                                  wallets: _walletsFromVault(vault)),
                            ),
                          );
                        },
                      ),
                      _OptionItem(
                        icon: Icons.history_rounded,
                        label: t.t('walletTransactionHistory', {
                          'default': 'Transaction history',
                        }),
                        subtitle: t.t('walletTxHistorySubtitle',
                            {'default': 'History of this card and operations'}),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => WalletTransactionHistoryScreen(
                                walletAddress: effectiveWallet.fullAddress,
                              ),
                            ),
                          );
                        },
                      ),
                      _OptionItem(
                        icon: Icons.tune_rounded,
                        label: t.t(
                            'walletSettings', {'default': 'Wallet settings'}),
                        subtitle: t.t('walletSettingsSubtitle', {
                          'default': 'Manage tokens, addresses and network'
                        }),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const WalletSettingsScreen(),
                            ),
                          );
                        },
                      ),
                      _OptionItem(
                        icon: Icons.show_chart_rounded,
                        label: t.t('shellMarket', {'default': 'Рынок'}),
                        subtitle: t.t('walletMarketSubtitle', {
                          'default': 'Networks, platforms and price overview'
                        }),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const MarketCommandScreen(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ── Expanded card ─────────────────────────────────────────────────────────────

class _ExpandedCard extends StatelessWidget {
  final WalletCardModel wallet;
  const _ExpandedCard({required this.wallet});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 240,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        boxShadow: const [
          BoxShadow(
              color: Color(0x44000000), blurRadius: 36, offset: Offset(0, 20))
        ],
        gradient: cardBorderGradient(wallet.accent),
      ),
      padding: const EdgeInsets.all(0.95),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(31),
          gradient: cardGradient(wallet.accent),
          border: Border.all(
            color: cardInnerStrokeColor(wallet.accent),
            width: 0.75,
          ),
        ),
        padding: const EdgeInsets.fromLTRB(26, 24, 26, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('IBITI',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.3)),
                    Text(
                        LocalizationService.instance
                            .t('walletEpkProtected'),
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.45),
                            fontSize: 10,
                            letterSpacing: 0.8)),
                  ],
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text('LIVE',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2)),
                ),
              ],
            ),
            const Spacer(),
            Text(
              _formatFull(wallet.fullAddress),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
                letterSpacing: 1.4,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const Spacer(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(wallet.name,
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                const Spacer(),
                const Text('IBITI',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Split full address into groups of 8 for readability
  String _formatFull(String addr) {
    if (addr.contains('*')) return addr;
    if (addr.length < 10) return addr;

    final isEvm = addr.startsWith('0x');
    final raw = isEvm ? addr.substring(2) : addr;

    final chunks = <String>[];
    for (var i = 0; i < raw.length; i += 8) {
      chunks.add(raw.substring(i, i + 8 > raw.length ? raw.length : i + 8));
    }

    return isEvm ? '0x${chunks.join('  ')}' : chunks.join('  ');
  }
}

// ── QR placeholder block ──────────────────────────────────────────────────────

class _QrBlock extends StatelessWidget {
  final String address;
  const _QrBlock({required this.address});

  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(t.t('walletReceiveMenu', {'default': 'Receive funds'}),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
              const Spacer(),
              Icon(Icons.qr_code_rounded,
                  color: Colors.white.withOpacity(0.5), size: 18),
            ],
          ),
          const SizedBox(height: 14),
          // QR placeholder — real QR via qr_flutter in Phase 13
          Container(
            width: 140,
            height: 140,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Center(
              child: Icon(Icons.qr_code_2_rounded,
                  size: 100, color: GuardianColors.background),
            ),
          ),
          const SizedBox(height: 14),
          SelectableText(
            address,
            style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.5),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ── Options section ───────────────────────────────────────────────────────────

class _OptionsSection extends StatelessWidget {
  final String title;
  final List<_OptionItem> items;
  const _OptionsSection({required this.title, required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          ...items,
        ],
      ),
    );
  }
}

class _OptionItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;
  const _OptionItem({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.07),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
      title: Text(label,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle,
          style:
              TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 12)),
      trailing: Icon(Icons.chevron_right_rounded,
          color: Colors.white.withOpacity(0.3), size: 20),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
    );
  }
}

// ── Three dots menu ───────────────────────────────────────────────────────────

class _ThreeDotsMenu extends StatelessWidget {
  final WalletCardModel wallet;
  const _ThreeDotsMenu({required this.wallet});

  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    return PopupMenuButton<String>(
      color: GuardianColors.surfaceElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      elevation: 8,
      onSelected: (value) {
        if (value == 'copy_address') {
          Clipboard.setData(ClipboardData(text: wallet.fullAddress));
          AuditLogService.instance.recordAddressCopy(
            address: wallet.fullAddress,
            networkLabel:
                PrivyChainRegistry.getChain(IBITIVaultService.instance.chainKey)
                    .displayName,
          );
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content:
                  Text(t.t('walletCopySuccess', {'default': 'Address copied'})),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
            ),
          );
        } else if (value == 'share') {
          Share.share(
            wallet.fullAddress,
            subject: t.t(
                'walletShareSubject', {'default': 'My IBITI Wallet Address'}),
          );
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'copy_address',
          child: Row(children: [
            const Icon(Icons.copy_rounded, size: 18, color: Colors.white),
            const SizedBox(width: 10),
            Text(t.t('walletCopyAddress', {'default': 'Copy address'}),
                style: const TextStyle(color: Colors.white))
          ]),
        ),
        PopupMenuItem(
          value: 'share',
          child: Row(children: [
            const Icon(Icons.share_rounded, size: 18, color: Colors.white),
            const SizedBox(width: 10),
            Text(t.t('walletShareAddress', {'default': 'Share address'}),
                style: const TextStyle(color: Colors.white))
          ]),
        ),
      ],
      child: const _GlassBtn(icon: Icons.more_horiz_rounded),
    );
  }
}

// ── Shared helpers ────────────────────────────────────────────────────────────

class _GlassBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _GlassBtn({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

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
