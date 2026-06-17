// ─── Entry Timing ──────────────────────────────────────────────────────────────
//
// Represents the quality/safety of the entry timing based on TA (RSI, Trend, Volume).
// ─────────────────────────────────────────────────────────────────────────────────

enum EntryTiming {
  early,
  normal,
  late,
  dangerous,
  unknown;

  @override
  String toString() => name;
}
