import 'dart:typed_data';
import 'package:crypto/crypto.dart';

class TronUtils {
  static const String _alphabet =
      '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

  /// Converts a standard 0x-prefixed EVM address to a Base58Check Tron address.
  /// E.g. 0x123... -> T123...
  static String evmAddressToTron(String evmAddress) {
    if (!evmAddress.startsWith('0x') || evmAddress.length != 42) {
      return evmAddress;
    }

    final hexStr = evmAddress.substring(2);
    final payloadBytes = <int>[];
    payloadBytes.add(0x41); // Tron prefix

    for (int i = 0; i < hexStr.length; i += 2) {
      payloadBytes.add(int.parse(hexStr.substring(i, i + 2), radix: 16));
    }

    final bytes = Uint8List.fromList(payloadBytes);

    // Double SHA256 for checksum
    final firstHash = sha256.convert(bytes).bytes;
    final secondHash = sha256.convert(firstHash).bytes;

    // Append 4 bytes of checksum
    final addressBytes = Uint8List(bytes.length + 4);
    addressBytes.setAll(0, bytes);
    addressBytes.setAll(bytes.length, secondHash.sublist(0, 4));

    return _encodeBase58(addressBytes);
  }

  static String _encodeBase58(Uint8List bytes) {
    if (bytes.isEmpty) return '';

    BigInt value = BigInt.zero;
    for (var i = 0; i < bytes.length; i++) {
      value = (value * BigInt.from(256)) + BigInt.from(bytes[i]);
    }

    String result = '';
    while (value > BigInt.zero) {
      final mod = value % BigInt.from(58);
      value = value ~/ BigInt.from(58);
      result = _alphabet[mod.toInt()] + result;
    }

    // Handle leading zeroes
    for (var i = 0; i < bytes.length && bytes[i] == 0; i++) {
      result = _alphabet[0] + result;
    }

    return result;
  }
}
