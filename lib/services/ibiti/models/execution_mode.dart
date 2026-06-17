// ─── IBITI Execution Mode ───────────────────────────────────────────────────────
//
// Controls what IBITI is allowed to DO. The architecture is always complete;
// execution modes act as safety fuses, not feature flags.
//
// Progression: observeOnly → paper → microReal → guardedReal → fullAutonomy
// Each level unlocks more capability. Downgrade is instant (kill switch).
// ─────────────────────────────────────────────────────────────────────────────────

/// What IBITI is allowed to do right now.
enum ExecutionMode {
  /// Eyes only. Perceive events, log decisions. No trades, no paper P&L.
  /// Use this while validating that Perception sees the market correctly.
  observeOnly,

  /// Paper trading. Full cognitive loop runs, decisions are made,
  /// but no real execution. Virtual P&L tracked for statistics.
  paper,

  /// Micro-real. Real trades via AutomationDispatchService, but
  /// hard-capped at $1–3 per trade. Proves real execution path works.
  microReal,

  /// Guarded real. Real trades within AutonomyMandate limits.
  /// User-configured caps (perTxLimit, dailyLimit) fully enforced.
  guardedReal,

  /// Full autonomy. All mandate limits still apply, but IBITI has
  /// maximum discretion within those bounds. Requires explicit user
  /// opt-in and proven statistical track record.
  fullAutonomy,
}

extension ExecutionModeExt on ExecutionMode {
  String get label => switch (this) {
        ExecutionMode.observeOnly => '👁️ Observe Only',
        ExecutionMode.paper => '📝 Paper Trading',
        ExecutionMode.microReal => '🔬 Micro Real',
        ExecutionMode.guardedReal => '🛡️ Guarded Real',
        ExecutionMode.fullAutonomy => '⚡ Full Autonomy',
      };

  /// Whether this mode can place real trades.
  bool get canExecuteReal => switch (this) {
        ExecutionMode.observeOnly => false,
        ExecutionMode.paper => false,
        ExecutionMode.microReal => true,
        ExecutionMode.guardedReal => true,
        ExecutionMode.fullAutonomy => true,
      };

  /// Whether this mode tracks paper P&L.
  bool get tracksPaperPnl => switch (this) {
        ExecutionMode.observeOnly => false,
        ExecutionMode.paper => true,
        ExecutionMode.microReal => false,
        ExecutionMode.guardedReal => false,
        ExecutionMode.fullAutonomy => false,
      };

  /// Max USD per trade for this mode. null = use mandate limit.
  double? get hardCapPerTradeUsd => switch (this) {
        ExecutionMode.observeOnly => 0,
        ExecutionMode.paper => 0,
        ExecutionMode.microReal => 3.0,
        ExecutionMode.guardedReal => null, // mandate limit
        ExecutionMode.fullAutonomy => null, // mandate limit
      };
}
