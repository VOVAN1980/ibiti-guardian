import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/wallet/address_book_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

class WalletAddressBookScreen extends StatelessWidget {
  const WalletAddressBookScreen({super.key});

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
        listenable: AddressBookService.instance,
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
                  color: GuardianColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.person_outline_rounded,
                  color: Colors.white,
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
                  } else if (value == 'delete') {
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
    builder: (_) => AlertDialog(
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
          onPressed: () => Navigator.pop(context),
          child: Text(t.t('cancel', {'default': 'Cancel'})),
        ),
        ElevatedButton(
          onPressed: () async {
            final label = labelCtrl.text.trim();
            final address = addrCtrl.text.trim();
            if (label.isEmpty || address.isEmpty) return;
            if (existing != null &&
                existing.address.toLowerCase() != address.toLowerCase()) {
              await AddressBookService.instance.remove(existing.address);
            }
            await AddressBookService.instance.add(label, address);
            if (context.mounted) Navigator.pop(context);
          },
          child: Text(t.t('save', {'default': 'Save'})),
        ),
      ],
    ),
  );
}
