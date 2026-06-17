// ─── Trend Direction ───────────────────────────────────────────────────────────
//
// Represents the current market structure trend based on TA (EMA, price action).
// ─────────────────────────────────────────────────────────────────────────────────

enum TrendDirection {
  bullish,
  bearish,
  sideways,
  volatile,
  exhaustion,
  unknown;

  @override
  String toString() => name;
}
