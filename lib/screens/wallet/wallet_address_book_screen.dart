import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/screens/security/ai_trust_actions.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/services/wallet/address_book_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';
import 'package:ibiti_guardian/utils/address_key.dart';

class WalletAddressBookScreen extends StatefulWidget {
  const WalletAddressBookScreen({super.key});

  @override
  State<WalletAddressBookScreen> createState() =>
      _WalletAddressBookScreenState();
}

class _WalletAddressBookScreenState extends State<WalletAddressBookScreen> {
  @override
  void initState() {
    super.initState();
    // Lets the assistant know the owner is looking at the address book.
    ScreenContextService.instance.setSubScreen('address_book');
  }

  @override
  void dispose() {
    ScreenContextService.instance.clearSubScreen('address_book');
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
          t.t('walletAddressBookTitle', {'default': 'Address book'}),
          style: GuardianTextStyles.headline,
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: GuardianColors.accent,
        foregroundColor: Colors.white,
        onPressed: () => _showAddressDialog(context, t: t),
        icon: const Icon(Icons.add_rounded),
        label:
            Text(t.t('walletSettingsAddAddress', {'default': 'Add address'})),
      ),
      body: ListenableBuilder(
        // The trusted-for-AI marks come from the policy profile, so the list
        // also rebuilds when an address is trusted or untrusted.
        listenable: Listenable.merge(
            [AddressBookService.instance, PolicyProfileStore.instance]),
        builder: (context, _) {
          final entries = AddressBookService.instance.entries;
          if (entries.isEmpty) {
            return _EmptyAddressBook(t: t);
          }

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            itemBuilder: (context, index) => _AddressCard(
              entry: entries[index],
              t: t,
            ),
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemCount: entries.length,
          );
        },
      ),
    );
  }
}

class _EmptyAddressBook extends StatelessWidget {
  final LocalizationService t;
  const _EmptyAddressBook({required this.t});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.04),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: GuardianColors.accent.withOpacity(0.14),
                ),
                child: const Icon(
                  Icons.import_contacts_rounded,
                  color: GuardianColors.accent,
                  size: 32,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                t.t('walletAddressBookEmptyTitle', {
                  'default': 'No saved recipients yet',
                }),
                style: GuardianTextStyles.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                t.t('walletAddressBookEmptySubtitle', {
                  'default':
                      'Save trusted wallet addresses here for faster and safer transfers.',
                }),
                style: GuardianTextStyles.bodySecondary,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddressCard extends StatelessWidget {
  final AddressEntry entry;
  final LocalizationService t;
  const _AddressCard({
    required this.entry,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    final canTrust = AiTrustActions.canTrust(entry.address);
    final trusted = canTrust && AiTrustActions.isTrusted(entry.address);
    final short = entry.address.length > 18
        ? '${entry.address.substring(0, 10)}...${entry.address.substring(entry.address.length - 6)}'
        : entry.address;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: trusted
                      ? GuardianColors.success.withOpacity(0.16)
                      : GuardianColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  trusted
                      ? Icons.verified_user_rounded
                      : Icons.person_outline_rounded,
                  color: trusted ? GuardianColors.success : Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.label,
                      style: GuardianTextStyles.bodyPrimary
                          .copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      short,
                      style: GuardianTextStyles.caption,
                    ),
                    if (trusted) ...[
                      const SizedBox(height: 4),
                      Text(
                        t.t('addressBookTrustedBadge',
                            {'default': 'Trusted for AI'}),
                        style: GuardianTextStyles.caption.copyWith(
                          color: GuardianColors.success,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                color: GuardianColors.surfaceElevated,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                onSelected: (value) async {
                  if (value == 'copy') {
                    await Clipboard.setData(ClipboardData(text: entry.address));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            t.t('walletAddressCopied', {
                              'default': 'Address copied',
                            }),
                          ),
                        ),
                      );
                    }
                  } else if (value == 'edit') {
                    _showAddressDialog(
                      context,
                      t: t,
                      existing: entry,
                    );
                  } else if (value == 'trust') {
                    await AiTrustActions.trust(context,
                        label: entry.label, address: entry.address);
                  } else if (value == 'untrust') {
                    await AiTrustActions.untrust(context,
                        label: entry.label, address: entry.address);
                  } else if (value == 'delete') {
                    // A deleted contact can no longer be seen or untrusted
                    // here, so it must not stay on the AI whitelist either.
                    await AiTrustActions.untrust(context,
                        label: entry.label,
                        address: entry.address,
                        silent: true,
                        reason: ' (contact deleted)');
                    await AddressBookService.instance.remove(entry.address);
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'copy',
                    child: Text(
                      t.t('copyAddress', {'default': 'Copy address'}),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'edit',
                    child: Text(
                      t.t('edit', {'default': 'Edit'}),
                    ),
                  ),
                  if (canTrust)
                    PopupMenuItem(
                      value: trusted ? 'untrust' : 'trust',
                      child: Text(
                        trusted
                            ? t.t('addressBookUntrustAi',
                                {'default': 'Remove from trusted'})
                            : t.t('addressBookTrustAi',
                                {'default': 'Trust for AI'}),
                      ),
                    ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      t.t('delete', {'default': 'Delete'}),
                    ),
                  ),
                ],
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.more_horiz_rounded,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.16),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.06)),
            ),
            child: SelectableText(
              entry.address,
              style: GuardianTextStyles.caption.copyWith(
                color: Colors.white.withOpacity(0.84),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _showAddressDialog(
  BuildContext context, {
  required LocalizationService t,
  AddressEntry? existing,
}) async {
  final labelCtrl = TextEditingController(text: existing?.label ?? '');
  final addrCtrl = TextEditingController(text: existing?.address ?? '');
  await showDialog(
    context: context,
    // Close with the dialog's own context: the card that opened it can be
    // rebuilt or removed while the change is being saved.
    builder: (dialogContext) => AlertDialog(
      backgroundColor: GuardianColors.surface,
      title: Text(
        existing == null
            ? t.t('walletSettingsAddAddress', {'default': 'Add address'})
            : t.t('walletAddressBookEditTitle', {'default': 'Edit recipient'}),
        style: GuardianTextStyles.titleMedium,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: labelCtrl,
            decoration: InputDecoration(
              labelText: t.t('walletSettingsLabel', {'default': 'Label'}),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: addrCtrl,
            decoration: InputDecoration(
              labelText: t.t('walletSettingsAddressField', {
                'default': 'Address (0x...)',
              }),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(t.t('cancel', {'default': 'Cancel'})),
        ),
        ElevatedButton(
          onPressed: () async {
            final label = labelCtrl.text.trim();
            final address = addrCtrl.text.trim();
            if (label.isEmpty || address.isEmpty) return;
            if (existing != null &&
                AddressKey.same(existing.address, address)) {
              // Renaming: change the name in place. Adding again used to
              // leave the old "Recent 0x…" entry next to the renamed copy.
              await AddressBookService.instance.update(address, label);
            } else {
              if (existing != null) {
                // Trust belongs to the old address; a new address must be
                // trusted again with the PIN.
                await AiTrustActions.untrust(dialogContext,
                    label: existing.label,
                    address: existing.address,
                    silent: true,
                    reason: ' (address changed)');
                await AddressBookService.instance.remove(existing.address);
              }
              await AddressBookService.instance.add(label, address);
            }
            if (dialogContext.mounted) Navigator.pop(dialogContext);
          },
          child: Text(t.t('save', {'default': 'Save'})),
        ),
      ],
    ),
  );
}
