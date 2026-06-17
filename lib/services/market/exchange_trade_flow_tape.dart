import 'dart:async';
import 'dart:collection';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

const _log = GuardianLogger('TradeFlowTape');

/// Identifies the source of a trade print.
enum TradeSource { ws, rest }

/// Represents a single matched trade on an exchange.
class TradePrint {
  final String exchange;
  final String symbol;
  final DateTime timestamp;
  final double price;
  final double baseQty;
  final double quoteUsd;

  /// 'buy', 'sell', or 'unknown'
  final String side;
  final TradeSource source;

  /// Confidence is high if exact taker side is known, low if inferred/unknown.
  final String confidence;

  const TradePrint({
    required this.exchange,
    required this.symbol,
    required this.timestamp,
    required this.price,
    required this.baseQty,
    required this.quoteUsd,
    required this.side,
    required this.source,
    required this.confidence,
  });

  bool get isBuy => side == 'buy';
  bool get isSell => side == 'sell';
}

enum CapitalImpactVerdict {
  realDemand,
  weakDemand,
  sellerPressure,
  absorption,
  liquidityTrap,
  lowData,
}

class FlowWindowSnapshot {
  final String exchange;
  final String symbol;
  final Duration window;

  final double buyTokens;
  final double sellTokens;
  final double buyUsd;
  final double sellUsd;

  final double priceStart;
  final double priceEnd;
  final int printCount;

  const FlowWindowSnapshot({
    required this.exchange,
    required this.symbol,
    required this.window,
    required this.buyTokens,
    required this.sellTokens,
    required this.buyUsd,
    required this.sellUsd,
    required this.priceStart,
    required this.priceEnd,
    required this.printCount,
  });

  double get totalFlowUsd => buyUsd + sellUsd;
  double get netFlowUsd => buyUsd - sellUsd;

  double get buyPressure {
    final total = totalFlowUsd;
    if (total <= 0) return 0.0;
    return buyUsd / total;
  }

  double get priceChangePct {
    if (priceStart <= 0) return 0.0;
    return ((priceEnd - priceStart) / priceStart) * 100.0;
  }

  String get confidence {
    // If not enough prints or volume, confidence is low
    if (printCount < 10 || totalFlowUsd < 1000) return 'low';
    return 'high';
  }

  // Impact metrics
  double get inflowImpact {
    if (buyUsd <= 0) return 0.0;
    if (priceChangePct > 0) {
      return priceChangePct / buyUsd;
    }
    return 0.0;
  }

  double get outflowDamage {
    if (sellUsd <= 0) return 0.0;
    if (priceChangePct < 0) {
      return priceChangePct.abs() / sellUsd;
    }
    return 0.0;
  }

  double get usdPer1PctUp {
    if (priceChangePct > 0 && buyUsd > 0) {
      return buyUsd / priceChangePct;
    }
    return 0.0;
  }

  double get usdPer1PctDown {
    if (priceChangePct < 0 && sellUsd > 0) {
      return sellUsd / priceChangePct.abs();
    }
    return 0.0;
  }

  double get absorptionScore {
    // High net flow, low price move -> trapped buyers or absorbed sellers
    if (priceChangePct.abs() < 0.1 && totalFlowUsd > 10000) {
      return buyPressure > 0.5 ? buyUsd : sellUsd; // basic score for now
    }
    return 0.0;
  }

  double get sellerPressureScore {
    // High sell flow, negative price move
    if (priceChangePct < 0 && sellUsd > 0) {
      return sellUsd * priceChangePct.abs();
    }
    return 0.0;
  }

  CapitalImpactVerdict get verdict {
    if (confidence == 'low') return CapitalImpactVerdict.lowData;

    if (buyPressure > 0.6 && priceChangePct > 0.5)
      return CapitalImpactVerdict.realDemand;
    if (buyPressure > 0.6 && priceChangePct <= 0.1)
      return CapitalImpactVerdict.absorption; // Buyers absorbed

    if (buyPressure < 0.4 && priceChangePct < -0.5)
      return CapitalImpactVerdict.sellerPressure;
    if (buyPressure < 0.4 && priceChangePct >= -0.1)
      return CapitalImpactVerdict.absorption; // Sellers absorbed

    // Low total flow but big price drop -> liquidity trap/vacuum
    if (totalFlowUsd < 5000 && priceChangePct < -1.0)
      return CapitalImpactVerdict.liquidityTrap;

    // High flow, weak price move
    if (usdPer1PctUp > 50000 && priceChangePct < 0.5)
      return CapitalImpactVerdict.weakDemand;

    return CapitalImpactVerdict.lowData;
  }
}

/// The main Exchange Trade Flow Tape.
/// Consumes real-time WS/REST trades from all exchanges and aggregates flow.
class ExchangeTradeFlowTape {
  ExchangeTradeFlowTape._();
  static final ExchangeTradeFlowTape instance = ExchangeTradeFlowTape._();

  // symbol key -> list of prints (kept for at least 60m)
  // key: exchange:symbol
  final Map<String, Queue<TradePrint>> _prints = {};

  // Health counters
  final Map<String, int> _printsByExchange = {};
  final Map<String, Set<String>> _symbolsByExchange = {};
  final Map<String, DateTime> _lastPrintAtByExchange = {};

  Timer? _logTimer;
  Timer? _cleanupTimer;

  void start() {
    _logTimer?.cancel();
    _cleanupTimer?.cancel();

    _logTimer = Timer.periodic(const Duration(minutes: 1), (_) => _logFlows());
    // Cleanup every 5 minutes
    _cleanupTimer =
        Timer.periodic(const Duration(minutes: 5), (_) => _cleanupOldPrints());
  }

  void stop() {
    _logTimer?.cancel();
    _cleanupTimer?.cancel();
    _prints.clear();
  }

  void processPrint(TradePrint p) {
    final key = '${p.exchange}:${p.symbol}';
    _prints.putIfAbsent(key, () => Queue<TradePrint>());
    _prints[key]!.addLast(p);

    _printsByExchange[p.exchange] = (_printsByExchange[p.exchange] ?? 0) + 1;
    _symbolsByExchange.putIfAbsent(p.exchange, () => {}).add(p.symbol);
    _lastPrintAtByExchange[p.exchange] = p.timestamp;
  }

  void _cleanupOldPrints() {
    // Keep prints for at least 65 minutes to safely query 60m windows
    final cutoff = DateTime.now().subtract(const Duration(minutes: 65));
    for (final queue in _prints.values) {
      while (queue.isNotEmpty && queue.first.timestamp.isBefore(cutoff)) {
        queue.removeFirst();
      }
    }
  }

  /// All known exchange:symbol keys that have flow data.
  Iterable<String> get knownKeys => _prints.keys;

  /// Public API to get rolling flow window
  FlowWindowSnapshot? getFlow(String exchange, String symbol, Duration window) {
    final key = '$exchange:$symbol';
    final queue = _prints[key];
    if (queue == null || queue.isEmpty) return null;

    final cutoff = DateTime.now().subtract(window);

    double buyTokens = 0.0;
    double sellTokens = 0.0;
    double buyUsd = 0.0;
    double sellUsd = 0.0;
    double priceStart = 0.0;
    double priceEnd = 0.0;
    int printCount = 0;

    // prints are ordered by time, oldest first
    for (final p in queue) {
      if (p.timestamp.isAfter(cutoff) || p.timestamp.isAtSameMomentAs(cutoff)) {
        if (printCount == 0) {
          priceStart = p.price;
        }
        priceEnd = p.price;
        printCount++;

        if (p.isBuy) {
          buyTokens += p.baseQty;
          buyUsd += p.quoteUsd;
        } else if (p.isSell) {
          sellTokens += p.baseQty;
          sellUsd += p.quoteUsd;
        }
      }
    }

    if (printCount == 0) return null;

    return FlowWindowSnapshot(
      exchange: exchange,
      symbol: symbol,
      window: window,
      buyTokens: buyTokens,
      sellTokens: sellTokens,
      buyUsd: buyUsd,
      sellUsd: sellUsd,
      priceStart: priceStart,
      priceEnd: priceEnd,
      printCount: printCount,
    );
  }

  void _logFlows() {
    // 1. Log Health summary (always — single line)
    final bP = _printsByExchange['binance'] ?? 0;
    final bS = _symbolsByExchange['binance']?.length ?? 0;
    final byP = _printsByExchange['bybit'] ?? 0;
    final byS = _symbolsByExchange['bybit']?.length ?? 0;
    final gP = _printsByExchange['gateio'] ?? 0;
    final gS = _symbolsByExchange['gateio']?.length ?? 0;
    final mP = _printsByExchange['mexc'] ?? 0;
    final mS = _symbolsByExchange['mexc']?.length ?? 0;

    _log.i('[TRADE_FLOW_HEALTH]\n'
        '  binance prints=$bP symbols=$bS\n'
        '  bybit prints=$byP symbols=$byS\n'
        '  gateio prints=$gP symbols=$gS\n'
        '  mexc prints=$mP symbols=$mS');

    // 2. Log ONLY actionable flow signals (non-lowData verdicts).
    //    Previously logged ALL keys (5000+) causing 8s ANR.
    //    Capped at 50 entries to prevent log spam.
    final keys = _prints.keys.toList();
    int logged = 0;
    for (final key in keys) {
      if (logged >= 50) break; // hard cap
      final parts = key.split(':');
      if (parts.length != 2) continue;
      final exchange = parts[0];
      final symbol = parts[1];

      final w5m = getFlow(exchange, symbol, const Duration(minutes: 5));
      if (w5m == null || w5m.printCount == 0 || w5m.totalFlowUsd <= 100) {
        continue;
      }

      // Skip lowData — it's 95%+ of all entries and not actionable
      if (w5m.verdict == CapitalImpactVerdict.lowData ||
          w5m.verdict == CapitalImpactVerdict.weakDemand) {
        continue;
      }

      // Suppress absorption logs with near-zero price change (market breathing noise)
      if (w5m.verdict == CapitalImpactVerdict.absorption &&
          w5m.priceChangePct.abs() < 0.15) {
        continue;
      }

      // Suppress low-flow/no-price-change logs
      if (w5m.totalFlowUsd < 5000 && w5m.priceChangePct.abs() < 0.15) {
        continue;
      }

      _log.d('[EXCHANGE_TRADE_FLOW]\n'
          'exchange=${w5m.exchange}\n'
          'symbol=${w5m.symbol}\n'
          'window=5m\n'
          'buyUsd=${w5m.buyUsd.toStringAsFixed(2)}\n'
          'sellUsd=${w5m.sellUsd.toStringAsFixed(2)}\n'
          'buyPressure=${w5m.buyPressure.toStringAsFixed(2)}\n'
          'priceChange=${w5m.priceChangePct.toStringAsFixed(2)}%\n'
          'usdPer1PctUp=${w5m.usdPer1PctUp.toStringAsFixed(2)}\n'
          'usdPer1PctDown=${w5m.usdPer1PctDown.toStringAsFixed(2)}\n'
          'verdict=${w5m.verdict.name}');
      logged++;
    }
  }
}
