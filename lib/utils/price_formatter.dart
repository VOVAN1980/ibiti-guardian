// ─── PriceFormatter ────────────────────────────────────────────────────────────
//
// Single source of truth for all numeric display in market screens.
// Rules mirror professional trading terminal conventions (Binance, MEXC web UI).
//
//   Price:
//     ≥ 1 000        → 2 significant decimals, trailing zeros trimmed
//     ≥ 1            → up to 4 decimals
//     ≥ 0.01         → up to 6 decimals
//     ≥ 0.0001       → up to 8 decimals
//     ≥ 0.000001     → up to 10 decimals
//     < 0.000001     → up to 12 decimals
//
//   Percent change:
//     percent()      → 2 decimals  (lists, badges, terminal rows)
//     percentLive()  → 4 decimals  (TokenDetail header — shows movement)
//
//   Large (market cap / volume):
//     T / B / M / K abbreviations, 2 decimal.
// ─────────────────────────────────────────────────────────────────────────────────

class PriceFormatter {
  PriceFormatter._();

  /// Format a USD price with terminal-grade precision.
  /// Returns the numeric string WITHOUT the leading '$'.
  ///
  /// Trailing zeros are trimmed for readability:
  ///   97654.00 → 97654    3.1400 → 3.14
  /// But significant digits are preserved:
  ///   0.00031415 → 0.00031415
  static String price(double p) {
    if (p <= 0) return '—';
    String raw;
    if (p >= 1000) {
      raw = p.toStringAsFixed(2);
    } else if (p >= 1) {
      raw = p.toStringAsFixed(4);
    } else if (p >= 0.01) {
      raw = p.toStringAsFixed(6);
    } else if (p >= 0.0001) {
      raw = p.toStringAsFixed(8);
    } else if (p >= 0.000001) {
      raw = p.toStringAsFixed(10);
    } else {
      raw = p.toStringAsFixed(12);
    }
    return _trimTrailingZeros(raw);
  }

  /// Format a USD price with leading '$'.
  static String priceUsd(double p) {
    if (p <= 0) return '—';
    return '\$${price(p)}';
  }

  /// Format percent change — 2 decimals for lists and badges.
  /// Includes leading '+' for positive values.
  static String percent(double pct, {bool showPlus = true}) {
    final s = pct.toStringAsFixed(2);
    if (showPlus && pct >= 0) return '+$s%';
    return '$s%';
  }

  /// Format percent change — 4 decimals for live TokenDetail header.
  /// Shows micro-movement that matters in real-time view.
  static String percentLive(double pct, {bool showPlus = true}) {
    final s = pct.toStringAsFixed(4);
    if (showPlus && pct >= 0) return '+$s%';
    return '$s%';
  }

  /// Compact format for large numbers (market cap, volume).
  /// Returns with leading '$'.
  static String large(double v) {
    if (v <= 0) return '—';
    if (v >= 1e12) return '\$${(v / 1e12).toStringAsFixed(2)}T';
    if (v >= 1e9) return '\$${(v / 1e9).toStringAsFixed(2)}B';
    if (v >= 1e6) return '\$${(v / 1e6).toStringAsFixed(2)}M';
    if (v >= 1e3) return '\$${(v / 1e3).toStringAsFixed(1)}K';
    return '\$${v.toStringAsFixed(0)}';
  }

  /// Compact format for volume WITHOUT leading '$' (e.g. exchange terminal).
  static String volume(double v) {
    if (v >= 1e9) return '${(v / 1e9).toStringAsFixed(1)}B';
    if (v >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
    if (v >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}K';
    return v.toStringAsFixed(0);
  }

  /// Trim trailing zeros after decimal point.
  /// '97654.00' → '97654', '3.1400' → '3.14', '0.00031415' → '0.00031415'
  static String _trimTrailingZeros(String s) {
    if (!s.contains('.')) return s;
    // Remove trailing '0's
    var trimmed = s;
    while (trimmed.endsWith('0')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    // Remove trailing '.' if all decimals were zeros
    if (trimmed.endsWith('.')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }
}
