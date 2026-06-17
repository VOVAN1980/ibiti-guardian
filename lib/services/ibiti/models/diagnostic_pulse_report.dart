// ─── Diagnostic Pulse Report ────────────────────────────────────────────────
//
// Phase 10F: Every 30 minutes, JARVIS writes an operational report.
//
// Not an alarm. An analyst report with evidence:
//   - What happened
//   - What worked / failed
//   - Which strategies performed
//   - What needs changing
//   - How to verify changes
// ─────────────────────────────────────────────────────────────────────────────

import '../models/developer_request.dart';
import '../models/strategy_knowledge.dart';
import '../models/counterfactual_result.dart';

/// Per-strategy stats for the pulse window.
class StrategyPulseStats {
  final String strategyType;
  int trades = 0;
  int wins = 0;
  int losses = 0;
  double pnl = 0;
  double totalWinPnl = 0;
  double totalLossPnl = 0;
  int stopLossCount = 0;
  int takeProfitCount = 0;
  int flowDiedCount = 0;

  StrategyPulseStats(this.strategyType);

  double get winRate => trades > 0 ? wins / trades : 0;
  double get avgWin => wins > 0 ? totalWinPnl / wins : 0;
  double get avgLoss => losses > 0 ? totalLossPnl / losses : 0;
  double get expectancy => trades > 0 ? pnl / trades : 0;

  String toLine() => '$strategyType: '
      '${trades}t ${wins}w ${losses}l '
      'WR=${(winRate * 100).toStringAsFixed(0)}% '
      'PnL=\$${pnl.toStringAsFixed(4)} '
      'exp=${expectancy.toStringAsFixed(4)} '
      'SL=$stopLossCount TP=$takeProfitCount';
}

/// Full 30-minute diagnostic pulse report.
class DiagnosticPulseReport {
  final DateTime windowStart;
  final DateTime windowEnd;
  final int windowMinutes;

  final int totalTrades;
  final int wins;
  final int losses;
  final double winRate;
  final double netPnl;
  final double profitFactor;

  final Map<String, StrategyPulseStats> strategies;
  final Map<String, int> closeReasons;
  final Map<String, int> diagnosticsByReason;

  final List<DeveloperRequest> developerRequests;
  final List<StrategyKnowledge> changedStrategies;
  final List<CounterfactualResult> topCounterfactuals;

  final List<String> whatWorked;
  final List<String> whatFailed;
  final List<String> whatINeed;
  final List<String> nextChecks;

  final DateTime createdAt;

  DiagnosticPulseReport({
    required this.windowStart,
    required this.windowEnd,
    this.windowMinutes = 30,
    this.totalTrades = 0,
    this.wins = 0,
    this.losses = 0,
    this.winRate = 0,
    this.netPnl = 0,
    this.profitFactor = 0,
    this.strategies = const {},
    this.closeReasons = const {},
    this.diagnosticsByReason = const {},
    this.developerRequests = const [],
    this.changedStrategies = const [],
    this.topCounterfactuals = const [],
    this.whatWorked = const [],
    this.whatFailed = const [],
    this.whatINeed = const [],
    this.nextChecks = const [],
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Human-readable report for logs.
  String toHumanReport() {
    final buf = StringBuffer();
    buf.writeln('══════════════════════════════════════════');
    buf.writeln('[JARVIS_PULSE] ${windowMinutes}m report');
    buf.writeln('Window: ${windowStart.toIso8601String()} → '
        '${windowEnd.toIso8601String()}');
    buf.writeln('');

    // Results
    buf.writeln('Result:');
    buf.writeln('  Trades: $totalTrades | WR: '
        '${(winRate * 100).toStringAsFixed(0)}% | '
        'Net PnL: \$${netPnl.toStringAsFixed(4)} | '
        'PF: ${profitFactor.toStringAsFixed(2)}');
    buf.writeln('');

    // Close reasons
    if (closeReasons.isNotEmpty) {
      buf.writeln('Close reasons:');
      for (final e in closeReasons.entries) {
        buf.writeln('  ${e.key}: ${e.value}');
      }
      buf.writeln('');
    }

    // Strategies
    if (strategies.isNotEmpty) {
      buf.writeln('Strategies:');
      for (final s in strategies.values) {
        buf.writeln('  ${s.toLine()}');
      }
      buf.writeln('');
    }

    // What worked
    if (whatWorked.isNotEmpty) {
      buf.writeln('What worked:');
      for (var i = 0; i < whatWorked.length; i++) {
        buf.writeln('  ${i + 1}. ${whatWorked[i]}');
      }
      buf.writeln('');
    }

    // What failed
    if (whatFailed.isNotEmpty) {
      buf.writeln('What failed:');
      for (var i = 0; i < whatFailed.length; i++) {
        buf.writeln('  ${i + 1}. ${whatFailed[i]}');
      }
      buf.writeln('');
    }

    // Counterfactuals
    if (topCounterfactuals.isNotEmpty) {
      buf.writeln('Counterfactuals:');
      for (final cf in topCounterfactuals.take(5)) {
        final sign = cf.deltaPnl >= 0 ? '+' : '';
        if (cf.deltaPnl >= 0) {
          buf.writeln(
              '  - missed profit by ${cf.scenario.name}: $sign\$${cf.deltaPnl.toStringAsFixed(4)}');
        } else {
          buf.writeln(
              '  - saved money by rule (${cf.scenario.name}): $sign\$${cf.deltaPnl.toStringAsFixed(4)}');
        }
      }
      buf.writeln('');
    }

    // What I need
    if (whatINeed.isNotEmpty) {
      buf.writeln('I need:');
      for (var i = 0; i < whatINeed.length; i++) {
        buf.writeln('  ${i + 1}. ${whatINeed[i]}');
      }
      buf.writeln('');
    }

    // Developer requests
    if (developerRequests.isNotEmpty) {
      buf.writeln('Active requests: ${developerRequests.length}');
      for (final r in developerRequests.take(5)) {
        buf.writeln('  [${r.priority.name}] ${r.id}: ${r.problem}');
      }
      buf.writeln('');
    }

    // Next checks
    if (nextChecks.isNotEmpty) {
      buf.writeln('Verification next 30m:');
      for (final c in nextChecks) {
        buf.writeln('  - $c');
      }
    }

    buf.writeln('══════════════════════════════════════════');
    return buf.toString();
  }

  /// Compact log line.
  String toLogLine() => '[JARVIS_PULSE] ${windowMinutes}m '
      'trades=$totalTrades WR=${(winRate * 100).toStringAsFixed(0)}% '
      'PnL=\$${netPnl.toStringAsFixed(4)} PF=${profitFactor.toStringAsFixed(2)} '
      'strats=${strategies.length} requests=${developerRequests.length}';

  Map<String, dynamic> toJson() => {
        'windowStart': windowStart.toIso8601String(),
        'windowEnd': windowEnd.toIso8601String(),
        'windowMinutes': windowMinutes,
        'totalTrades': totalTrades,
        'wins': wins,
        'losses': losses,
        'winRate': winRate,
        'netPnl': netPnl,
        'profitFactor': profitFactor,
        'strategies': strategies.map((k, v) => MapEntry(k, v.toLine())),
        'closeReasons': closeReasons,
        'diagnosticsByReason': diagnosticsByReason,
        'whatWorked': whatWorked,
        'whatFailed': whatFailed,
        'topCounterfactuals': topCounterfactuals.length,
        'whatINeed': whatINeed,
        'nextChecks': nextChecks,
        'developerRequests': developerRequests.length,
        'createdAt': createdAt.toIso8601String(),
      };
}
