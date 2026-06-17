// ─── IBITI Memory ───────────────────────────────────────────────────────────────
//
// 7 layers of memory, all present from day one:
//   1. Short-term (RAM): recent events and decisions (last 30 min)
//   2. Token profiles (persistent): experience per token
//   3. Exchange profiles (persistent): experience per exchange
//   4. Pattern lessons (persistent): learned rules with weights
//   5. Decision history (persistent): last 200 decisions
//   6. Postmortem history (persistent): last 100 postmortems
//   7. Market phase memory (RAM): current phase + recent shifts
//
// Persistent layers use SQLite via IbitiDatabase.
// ─────────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'package:ibiti_guardian/services/ibiti/ibiti_database.dart';
import 'package:ibiti_guardian/services/ibiti/models/market_event.dart';
import 'package:ibiti_guardian/services/ibiti/models/market_phase.dart';
import 'package:ibiti_guardian/services/ibiti/models/token_profile.dart';
import 'package:ibiti_guardian/services/ibiti/models/exchange_profile.dart';
import 'package:ibiti_guardian/services/ibiti/models/pattern_lesson.dart';
import 'package:ibiti_guardian/services/ibiti/models/ibiti_decision.dart';
import 'package:ibiti_guardian/services/ibiti/models/ibiti_hypothesis.dart';
import 'package:ibiti_guardian/services/ibiti/models/postmortem_entry.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

const _log = GuardianLogger('IbitiMemory');

class IbitiMemory {
  IbitiMemory._();
  static final IbitiMemory instance = IbitiMemory._();

  // ── Database reference ──────────────────────────────────────────────────────
  IbitiDatabase get _db => IbitiDatabase.instance;

  // ── Capacity limits ─────────────────────────────────────────────────────────
  static const _maxShortTermEvents = 50;
  static const _maxShortTermDecisions = 30;
  static const _maxDecisionHistory = 200;
  static const _maxPostmortems = 100;
  static const _maxLessons = 100;
  static const _maxPhaseHistory = 20;

  // ── Layer 1: Short-term (RAM) ───────────────────────────────────────────────
  final List<MarketEvent> recentEvents = [];
  final List<IbitiDecision> recentDecisions = [];

  // ── Layer 2: Token profiles (persistent) ────────────────────────────────────
  final Map<String, TokenProfile> tokenProfiles = {};

  // ── Layer 3: Exchange profiles (persistent) ─────────────────────────────────
  final Map<String, ExchangeProfile> exchangeProfiles = {};

  // ── Layer 4: Pattern lessons (persistent) ────────────────────────────────────
  final List<PatternLesson> lessons = [];

  // ── Layer 5: Decision history (persistent) ───────────────────────────────────
  final List<IbitiDecision> decisionHistory = [];

  // ── Layer 6: Postmortem history (persistent) ─────────────────────────────────
  final List<PostmortemEntry> postmortems = [];

  // ── Layer 7: Market phase memory (RAM) ───────────────────────────────────────
  MarketPhaseSnapshot? currentPhase;
  final List<MarketPhaseSnapshot> phaseHistory = [];

  // ── Event tracking for Constitution ─────────────────────────────────────────
  /// exchange:symbol → list of recent event timestamps (for anti-noise rule).
  final Map<String, List<DateTime>> recentEventTimes = {};

  /// When the last loss occurred (for revenge cooldown).
  DateTime? lastLossAt;

  bool _loaded = false;
  bool get isLoaded => _loaded;

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Record a new market event.
  void recordEvent(MarketEvent event) {
    recentEvents.add(event);
    if (recentEvents.length > _maxShortTermEvents) {
      recentEvents.removeAt(0);
    }

    // Track event times per exchange:symbol for Constitution anti-noise rule.
    final noiseKey = '${event.exchange}:${event.symbol}';
    recentEventTimes.putIfAbsent(noiseKey, () => []).add(event.timestamp);

    // Clean old timestamps (>1 hour).
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    recentEventTimes[noiseKey]?.removeWhere((t) => t.isBefore(cutoff));

    // Queue for batch DB write (flushed every 5s).
    if (_db.isOpen) _db.queueEvent(event);
  }

  /// Record a decision. Returns SQLite row id (null if DB write failed).
  Future<int?> recordDecision(IbitiDecision decision) async {
    // Short-term.
    recentDecisions.add(decision);
    if (recentDecisions.length > _maxShortTermDecisions) {
      recentDecisions.removeAt(0);
    }

    // History (persistent).
    decisionHistory.add(decision);
    if (decisionHistory.length > _maxDecisionHistory) {
      decisionHistory.removeAt(0);
    }

    // Update token profile.
    final profile = profileFor(decision.event.exchange, decision.event.symbol);
    profile.recordSeen(
      price: decision.priceAtDecision,
      reason: decision.reason,
    );
    switch (decision.verdict) {
      case IbitiVerdict.watch:
        profile.timesWatched++;
        break;
      case IbitiVerdict.reject:
        profile.timesRejected++;
        break;
      case IbitiVerdict.buy:
        profile.timesActed++;
        break;
      case IbitiVerdict.wouldBuy:
        profile.timesWouldBuy++;
        break;
      case IbitiVerdict.askUser:
        break;
    }

    // Update exchange profile.
    final exProfile = exchangeProfileFor(decision.event.exchange);
    exProfile.totalEvents++;
    exProfile.lastUpdated = DateTime.now();

    // Persist to SQLite.
    int? decisionDbId;
    if (_db.isOpen) {
      try {
        decisionDbId = await _db.insertDecision(decision);
      } catch (e) {
        _log.e('DB insertDecision failed', e);
      }
      unawaited(_db
          .upsertTokenProfile(profile)
          .catchError((e) => _log.e('DB upsertTokenProfile failed', e)));
      unawaited(_db
          .upsertExchangeProfile(exProfile)
          .catchError((e) => _log.e('DB upsertExchangeProfile failed', e)));
    }
    return decisionDbId;
  }

  /// Record a postmortem.
  void recordPostmortem(PostmortemEntry entry) {
    postmortems.add(entry);
    if (postmortems.length > _maxPostmortems) {
      postmortems.removeAt(0);
    }
    // Persist immediately.
    if (_db.isOpen) {
      unawaited(_db.insertPostmortem(entry).catchError((Object e) {
        _log.e('DB insertPostmortem failed', e);
        return -1;
      }));
    }
  }

  /// Add a learned lesson.
  /// Deduplicates: if a lesson with the same symbol + pattern prefix exists
  /// and was confirmed within the last 60 minutes, we confirm() the existing
  /// lesson instead of adding a duplicate. This prevents 20 identical
  /// "missed_opportunity_billusdt" lessons from flooding memory.
  void addLesson(PatternLesson lesson) {
    // ── Dedupe check ──
    // Pattern format: "missed_opportunity_billusdt", "bad_entry_chipusdt", etc.
    // Extract prefix (everything before the last "_timestamp" segment).
    final patternBase = lesson.pattern.contains('_')
        ? lesson.pattern.substring(0, lesson.pattern.lastIndexOf('_'))
        : lesson.pattern;

    final existing = lessons.cast<PatternLesson?>().firstWhere(
      (l) {
        if (l == null) return false;
        final lBase = l.pattern.contains('_')
            ? l.pattern.substring(0, l.pattern.lastIndexOf('_'))
            : l.pattern;
        return lBase == patternBase &&
            l.symbol == lesson.symbol &&
            DateTime.now().difference(l.lastConfirmedAt).inMinutes < 60;
      },
      orElse: () => null,
    );

    if (existing != null) {
      // Merge: strengthen existing lesson instead of adding duplicate.
      existing.confirm();
      if (_db.isOpen) {
        unawaited(_db
            .upsertLesson(existing)
            .catchError((e) => _log.e('DB upsertLesson (merge) failed', e)));
      }
      return;
    }

    lessons.add(lesson);
    // If over capacity, remove the lesson with weakest effective weight.
    if (lessons.length > _maxLessons) {
      lessons.sort(
          (a, b) => a.effectiveWeight.abs().compareTo(b.effectiveWeight.abs()));
      lessons.removeAt(0); // Remove weakest.
    }
    // Persist immediately.
    if (_db.isOpen) {
      unawaited(_db
          .upsertLesson(lesson)
          .catchError((e) => _log.e('DB upsertLesson failed', e)));
    }
  }

  /// Update market phase.
  void updatePhase(MarketPhaseSnapshot snapshot) {
    currentPhase = snapshot;
    phaseHistory.add(snapshot);
    if (phaseHistory.length > _maxPhaseHistory) {
      phaseHistory.removeAt(0);
    }
  }

  /// Get or create token profile (keyed by exchange:symbol).
  TokenProfile profileFor(String exchange, String symbol) {
    final key = TokenProfile.buildKey(exchange, symbol);
    return tokenProfiles.putIfAbsent(
        key, () => TokenProfile(exchange: exchange, symbol: symbol));
  }

  /// Get or create exchange profile.
  ExchangeProfile exchangeProfileFor(String exchange) {
    return exchangeProfiles.putIfAbsent(exchange.toLowerCase(),
        () => ExchangeProfile(exchange: exchange.toLowerCase()));
  }

  /// Get relevant lessons for a symbol and event type.
  List<PatternLesson> relevantLessons({
    String? symbol,
    MarketEventType? eventType,
  }) {
    return lessons.where((l) {
      if (symbol != null && l.symbol != null && l.symbol != symbol) {
        return false;
      }
      if (eventType != null &&
          l.relatedEventType != null &&
          l.relatedEventType != eventType) {
        return false;
      }
      return true;
    }).toList();
  }

  /// Pending postmortems that need price checks.
  List<PostmortemEntry> get pendingPostmortems =>
      postmortems.where((p) => !p.isComplete).toList();

  // ── Persistence (SQLite via IbitiDatabase) ──────────────────────────────────

  /// Load all persistent layers from SQLite.
  Future<void> load() async {
    try {
      // Load from SQLite.
      final dbProfiles = await _db.loadAllTokenProfiles();
      tokenProfiles.addAll(dbProfiles);

      final dbExchanges = await _db.loadAllExchangeProfiles();
      exchangeProfiles.addAll(dbExchanges);

      final dbLessons = await _db.loadAllLessons();
      lessons.addAll(dbLessons);

      final dbPostmortems = await _db.loadPendingPostmortems();
      postmortems.addAll(dbPostmortems);

      _loaded = true;
      _log.i('Memory loaded: ${tokenProfiles.length} tokens, '
          '${exchangeProfiles.length} exchanges, '
          '${lessons.length} lessons, '
          '${postmortems.length} postmortems (source: SQLite)');
    } catch (e) {
      _log.e('Memory load failed', e);
      _loaded = true; // Continue with empty memory.
    }
  }

  /// Flush any pending writes. Called by IbitiLoop.stop().
  Future<void> save() async {
    try {
      if (!_db.isOpen) return;
      // Flush batch event queue.
      await _db.flushEventQueue();
      // Persist all current profiles (in case RAM was updated without DB sync).
      for (final tp in tokenProfiles.values) {
        await _db.upsertTokenProfile(tp);
      }
      for (final ep in exchangeProfiles.values) {
        await _db.upsertExchangeProfile(ep);
      }
      _log.d('Memory flushed to SQLite');
    } catch (e) {
      _log.e('Memory flush failed', e);
    }
  }

  // ── Dev / Debug ──────────────────────────────────────────────────────────────

  /// One-time reset of all IBITI learning memory.
  /// Clears SQLite tables + RAM state.
  /// Does NOT touch wallets, Privy, user settings, billing, alerts, etc.
  ///
  /// Usage: call once before a clean test run, then remove the call.
  Future<void> clearLearningMemoryForDebug() async {
    // RAM.
    recentEvents.clear();
    recentDecisions.clear();
    tokenProfiles.clear();
    exchangeProfiles.clear();
    lessons.clear();
    decisionHistory.clear();
    postmortems.clear();
    recentEventTimes.clear();
    currentPhase = null;
    phaseHistory.clear();
    lastLossAt = null;

    // SQLite.
    if (_db.isOpen) await _db.clearAll();

    _log.i('🧹 IBITI learning memory CLEARED. Fresh start.');
  }
}
