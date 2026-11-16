/// How addresses are stored and compared in the trusted lists (AI whitelist)
/// and the address book.
///
/// EVM (0x) addresses are hex: letter case only carries a checksum, so they
/// are compared in lower case. Solana and Tron (base58) addresses are
/// case-sensitive: changing a letter's case gives a different account, so
/// they are kept and compared exactly as written.
class AddressKey {
  const AddressKey._();

  // Base58 (Solana, Tron) has no "0", so a leading "0x" always means hex.
  static final _evm = RegExp(r'^0[xX]');

  /// The form to store and compare.
  static String of(String address) {
    final a = address.trim();
    return _evm.hasMatch(a) ? a.toLowerCase() : a;
  }

  /// Whether [a] and [b] are the same address.
  static bool same(String a, String b) => of(a) == of(b);
}
