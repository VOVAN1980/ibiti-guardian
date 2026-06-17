// ─── IBITI Perception ───────────────────────────────────────────────────────────
//
// Eyes of IBITI. Converts raw ticks into meaningful MarketEvents.
// Pure Dart — no LLM, no API calls, runs in <10ms.
//
// Data source: MarketLiveEngine.snapshotAll() — single source of truth.
// No ExchangeRegistry iteration. No notifier creation. Read-only snapshot.
//
// Fixes applied:
//   - volumeSpike uses delta (current-prev), not cumulative 24h comparison
//   - priceBreakout uses localHigh from ring buffer, not high24h
//   - Universe filter removes 3L/3S/5L/5S, stables, garbage, low volume
//   - All 10 detectors defined, 6 active by default
// ─────────────────────────────────────────────────────────────────────────────────

import 'package:ibiti_guardian/services/ibiti/models/market_event.dart';
import 'package:ibiti_guardian/services/ibiti/models/market_phase.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_interface.dart';
import 'package:ibiti_guardian/services/market/market_live_engine.dart';

import 'package:ibiti_guardian/utils/guardian_logger.dart';

const _log = GuardianLogger('IbitiPerception');

class IbitiPerception {
  IbitiPerception._();
  static final IbitiPerception instance = IbitiPerception._();

  /// Previous tick snapshots. Key = "exchange:SYMBOL".
  final Map<String, _TickSnapshot> _prevSnapshot = {};

  /// Ring buffer of prices for local high detection. Key = "exchange:SYMBOL".
  /// Stores last 10 prices (= 5 minutes at 30s intervals).
  final Map<String, List<double>> _priceRingBuffer = {};
  static const _ringBufferSize = 10;

  /// Phase 16B: Ring buffer of volume deltas for dollar flow intelligence.
  /// Tracks last 120 volume deltas (= 60 minutes at 30s intervals).
  /// Windows: last 10 = 5min, last 30 = 15min, last 120 = 60min.
  final Map<String, List<double>> _volumeDeltaRingBuffer = {};
  static const _volRingSize = 120;

  /// Current market phase (updated by IbitiLoop).
  MarketPhase currentPhase = MarketPhase.sideways;
  MarketHeartbeat currentHeartbeat = MarketHeartbeat.unknown;

  /// Which detectors are currently active.
  final Set<MarketEventType> _activeDetectors = {
    MarketEventType.volumeSpike,
    MarketEventType.priceBreakout,
    MarketEventType.exhaustionCandle,
    MarketEventType.newListingMove,
    MarketEventType.fakeBreakout,
    MarketEventType.crossExchangeMove,
    MarketEventType.liquidityDrain,
    MarketEventType.consolidation,
    MarketEventType.marketMoodShift,
    MarketEventType.trendContinuation,
  };

  final Map<String, DateTime> _lastDetectorEmit = {};

  bool _canEmit(MarketEventType type, String key, Duration cooldown) {
    final emitKey = '${type.name}:$key';
    final last = _lastDetectorEmit[emitKey];
    if (last == null || DateTime.now().difference(last) > cooldown) {
      _lastDetectorEmit[emitKey] = DateTime.now();
      return true;
    }
    return false;
  }

  void enableDetector(MarketEventType type) => _activeDetectors.add(type);
  void disableDetector(MarketEventType type) => _activeDetectors.remove(type);
  Set<MarketEventType> get activeDetectors =>
      Set.unmodifiable(_activeDetectors);

  // ── Universe filter ─────────────────────────────────────────────────────────

  static const _stablecoins = {
    'USDT',
    'USDC',
    'DAI',
    'FDUSD',
    'BUSD',
    'USDE',
    'PYUSD',
    'TUSD',
    'USDP',
  };

  /// Leveraged token suffixes.
  static final _leveragedRe = RegExp(r'[235][LS]USDT$', caseSensitive: false);

  /// Minimum volume to even consider (below = noise).
  static const _minScanVolume = 10000.0;

  /// Returns true if this ticker should be SKIPPED (garbage).
  static bool _isGarbage(String key, LiveTicker t) {
    final base = t.baseAsset.toUpperCase();

    // Skip stablecoins.
    if (_stablecoins.contains(base)) return true;

    // Skip leveraged tokens: 3L, 3S, 5L, 5S.
    if (_leveragedRe.hasMatch(t.symbol)) return true;

    // Skip symbols with weird unicode / non-ASCII characters.
    if (!RegExp(r'^[A-Z0-9]+$').hasMatch(base)) return true;

    // Skip zero or negative price.
    if (t.lastPrice <= 0) return true;

    // Skip very low volume.
    if (t.quoteVolume24h < _minScanVolume) return true;

    return false;
  }

  // ── Main scan ─────────────────────────────────────────────────────────────

  /// Scan all tickers via MarketLiveEngine.snapshotAll().
  /// Called every 30 seconds by IbitiLoop. Returns significant events.
  List<MarketEvent> scan() {
    final events = <MarketEvent>[];
    final now = DateTime.now();
    final allTickers = MarketLiveEngine.instance.snapshotAll();

    for (final entry in allTickers.entries) {
      final key = entry.key; // "exchange:PAIR"
      final ticker = entry.value;

      // Parse exchange from key.
      final colonIdx = key.indexOf(':');
      if (colonIdx < 0) continue;
      final exchange = key.substring(0, colonIdx);

      // ── Universe filter ──
      if (_isGarbage(key, ticker)) continue;

      final prev = _prevSnapshot[key];

      final prevVolume = prev?.volume24h ?? ticker.quoteVolume24h;
      final currentDelta = ticker.quoteVolume24h - prevVolume;

      // ── Update ring buffers ──
      _updateRingBuffer(key, ticker.lastPrice);
      _updateVolumeDeltaRingBuffer(key, currentDelta);

      // ── Run active detectors ──
      if (_activeDetectors.contains(MarketEventType.volumeSpike)) {
        final e = _detectVolumeSpike(ticker, prev, exchange, now);
        if (e != null) events.add(e);
      }
      if (_activeDetectors.contains(MarketEventType.priceBreakout)) {
        final e = _detectPriceBreakout(ticker, prev, key, exchange, now);
        if (e != null) events.add(e);
      }
      if (_activeDetectors.contains(MarketEventType.exhaustionCandle)) {
        final e = _detectExhaustionCandle(ticker, exchange, now);
        if (e != null) events.add(e);
      }
      if (_activeDetectors.contains(MarketEventType.newListingMove)) {
        final e = _detectNewListingMove(ticker, key, exchange, now);
        if (e != null) events.add(e);
      }
      if (_activeDetectors.contains(MarketEventType.liquidityDrain)) {
        final e = _detectLiquidityDrain(ticker, prev, key, exchange, now);
        if (e != null) events.add(e);
      }
      if (_activeDetectors.contains(MarketEventType.fakeBreakout)) {
        final e = _detectFakeBreakout(ticker, prev, key, exchange, now);
        if (e != null) events.add(e);
      }
      if (_activeDetectors.contains(MarketEventType.consolidation)) {
        final e = _detectConsolidation(ticker, key, exchange, now);
        if (e != null) events.add(e);
      }
      if (_activeDetectors.contains(MarketEventType.trendContinuation)) {
        final e = _detectTrendContinuation(ticker, exchange, now);
        if (e != null) events.add(e);
      }

      // ── Save snapshot for next scan ──

      _prevSnapshot[key] = _TickSnapshot(
        price: ticker.lastPrice,
        volume24h: ticker.quoteVolume24h,
        volumeDelta: currentDelta,
        high24h: ticker.highPrice24h,
        change24h: ticker.priceChangePercent24h,
        capturedAt: now,
      );
    }

    // ── Aggregate detectors ──
    if (_activeDetectors.contains(MarketEventType.crossExchangeMove)) {
      events.addAll(_detectCrossExchangeMoves(allTickers, now));
    }
    if (_activeDetectors.contains(MarketEventType.marketMoodShift)) {
      final e = _detectMarketMoodShift(now);
      if (e != null) events.add(e);
    }




    final filteredEvents = <MarketEvent>[];
    for (final e in events) {
      if (e.flowClass == 'retailNoise') {
        if (e.type == MarketEventType.volumeSpike) {
          // Suppress unless it has a strong price change and sustained flow score
          final isStrongSustained = e.changePercent >= 5.0 && e.volumeFlowScore >= 0.65;
          if (isStrongSustained) {
            filteredEvents.add(e.copyWith(severity: MarketEventSeverity.info));
          }
          continue;
        }
        if (e.type == MarketEventType.priceBreakout) {
          // Suppress unless breakout is strong or 24h change is high, and flow is sustained
          final isStrongSustained = (e.triggerValue >= 1.5 || e.changePercent >= 5.0) && e.volumeFlowScore >= 0.6;
          if (isStrongSustained) {
            filteredEvents.add(e.copyWith(severity: MarketEventSeverity.info));
          }
          continue;
        }
        if (e.type == MarketEventType.newListingMove) {
          // Suppress unless 24h change is huge
          final isStrong = e.changePercent.abs() >= 25.0;
          if (isStrong) {
            filteredEvents.add(e.copyWith(severity: MarketEventSeverity.info));
          }
          continue;
        }
      }
      filteredEvents.add(e);
    }

    if (filteredEvents.isNotEmpty) {
      _log.i('Perception: ${filteredEvents.length} events detected');
    }
    return filteredEvents;
  }

  // ── Ring buffer ─────────────────────────────────────────────────────────────

  void _updateRingBuffer(String key, double price) {
    final buf = _priceRingBuffer.putIfAbsent(key, () => []);
    buf.add(price);
    if (buf.length > _ringBufferSize) buf.removeAt(0);
  }

  /// Phase 16B: Update volume delta ring buffer.
  void _updateVolumeDeltaRingBuffer(String key, double delta) {
    final buf = _volumeDeltaRingBuffer.putIfAbsent(key, () => []);
    buf.add(delta);
    if (buf.length > _volRingSize) buf.removeAt(0);
  }

  /// Phase 16B: Volume Flow Score (0.0–1.0) — consistency check.
  /// Uses last 10 entries (= 5 minutes) of the delta buffer.
  /// Measures whether deltas are consistently positive (sustained flow)
  /// or a single spike (noise).
  double volumeFlowScore(String key) {
    final buf = _volumeDeltaRingBuffer[key];
    if (buf == null || buf.length < 2) return 0.5; // Not enough data = neutral.

    // Use last 10 entries (5 minutes) for consistency scoring.
    final recent = buf.length > 10 ? buf.sublist(buf.length - 10) : buf;

    // 1. Consistency: how many recent deltas are positive?
    int positiveCount = 0;
    for (final d in recent) {
      if (d > 0) positiveCount++;
    }
    final consistencyRatio = positiveCount / recent.length;

    // 2. Trend: is the flow growing or fading?
    final lastDelta = recent.last;
    double earlierSum = 0;
    for (int i = 0; i < recent.length - 1; i++) {
      earlierSum += recent[i];
    }
    final earlierAvg = earlierSum / (recent.length - 1);

    double trendScore = 0.5;
    if (earlierAvg > 0 && lastDelta > 0) {
      final ratio = lastDelta / earlierAvg;
      trendScore = (ratio).clamp(0.0, 2.0) / 2.0;
    } else if (lastDelta <= 0) {
      trendScore = 0.1;
    }

    final score = consistencyRatio * 0.6 + trendScore * 0.4;
    return score.clamp(0.0, 1.0);
  }

  /// Phase 20: Get the best flow class for a symbol across all exchanges.
  /// Used by thesis-based exit engine to check if money is still flowing in.
  /// Returns the strongest flow class found (whaleInflow > seriousInflow > retailInterest > retailNoise).
  String flowClassForSymbol(String symbol) {
    // Check all known exchange:symbol combinations
    final exchanges = ['binance', 'bybit', 'mexc', 'gateio'];
    String bestFlow = 'retailNoise';
    const flowRank = {
      'whaleInflow': 4,
      'seriousInflow': 3,
      'retailInterest': 2,
      'retailNoise': 1,
    };
    for (final ex in exchanges) {
      final key = '$ex:$symbol';
      final flows = _calculateDollarFlows(key);
      final rank = flowRank[flows.flowClass] ?? 0;
      if (rank > (flowRank[bestFlow] ?? 0)) {
        bestFlow = flows.flowClass;
      }
    }
    return bestFlow;
  }

  /// Phase 11B: Get flow class for a specific exchange and symbol pair.
  /// Used for precise exit conditions and whale watch on the actual traded pair.
  String flowClassForPair(String exchange, String symbol) {
    final flows = _calculateDollarFlows('$exchange:$symbol');
    return flows.flowClass;
  }

  // ── Phase 16B Full: Dollar Flow Intelligence ─────────────────────────────

  /// Calculate real dollar flows over 5m/15m/60m windows.
  /// Sums POSITIVE volume deltas (inflow, not outflow) over each window.
  ///
  /// Windows:
  ///   last 10 deltas = 5 minutes  (at 30s intervals)
  ///   last 30 deltas = 15 minutes
  ///   last 120 deltas = 60 minutes
  _DollarFlows _calculateDollarFlows(String key) {
    final buf = _volumeDeltaRingBuffer[key];
    if (buf == null || buf.isEmpty) {
      return const _DollarFlows(
        flow5mUsd: 0,
        flow15mUsd: 0,
        flow60mUsd: 0,
        acceleration: 0,
        flowClass: 'retailNoise',
      );
    }

    double sum5m = 0, sum15m = 0, sum60m = 0;
    final len = buf.length;

    for (int i = 0; i < len; i++) {
      final d = buf[len - 1 - i]; // Walk backwards from most recent.
      if (d > 0) {
        if (i < 10) sum5m += d; // Last 10 = 5 min
        if (i < 30) sum15m += d; // Last 30 = 15 min
        sum60m += d; // All = up to 60 min
      }
    }

    // Acceleration: is recent flow faster than medium-term?
    // flow5m covers 5 min, flow15m covers 15 min.
    // Normalized rate: flow5m vs (flow15m / 3).
    double acceleration = 1.0;
    final mediumRate = sum15m / 3.0; // Average 5-min rate over 15 min.
    if (mediumRate > 100) {
      acceleration = sum5m / mediumRate;
    } else if (sum5m > 100) {
      acceleration = 10.0; // New flow appearing, previously nothing.
    }

    final flowClass = _classifyFlow(sum5m);

    return _DollarFlows(
      flow5mUsd: sum5m,
      flow15mUsd: sum15m,
      flow60mUsd: sum60m,
      acceleration: acceleration,
      flowClass: flowClass,
    );
  }

  /// Classify dollar flow by absolute threshold.
  /// Category-aware gating (per asset type) is in PaperTrader/Debate.
  /// Thresholds are for 5-minute buy-side flow.
  static String _classifyFlow(double flow5mUsd) {
    if (flow5mUsd >= 200000) return 'whaleInflow';
    if (flow5mUsd >= 20000) return 'seriousInflow';
    if (flow5mUsd >= 1000) return 'retailInterest';
    return 'retailNoise';
  }

  /// Format dollar amount for logs (e.g. $42K, $1.2M).
  static String _fmtUsd(double usd) {
    if (usd >= 1000000) return '\$${(usd / 1000000).toStringAsFixed(1)}M';
    if (usd >= 1000) return '\$${(usd / 1000).toStringAsFixed(0)}K';
    return '\$${usd.toStringAsFixed(0)}';
  }

  /// Local high over the ring buffer (last ~5 min).
  double? _localHigh(String key) {
    final buf = _priceRingBuffer[key];
    if (buf == null || buf.length < 3) return null; // Need at least 3 points.
    double max = buf[0];
    for (int i = 1; i < buf.length - 1; i++) {
      // Exclude current (last) price — we compare current TO the local high.
      if (buf[i] > max) max = buf[i];
    }
    return max;
  }

  // ── Detectors ─────────────────────────────────────────────────────────────

  /// Fix #2: Volume spike via DELTA, not cumulative comparison.
  /// currentDelta = current.volume24h - prev.volume24h (volume gained in 30s).
  /// Spike = currentDelta >= prevDelta * 3.
  MarketEvent? _detectVolumeSpike(
    LiveTicker t,
    _TickSnapshot? prev,
    String exchange,
    DateTime now,
  ) {
    if (prev == null) return null;

    final currentDelta = t.quoteVolume24h - prev.volume24h;
    final prevDelta = prev.volumeDelta;

    // Need positive deltas and previous delta must be meaningful.
    if (currentDelta <= 0 || prevDelta <= 100) return null;

    final ratio = currentDelta / prevDelta;
    if (ratio < 3.0) return null;

    // Phase 16B: Attach volume flow score + dollar flows.
    final flowKey = '$exchange:${t.symbol}';
    final vfScore = volumeFlowScore(flowKey);
    final flows = _calculateDollarFlows(flowKey);

    // Log dollar flow for observability.
    _log.d('[Flow] ${t.symbol}@$exchange '
        '5m=${_fmtUsd(flows.flow5mUsd)} '
        '15m=${_fmtUsd(flows.flow15mUsd)} '
        '60m=${_fmtUsd(flows.flow60mUsd)} '
        'accel=${flows.acceleration.toStringAsFixed(1)}x '
        'class=${flows.flowClass}');

    return MarketEvent(
      type: MarketEventType.volumeSpike,
      symbol: t.symbol,
      exchange: exchange,
      price: t.lastPrice,
      changePercent: t.priceChangePercent24h,
      volume24h: t.quoteVolume24h,
      triggerValue: ratio,
      volumeFlowScore: vfScore,
      flow5mUsd: flows.flow5mUsd,
      flow15mUsd: flows.flow15mUsd,
      flow60mUsd: flows.flow60mUsd,
      flowClass: flows.flowClass,
      timestamp: now,
      description: 'Volume delta ${ratio.toStringAsFixed(1)}× previous '
          '(\$${currentDelta.toStringAsFixed(0)} vs '
          '\$${prevDelta.toStringAsFixed(0)}) '
          'flow=${vfScore.toStringAsFixed(2)} '
          '5m=${_fmtUsd(flows.flow5mUsd)} ${flows.flowClass}',
    );
  }

  /// Fix #3: Breakout uses localHigh from ring buffer, not high24h.
  /// currentPrice > localHigh5min * 1.003.
  MarketEvent? _detectPriceBreakout(
    LiveTicker t,
    _TickSnapshot? prev,
    String key,
    String exchange,
    DateTime now,
  ) {
    final localHigh = _localHigh(key);
    if (localHigh == null || localHigh <= 0) return null;

    // Must break above local high by at least 0.3%.
    if (t.lastPrice < localHigh * 1.003) return null;

    // Must not have been breaking out in previous snapshot (new break).
    if (prev != null && prev.price >= localHigh * 1.003) return null;

    final aboveHighPct = ((t.lastPrice - localHigh) / localHigh) * 100;

    // Phase 16B: Attach volume flow score + dollar flows to breakouts.
    final flowKey = '$exchange:${t.symbol}';
    final vfScore = volumeFlowScore(flowKey);
    final flows = _calculateDollarFlows(flowKey);

    _log.d('[Flow] ${t.symbol}@$exchange '
        '5m=${_fmtUsd(flows.flow5mUsd)} '
        '15m=${_fmtUsd(flows.flow15mUsd)} '
        '60m=${_fmtUsd(flows.flow60mUsd)} '
        'accel=${flows.acceleration.toStringAsFixed(1)}x '
        'class=${flows.flowClass}');

    return MarketEvent(
      type: MarketEventType.priceBreakout,
      symbol: t.symbol,
      exchange: exchange,
      price: t.lastPrice,
      changePercent: t.priceChangePercent24h,
      volume24h: t.quoteVolume24h,
      triggerValue: aboveHighPct,
      volumeFlowScore: vfScore,
      flow5mUsd: flows.flow5mUsd,
      flow15mUsd: flows.flow15mUsd,
      flow60mUsd: flows.flow60mUsd,
      flowClass: flows.flowClass,
      timestamp: now,
      description: 'Broke local 5m high \$${localHigh.toStringAsFixed(6)} '
          'by +${aboveHighPct.toStringAsFixed(2)}% '
          '(24h high: \$${t.highPrice24h.toStringAsFixed(6)}) '
          '5m=${_fmtUsd(flows.flow5mUsd)} ${flows.flowClass}',
    );
  }

  /// Vertical candle: >80% gain, huge range, near the top.
  MarketEvent? _detectExhaustionCandle(
    LiveTicker t,
    String exchange,
    DateTime now,
  ) {
    if (t.priceChangePercent24h < 80) return null;
    if (t.lowPrice24h <= 0) return null;

    final range = (t.highPrice24h - t.lowPrice24h) / t.lowPrice24h;
    if (range < 0.5) return null;

    final distFromHigh = t.highPrice24h > 0
        ? (t.highPrice24h - t.lastPrice) / t.highPrice24h
        : 0.0;
    if (distFromHigh > 0.1) return null;

    return MarketEvent(
      type: MarketEventType.exhaustionCandle,
      severity: MarketEventSeverity.critical,
      symbol: t.symbol,
      exchange: exchange,
      price: t.lastPrice,
      changePercent: t.priceChangePercent24h,
      volume24h: t.quoteVolume24h,
      triggerValue: range * 100,
      timestamp: now,
      description:
          'Exhaustion: +${t.priceChangePercent24h.toStringAsFixed(1)}% '
          'range=${(range * 100).toStringAsFixed(0)}% '
          '${(distFromHigh * 100).toStringAsFixed(1)}% from high',
    );
  }

  MarketEvent? _detectNewListingMove(
    LiveTicker t,
    String key,
    String exchange,
    DateTime now,
  ) {
    if (!t.isNewlyListed && (t.daysListed ?? 999) > 3) return null;
    if (t.priceChangePercent24h.abs() < 15) return null;

    final vfScore = volumeFlowScore(key);
    final flows = _calculateDollarFlows(key);

    return MarketEvent(
      type: MarketEventType.newListingMove,
      symbol: t.symbol,
      exchange: exchange,
      price: t.lastPrice,
      changePercent: t.priceChangePercent24h,
      volume24h: t.quoteVolume24h,
      triggerValue: t.priceChangePercent24h,
      volumeFlowScore: vfScore,
      flow5mUsd: flows.flow5mUsd,
      flow15mUsd: flows.flow15mUsd,
      flow60mUsd: flows.flow60mUsd,
      flowClass: flows.flowClass,
      timestamp: now,
      description: 'New listing (${t.daysListed ?? 0}d) '
          'moved ${t.priceChangePercent24h.toStringAsFixed(1)}% '
          '5m=${_fmtUsd(flows.flow5mUsd)} ${flows.flowClass}',
    );
  }

  MarketEvent? _detectLiquidityDrain(
    LiveTicker t,
    _TickSnapshot? prev,
    String key,
    String exchange,
    DateTime now,
  ) {
    if (prev == null || prev.volumeDelta <= 0) return null;
    final currentDelta = t.quoteVolume24h - prev.volume24h;
    if (currentDelta <= 0) return null;
    final ratio = currentDelta / prev.volumeDelta;
    if (ratio > 0.3) return null;
    if (t.priceChangePercent24h < 20) return null;

    final flows = _calculateDollarFlows(key);
    final vf = volumeFlowScore(key);
    if (flows.flow5mUsd >= flows.flow15mUsd / 4 && vf >= 0.35) return null;

    if (!_canEmit(
        MarketEventType.liquidityDrain, key, const Duration(minutes: 10)))
      return null;

    return MarketEvent(
      type: MarketEventType.liquidityDrain,
      severity: MarketEventSeverity.critical,
      symbol: t.symbol,
      exchange: exchange,
      price: t.lastPrice,
      changePercent: t.priceChangePercent24h,
      volume24h: t.quoteVolume24h,
      triggerValue: ratio,
      timestamp: now,
      description: 'Volume delta collapsed to '
          '${(ratio * 100).toStringAsFixed(0)}% of previous '
          'after +${t.priceChangePercent24h.toStringAsFixed(1)}% pump',
    );
  }

  MarketEvent? _detectFakeBreakout(
    LiveTicker t,
    _TickSnapshot? prev,
    String key,
    String exchange,
    DateTime now,
  ) {
    if (prev == null) return null;
    final localHigh = _localHigh(key);
    if (localHigh == null) return null;
    // Previous scan was above local high, now pulled back >3%.
    if (prev.price < localHigh * 1.003) return null;
    final pullback =
        prev.price > 0 ? ((prev.price - t.lastPrice) / prev.price) * 100 : 0.0;
    if (pullback < 3.0) return null;
    return MarketEvent(
      type: MarketEventType.fakeBreakout,
      severity: MarketEventSeverity.critical,
      symbol: t.symbol,
      exchange: exchange,
      price: t.lastPrice,
      changePercent: t.priceChangePercent24h,
      volume24h: t.quoteVolume24h,
      triggerValue: pullback,
      timestamp: now,
      description: 'Was above local high, pulled back '
          '${pullback.toStringAsFixed(1)}%',
    );
  }

  MarketEvent? _detectConsolidation(
    LiveTicker t,
    String key,
    String exchange,
    DateTime now,
  ) {
    if (t.highPrice24h <= 0 || t.lowPrice24h <= 0) return null;
    final range = (t.highPrice24h - t.lowPrice24h) / t.lowPrice24h;
    if (range > 0.05) return null;
    if (t.quoteVolume24h < 100000) return null;
    if (!_canEmit(
        MarketEventType.consolidation, key, const Duration(minutes: 30)))
      return null;
    return MarketEvent(
      type: MarketEventType.consolidation,
      severity: MarketEventSeverity.info,
      symbol: t.symbol,
      exchange: exchange,
      price: t.lastPrice,
      changePercent: t.priceChangePercent24h,
      volume24h: t.quoteVolume24h,
      triggerValue: range * 100,
      timestamp: now,
      description: 'Tight range ${(range * 100).toStringAsFixed(1)}% '
          'vol=\$${t.quoteVolume24h.toStringAsFixed(0)}',
    );
  }

  List<MarketEvent> _detectCrossExchangeMoves(
    Map<String, LiveTicker> allTickers,
    DateTime now,
  ) {
    final events = <MarketEvent>[];
    final byBase = <String, List<_ExchangeTicker>>{};
    for (final entry in allTickers.entries) {
      final colonIdx = entry.key.indexOf(':');
      if (colonIdx < 0) continue;
      final ex = entry.key.substring(0, colonIdx);
      final t = entry.value;
      if (_isGarbage(entry.key, t)) continue;
      byBase.putIfAbsent(t.baseAsset, () => []).add(_ExchangeTicker(ex, t));
    }
    for (final entry in byBase.entries) {
      if (entry.value.length < 2) continue;
      final changes = entry.value.map((e) => e.ticker.priceChangePercent24h);
      final maxC = changes.reduce((a, b) => a > b ? a : b);
      final minC = changes.reduce((a, b) => a < b ? a : b);
      final spread = maxC - minC;
      if (spread > 15) {
        final leader = entry.value.reduce((a, b) =>
            a.ticker.priceChangePercent24h > b.ticker.priceChangePercent24h
                ? a
                : b);
        events.add(MarketEvent(
          type: MarketEventType.crossExchangeMove,
          symbol: leader.ticker.symbol,
          exchange: leader.exchange,
          price: leader.ticker.lastPrice,
          changePercent: leader.ticker.priceChangePercent24h,
          volume24h: leader.ticker.quoteVolume24h,
          triggerValue: spread,
          timestamp: now,
          description: '${entry.key} divergence: '
              '${spread.toStringAsFixed(1)}% spread across exchanges',
        ));
      }
    }
    return events;
  }

  MarketEvent? _detectMarketMoodShift(DateTime now) {
    final engine = MarketLiveEngine.instance;
    final btc = engine.latestByKey('binance:BTCUSDT') ??
        engine.latestByKey('mexc:BTCUSDT');
    if (btc == null) return null;
    final prevBtc = _prevSnapshot['_mood_btc'];
    if (prevBtc != null) {
      final deltaPct = prevBtc.price > 0
          ? ((btc.lastPrice - prevBtc.price) / prevBtc.price) * 100
          : 0.0;
      if (deltaPct.abs() > 2.0) {
        if (!_canEmit(MarketEventType.marketMoodShift, 'market:btc',
            const Duration(minutes: 10))) {
          return null;
        }
        _prevSnapshot['_mood_btc'] = _TickSnapshot(
          price: btc.lastPrice,
          volume24h: btc.quoteVolume24h,
          volumeDelta: 0,
          high24h: btc.highPrice24h,
          change24h: btc.priceChangePercent24h,
          capturedAt: now,
        );
        return MarketEvent(
          type: MarketEventType.marketMoodShift,
          severity: MarketEventSeverity.critical,
          symbol: 'BTCUSDT',
          exchange: 'binance',
          price: btc.lastPrice,
          changePercent: btc.priceChangePercent24h,
          volume24h: btc.quoteVolume24h,
          triggerValue: deltaPct,
          timestamp: now,
          description: 'BTC moved ${deltaPct.toStringAsFixed(1)}% '
              'since last scan — mood shift',
        );
      }
    }
    _prevSnapshot['_mood_btc'] = _TickSnapshot(
      price: btc.lastPrice,
      volume24h: btc.quoteVolume24h,
      volumeDelta: 0,
      high24h: btc.highPrice24h,
      change24h: btc.priceChangePercent24h,
      capturedAt: now,
    );
    return null;
  }

  MarketEvent? _detectTrendContinuation(
    LiveTicker t,
    String exchange,
    DateTime now,
  ) {
    if (t.priceChangePercent24h < 5) return null;
    final key = '$exchange:${t.symbol}';
    final buf = _priceRingBuffer[key];
    if (buf == null || buf.length < 10) return null;

    if (t.lastPrice < buf.first) return null; // Price lower than 5 mins ago

    final vScore = volumeFlowScore(key);
    if (vScore < 0.55) return null;

    final flows = _calculateDollarFlows(key);
    final fc = _classifyFlow(flows.flow5mUsd);
    if (fc == 'retailNoise') return null;

    if (!_canEmit(
        MarketEventType.trendContinuation, key, const Duration(minutes: 10))) {
      return null;
    }

    return MarketEvent(
      type: MarketEventType.trendContinuation,
      severity: MarketEventSeverity.info,
      symbol: t.symbol,
      exchange: exchange,
      price: t.lastPrice,
      changePercent: t.priceChangePercent24h,
      volume24h: t.quoteVolume24h,
      triggerValue: t.priceChangePercent24h,
      flowClass: fc,
      volumeFlowScore: vScore,
      flow5mUsd: flows.flow5mUsd,
      flow15mUsd: flows.flow15mUsd,
      flow60mUsd: flows.flow60mUsd,
      timestamp: now,
      description: 'Trend continuation with steady climb',
    );
  }
}

// ── Internal helpers ─────────────────────────────────────────────────────────

class _TickSnapshot {
  final double price;
  final double volume24h;
  final double volumeDelta; // Fix #2: delta = current - previous.
  final double high24h;
  final double change24h;
  final DateTime capturedAt;

  const _TickSnapshot({
    required this.price,
    required this.volume24h,
    required this.volumeDelta,
    required this.high24h,
    required this.change24h,
    required this.capturedAt,
  });
}

class _ExchangeTicker {
  final String exchange;
  final LiveTicker ticker;
  const _ExchangeTicker(this.exchange, this.ticker);
}

/// Phase 16B: Dollar-denominated flow data for a symbol.
class _DollarFlows {
  final double flow5mUsd;
  final double flow15mUsd;
  final double flow60mUsd;
  final double acceleration;
  final String flowClass;

  const _DollarFlows({
    required this.flow5mUsd,
    required this.flow15mUsd,
    required this.flow60mUsd,
    required this.acceleration,
    required this.flowClass,
  });
}
