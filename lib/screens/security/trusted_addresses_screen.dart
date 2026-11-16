import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/screens/security/ai_trust_actions.dart';
import 'package:ibiti_guardian/screens/wallet/wallet_address_book_screen.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/services/policy/trusted_address_directory.dart';
import 'package:ibiti_guardian/services/wallet/address_book_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

/// The AI whitelist: the only addresses the AI may send to. Opened from the
/// Command Center ("Trusted addresses") or by asking the assistant.
class TrustedAddressesScreen extends StatefulWidget {
  const TrustedAddressesScreen({super.key});

  /// How many copies are open; the assistant opens it only when none is.
  static int openCount = 0;

  static String _short(String a) => a.length > 18
      ? '${a.substring(0, 10)}...${a.substring(a.length - 6)}'
      : a;

  @override
  State<TrustedAddressesScreen> createState() => _TrustedAddressesScreenState();
}

class _TrustedAddressesScreenState extends State<TrustedAddressesScreen> {
  static const _subScreen = 'trusted_addresses';

  @override
  void initState() {
    super.initState();
    TrustedAddressesScreen.openCount++;
    // Lets the assistant know what the owner is looking at.
    ScreenContextService.instance.setSubScreen(_subScreen);
  }

  @override
  void dispose() {
    TrustedAddressesScreen.openCount--;
    ScreenContextService.instance.clearSubScreen(_subScreen);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    return Scaffold(
      backgroundColor: GuardianColors.background,
      appBar: AppBar(
        backgroundColor: GuardianColors.background,
        elevation: 0,
        title: Text(
          t.t('trustedAddressesTitle', {'default': 'Trusted addresses'}),
          style: GuardianTextStyles.headline,
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: GuardianColors.accent,
        foregroundColor: Colors.white,
        onPressed: () => _pickFromAddressBook(context, t),
        icon: const Icon(Icons.add_rounded),
        label: Text(t.t('trustedAddressesAdd', {'default': 'Add'})),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge(
            [PolicyProfileStore.instance, AddressBookService.instance]),
        builder: (context, _) {
          final items = TrustedAddressDirectory.current();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
            children: [
              Text(
                t.t('trustedAddressesHint', {
                  'default':
                      'AI can send only to these addresses. Your own transfers are not limited.',
                }),
                style: GuardianTextStyles.bodySecondary,
              ),
              const SizedBox(height: 16),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: Column(
                    children: [
                      const Icon(Icons.verified_user_outlined,
                          color: GuardianColors.success, size: 40),
                      const SizedBox(height: 12),
                      Text(
                        t.t('trustedAddressesEmpty',
                            {'default': 'No trusted addresses yet'}),
                        style: GuardianTextStyles.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              else
                for (final item in items) ...[
                  _TrustedCard(item: item, t: t),
                  const SizedBox(height: 12),
                ],
            ],
          );
        },
      ),
    );
  }

  /// Lists address-book contacts that can be trusted and aren't yet.
  Future<void> _pickFromAddressBook(
      BuildContext context, LocalizationService t) async {
    final candidates = AddressBookService.instance.entries
        .where((e) =>
            AiTrustActions.canTrust(e.address) &&
            !AiTrustActions.isTrusted(e.address))
        .toList();

    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(t.t('trustedAddressesNoCandidates', {
          'default': 'Save the address in the address book first.',
        })),
      ));
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const WalletAddressBookScreen(),
      ));
      return;
    }

    final picked = await showModalBottomSheet<AddressEntry>(
      context: context,
      useSafeArea: true,
      backgroundColor: GuardianColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Text(
              t.t('trustedAddressesPickTitle',
                  {'default': 'Choose a contact'}),
              style: GuardianTextStyles.titleMedium,
            ),
          ),
          for (final e in candidates)
            ListTile(
              leading: const Icon(Icons.person_outline_rounded,
                  color: Colors.white),
              title: Text(e.label, style: GuardianTextStyles.bodyPrimary),
              subtitle: Text(TrustedAddressesScreen._short(e.address),
                  style: GuardianTextStyles.caption),
              onTap: () => Navigator.of(sheetContext).pop(e),
            ),
        ],
      ),
    );
    if (picked == null || !context.mounted) return;
    await AiTrustActions.trust(context,
        label: picked.label, address: picked.address);
  }
}

class _TrustedCard extends StatelessWidget {
  final TrustedAddressItem item;
  final LocalizationService t;
  const _TrustedCard({required this.item, required this.t});

  @override
  Widget build(BuildContext context) {
    final title = item.label ?? TrustedAddressesScreen._short(item.address);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: GuardianColors.success.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: GuardianColors.success.withOpacity(0.16),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.verified_user_rounded,
                color: GuardianColors.success, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GuardianTextStyles.bodyPrimary
                      .copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  item.address,
                  style: GuardianTextStyles.caption,
                ),
                if (item.isContract)
                  Text(
                    t.t('securityTrustTypeContract', {'default': 'Contract'}),
                    style: GuardianTextStyles.caption,
                  ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            color: GuardianColors.surfaceElevated,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            icon: const Icon(Icons.more_horiz_rounded, color: Colors.white),
            onSelected: (value) async {
              if (value == 'copy') {
                await Clipboard.setData(ClipboardData(text: item.address));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(t.t('walletAddressCopied',
                        {'default': 'Address copied'})),
                  ));
                }
              } else if (value == 'untrust') {
                await AiTrustActions.untrust(context,
                    label: title, address: item.address);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'copy',
                child: Text(t.t('copyAddress', {'default': 'Copy address'})),
              ),
              PopupMenuItem(
                value: 'untrust',
                child: Text(t.t('addressBookUntrustAi',
                    {'default': 'Remove from trusted'})),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
