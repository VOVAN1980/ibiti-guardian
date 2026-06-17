// ─── IBITI Loop ─────────────────────────────────────────────────────────────────
//
// The heartbeat. Every 30 seconds:
//   1. Perception: scan all tickers → events
//   2. For each event: record to memory
//   3. Market cardiogram / phase detection
//   4. Candle updates
//   5. Memory save
//
// Auto-trading pipeline (Brain, Debate, Constitution, PaperTrader,
// Operator, etc.) has been archived. This loop now focuses on
// market monitoring and data collection.
// ─────────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:convert';
import 'package:ibiti_guardian/services/ibiti/models/market_event.dart';
import 'package:ibiti_guardian/services/ibiti/market_cardiogram_service.dart';
import 'package:ibiti_guardian/services/ibiti/models/market_phase.dart';
import 'package:ibiti_guardian/services/ibiti/models/execution_mode.dart';
import 'package:ibiti_guardian/services/ibiti/ibiti_perception.dart';
import 'package:ibiti_guardian/services/ibiti/ibiti_memory.dart';
import 'package:ibiti_guardian/services/ibiti/ibiti_database.dart';
import 'package:ibiti_guardian/services/ibiti/candle_history_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/market/market_live_engine.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/services/ibiti/stablecoin_registry_service.dart';
import 'package:ibiti_guardian/services/ibiti/jarvis_ai_core.dart';
import 'package:ibiti_guardian/services/ibiti/external_data_connectors.dart';
import 'package:ibiti_guardian/services/ibiti/macro_sensor_service.dart';

const _log = GuardianLogger('IbitiLoop');

/// Event types that are strong buy-candidates — worth prefetching TA for.
const _prefetchableEventTypes = {
  MarketEventType.volumeSpike,
  MarketEventType.priceBreakout,
  MarketEventType.newListingMove,
};

class IbitiLoop {
  IbitiLoop._();
  static final IbitiLoop instance = IbitiLoop._();

  // ── Components ──────────────────────────────────────────────────────────────
  final perception = IbitiPerception.instance;
  IbitiMemory get memory => IbitiMemory.instance;

  // ── State ───────────────────────────────────────────────────────────────────
  Timer? _timer;
  bool _running = false;
  bool _ticking = false; // Prevent overlapping ticks.
  int _tickCount = 0;
  int _totalEvents = 0;
  DateTime? _startedAt;
  DateTime _lastCleanup = DateTime.now();

  /// Per-cycle suppression tracker: symbols already blocked by ANTI_NOISE
  /// in the current tick cycle. Key = exchange:symbol, value = count.
  /// Prevents log spam from 100+ identical blocks.
  final Map<String, int> _cycleSuppressed = {};

  /// Per-cycle TA source counters (reset every tick).
  int _cycleTaReady = 0;
  int _cycleTaEmpty = 0;

  /// Phase 17F: Per-cycle cross-exchange log compression.
  int _cycleCrossTotal = 0;
  int _cycleCrossWatch = 0;
  int _cycleCrossWouldBuy = 0;
  MarketHeartbeat? _lastHeartbeat;
  final List<String> _cycleCrossTopSymbols = [];

  /// Phase 6: true when market is too dirty to trade
  /// (BTC/ETH average dump > 8% AND market breadth < 20%).
  bool _isDirtyMarket = false;

  /// Warm list: symbols that received WATCH/WOULD_BUY in the previous tick.
  /// Prefetched with highest priority so their TA is ready if they fire again.
  final List<({String symbol, String exchange})> _warmList = [];

  /// Current execution mode (kept for API compatibility).
  ExecutionMode executionMode = ExecutionMode.observeOnly;

  bool get isRunning => _running;
  int get tickCount => _tickCount;
  int get totalEvents => _totalEvents;
  Duration get uptime => _startedAt != null
      ? DateTime.now().difference(_startedAt!)
      : Duration.zero;

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  /// Start the IBITI loop. Initializes DB, loads memory, then ticks every 30s.
  Future<void> start() async {
    if (_running) return;

    // Initialize SQLite database + migrate from SharedPreferences if needed.
    final db = IbitiDatabase.instance;
    await db.initialize();
    await db.migrateFromSharedPreferences();

    // Load memory from SQLite.
    await memory.load();

    // Phase 15A.2: Initialize stablecoin registry (local + CoinGecko).
    StablecoinRegistryService.instance.initialize();
    StablecoinRegistryService.instance.startPeriodicRefresh();

    // Phase 18E: AI Core — load LLM provider keys.
    unawaited(JarvisAICore.instance.initialize().catchError(
          (e) => _log.w('AI Core init skipped: $e'),
        ));

    // Phase 18F: External data — first global refresh (non-blocking).
    unawaited(ExternalDataAggregator.instance.refreshGlobalContext().catchError(
          (e) => _log.w('External data init skipped: $e'),
        ));

    // Macro Eyes v1: load Fear & Greed + CoinGecko global at startup.
    unawaited(MacroSensorService.instance.forceRefresh().catchError(
          (e) => _log.w('Macro sensor init skipped: $e'),
        ));

    // ── Morning report: print once at startup, non-blocking. ──
    unawaited(printOvernightReport(hours: 12).catchError(
      (e) => _log.e('Morning report failed', e),
    ));

    _running = true;
    _startedAt = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _tick());

    _log.i('IBITI started | mode=${executionMode.name} | '
        'memory: ${memory.tokenProfiles.length} tokens, '
        '${memory.lessons.length} lessons');
    _log.i('[DETECTOR_ON] volumeSpike priceBreakout exhaustionCandle '
        'newListingMove fakeBreakout crossExchangeMove '
        'liquidityDrain consolidation marketMoodShift trendContinuation');
  }

  /// Stop the IBITI loop. Flushes memory and closes DB.
  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;

    await memory.save();
    await IbitiDatabase.instance.close();

    _log.i('IBITI stopped | ticks=$_tickCount events=$_totalEvents '
        'uptime=${uptime.inMinutes}m');
  }

  /// Kill switch — immediately stop, set to observe mode.
  Future<void> killSwitch() async {
    executionMode = ExecutionMode.observeOnly;
    await stop();
    _log.i('🛑 IBITI KILL SWITCH ACTIVATED');
  }

  // ── Market Radar ──────────────────────────────────────────────────────────
  //
  // Before processing individual events, build a snapshot of what's
  // happening RIGHT NOW across all exchanges.

  /// Last radar snapshot.
  List<Map<String, dynamic>> _radarSnapshot = const [];

  /// Event density tracker: count events per symbol across recent ticks.
  final Map<String, int> _eventDensity = {};
  static const _eventDensityDecayTicks = 30; // ~15 minutes
  int _densityDecayCounter = 0;

  List<Map<String, dynamic>> _buildMarketRadar(List<MarketEvent> events) {
    // Update event density per symbol
    _densityDecayCounter++;
    if (_densityDecayCounter >= _eventDensityDecayTicks) {
      _eventDensity.clear();
      _densityDecayCounter = 0;
    }
    for (final e in events) {
      _eventDensity[e.symbol] = (_eventDensity[e.symbol] ?? 0) + 1;
    }

    // Aggregate: one entry per symbol across all events this tick
    final symbolMap = <String, Map<String, dynamic>>{};
    final allTickers = MarketLiveEngine.instance.snapshotAll();
    for (final e in events) {
      final existing = symbolMap[e.symbol];
      if (existing == null ||
          e.changePercent > (existing['change'] as double)) {
        // Look up ticker for high/low data
        final tickerKey = MarketLiveEngine.key(e.exchange, e.symbol);
        final ticker = allTickers[tickerKey];
        final highPrice = ticker?.highPrice24h ?? e.price;
        final fromHighPct =
            highPrice > 0 ? ((e.price / highPrice) - 1.0) * 100 : 0.0;

        symbolMap[e.symbol] = {
          'symbol': e.symbol,
          'exchange': e.exchange,
          'price': e.price,
          'change': e.changePercent,
          'volume24h': e.volume24h,
          'flow': e.flowClass,
          'flow5m': e.flow5mUsd,
          'eventType': e.type.name,
          'density': _eventDensity[e.symbol] ?? 1,
          'highPrice24h': highPrice,
          'fromHighPct': fromHighPct,
          'buyPressure': ticker?.buyPressure ?? 0.0,
          'stage': _classifyStage(fromHighPct, e.flowClass),
        };
      }
    }

    // Also scan ALL live tickers for top movers the events might have missed
    for (final entry in allTickers.entries) {
      final key = entry.key; // "exchange:SYMBOL"
      final t = entry.value;
      if (t.priceChangePercent24h >= 100 && !symbolMap.containsKey(t.symbol)) {
        final parts = key.split(':');
        final fromHighPct = t.highPrice24h > 0
            ? ((t.lastPrice / t.highPrice24h) - 1.0) * 100
            : 0.0;
        final exchange = parts.isNotEmpty ? parts[0] : 'unknown';
        final flowClass = perception.flowClassForPair(exchange, t.symbol);
        symbolMap[t.symbol] = {
          'symbol': t.symbol,
          'exchange': exchange,
          'price': t.lastPrice,
          'change': t.priceChangePercent24h,
          'volume24h': t.quoteVolume24h,
          'flow': flowClass,
          'flow5m': 0.0,
          'eventType': 'ticker_scan',
          'density': 0,
          'buyPressure': t.buyPressure ?? 0.0,
          'daysListed': t.daysListed,
          'highPrice24h': t.highPrice24h,
          'fromHighPct': fromHighPct,
          'stage': _classifyStage(fromHighPct, flowClass),
        };
      }
    }

    // Filter out:
    // 1. Dead/crashed pumps: dumping/crashed (fromHighPct < -10) with retailNoise or unknown flow
    // 2. Retail noise with no significant price change (change < 15.0)
    final entries = symbolMap.values.where((entry) {
      final flow = entry['flow'] as String? ?? 'unknown';
      final change = (entry['change'] as double?) ?? 0.0;
      final fromHigh = (entry['fromHighPct'] as double?) ?? 0.0;

      // Rule 1: crashed/dumping (fromHigh < -10) and has no serious flow
      final isDeadPump = fromHigh < -10 && (flow == 'retailNoise' || flow == 'unknown');
      if (isDeadPump) return false;

      // Rule 2: retail noise with no significant price change (change < 15.0)
      final isNoisyMinor = (flow == 'retailNoise' || flow == 'unknown') && change < 15.0;
      if (isNoisyMinor) return false;

      return true;
    }).toList();

    // Sort by priority: change% * flow weight * density
    entries.sort((a, b) {
      final scoreA = _radarPriority(a);
      final scoreB = _radarPriority(b);
      return scoreB.compareTo(scoreA);
    });

    // Take top 10
    final top = entries.take(10).toList();

    // Log the radar
    if (top.isNotEmpty) {
      final buf = StringBuffer('[MARKET_RADAR] ');
      for (var i = 0; i < top.length && i < 5; i++) {
        final e = top[i];
        final fh = (e['fromHighPct'] as double?)?.toStringAsFixed(0) ?? '?';
        buf.write(
            '${e["symbol"]} +${(e["change"] as double).toStringAsFixed(0)}% ');
        buf.write('hi=$fh% ${e["stage"]} f=${e["flow"]} | ');
      }
      _log.i(buf.toString());
    }

    return top;
  }

  double _radarPriority(Map<String, dynamic> entry) {
    final change = (entry['change'] as double).clamp(0, 10000);
    final density = (entry['density'] as int).clamp(0, 100);
    final flow = entry['flow'] as String;
    final flowWeight = switch (flow) {
      'whaleInflow' => 4.0,
      'seriousInflow' => 3.0,
      'retailInterest' => 1.5,
      'retailNoise' => 0.5,
      _ => 1.0,
    };
    final fromHigh = (entry['fromHighPct'] as double?) ?? 0.0;
    final peakPenalty = fromHigh < -10 ? 0.3 : (fromHigh < -5 ? 0.6 : 1.0);
    return change * flowWeight * (1 + density * 0.1) * peakPenalty;
  }

  /// Classify where the asset is relative to its peak.
  String _classifyStage(double fromHighPct, String flowClass) {
    if (fromHighPct >= -3) {
      if (flowClass == 'whaleInflow' || flowClass == 'seriousInflow') {
        return 'climbing';
      }
      return 'at_peak';
    } else if (fromHighPct >= -10) {
      return 'pulling_back';
    } else if (fromHighPct >= -25) {
      return 'dumping';
    } else {
      return 'crashed';
    }
  }

  // ── Main tick ───────────────────────────────────────────────────────────────

  Future<void> _tick() async {
    if (!_running || _ticking) return;

    // Kill switch: if AiControlService is in manual mode, don't act.
    if (AiControlService.instance.settings.mode == AiMode.manual) {
      return;
    }

    _ticking = true;
    _tickCount++;

    try {
      // 0. Phase detection: read BTC/ETH, update market context.
      _detectMarketPhase();

      // 0a. Refresh external data (self-throttled to 15-min intervals).
      unawaited(ExternalDataAggregator.instance.refreshGlobalContext());

      // 0b. Reset per-tick candle fetch budget.
      CandleHistoryService.instance.startTickBudget();

      // 1. Perception: scan for events.
      final events = perception.scan();

      // 2c-pre4. Check pending observations (researchOnly price tracking).
      await _checkPendingObservations();

      // 2c. Hourly memory hygiene.
      await _maybeHourlyCleanup();

      if (events.isEmpty) {
        _ticking = false;
        return;
      }

      _totalEvents += events.length;

      // ── MARKET RADAR ──
      _radarSnapshot = _buildMarketRadar(events);

      // Prefetch TA for interesting events.
      _prefetchTaCandidates(events);

      // Reset per-cycle trackers.
      _cycleSuppressed.clear();
      _cycleTaReady = 0;
      _cycleTaEmpty = 0;
      _cycleCrossTotal = 0;
      _cycleCrossWatch = 0;
      _cycleCrossWouldBuy = 0;
      _cycleCrossTopSymbols.clear();

      // 3. Record each event to memory.
      for (final event in events) {
        memory.recordEvent(event);
      }

      // 4. Summary log — one human-readable line per cycle.
      final mins = _tickCount * 30 ~/ 60;

      _log.i('IBITI: ${mins}мин. '
          'События: ${events.length}. '
          '${_isDirtyMarket ? ' ⚠️DIRTY' : ''}');

      // 5. Periodic memory save (every 10 ticks = ~5 min).
      if (_tickCount % 10 == 0) {
        await memory.save();
        _log.d(CandleHistoryService.instance.summary);
      }

      // 7. Memory compactor — once per day (2880 ticks × 30s = 24h).
      if (_tickCount % 2880 == 0) {
        await IbitiDatabase.instance.compactMemory();
      }
    } catch (e) {
      _log.e('Tick error', e);
    } finally {
      _ticking = false;
    }
  }

  // ── Phase Detection ─────────────────────────────────────────────────────────

  /// Detect current market phase using MarketCardiogramService.
  /// Called every tick (30s). Updates memory + perception.
  void _detectMarketPhase() {
    final cardio = MarketCardiogramService.instance.update();
    final phase = cardio.mappedPhase;
    final heartbeat = cardio.heartbeat;

    if (_lastHeartbeat != null && _lastHeartbeat != heartbeat) {
      _log.i(
          '[HEARTBEAT_CHANGE] old=${_lastHeartbeat!.name} new=${heartbeat.name}');
    }
    _lastHeartbeat = heartbeat;

    // ── Phase 6: Dirty market detection ──
    final wasDirty = _isDirtyMarket;
    _isDirtyMarket = heartbeat == MarketHeartbeat.panicDump;
    if (_isDirtyMarket && !wasDirty) {
      _log.i('[JARVIS] 🚨 Грязный рынок: Panic Dump');
    } else if (!_isDirtyMarket && wasDirty) {
      _log.i('[JARVIS] ✅ Рынок очистился');
    }

    // ── Update memory & perception ──
    final snapshot = MarketPhaseSnapshot(
      phase: phase,
      btcChange24h: cardio.btcChange24h,
      ethChange24h: cardio.ethChange24h,
      marketBreadth: cardio.marketBreadth,
      timestamp: cardio.timestamp,
    );
    memory.updatePhase(snapshot);
    perception.currentPhase = phase;
    perception.currentHeartbeat = heartbeat;

    // ── Log every 10 ticks (~5 minutes) ──
    if (_tickCount % 10 == 1) {
      _log.i('[JARVIS_CARDIO] ' + cardio.toLogLine());

      if (heartbeat == MarketHeartbeat.panicDump ||
          heartbeat == MarketHeartbeat.distribution) {
        _log.w('[JARVIS_CARDIO_RISK] $heartbeat detected. Caution advised.');
      } else if (heartbeat == MarketHeartbeat.acceleration ||
          heartbeat == MarketHeartbeat.earlyInflow ||
          heartbeat == MarketHeartbeat.listingMania) {
        _log.i(
            '[JARVIS_CARDIO_EDGE] $heartbeat detected. Favorable conditions.');
      }
    }
  }

  // ── TA Prefetch (fire-and-forget) ───────────────────────────────────────────

  /// Pick the best candidates from current tick's perception events and
  /// pre-warm their candle caches. Fire-and-forget — does NOT block.
  void _prefetchTaCandidates(List<MarketEvent> events) {
    final candleService = CandleHistoryService.instance;

    final bestScores = <String, double>{};
    final bestEvents = <String, MarketEvent>{};

    for (final e in events) {
      if (!_prefetchableEventTypes.contains(e.type)) continue;

      final key = '${e.exchange}:${e.symbol}';

      if (candleService.hasFreshCache(symbol: e.symbol, exchange: e.exchange)) {
        continue;
      }

      double score = e.volume24h;

      if (e.type == MarketEventType.newListingMove) {
        score += 1000000000;
      } else {
        if (e.flowClass == 'seriousInflow' || e.flowClass == 'whaleInflow') {
          score += 500000000;
        } else if (e.flowClass == 'retailNoise') {
          score *= 0.1;
        }
        if (e.volume24h < 50000) {
          score *= 0.1;
        }
      }

      final times = memory.recentEventTimes[key];
      if (times != null) {
        final oneHourAgo = DateTime.now().subtract(const Duration(hours: 1));
        final recentCount = times.where((t) => t.isAfter(oneHourAgo)).length;

        if (e.type == MarketEventType.newListingMove) {
          score += recentCount * 100000000;
        } else if (recentCount >= 3) {
          score *= 0.2;
        }
      }

      final currentBest = bestScores[key] ?? -1.0;
      if (score > currentBest) {
        bestScores[key] = score;
        bestEvents[key] = e;
      }
    }

    if (bestEvents.isEmpty) return;

    final scoredCandidates = bestEvents.entries.toList();
    scoredCandidates
        .sort((a, b) => bestScores[b.key]!.compareTo(bestScores[a.key]!));

    final top = scoredCandidates.take(10).map((entry) => entry.value).toList();

    candleService.prefetchCandidates(
      top.map((e) => (symbol: e.symbol, exchange: e.exchange)).toList(),
    );
  }

  // ── Memory Hygiene (Phase 1) ───────────────────────────────────────────────

  /// Run hourly cleanup: dead lessons, stale postmortems, old events.
  Future<void> _maybeHourlyCleanup() async {
    final now = DateTime.now();
    if (now.difference(_lastCleanup).inMinutes < 60) return;
    _lastCleanup = now;

    final db = IbitiDatabase.instance;
    if (!db.isOpen) return;

    try {
      int lessonsRemoved = 0;

      // 1. Remove dead lessons from SQLite.
      final cutoff7d = now.subtract(const Duration(days: 7)).toIso8601String();
      lessonsRemoved += await db.db.delete(
        'lessons',
        where: 'confirmations <= 1 AND learned_at < ?',
        whereArgs: [cutoff7d],
      );

      lessonsRemoved += await db.db.delete(
        'lessons',
        where: 'ABS(rule_weight) < 0.01',
      );

      // 2. Remove stale pending postmortems (> 3h old).
      final cutoff3h = now.subtract(const Duration(hours: 3)).toIso8601String();
      final stalePm = await db.db.delete(
        'postmortems',
        where: 'price_60m IS NULL AND decided_at < ?',
        whereArgs: [cutoff3h],
      );

      // 3. Old completed postmortems (> 14 days).
      final cutoff14d =
          now.subtract(const Duration(days: 14)).toIso8601String();
      final oldPm = await db.db.delete(
        'postmortems',
        where: 'evaluated_at IS NOT NULL AND evaluated_at < ?',
        whereArgs: [cutoff14d],
      );

      // 4. Old raw events (> 7 days).
      final oldEvents = await db.db.delete(
        'market_events',
        where: 'timestamp < ?',
        whereArgs: [cutoff7d],
      );

      // 5. Sync RAM lessons.
      if (lessonsRemoved > 0) {
        memory.lessons.removeWhere((l) {
          final age = now.difference(l.learnedAt).inDays;
          if (l.confirmations <= 1 && age > 7) return true;
          if (l.effectiveWeight.abs() < 0.01) return true;
          return false;
        });
      }

      // 6. Lesson confidence decay.
      int deadRemoved = 0;
      for (final lesson in memory.lessons) {
        lesson.applyTimeDecay();
      }
      final beforeCount = memory.lessons.length;
      memory.lessons.removeWhere((l) => l.isDead);
      deadRemoved = beforeCount - memory.lessons.length;
      if (deadRemoved > 0) {
        await db.db.delete(
          'lessons',
          where: 'confidence < 0.1',
        );
      }

      // 7. Reset token noise counters + log noisy tokens.
      final noisyTokens = <String>[];
      for (final profile in memory.tokenProfiles.values) {
        if (profile.hourlyEventCount > 50) {
          noisyTokens.add('${profile.symbol}×${profile.hourlyEventCount}');
        }
        profile.resetHourlyNoise();
      }

      // 8. Log suppressed symbols summary.
      final suppressedSummary = <String>[];
      _cycleSuppressed.forEach((key, count) {
        if (count > 1) suppressedSummary.add('$key×$count');
      });

      final totalCleaned =
          lessonsRemoved + stalePm + oldPm + oldEvents + deadRemoved;
      if (totalCleaned > 0 ||
          noisyTokens.isNotEmpty ||
          suppressedSummary.isNotEmpty) {
        _log.i('[Hygiene] Cleaned: lessons=$lessonsRemoved '
            'dead=$deadRemoved '
            'stalePM=$stalePm oldPM=$oldPm events=$oldEvents');
        if (noisyTokens.isNotEmpty) {
          _log.i('[Hygiene] Noisy tokens: ${noisyTokens.take(10).join(', ')}');
        }
        if (suppressedSummary.isNotEmpty) {
          _log.i(
              '[Hygiene] Suppressed: ${suppressedSummary.take(15).join(', ')}');
        }
        await db.db.execute('VACUUM');
      }

      // 9. Evict stale candle caches.
      CandleHistoryService.instance.evictStale();
    } catch (e) {
      _log.e('[Hygiene] Hourly cleanup failed', e);
    }
  }

  // ── Reporting ───────────────────────────────────────────────────────────────

  /// Print full overnight diagnostic report to logs.
  Future<void> printOvernightReport({int hours = 12}) async {
    final since = DateTime.now().subtract(Duration(hours: hours));
    final r = await IbitiDatabase.instance.overnightReport(since: since);
    if (r.isEmpty || (r['trades'] as int) == 0) {
      _log.i('[JARVIS] Нет закрытых сделок за последние ${hours}ч.');
      return;
    }

    final trades = r['trades'] as int;
    final wins = r['wins'] as int;
    final losses = r['losses'] as int;
    final open = r['openCount'] as int;
    final wr = ((r['winRate'] as double) * 100).toStringAsFixed(0);
    final netPnl = (r['netPnl'] as double).toStringAsFixed(2);
    final grossPF = (r['grossPF'] as double).toStringAsFixed(2);
    final netPF = (r['netPF'] as double).toStringAsFixed(2);
    final fees = (r['totalFees'] as double).toStringAsFixed(2);
    final slip = (r['totalSlippage'] as double).toStringAsFixed(2);
    final best = (r['bestTrade'] as double).toStringAsFixed(2);
    final worst = (r['worstTrade'] as double).toStringAsFixed(2);
    final avgWin = (r['avgWinHoldMin'] as double).toStringAsFixed(0);
    final avgLoss = (r['avgLossHoldMin'] as double).toStringAsFixed(0);
    final lessons = r['newLessons'] as int;

    // ── Format winners ──
    final topWinners = r['topWinners'] as List;
    final winnerLines = <String>[];
    for (var i = 0; i < topWinners.length; i++) {
      final w = topWinners[i] as Map<String, dynamic>;
      final sym = _cleanSymbol(w['symbol'] as String);
      final pnl = (w['pnl'] as num).toStringAsFixed(2);
      final cnt = w['count'] as int;
      winnerLines.add(
          '  ${i + 1}. $sym   +\$$pnl ($cnt ${cnt == 1 ? "trade" : "trades"})');
    }

    // ── Format losers ──
    final topLosers = r['topLosers'] as List;
    final loserLines = <String>[];
    for (var i = 0; i < topLosers.length; i++) {
      final l = topLosers[i] as Map<String, dynamic>;
      final sym = _cleanSymbol(l['symbol'] as String);
      final pnl = (l['pnl'] as num).abs().toStringAsFixed(2);
      final cnt = l['count'] as int;
      loserLines.add(
          '  ${i + 1}. $sym   -\$$pnl ($cnt ${cnt == 1 ? "trade" : "trades"})');
    }

    // ── Format exchanges ──
    final exchanges = r['exchanges'] as Map<String, Map<String, dynamic>>;
    final exLines = <String>[];
    for (final entry in exchanges.entries) {
      final name = _cleanExchange(entry.key);
      final total = entry.value['total'] as int;
      final exWr = ((entry.value['wr'] as double) * 100).toStringAsFixed(0);
      exLines.add('  $name: $total trades | WR $exWr%');
    }

    // ── Format close reasons ──
    final reasons = r['closeReasons'] as Map<String, int>;
    final reasonParts = <String>[];
    for (final entry in reasons.entries) {
      reasonParts.add('${entry.key}: ${entry.value}');
    }

    // ── Print ──
    const sep = '───────────────────────────────────────';
    const dbl = '═══════════════════════════════════════';

    _log.i('[JARVIS] $dbl');
    _log.i('[JARVIS]  НОЧНОЙ ОТЧЁТ (${hours}ч)');
    _log.i('[JARVIS] $dbl');
    _log.i('[JARVIS]  Сделок: $trades closed | $open open');
    _log.i('[JARVIS]  Wins: $wins | Losses: $losses | WR: $wr%');
    _log.i('[JARVIS]  PnL (net): \$$netPnl');
    _log.i('[JARVIS] $sep');
    _log.i('[JARVIS]  Gross PF: $grossPF | Net PF: $netPF');
    _log.i('[JARVIS]  Fees: \$$fees | Slippage: \$$slip');
    _log.i('[JARVIS]  Best: +\$$best | Worst: \$$worst');
    _log.i('[JARVIS] $sep');
    if (winnerLines.isNotEmpty) {
      _log.i('[JARVIS]  TOP WINNERS:');
      for (final line in winnerLines) {
        _log.i('[JARVIS] $line');
      }
      _log.i('[JARVIS] $sep');
    }
    if (loserLines.isNotEmpty) {
      _log.i('[JARVIS]  TOP LOSERS:');
      for (final line in loserLines) {
        _log.i('[JARVIS] $line');
      }
      _log.i('[JARVIS] $sep');
    }
    if (exLines.isNotEmpty) {
      _log.i('[JARVIS]  БИРЖИ:');
      for (final line in exLines) {
        _log.i('[JARVIS] $line');
      }
      _log.i('[JARVIS] $sep');
    }
    if (reasonParts.isNotEmpty) {
      _log.i('[JARVIS]  CLOSE REASONS: ${reasonParts.join(' | ')}');
      _log.i('[JARVIS] $sep');
    }
    _log.i('[JARVIS]  HOLD TIME: Wins avg ${avgWin}m | Losses avg ${avgLoss}m');
    _log.i('[JARVIS] $sep');
    _log.i('[JARVIS]  Уроки: $lessons новых');
    _log.i('[JARVIS] $dbl');
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  /// PUMPUSDT → PUMP
  static String _cleanSymbol(String s) {
    if (s.endsWith('USDT')) return s.substring(0, s.length - 4);
    if (s.endsWith('USDC')) return s.substring(0, s.length - 4);
    return s;
  }

  /// mexc → MEXC, gateio → Gate.io
  static String _cleanExchange(String e) => switch (e.toLowerCase()) {
        'mexc' => 'MEXC',
        'binance' => 'Binance',
        'gateio' => 'Gate.io',
        'bybit' => 'Bybit',
        _ => e,
      };

  /// Phase 6 v2: Check pending observations and fetch current price.
  Future<void> _checkPendingObservations() async {
    final pending = await IbitiDatabase.instance.getPendingObservations();
    if (pending.isEmpty) return;

    int updated = 0;
    final now = DateTime.now();

    for (final obs in pending) {
      final id = obs['id'] as int;
      final exchange = obs['exchange'] as String;
      final symbol = obs['symbol'] as String;
      final priceAtSignal = obs['price_at_signal'] as double;
      final check1hAt = DateTime.tryParse(obs['check_1h_at'] as String? ?? '');
      final check4hAt = DateTime.tryParse(obs['check_4h_at'] as String? ?? '');

      final price1h = obs['price_after_1h'] as double?;
      final price4h = obs['price_after_4h'] as double?;

      final ticker = MarketLiveEngine.instance.latest(exchange, symbol);
      if (ticker == null || ticker.lastPrice <= 0) continue;

      double? newPrice1h;
      double? newPrice4h;
      double? pnl1h;
      double? pnl4h;

      if (price1h == null && check1hAt != null && now.isAfter(check1hAt)) {
        newPrice1h = ticker.lastPrice;
        pnl1h = ((newPrice1h - priceAtSignal) / priceAtSignal) * 100;
        _log.i(
            '[OBSERVATION] 1h update for $exchange:$symbol (signal: \$${priceAtSignal.toStringAsFixed(6)} -> \$${newPrice1h.toStringAsFixed(6)}, PnL: ${pnl1h.toStringAsFixed(2)}%)');
      }

      if (price4h == null && check4hAt != null && now.isAfter(check4hAt)) {
        newPrice4h = ticker.lastPrice;
        pnl4h = ((newPrice4h - priceAtSignal) / priceAtSignal) * 100;
        _log.i(
            '[OBSERVATION] 4h update for $exchange:$symbol (PnL: ${pnl4h.toStringAsFixed(2)}%)');
      }

      if (newPrice1h != null || newPrice4h != null) {
        String? lesson;
        if (pnl4h != null || pnl1h != null) {
          final finalPnl = pnl4h ?? pnl1h ?? 0.0;
          if (finalPnl > 5.0) {
            lesson = 'Missed opportunity: Strong move without entry';
          } else if (finalPnl < -5.0) {
            lesson = 'Dodged bullet: Bad signal confirmed';
          } else {
            lesson = 'Noise: Signal did not result in move';
          }
        }
        await IbitiDatabase.instance.updateObservationPrice(
          id: id,
          priceAfter1h: newPrice1h,
          priceAfter4h: newPrice4h,
          hypotheticalPnl1h: pnl1h,
          hypotheticalPnl4h: pnl4h,
          lesson: lesson,
        );

        updated++;
      }
    }

    if (updated > 0) {
      _log.d('Updated $updated pending observations');
    }
  }
}
