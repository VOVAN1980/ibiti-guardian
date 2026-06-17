import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_interface.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

// ─── MarketLiveEngine ──────────────────────────────────────────────────────────
//
// Central hub: WS tick → memory cache → pair-level ValueNotifier → UI.
//
// Rules:
//   1. latestByKey always updated on every WS tick — O(1).
//   2. ValueNotifier created LAZILY — only when UI actually subscribes.
//      pushTick only calls notifier.value if notifier already exists.
//   3. Logging: aggregate summary every 10s. Zero per-pair logs.
//   4. Key format: "${exchange.toLowerCase()}:${pair.toUpperCase()}"
//      e.g. "binance:BTCUSDT", "gateio:BTCUSDT", "mexc:ACNUSDT"
// ─────────────────────────────────────────────────────────────────────────────

const _log = GuardianLogger('LiveEngine');

class MarketLiveEngine {
  MarketLiveEngine._();
  static final MarketLiveEngine instance = MarketLiveEngine._();

  // ── Storage ──────────────────────────────────────────────────────────────

  /// Always populated on WS tick. O(1) read. Never null after first tick.
  final Map<String, LiveTicker> _latest = {};

  /// Created lazily — only when UI calls notifierFor().
  /// pushTick does NOT create notifiers; only updates existing ones.
  final Map<String, ValueNotifier<LiveTicker?>> _notifiers = {};

  // ── Diagnostics ──────────────────────────────────────────────────────────

  /// Global aggregate counters — reset every summary.
  int _totalTicks = 0;
  int _notifierHits = 0;
  final Map<String, int> _exchangeTicks = {};
  DateTime _lastSummary = DateTime.now();
  static const _summaryInterval = Duration(seconds: 10);

  // ─────────────────────────────────────────────────────────────────────────

  /// Canonical key. Use this everywhere — do not build keys manually.
  static String key(String exchange, String pair) =>
      '${exchange.toLowerCase()}:${pair.toUpperCase()}';

  // ── Public stats (for voice fast path, IBITI, etc.) ─────────────────────

  /// Number of unique exchange:pair keys currently cached.
  int get pairCount => _latest.length;

  /// Cumulative tick counter since last summary reset.
  int get totalTicks => _totalTicks;

  // ── Public API ───────────────────────────────────────────────────────────

  /// Latest ticker from cache. Returns null if no WS tick received yet.
  /// O(1). Zero latency. Call this on TokenDetail open for instant price.
  LiveTicker? latest(String exchange, String pair) =>
      _latest[key(exchange, pair)];

  /// Latest ticker by pre-built key (avoids double key construction).
  LiveTicker? latestByKey(String k) => _latest[k];

  /// Snapshot of ALL live tickers. Read-only copy for IBITI Perception.
  /// Key = "exchange:PAIR", e.g. "binance:BTCUSDT".
  /// O(n) copy — call at most once per scan cycle (every 30s).
  Map<String, LiveTicker> snapshotAll() => Map.unmodifiable(_latest);

  /// Get or create a ValueNotifier for a pair.
  /// Called by UI when it wants to subscribe to live updates.
  /// The notifier is created here and kept alive until [releaseNotifier].
  ValueNotifier<LiveTicker?> notifierFor(String exchange, String pair) {
    final k = key(exchange, pair);
    return _notifiers.putIfAbsent(k, () {
      // Pre-fill with any existing cached value so UI gets data immediately.
      return ValueNotifier(_latest[k]);
    });
  }

  /// Release notifier when no UI is listening anymore.
  /// Call this only if you are certain no other widget is subscribed.
  /// In practice, TokenDetail can call this on dispose for its pair.
  void releaseNotifier(String exchange, String pair) {
    final k = key(exchange, pair);
    _notifiers.remove(k)?.dispose();
  }

  // ── Push ─────────────────────────────────────────────────────────────────

  /// Called by ExchangeService._onWsMessage for every parsed ticker.
  ///
  /// [wsReceivedAt] — timestamp when the WS frame arrived (set at top of
  /// _onWsMessage before any parsing). Used to compute wsToCache latency.
  void pushTick(
    String exchange,
    String pair,
    LiveTicker tick, {
    DateTime? wsReceivedAt,
  }) {
    final k = key(exchange, pair);

    // 1. Always update latest cache.
    _latest[k] = tick;

    // 2. Update notifier ONLY if UI already created it (lazy guard).
    final n = _notifiers[k];
    if (n != null) {
      n.value = tick;
      _notifierHits++;
    }

    // 3. Lightweight aggregate counter (no per-pair logs).
    _totalTicks++;
    _exchangeTicks[exchange] = (_exchangeTicks[exchange] ?? 0) + 1;

    // 4. Emit summary every 10s.
    final now = DateTime.now();
    if (now.difference(_lastSummary) >= _summaryInterval) {
      _emitSummary();
      _lastSummary = now;
    }
  }

  // ── Diagnostics ──────────────────────────────────────────────────────────

  void _emitSummary() {
    final parts =
        _exchangeTicks.entries.map((e) => '${e.key}=${e.value}').join(' ');
    _log.i('[Summary] $_totalTicks ticks | $parts | '
        'pairs=${_latest.length} notifiers=${_notifiers.length} '
        'notifierHits=$_notifierHits');
    _totalTicks = 0;
    _notifierHits = 0;
    _exchangeTicks.clear();
  }

  void clearForTest() {
    _latest.clear();
    _notifiers.clear();
  }
}
