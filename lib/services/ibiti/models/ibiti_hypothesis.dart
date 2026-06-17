// ─── IBITI Hypothesis ───────────────────────────────────────────────────────────
//
// When IBITI sees something interesting, it builds a hypothesis: why this
// might be a good trade (bull), why it might fail (bear), what could go
// wrong (risk), and whether execution is feasible (execution).
//
// Brain fills this. Constitution validates it. Debate challenges it.
// ─────────────────────────────────────────────────────────────────────────────────

import 'package:ibiti_guardian/services/ibiti/models/market_event.dart';
import 'package:ibiti_guardian/services/ibiti/models/market_phase.dart';
import 'package:ibiti_guardian/services/ibiti/models/strategy_context.dart';

/// Final verdict after hypothesis evaluation.
enum IbitiVerdict {
  /// Enter the trade (paper or real depending on ExecutionMode).
  buy,

  /// Brain said buy, but mode is observeOnly — log intent, don't act.
  wouldBuy,

  /// Interesting but not ready — monitor and re-evaluate.
  watch,

  /// Not worth it — skip with documented reason.
  reject,

  /// Too uncertain — escalate to user for manual decision.
  askUser,
}

extension IbitiVerdictExt on IbitiVerdict {
  String get label => switch (this) {
        IbitiVerdict.buy => 'КУПИТЬ',
        IbitiVerdict.wouldBuy => 'КУПИЛ БЫ',
        IbitiVerdict.watch => 'НАБЛЮДАЮ',
        IbitiVerdict.reject => 'ПРОПУСКАЮ',
        IbitiVerdict.askUser => 'СПРОСИТЬ',
      };

  bool get isActionable =>
      this == IbitiVerdict.buy || this == IbitiVerdict.askUser;
}

/// A full hypothesis about a market event.
class IbitiHypothesis {
  /// The event that triggered this hypothesis.
  final MarketEvent event;

  /// Market phase at hypothesis time.
  final MarketPhase marketPhase;

  // ── Four cases ──

  /// Why this trade could work.
  final String bullCase;

  /// Why this trade could fail.
  final String bearCase;

  /// What execution/market risks exist.
  final String riskCase;

  /// Whether we can actually execute (liquidity, spread, gas).
  final String executionCase;

  // ── Verdict ──

  /// Final decision.
  final IbitiVerdict verdict;

  /// Full reasoning chain explaining the verdict.
  final String reasoning;

  /// Confidence in the verdict (0.0–1.0).
  final double confidence;

  /// Uncertainty level (0.0–1.0). High = too many unknowns.
  final double uncertainty;

  /// When this hypothesis was created.
  final DateTime createdAt;

  /// Source: "deterministic" or "llm" — tracks how the hypothesis was built.
  final String source;

  /// Phase 9: TA-suggested take-profit percent (e.g. 3.5 = +3.5%).
  /// Null if TA unavailable — PaperTrader will use its default.
  final double? suggestedTpPercent;

  /// Phase 9: TA-suggested stop-loss percent (e.g. 2.0 = -2.0%).
  /// Null if TA unavailable — PaperTrader will use its default.
  final double? suggestedSlPercent;

  /// Phase 10A: Context classification — what kind of asset/situation is this?
  final StrategyContext? strategyContext;

  const IbitiHypothesis({
    required this.event,
    this.marketPhase = MarketPhase.sideways,
    required this.bullCase,
    required this.bearCase,
    required this.riskCase,
    required this.executionCase,
    required this.verdict,
    required this.reasoning,
    this.confidence = 0.5,
    this.uncertainty = 0.5,
    required this.createdAt,
    this.source = 'deterministic',
    this.suggestedTpPercent,
    this.suggestedSlPercent,
    this.strategyContext,
  });

  Map<String, dynamic> toJson() => {
        'event': event.toJson(),
        'marketPhase': marketPhase.name,
        'bullCase': bullCase,
        'bearCase': bearCase,
        'riskCase': riskCase,
        'executionCase': executionCase,
        'verdict': verdict.name,
        'reasoning': reasoning,
        'confidence': confidence,
        'uncertainty': uncertainty,
        'createdAt': createdAt.toIso8601String(),
        'source': source,
        'suggestedTpPercent': suggestedTpPercent,
        'suggestedSlPercent': suggestedSlPercent,
        'strategyContext': strategyContext?.toJson(),
      };

  factory IbitiHypothesis.fromJson(Map<String, dynamic> json) {
    return IbitiHypothesis(
      event: MarketEvent.fromJson(json['event'] as Map<String, dynamic>? ?? {}),
      marketPhase: MarketPhase.values.firstWhere(
        (e) => e.name == json['marketPhase'],
        orElse: () => MarketPhase.sideways,
      ),
      bullCase: json['bullCase'] as String? ?? '',
      bearCase: json['bearCase'] as String? ?? '',
      riskCase: json['riskCase'] as String? ?? '',
      executionCase: json['executionCase'] as String? ?? '',
      verdict: IbitiVerdict.values.firstWhere(
        (e) => e.name == json['verdict'],
        orElse: () => IbitiVerdict.reject,
      ),
      reasoning: json['reasoning'] as String? ?? '',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.5,
      uncertainty: (json['uncertainty'] as num?)?.toDouble() ?? 0.5,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      source: json['source'] as String? ?? 'deterministic',
      suggestedTpPercent: (json['suggestedTpPercent'] as num?)?.toDouble(),
      suggestedSlPercent: (json['suggestedSlPercent'] as num?)?.toDouble(),
    );
  }
}
