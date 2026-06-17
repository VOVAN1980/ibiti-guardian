import 'dart:collection';
import 'package:ibiti_guardian/services/market/market_live_engine.dart';
import 'package:ibiti_guardian/services/ibiti/models/market_phase.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

const _log = GuardianLogger('Cardiogram');

class _QuoteDeltaRingBuffer {
  final DoubleLinkedQueue<double> _deltas = DoubleLinkedQueue<double>();
  final int capacity;

  _QuoteDeltaRingBuffer(this.capacity);

  void add(double delta) {
    _deltas.addLast(delta);
    if (_deltas.length > capacity) {
      _deltas.removeFirst();
    }
  }

  double sumInflow(int lastN) {
    int count = 0;
    double sum = 0.0;
    for (final d in _deltas.toList().reversed) {
      if (count >= lastN) break;
      if (d > 0) sum += d;
      count++;
    }
    return sum;
  }

  double sumOutflow(int lastN) {
    int count = 0;
    double sum = 0.0;
    for (final d in _deltas.toList().reversed) {
      if (count >= lastN) break;
      if (d < 0) sum += d.abs();
      count++;
    }
    return sum;
  }
}

class MarketCardiogramService {
  MarketCardiogramService._();
  static final MarketCardiogramService instance = MarketCardiogramService._();

  MarketCardiogramSnapshot _current = MarketCardiogramSnapshot.empty;
  MarketCardiogramSnapshot get current => _current;

  MarketPhase get mappedPhase => _current.mappedPhase;
  MarketHeartbeat get heartbeat => _current.heartbeat;

  final Map<String, _QuoteDeltaRingBuffer> _buffers = {};
  final Map<String, double> _lastQuoteVolumes = {};

  static const int _capacity = 120; // 60 minutes with 30s ticks

  static final Set<String> _major = {
    'BTC',
    'ETH',
    'BNB',
    'SOL',
    'XRP',
    'DOGE',
    'ADA',
    'AVAX',
    'LINK',
    'DOT',
    'TRX',
    'TON',
    'SUI'
  };
  static final Set<String> _meme = {
    'DOGE',
    'SHIB',
    'PEPE',
    'BONK',
    'FLOKI',
    'WIF',
    'MEME',
    'TURBO',
    'MOG',
    'BOME',
    'NEIRO',
    'PNUT'
  };
  static final Set<String> _ai = {
    'FET',
    'AGIX',
    'OCEAN',
    'WLD',
    'TAO',
    'AI',
    'AIXBT',
    'VIRTUAL',
    'GRIFFAIN'
  };
  static final Set<String> _defi = {
    'UNI',
    'AAVE',
    'CRV',
    'COMP',
    'MKR',
    'SNX',
    'CAKE',
    'JUP',
    'RAY',
    'DYDX'
  };
  static final Set<String> _gaming = {
    'AXS',
    'SAND',
    'MANA',
    'GALA',
    'ILV',
    'YGG',
    'PIXEL'
  };

  String _getSector(String baseAsset, bool isNewListing) {
    if (isNewListing) return 'newListing';
    if (_major.contains(baseAsset)) return 'major';
    if (_meme.contains(baseAsset)) return 'meme';
    if (_ai.contains(baseAsset)) return 'ai';
    if (_defi.contains(baseAsset)) return 'defi';
    if (_gaming.contains(baseAsset)) return 'gaming';
    return 'otherAlt';
  }

  MarketCardiogramSnapshot update() {
    final snapshots = MarketLiveEngine.instance.snapshotAll();

    int greenCount = 0;
    int topCount = 0;
    double btc24h = 0;
    double eth24h = 0;

    double flow1m = 0;
    double flow5m = 0;
    double flow15m = 0;
    double flow60m = 0;

    double out5m = 0;

    final Map<String, double> sectorFlow5m = {};
    double totalSectorFlow5m = 0;

    for (final entry in snapshots.entries) {
      final key = entry.key;
      final s = entry.value;

      if (s.symbol == 'BTCUSDT' || s.symbol == 'BTC-USDT')
        btc24h = s.priceChangePercent24h;
      if (s.symbol == 'ETHUSDT' || s.symbol == 'ETH-USDT')
        eth24h = s.priceChangePercent24h;

      if (s.quoteVolume24h > 10000000) {
        topCount++;
        if (s.priceChangePercent24h > 0) greenCount++;
      }

      final lastQv = _lastQuoteVolumes[key] ?? s.quoteVolume24h;
      double delta = s.quoteVolume24h - lastQv;
      if (delta < 0 || delta > s.quoteVolume24h * 0.1)
        delta = 0; // reset/anomaly
      _lastQuoteVolumes[key] = s.quoteVolume24h;

      // Ensure buffer exists
      final buffer =
          _buffers.putIfAbsent(key, () => _QuoteDeltaRingBuffer(_capacity));
      buffer.add(delta *
          (s.priceChangePercent24h > 0 ? 1 : -1)); // rough direction proxy

      final in1 = buffer.sumInflow(2);
      final in5 = buffer.sumInflow(10);
      final in15 = buffer.sumInflow(30);
      final in60 = buffer.sumInflow(120);

      final o5 = buffer.sumOutflow(10);

      flow1m += in1;
      flow5m += in5;
      flow15m += in15;
      flow60m += in60;

      out5m += o5;

      final baseAsset = s.symbol.replaceAll('USDT', '').replaceAll('-USDT', '');
      final isNewListing = s.isNewlyListed || (s.daysListed ?? 99) <= 3;
      final sector = _getSector(baseAsset, isNewListing);

      sectorFlow5m[sector] = (sectorFlow5m[sector] ?? 0) + in5;
      totalSectorFlow5m += in5;
    }

    final breadth = topCount > 0 ? greenCount / topCount : 0.5;
    final accel = flow15m > 0 ? (flow5m * 3) / flow15m : 1.0;

    String leadingSector = 'unknown';
    double maxSectorShare = 0;
    double topCoinShare = 0;
    double altShare = 0;
    double memeShare = 0;
    double newListingShare = 0;

    if (totalSectorFlow5m > 0) {
      topCoinShare = (sectorFlow5m['major'] ?? 0) / totalSectorFlow5m;
      altShare = 1.0 - topCoinShare;
      memeShare = (sectorFlow5m['meme'] ?? 0) / totalSectorFlow5m;
      newListingShare = (sectorFlow5m['newListing'] ?? 0) / totalSectorFlow5m;

      for (final entry in sectorFlow5m.entries) {
        if (entry.key != 'major' && entry.key != 'otherAlt') {
          final share = entry.value / totalSectorFlow5m;
          if (share > maxSectorShare) {
            maxSectorShare = share;
            leadingSector = entry.key;
          }
        }
      }
    }

    final dumpPressure = out5m > 0 && flow5m > 0 ? out5m / flow5m : 0.0;

    // Determine heartbeat
    MarketHeartbeat hb = MarketHeartbeat.unknown;

    final avgMajor = (btc24h + eth24h) / 2;

    if ((avgMajor < -5 || breadth < 0.25) &&
        dumpPressure > 1.5 &&
        accel < 0.8) {
      hb = MarketHeartbeat.panicDump;
    } else if (flow60m > 10000000 &&
        accel < 0.8 &&
        breadth < 0.45 &&
        dumpPressure > 1.2) {
      hb = MarketHeartbeat.distribution;
    } else if (newListingShare > 0.4 && totalSectorFlow5m > 5000000) {
      hb = MarketHeartbeat.listingMania;
    } else if (maxSectorShare > 0.5 &&
        altShare > 0.6 &&
        totalSectorFlow5m > 5000000) {
      hb = MarketHeartbeat.rotation;
    } else if (accel > 1.2 &&
        flow5m > 5000000 &&
        flow15m > 15000000 &&
        breadth > 0.55 &&
        dumpPressure < 1.0) {
      hb = MarketHeartbeat.acceleration;
    } else if (accel > 1.5 && flow5m > 2000000 && breadth >= 0.45) {
      hb = MarketHeartbeat.earlyInflow;
    } else if (flow60m > 20000000 &&
        accel >= 0.8 &&
        accel <= 1.2 &&
        breadth > 0.48 &&
        dumpPressure < 1.0) {
      hb = MarketHeartbeat.accumulation;
    } else if (flow15m < 5000000 &&
        breadth > 0.40 &&
        breadth < 0.60 &&
        accel < 1.1) {
      hb = MarketHeartbeat.deadChop;
    }

    // Map to old Phase
    MarketPhase mapped = MarketPhase.sideways;
    switch (hb) {
      case MarketHeartbeat.accumulation:
        mapped = MarketPhase.sideways;
        break;
      case MarketHeartbeat.earlyInflow:
        mapped = MarketPhase.bull;
        break;
      case MarketHeartbeat.acceleration:
        mapped = MarketPhase.bull;
        break;
      case MarketHeartbeat.distribution:
        mapped = MarketPhase.exhaustion;
        break;
      case MarketHeartbeat.panicDump:
        mapped = MarketPhase.bear;
        break;
      case MarketHeartbeat.deadChop:
        mapped = MarketPhase.sideways;
        break;
      case MarketHeartbeat.rotation:
        mapped = MarketPhase.volatile;
        break;
      case MarketHeartbeat.listingMania:
        mapped = MarketPhase.volatile;
        break;
      case MarketHeartbeat.unknown:
        mapped = _current.mappedPhase;
        break;
    }

    _current = MarketCardiogramSnapshot(
      heartbeat: hb,
      mappedPhase: mapped,
      flow1mUsd: flow1m,
      flow5mUsd: flow5m,
      flow15mUsd: flow15m,
      flow60mUsd: flow60m,
      flowAcceleration5m: accel,
      marketBreadth: breadth,
      btcChange24h: btc24h,
      ethChange24h: eth24h,
      topCoinFlowShare: topCoinShare,
      altFlowShare: altShare,
      memeFlowShare: memeShare,
      newListingFlowShare: newListingShare,
      leadingSector: leadingSector,
      rotationScore: maxSectorShare,
      dumpPressure: dumpPressure,
      liquidityExpansion: flow60m > 0 ? flow15m / (flow60m / 4) : 1.0,
      activeTickers: snapshots.length,
      timestamp: DateTime.now(),
    );

    return _current;
  }
}
