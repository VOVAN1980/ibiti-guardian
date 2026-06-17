// ─── JARVIS Context Pack Builder ────────────────────────────────────────────────
//
// Phase 18D: Assembles ALL available information into a single structured
// package for the AI Core (LLM) to consume.
//
// This is the "eyes" of JARVIS: everything he knows about a signal before
// making a decision. The Context Pack is designed to be:
//   1. Serializable to JSON (for LLM prompt construction)
//   2. Comprehensive (market + memory + system state)
//   3. Extensible (Phase 18F connectors plug in here)
//
// Data Sources:
//   ✅ Market event (price, volume, flow, change%)
//   ✅ KnownAssetRegistry (18A identity)
//   ✅ Freedom Mode state (18B overrides)
//   ✅ Continuation Score (18C rocket analysis)
//   ✅ StrategyContext (classifier output)
//   ✅ Token/Exchange profiles (memory)
//   ✅ Candle data (TA)
//   ✅ Portfolio state (paper trader)
//   ✅ Lessons from past trades
//   ✅ Heartbeat (market perception)
//   ✅ Soft penalties (Constitution)
//   🔜 External data (18F: CoinGecko, DexScreener, News, Social, OnChain)
// ─────────────────────────────────────────────────────────────────────────────────

import 'package:ibiti_guardian/services/ibiti/models/market_event.dart';
import 'package:ibiti_guardian/services/ibiti/models/market_phase.dart';
import 'package:ibiti_guardian/services/ibiti/models/strategy_context.dart';
import 'package:ibiti_guardian/services/ibiti/models/candle_snapshot.dart';
import 'package:ibiti_guardian/services/ibiti/models/trading_policy_snapshot.dart';
import 'package:ibiti_guardian/services/ibiti/known_asset_registry.dart';

// ── Stub types for archived dependencies ──
// These were defined in archived files. Minimal stubs to keep the data class compiling.

class ContinuationResult {
  final double score;
  final String stage;
  final double eqModifier;
  final List<String> factors;
  const ContinuationResult({this.score = 0, this.stage = 'unknown', this.eqModifier = 0, this.factors = const []});
}

class SoftPenalty {
  final String ruleId;
  final double eqModifier;
  const SoftPenalty({required this.ruleId, required this.eqModifier});
}

class SymbolMemorySummary {
  final String? status;
  const SymbolMemorySummary({this.status});
  String toLLMContext() => '';
}

class JournalEntry {
  String toContextLine() => '';
}

class GlobalRule {
  String toLLMContext() => '';
}

// ═════════════════════════════════════════════════════════════════════════════
// CONTEXT PACK — everything JARVIS knows about a signal
// ═════════════════════════════════════════════════════════════════════════════

class JarvisContextPack {
  // ── Market Event ──
  final String symbol;
  final String exchange;
  final double price;
  final double changePercent;
  final double volume24h;
  final String eventType;
  final DateTime timestamp;

  // ── Flow ──
  final String flowClass;
  final double volumeFlowScore;
  final double flow5mUsd;

  // ── Identity (18A) ──
  final AssetIdentity? knownIdentity;
  final AssetCategory assetCategory;
  final String assetCategoryLabel;

  // ── Strategy Classification ──
  final StrategyType strategyType;
  final RocketStage rocketStage;
  final TokenMaturity tokenMaturity;
  final double strategyConfidence;
  final List<String> strategyReasons;
  final bool isExhaustionRisk;

  // ── Continuation Score (18C) ──
  final ContinuationResult? continuation;

  // ── Constitution State (18B) ──
  final List<String> softPenaltyRules;
  final double softPenaltyTotal;
  final bool freedomModeActive;

  // ── Market Perception ──
  final MarketPhase marketPhase;
  final String marketHeartbeat;

  // ── Token Memory ──
  final int tokenTimesSeen;
  final double tokenWinRate;
  final double tokenFakeBreakoutRate;
  final bool tokenIsNoisy;

  // ── Portfolio State ──
  final int openTradeCount;
  final double exposurePct;
  final double maxExposurePct;
  final double portfolioWinRate;
  final double portfolioProfitFactor;
  final double dailyPnl;
  final double bankrollBalance;
  final int consecutiveLosses;

  // ── Candle Data ──
  final int candleCount5m;
  final bool hasTaData;
  final double? suggestedTpPercent;
  final double? suggestedSlPercent;

  // ── Last Trade on This Token ──
  final double? lastTradeEntryPrice;
  final double? lastTradeExitPrice;
  final double? lastTradeNetPnl;
  final String? lastTradeCloseReason;
  final double? priceVsLastExit; // current price / last exit price - 1.0 (e.g. +0.50 = price 50% higher than exit)

  // ── Strategy Pattern Memory ──
  // From StrategyKnowledgeEngine: how this pattern performed historically.
  // LLM MUST see this before deciding. No more blind entries.
  final int patternSamples;
  final double patternWinRate;
  final double patternProfitFactor;
  final double patternExpectancy;
  final int symbolDisasterStops;
  final String patternVerdict; // 'proven_good' / 'proven_bad' / 'insufficient_data' / 'neutral'

  // ── Lessons ──
  final List<String> relevantLessonSummaries;

  // ── Trading Policy (read-only visibility) ──
  // JARVIS sees the policy but does NOT execute through it.
  final TradingPolicySnapshot? policySnapshot;

  // ── External Data (18F placeholder) ──
  // These will be populated when connectors are added.
  final Map<String, dynamic>? externalData;

  // ── Market Radar ──
  final List<Map<String, dynamic>> marketRadar;

  // ── Brain v2: Journal Memory ──
  // JARVIS's own past analysis of this symbol.
  final SymbolMemorySummary? symbolMemory;
  final List<JournalEntry> journalEntries;

  // ── Brain v3: Global Rules ──
  // Rules proposed by Reflection Loop (guidance, not hard gates).
  final List<GlobalRule> globalRules;

  // ── Pre-Decision Risk Warnings ──
  // Computed BEFORE LLM thinks. JARVIS sees these and decides himself.
  final List<String> riskWarnings;

  const JarvisContextPack({
    required this.symbol,
    required this.exchange,
    required this.price,
    required this.changePercent,
    required this.volume24h,
    required this.eventType,
    required this.timestamp,
    required this.flowClass,
    required this.volumeFlowScore,
    required this.flow5mUsd,
    this.knownIdentity,
    required this.assetCategory,
    required this.assetCategoryLabel,
    required this.strategyType,
    required this.rocketStage,
    required this.tokenMaturity,
    required this.strategyConfidence,
    required this.strategyReasons,
    required this.isExhaustionRisk,
    this.continuation,
    required this.softPenaltyRules,
    required this.softPenaltyTotal,
    required this.freedomModeActive,
    required this.marketPhase,
    required this.marketHeartbeat,
    required this.tokenTimesSeen,
    required this.tokenWinRate,
    required this.tokenFakeBreakoutRate,
    required this.tokenIsNoisy,
    required this.openTradeCount,
    required this.exposurePct,
    required this.maxExposurePct,
    required this.portfolioWinRate,
    required this.portfolioProfitFactor,
    required this.dailyPnl,
    required this.bankrollBalance,
    required this.consecutiveLosses,
    required this.candleCount5m,
    required this.hasTaData,
    this.suggestedTpPercent,
    this.suggestedSlPercent,
    this.lastTradeEntryPrice,
    this.lastTradeExitPrice,
    this.lastTradeNetPnl,
    this.lastTradeCloseReason,
    this.priceVsLastExit,
    this.patternSamples = 0,
    this.patternWinRate = 0,
    this.patternProfitFactor = 0,
    this.patternExpectancy = 0,
    this.symbolDisasterStops = 0,
    this.patternVerdict = 'insufficient_data',
    required this.relevantLessonSummaries,
    this.policySnapshot,
    this.externalData,
    this.marketRadar = const [],
    this.symbolMemory,
    this.journalEntries = const [],
    this.globalRules = const [],
    this.riskWarnings = const [],
  });

  // ── Serialization for LLM prompt ──────────────────────────────────────

  /// Convert to JSON map for LLM prompt construction.
  Map<String, dynamic> toJson() => {
        'market': {
          'symbol': symbol,
          'exchange': exchange,
          'price': price,
          'change_percent': changePercent,
          'volume_24h': volume24h,
          'event_type': eventType,
          'timestamp': timestamp.toIso8601String(),
        },
        'flow': {
          'class': flowClass,
          'volume_flow_score': volumeFlowScore,
          'flow_5m_usd': flow5mUsd,
        },
        'identity': {
          'known': knownIdentity != null,
          'tier': knownIdentity?.tier.name,
          'sector': knownIdentity?.sector,
          'category': assetCategoryLabel,
        },
        'strategy': {
          'type': strategyType.name,
          'rocket_stage': rocketStage.name,
          'maturity': tokenMaturity.name,
          'confidence': strategyConfidence,
          'reasons': strategyReasons,
          'exhaustion_risk': isExhaustionRisk,
        },
        'continuation': continuation != null
            ? {
                'score': continuation!.score,
                'stage': continuation!.stage,
                'eq_modifier': continuation!.eqModifier,
                'factors': continuation!.factors,
              }
            : null,
        'rules': {
          'soft_penalties': softPenaltyRules,
          'soft_penalty_total': softPenaltyTotal,
          'freedom_mode': freedomModeActive,
        },
        'perception': {
          'market_phase': marketPhase.name,
          'heartbeat': marketHeartbeat,
        },
        'token_memory': {
          'times_seen': tokenTimesSeen,
          'win_rate': tokenWinRate,
          'fake_breakout_rate': tokenFakeBreakoutRate,
          'is_noisy': tokenIsNoisy,
        },
        'portfolio': {
          'open_trades': openTradeCount,
          'exposure_pct': exposurePct,
          'max_exposure_pct': maxExposurePct,
          'win_rate': portfolioWinRate,
          'profit_factor': portfolioProfitFactor,
          'daily_pnl': dailyPnl,
          'bankroll': bankrollBalance,
          'consecutive_losses': consecutiveLosses,
        },
        'ta': {
          'candle_count_5m': candleCount5m,
          'has_data': hasTaData,
          'suggested_tp_pct': suggestedTpPercent,
          'suggested_sl_pct': suggestedSlPercent,
        },
        'pattern_memory': {
          'samples': patternSamples,
          'win_rate': patternWinRate,
          'profit_factor': patternProfitFactor,
          'expectancy_per_trade': patternExpectancy,
          'disaster_stops_on_symbol': symbolDisasterStops,
          'verdict': patternVerdict,
        },
        'lessons': relevantLessonSummaries,
        if (policySnapshot != null)
          'policy': {
            'trading_allowed': policySnapshot!.tradingAllowed,
            'remaining_daily_limit_usd':
                policySnapshot!.remainingDailyTradingLimitUsd,
            'max_daily_loss_usd': policySnapshot!.maxDailyLossUsd,
            'max_drawdown_pct': policySnapshot!.maxDrawdownPct,
            'max_open_positions': policySnapshot!.maxOpenPositions,
            'is_settlement_window': policySnapshot!.isSettlementWindow,
            'reason_if_blocked': policySnapshot!.reasonIfBlocked,
          },
        if (externalData != null) 'external': externalData,
        if (marketRadar.isNotEmpty) 'market_radar': marketRadar,
      };

  /// Compact one-line summary for logging.
  String toLogLine() {
    final identityTag =
        knownIdentity != null ? '${knownIdentity!.tier.name}/' : '';
    final contTag = continuation != null
        ? ' cont=${continuation!.stage}(${continuation!.score.toStringAsFixed(2)})'
        : '';
    return '$symbol@$exchange $identityTag${assetCategoryLabel} '
        '${eventType} \$$price chg=${changePercent.toStringAsFixed(1)}% '
        'flow=$flowClass vfs=${volumeFlowScore.toStringAsFixed(2)} '
        'phase=${marketPhase.name} hb=$marketHeartbeat '
        'stage=${rocketStage.name}$contTag '
        'exposure=${(exposurePct * 100).toStringAsFixed(0)}% '
        'lessons=${relevantLessonSummaries.length}'
        '${policySnapshot != null ? ' policy=${policySnapshot!.tradingAllowed ? "ON" : "OFF"}' : ''}'
        '${policySnapshot?.isSettlementWindow == true ? ' SETTLEMENT' : ''}';
  }

  /// Build a natural language context string for LLM prompt.
  String toLLMContext() {
    final buf = StringBuffer();

    // ── Identity ──
    buf.writeln('## Signal: $symbol on $exchange');
    if (knownIdentity != null) {
      buf.writeln(
          'Known asset: ${knownIdentity!.tier.name} | sector: ${knownIdentity!.sector}');
    }
    buf.writeln(
        'Category: $assetCategoryLabel | Maturity: ${tokenMaturity.name}');
    buf.writeln('');

    // ── Market Data ──
    buf.writeln('## Market');
    buf.writeln(
        'Price: \$$price | Change: ${changePercent >= 0 ? "+" : ""}${changePercent.toStringAsFixed(1)}%');
    buf.writeln(
        'Volume 24h: \$${volume24h.toStringAsFixed(0)} | Event: $eventType');
    buf.writeln('');

    // ── Flow Analysis ──
    buf.writeln('## Flow');
    buf.writeln(
        'Flow class: $flowClass | Volume Flow Score: ${volumeFlowScore.toStringAsFixed(2)}');
    buf.writeln('5-min flow: \$${flow5mUsd.toStringAsFixed(0)}');
    buf.writeln('');

    // ── Rocket / Continuation ──
    buf.writeln('## Momentum Assessment');
    buf.writeln(
        'Rocket stage: ${rocketStage.name} | Exhaustion risk: $isExhaustionRisk');
    if (continuation != null) {
      buf.writeln(
          'Continuation score: ${continuation!.score.toStringAsFixed(2)} (${continuation!.stage})');
      buf.writeln('Factors: ${continuation!.factors.join(", ")}');
    }
    buf.writeln('');

    // ── Market Perception ──
    buf.writeln('## Market Environment');
    buf.writeln('Phase: ${marketPhase.name} | Heartbeat: $marketHeartbeat');
    buf.writeln('');

    // ── Strategy ──
    buf.writeln('## Strategy');
    buf.writeln(
        'Selected: ${strategyType.name} | Confidence: ${strategyConfidence.toStringAsFixed(2)}');
    if (strategyReasons.isNotEmpty) {
      buf.writeln('Reasons: ${strategyReasons.join("; ")}');
    }
    buf.writeln('');

    // ── Token History ──
    buf.writeln('## Token History');
    buf.writeln(
        'Seen ${tokenTimesSeen}x | Win rate: ${(tokenWinRate * 100).toStringAsFixed(0)}%');
    buf.writeln(
        'Fake breakout rate: ${(tokenFakeBreakoutRate * 100).toStringAsFixed(0)}%');
    if (tokenIsNoisy) buf.writeln('⚠️ Token is historically noisy');
    buf.writeln('');

    // ── Last Trade on This Token ──
    if (lastTradeExitPrice != null) {
      buf.writeln('## Last Trade on This Token');
      buf.writeln(
          'Entry: \$${lastTradeEntryPrice?.toStringAsFixed(6)} → Exit: \$${lastTradeExitPrice!.toStringAsFixed(6)}');
      buf.writeln(
          'PnL: \$${lastTradeNetPnl?.toStringAsFixed(4)} | Close reason: $lastTradeCloseReason');
      if (priceVsLastExit != null) {
        final pctVsExit = (priceVsLastExit! * 100).toStringAsFixed(1);
        final direction = priceVsLastExit! >= 0 ? 'HIGHER' : 'LOWER';
        buf.writeln(
            'Current price vs last exit: ${priceVsLastExit! >= 0 ? "+" : ""}$pctVsExit% $direction');
        if (priceVsLastExit! > 0.10 && (lastTradeNetPnl ?? 0) < 0) {
          buf.writeln(
              '⚠️ RECOVERY SIGNAL: You lost on this token but price is now ${pctVsExit}% ABOVE your exit. '
              'The token proved stronger than your exit. Consider re-entry.');
        }
      }
      buf.writeln('');
    }

    // ── Portfolio State ──
    buf.writeln('## Portfolio');
    buf.writeln(
        'Exposure: ${(exposurePct * 100).toStringAsFixed(0)}% / ${(maxExposurePct * 100).toStringAsFixed(0)}% | Bankroll: \$${bankrollBalance.toStringAsFixed(2)}');
    buf.writeln(
        'Win rate: ${(portfolioWinRate * 100).toStringAsFixed(0)}% | PF: ${portfolioProfitFactor.toStringAsFixed(2)}');
    buf.writeln(
        'Daily PnL: \$${dailyPnl.toStringAsFixed(2)} | Loss streak: $consecutiveLosses');
    buf.writeln('');

    // ── TA ──
    buf.writeln('## Technical Analysis');
    if (hasTaData) {
      buf.writeln('Candles (5m): $candleCount5m');
      if (suggestedTpPercent != null) {
        buf.writeln(
            'Suggested TP: ${suggestedTpPercent!.toStringAsFixed(2)}% | SL: ${suggestedSlPercent?.toStringAsFixed(2)}%');
      }
    } else {
      buf.writeln('No TA data available');
    }
    buf.writeln('');

    // ── Rules / Risk ──
    if (softPenaltyRules.isNotEmpty) {
      buf.writeln('## Risk Signals');
      buf.writeln(
          'Active: ${softPenaltyRules.join(", ")} (total: ${softPenaltyTotal.toStringAsFixed(2)})');
      if (freedomModeActive) {
        buf.writeln('Freedom Mode: ACTIVE (penalties weakened for learning)');
      }
      buf.writeln('');
    }

    // ── Market Radar ──
    if (marketRadar.isNotEmpty) {
      buf.writeln('== MARKET RADAR (what\'s happening RIGHT NOW) ==');
      for (var i = 0; i < marketRadar.length && i < 5; i++) {
        final r = marketRadar[i];
        final fromHigh = (r['fromHighPct'] as double?)?.toStringAsFixed(0) ?? '?';
        final stage = r['stage'] as String? ?? 'unknown';
        buf.writeln('${i + 1}. ${r["symbol"]} +${(r["change"] as double).toStringAsFixed(0)}% '
            '[$stage] fromHigh=${fromHigh}% '
            'flow=${r["flow"]} vol=\$${((r["volume24h"] as double) / 1000).toStringAsFixed(0)}K '
            'events=${r["density"]}');
      }
      buf.writeln('STAGE KEY: climbing=at peak+money in, at_peak=near high, '
          'pulling_back=3-10% off, dumping=10-25% off, crashed=>25% off');
      buf.writeln('');
    }

    // ── Brain v2: Your Memory of This Symbol ──
    if (symbolMemory != null || journalEntries.isNotEmpty) {
      buf.writeln('## YOUR MEMORY (your own past analysis)');
      if (symbolMemory != null) {
        buf.writeln(symbolMemory!.toLLMContext());
      }
      if (journalEntries.isNotEmpty) {
        buf.writeln('Your recent conclusions about $symbol:');
        for (final entry in journalEntries) {
          buf.writeln('- ${entry.toContextLine()}');
        }
      }
      if (symbolMemory?.status == 'dangerous') {
        buf.writeln('⚠️ WARNING: Your own analysis classifies this symbol as DANGEROUS.');
        buf.writeln('You have been burned here before. Think twice before entering.');
      }
      buf.writeln('');
    }

    // ── Brain v3: Your Global Rules ──
    if (globalRules.isNotEmpty) {
      buf.writeln('## YOUR GLOBAL RULES (self-proposed, not hard gates)');
      buf.writeln('These are rules you proposed from reflecting on your journal.');
      buf.writeln('Use them as guidance — they are NOT enforced automatically.');
      for (final rule in globalRules) {
        buf.writeln('- ${rule.toLLMContext()}');
      }
      buf.writeln('');
    }

    // ── Lessons ──
    if (relevantLessonSummaries.isNotEmpty) {
      buf.writeln('## Relevant Past Lessons');
      for (final lesson in relevantLessonSummaries) {
        buf.writeln('- $lesson');
      }
      buf.writeln('');
    }

    // ── Trading Policy ──
    if (policySnapshot != null) {
      final p = policySnapshot!;
      buf.writeln('## Trading Policy');
      buf.writeln(
          'Trading allowed: ${p.tradingAllowed}${p.reasonIfBlocked != null ? " (blocked: ${p.reasonIfBlocked})" : ""}');
      buf.writeln(
          'Daily limit: \$${p.maxDailyTradingLimitUsd.toStringAsFixed(2)} | Remaining: \$${p.remainingDailyTradingLimitUsd.toStringAsFixed(2)}');
      buf.writeln(
          'Max daily loss: \$${p.maxDailyLossUsd.toStringAsFixed(2)} | Max drawdown: ${p.maxDrawdownPct.toStringAsFixed(1)}%');
      buf.writeln(
          'Max open positions: ${p.maxOpenPositions} | Stop after losses: ${p.stopAfterLosses}');
      buf.writeln(
          'Window: ${p.tradingWindowStartLocal}–${p.tradingWindowEndLocal} | Settlement: ${p.isSettlementWindow}');
      buf.writeln('');
    }

    // Legacy external data (trending, per-token data).
    if (externalData != null && externalData!.isNotEmpty) {
      if (externalData!['trending'] != null) {
        buf.writeln(
            'Trending: ${(externalData!["trending"] as List).join(", ")}');
      }
      buf.writeln('');
    }

    // ── Pre-Decision Risk Warnings ──
    if (riskWarnings.isNotEmpty) {
      buf.writeln('## ⚠️ RISK WARNINGS FOR THIS SIGNAL');
      for (final w in riskWarnings) {
        buf.writeln('$w');
      }
      buf.writeln('');
    }

    return buf.toString();
  }
}
