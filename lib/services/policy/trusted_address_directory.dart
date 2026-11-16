import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/services/wallet/address_book_service.dart';
import 'package:ibiti_guardian/utils/address_key.dart';

/// One trusted (AI-whitelisted) address with its address-book name, if any.
class TrustedAddressItem {
  final String address;
  final String? label;
  final bool isContract;
  const TrustedAddressItem({
    required this.address,
    this.label,
    this.isContract = false,
  });

  /// Short form for lists and speech: 0x1958...1383.
  String get shortAddress => address.length > 12
      ? '${address.substring(0, 6)}...${address.substring(address.length - 4)}'
      : address;

  /// The name the owner gave it, else the short address.
  String get displayName => label ?? shortAddress;
}

/// The AI whitelist ("trusted addresses") named from the address book.
///
/// Read-only: the screen, the Command Center and the assistant all list it
/// from here. Only the owner changes it, with the PIN (AiTrustActions).
class TrustedAddressDirectory {
  const TrustedAddressDirectory._();

  static List<TrustedAddressItem> current() => build(
        PolicyProfileStore.instance.current,
        AddressBookService.instance.entries,
      );

  static List<TrustedAddressItem> build(
    PolicyProfile profile,
    List<AddressEntry> book,
  ) {
    String? nameOf(String address) {
      for (final e in book) {
        if (AddressKey.same(e.address, address)) return e.label;
      }
      return null;
    }

    return [
      for (final a in profile.trustedAddresses)
        TrustedAddressItem(address: a, label: nameOf(a)),
      for (final c in profile.trustedContracts)
        TrustedAddressItem(address: c, label: nameOf(c), isContract: true),
    ];
  }
}
