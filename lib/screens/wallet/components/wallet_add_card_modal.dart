import 'package:flutter/material.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/screens/wallet/wallet_space_screen.dart'
    show CardAccent;
import 'package:ibiti_guardian/services/localization_service.dart';

class WalletAddCardModal extends StatelessWidget {
  final Function(CardAccent color) onSelect;
  final List<CardAccent> availableAccents;

  const WalletAddCardModal({
    super.key,
    required this.onSelect,
    required this.availableAccents,
  });

  static void show(
    BuildContext context, {
    required Function(CardAccent) onSelect,
    required List<CardAccent> availableAccents,
  }) {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => WalletAddCardModal(
        onSelect: onSelect,
        availableAccents: availableAccents,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    return SafeArea(
        bottom: true,
        top: false,
        child: Container(
          decoration: const BoxDecoration(
            color: GuardianColors.background,
            borderRadius: BorderRadius.vertical(top: Radius.circular(36)),
            border: Border(top: BorderSide(color: GuardianColors.glassBorder)),
          ),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: GuardianColors.glassBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 32),

              // Header
              const Icon(Icons.credit_card_rounded,
                  color: Colors.white, size: 48),
              const SizedBox(height: 16),
              Text(
                t.t('walletAddCardMenu', {'default': 'Issue Virtual Card'}),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                t.t('walletAddCardHelpText', {
                  'default':
                      'Choose a premium accent for your new secondary wallet card.'
                }),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 40),

              if (availableAccents.isEmpty)
                Text(
                  t.t('walletAllCardsIssued',
                      {'default': 'All 4 wallet cards are already issued.'}),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                )
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: availableAccents
                      .map(
                        (accent) => _ColorSelector(
                          accent: accent,
                          label: switch (accent) {
                            CardAccent.silver =>
                              t.t('walletColorSilver', {'default': 'Silver'}),
                            CardAccent.gold =>
                              t.t('walletColorGold', {'default': 'Gold'}),
                            CardAccent.platinum => t.t(
                                'walletColorPlatinum', {'default': 'Platinum'}),
                            CardAccent.black => 'Black',
                          },
                          gradient: switch (accent) {
                            CardAccent.silver => const LinearGradient(
                                colors: [
                                  Color(0xFF8E9EAB),
                                  Color(0xFF4C5866),
                                  Color(0xFF2C3E50),
                                ],
                              ),
                            CardAccent.gold => const LinearGradient(
                                colors: [
                                  Color(0xFFD4AF37),
                                  Color(0xFF8C6207),
                                  Color(0xFF5D4002),
                                ],
                              ),
                            CardAccent.platinum => const LinearGradient(
                                colors: [
                                  Color(0xFF536976),
                                  Color(0xFF292E49),
                                  Color(0xFF1C1A27),
                                ],
                              ),
                            CardAccent.black => const LinearGradient(
                                colors: [
                                  Color(0xFF151515),
                                  Color(0xFF090909),
                                ],
                              ),
                          },
                          onSelect: onSelect,
                        ),
                      )
                      .toList(),
                ),
              const SizedBox(height: 48),
            ],
          ),
        ));
  }
}

class _ColorSelector extends StatelessWidget {
  final CardAccent accent;
  final String label;
  final LinearGradient gradient;
  final Function(CardAccent) onSelect;

  const _ColorSelector({
    required this.accent,
    required this.label,
    required this.gradient,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onTap: () {
            Navigator.of(context).pop();
            onSelect(accent);
          },
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: gradient,
              border:
                  Border.all(color: Colors.white.withOpacity(0.1), width: 2),
              boxShadow: [
                BoxShadow(
                  color: gradient.colors.last.withOpacity(0.5),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                )
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
