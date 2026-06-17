BigInt parseDecimalToAtomic(String input, int decimals) {
  var clean = input.replaceAll(',', '.').trim();

  // 1. Return 0 for empty or negative
  if (clean.isEmpty || clean.startsWith('-')) return BigInt.zero;

  // 2. Normalize ".5" -> "0.5"
  if (clean.startsWith('.')) {
    clean = '0$clean';
  }

  // 3. Strict regex: only digits and at most one dot
  // e.g. "1.2.3" fails, "abc" fails, " 0.5 " fails (was trimmed)
  final validRegex = RegExp(r'^[0-9]+(\.[0-9]+)?$');
  if (!validRegex.hasMatch(clean)) {
    return BigInt.zero;
  }

  // 4. Split
  final parts = clean.split('.');
  String whole = parts[0];
  String frac = parts.length > 1 ? parts[1] : '';

  // 5. Strip extra leading zeros from whole (e.g. "000" -> "0")
  while (whole.length > 1 && whole.startsWith('0')) {
    whole = whole.substring(1);
  }

  // 6. Pad or truncate fraction
  if (frac.length > decimals) {
    frac = frac.substring(0, decimals);
  } else {
    frac = frac.padRight(decimals, '0');
  }

  final combinedStr = whole + frac;

  // 7. Parse safely
  try {
    return BigInt.parse(combinedStr);
  } catch (_) {
    return BigInt.zero;
  }
}
