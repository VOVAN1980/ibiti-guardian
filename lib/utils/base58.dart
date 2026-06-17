import 'dart:typed_data';

class Base58 {
  static const String _alphabet =
      '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

  static Uint8List decode(String input) {
    if (input.isEmpty) return Uint8List(0);

    BigInt value = BigInt.zero;
    for (int i = 0; i < input.length; i++) {
      final charIndex = _alphabet.indexOf(input[i]);
      if (charIndex < 0) {
        throw FormatException('Invalid Base58 character: ${input[i]}');
      }
      value = (value * BigInt.from(58)) + BigInt.from(charIndex);
    }

    final bytes = <int>[];
    while (value > BigInt.zero) {
      bytes.add((value % BigInt.from(256)).toInt());
      value = value ~/ BigInt.from(256);
    }

    final reversed = bytes.reversed.toList();

    // Preserve leading zeros
    int leadingZeros = 0;
    while (leadingZeros < input.length && input[leadingZeros] == '1') {
      leadingZeros++;
    }

    final result = Uint8List(leadingZeros + reversed.length);
    for (int i = 0; i < leadingZeros; i++) {
      result[i] = 0;
    }
    for (int i = 0; i < reversed.length; i++) {
      result[leadingZeros + i] = reversed[i];
    }

    return result;
  }

  static String encode(Uint8List bytes) {
    if (bytes.isEmpty) return '';

    BigInt value = BigInt.zero;
    for (int i = 0; i < bytes.length; i++) {
      value = (value * BigInt.from(256)) + BigInt.from(bytes[i]);
    }

    String result = '';
    while (value > BigInt.zero) {
      final mod = value % BigInt.from(58);
      value = value ~/ BigInt.from(58);
      result = '${_alphabet[mod.toInt()]}$result';
    }

    // Preserve leading zeros
    int leadingZeros = 0;
    while (leadingZeros < bytes.length && bytes[leadingZeros] == 0) {
      leadingZeros++;
    }

    for (int i = 0; i < leadingZeros; i++) {
      result = '1$result';
    }

    return result;
  }
}
