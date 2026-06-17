// ─── Macro Sensor Service ────────────────────────────────────────────────────
//
// JARVIS "far vision" — external macro market context.
// Gives JARVIS the ability to understand the broader market battlefield,
// not just the single pair in front of it.
//
// Sources (all free, no API key required):
//   1. Fear & Greed Index — alternative.me/fng
//   2. CoinGecko Global   — coingecko.com/api/v3/global
//      → BTC dominance, total market cap, altcoin market cap, active coins
//
// Design rules:
//   • This is a SENSOR LAYER, not a gate. No hard blocks.
//   • JARVIS reads this as context. It learns from it. It does not use it
//     to block trades directly — that would create a new cage.
//   • TTL: 30 minutes. API rarely changes faster than that.
//   • On any API error → MacroSnapshot.unknown. No crash, no block.
//   • No UI. No execution. Read-only sensor.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/utils/guardian_logger.dart';

const _log = GuardianLogger('MacroSensor');

// ── Data Model ────────────────────────────────────────────────────────────────

/// Macro market sentiment classification.
enum FearGreedLabel {
  extremeFear,  // 0–24
  fear,         // 25–44
  neutral,      // 45–55
  greed,        // 56–75
  extremeGreed, // 76–100
  unknown,
}

extension FearGreedLabelExt on FearGreedLabel {
  String get display => switch (this) {
    FearGreedLabel.extremeFear  => 'Extreme Fear',
    FearGreedLabel.fear         => 'Fear',
    FearGreedLabel.neutral      => 'Neutral',
    FearGreedLabel.greed        => 'Greed',
    FearGreedLabel.extremeGreed => 'Extreme Greed',
    FearGreedLabel.unknown      => 'Unknown',
  };

  /// Whether this reading suggests market is oversold / good to buy dips.
  bool get isOpportunityZone =>
      this == FearGreedLabel.extremeFear || this == FearGreedLabel.fear;

  /// Whether this reading suggests market is overheated / take profits.
  bool get isOverheatedZone =>
      this == FearGreedLabel.extremeGreed || this == FearGreedLabel.greed;
}

/// Altcoin season classification based on BTC dominance.
enum AltcoinRegime {
  btcSeason,    // BTC dominance > 60% — money flowing into BTC, alts suffer
  mixed,        // 50–60% — balanced
  altSeason,    // < 50% — alts outperforming, rotate freely
  unknown,
}

extension AltcoinRegimeExt on AltcoinRegime {
  String get display => switch (this) {
    AltcoinRegime.btcSeason  => 'BTC Season',
    AltcoinRegime.mixed      => 'Mixed',
    AltcoinRegime.altSeason  => 'Alt Season',
    AltcoinRegime.unknown    => 'Unknown',
  };

  bool get favoursAlts => this == AltcoinRegime.altSeason || this == AltcoinRegime.mixed;
}

/// Complete macro context snapshot.
/// All fields have safe defaults — never null.
class MacroSnapshot {
  // ── Fear & Greed ──
  final int fearGreedValue;         // 0–100, -1 if unknown
  final FearGreedLabel fearGreed;
  final String fearGreedLastUpdate; // ISO8601 or 'unknown'

  // ── CoinGecko Global ──
  final double btcDominancePct;     // e.g. 54.3
  final double ethDominancePct;     // e.g. 16.1
  final double totalMarketCapUsd;   // e.g. 2_400_000_000_000
  final double totalMarketCap24hChangePct; // e.g. -3.2
  final int activeCryptos;          // e.g. 15000
  final AltcoinRegime altcoinRegime;

  // ── Meta ──
  final DateTime fetchedAt;
  final bool isStale; // true if data could not be refreshed
  final String errorNote; // empty if OK

  const MacroSnapshot({
    this.fearGreedValue = -1,
    this.fearGreed = FearGreedLabel.unknown,
    this.fearGreedLastUpdate = 'unknown',
    this.btcDominancePct = 0,
    this.ethDominancePct = 0,
    this.totalMarketCapUsd = 0,
    this.totalMarketCap24hChangePct = 0,
    this.activeCryptos = 0,
    this.altcoinRegime = AltcoinRegime.unknown,
    required this.fetchedAt,
    this.isStale = false,
    this.errorNote = '',
  });

  /// Safe unknown state — used when API fails.
  static MacroSnapshot get unknown => MacroSnapshot(
        fetchedAt: DateTime.now(),
        isStale: true,
        errorNote: 'no_data',
      );

  /// One-line log summary for JARVIS context prompt.
  String toContextLine() {
    if (isStale) return 'MacroContext: unknown (stale/error)';
    final mktCap = totalMarketCapUsd > 0
        ? '\$${(totalMarketCapUsd / 1e12).toStringAsFixed(2)}T'
        : 'unknown';
    return 'Fear&Greed=${fearGreedValue == -1 ? "?" : fearGreedValue}(${fearGreed.display}) | '
        'BTC_dom=${btcDominancePct.toStringAsFixed(1)}% | '
        'AltRegime=${altcoinRegime.display} | '
        'TotalMktCap=$mktCap(${totalMarketCap24hChangePct >= 0 ? '+' : ''}${totalMarketCap24hChangePct.toStringAsFixed(1)}% 24h)';
  }

  /// Multi-line context block for self-evolution prompt.
  String toPromptBlock() {
    if (isStale) {
      return '## Macro Market Context\nStatus: UNAVAILABLE (${errorNote.isEmpty ? 'stale' : errorNote})\n'
          'JARVIS: treat macro context as unknown, rely on local cardiogram only.\n';
    }
    final mktCap = totalMarketCapUsd > 0
        ? '\$${(totalMarketCapUsd / 1e12).toStringAsFixed(2)}T'
        : 'unknown';
    final buf = StringBuffer();
    buf.writeln('## Macro Market Context (External Sensors)');
    buf.writeln('Fear & Greed: $fearGreedValue/100 — ${fearGreed.display}');
    if (fearGreed.isOpportunityZone) {
      buf.writeln('  → Market in fear. Historically good to buy selectively.');
    } else if (fearGreed.isOverheatedZone) {
      buf.writeln('  → Market in greed. Caution: exits may reverse quickly.');
    }
    buf.writeln('BTC Dominance: ${btcDominancePct.toStringAsFixed(1)}% | ETH: ${ethDominancePct.toStringAsFixed(1)}%');
    buf.writeln('Altcoin Regime: ${altcoinRegime.display}');
    if (altcoinRegime == AltcoinRegime.btcSeason) {
      buf.writeln('  → BTC season: altcoins may bleed even if BTC is flat. Be selective.');
    } else if (altcoinRegime == AltcoinRegime.altSeason) {
      buf.writeln('  → Alt season: altcoins rotating broadly. Good environment for entries.');
    }
    buf.writeln('Total Crypto Market Cap: $mktCap (${totalMarketCap24hChangePct >= 0 ? '+' : ''}${totalMarketCap24hChangePct.toStringAsFixed(1)}% 24h)');
    buf.writeln('Active Cryptos: $activeCryptos');
    buf.writeln('Data age: ${DateTime.now().difference(fetchedAt).inMinutes}min');
    return buf.toString();
  }
}

// ── Service ───────────────────────────────────────────────────────────────────

class MacroSensorService {
  MacroSensorService._();
  static final MacroSensorService instance = MacroSensorService._();

  static const _ttl = Duration(minutes: 30);
  static const _fngUrl = 'https://api.alternative.me/fng/?limit=1&format=json';
  static const _geckoGlobalUrl = 'https://api.coingecko.com/api/v3/global';
  static const _timeout = Duration(seconds: 10);

  MacroSnapshot _snapshot = MacroSnapshot.unknown;
  DateTime? _lastFetch;
  bool _fetching = false;

  MacroSnapshot get current => _snapshot;

  bool get isStale => _snapshot.isStale;

  /// Returns cached snapshot. Triggers background refresh if TTL expired.
  /// Never blocks — always returns immediately.
  MacroSnapshot get() {
    final now = DateTime.now();
    final shouldRefresh = _lastFetch == null ||
        now.difference(_lastFetch!) > _ttl;

    if (shouldRefresh && !_fetching) {
      _refreshInBackground();
    }

    return _snapshot;
  }

  /// Force refresh now (e.g. on app start). Returns when done.
  Future<void> forceRefresh() => _doFetch();

  void _refreshInBackground() {
    _fetching = true;
    _doFetch().then((_) {
      _fetching = false;
    }).catchError((e) {
      _fetching = false;
      _log.w('[MACRO] Background refresh failed: $e');
    });
  }

  Future<void> _doFetch() async {
    _log.d('[MACRO] Fetching Fear&Greed + CoinGecko global...');
    final results = await Future.wait([
      _fetchFearGreed(),
      _fetchCoinGeckoGlobal(),
    ]);

    final fng = results[0] as _FngResult;
    final cg  = results[1] as _CgGlobalResult;

    final regime = _classifyAltcoinRegime(cg.btcDominancePct);

    _snapshot = MacroSnapshot(
      fearGreedValue: fng.value,
      fearGreed: _classifyFearGreed(fng.value),
      fearGreedLastUpdate: fng.lastUpdate,
      btcDominancePct: cg.btcDominancePct,
      ethDominancePct: cg.ethDominancePct,
      totalMarketCapUsd: cg.totalMarketCapUsd,
      totalMarketCap24hChangePct: cg.marketCap24hChangePct,
      activeCryptos: cg.activeCryptos,
      altcoinRegime: regime,
      fetchedAt: DateTime.now(),
      isStale: fng.error != null && cg.error != null,
      errorNote: [
        if (fng.error != null) 'fng:${fng.error}',
        if (cg.error != null) 'cg:${cg.error}',
      ].join(' '),
    );

    _lastFetch = DateTime.now();
    _log.i('[MACRO] ${_snapshot.toContextLine()}');
  }

  Future<_FngResult> _fetchFearGreed() async {
    try {
      final resp = await http
          .get(Uri.parse(_fngUrl))
          .timeout(_timeout);
      if (resp.statusCode != 200) {
        return _FngResult(error: 'http_${resp.statusCode}');
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = data['data'] as List?;
      if (items == null || items.isEmpty) {
        return _FngResult(error: 'empty_data');
      }
      final item = items.first as Map<String, dynamic>;
      final value = int.tryParse(item['value']?.toString() ?? '') ?? -1;
      final ts = item['timestamp']?.toString() ?? 'unknown';
      return _FngResult(value: value, lastUpdate: ts);
    } catch (e) {
      _log.w('[MACRO] Fear&Greed fetch error: $e');
      return _FngResult(error: e.toString().substring(0, e.toString().length.clamp(0, 60)));
    }
  }

  Future<_CgGlobalResult> _fetchCoinGeckoGlobal() async {
    try {
      final resp = await http
          .get(Uri.parse(_geckoGlobalUrl),
              headers: {'accept': 'application/json'})
          .timeout(_timeout);
      if (resp.statusCode == 429) {
        _log.w('[MACRO] CoinGecko rate limited (429) — using cached data');
        return _CgGlobalResult(error: 'rate_limited');
      }
      if (resp.statusCode != 200) {
        return _CgGlobalResult(error: 'http_${resp.statusCode}');
      }
      final raw = jsonDecode(resp.body) as Map<String, dynamic>;
      final data = raw['data'] as Map<String, dynamic>?;
      if (data == null) return _CgGlobalResult(error: 'no_data_key');

      final mcap = data['total_market_cap'] as Map<String, dynamic>?;
      final totalUsd = (mcap?['usd'] as num?)?.toDouble() ?? 0;

      final dom = data['market_cap_percentage'] as Map<String, dynamic>?;
      final btcDom = (dom?['btc'] as num?)?.toDouble() ?? 0;
      final ethDom = (dom?['eth'] as num?)?.toDouble() ?? 0;

      final change24h = (data['market_cap_change_percentage_24h_usd'] as num?)
              ?.toDouble() ?? 0;
      final active = (data['active_cryptocurrencies'] as num?)?.toInt() ?? 0;

      return _CgGlobalResult(
        btcDominancePct: btcDom,
        ethDominancePct: ethDom,
        totalMarketCapUsd: totalUsd,
        marketCap24hChangePct: change24h,
        activeCryptos: active,
      );
    } catch (e) {
      _log.w('[MACRO] CoinGecko global fetch error: $e');
      return _CgGlobalResult(error: e.toString().substring(0, e.toString().length.clamp(0, 60)));
    }
  }

  // ── Classification ────────────────────────────────────────────────────────

  static FearGreedLabel _classifyFearGreed(int value) {
    if (value < 0)   return FearGreedLabel.unknown;
    if (value <= 24) return FearGreedLabel.extremeFear;
    if (value <= 44) return FearGreedLabel.fear;
    if (value <= 55) return FearGreedLabel.neutral;
    if (value <= 75) return FearGreedLabel.greed;
    return FearGreedLabel.extremeGreed;
  }

  static AltcoinRegime _classifyAltcoinRegime(double btcDominance) {
    if (btcDominance <= 0) return AltcoinRegime.unknown;
    if (btcDominance >= 60) return AltcoinRegime.btcSeason;
    if (btcDominance >= 50) return AltcoinRegime.mixed;
    return AltcoinRegime.altSeason;
  }
}

// ── Private Result Types ──────────────────────────────────────────────────────

class _FngResult {
  final int value;
  final String lastUpdate;
  final String? error;
  const _FngResult({this.value = -1, this.lastUpdate = 'unknown', this.error});
}

class _CgGlobalResult {
  final double btcDominancePct;
  final double ethDominancePct;
  final double totalMarketCapUsd;
  final double marketCap24hChangePct;
  final int activeCryptos;
  final String? error;
  const _CgGlobalResult({
    this.btcDominancePct = 0,
    this.ethDominancePct = 0,
    this.totalMarketCapUsd = 0,
    this.marketCap24hChangePct = 0,
    this.activeCryptos = 0,
    this.error,
  });
}
