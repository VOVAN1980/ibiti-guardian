import 'package:ibiti_guardian/models/trading_plan.dart';

import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/market/market_scout_service.dart';

import 'package:ibiti_guardian/services/security/ai_control_service.dart';

/// Deterministic fast-path command handler.
///
/// Handles commands that can be resolved WITHOUT calling the LLM:
/// navigation, market queries, trading commands, panic, safe, capabilities.
///
/// Extracted from [GuardianAssistantService] as part of P3-1 decomposition.
/// Returns [AssistantResponse?] — null means "not handled, fall through to LLM".
class FastPathHandler {
  FastPathHandler._();

  // ── Known slang / alias map for asset matching ────────────────────────────
  static const _assetAliases = <String, String>{
    'биток': 'BTC',
    'биткоин': 'BTC',
    'bitcoin': 'BTC',
    'эфир': 'ETH',
    'эфириум': 'ETH',
    'ethereum': 'ETH',
    'бнб': 'BNB',
    'солана': 'SOL',
    'solana': 'SOL',
    'usdt': 'USDT',
    'тезер': 'USDT',
    'tether': 'USDT',
    'usdc': 'USDC',
    'юсдк': 'USDC',
    'busd': 'BUSD',
    'wbnb': 'WBNB',
    'ибити': 'IBITI',
    'ибитикоин': 'IBITI',
    'ibit': 'IBITI',
    'ibiti': 'IBITI',
  };

  /// Extracts a canonical token symbol if the input mentions a known asset.
  static String? extractAssetSymbol(String lower) {
    for (final entry in _assetAliases.entries) {
      if (lower.contains(entry.key)) return entry.value;
    }
    for (final sym in [
      'btc',
      'eth',
      'bnb',
      'sol',
      'ada',
      'dot',
      'matic',
      'arb'
    ]) {
      if (lower.contains(sym)) return sym.toUpperCase();
    }
    return null;
  }

  /// Returns true if the user is asking about market state / signals / analysis.
  static bool isMarketQuery(String lower) {
    if (lower.contains('что на рынке') ||
        lower.contains('обзор рынк') ||
        lower.contains('market overview')) {
      return true;
    }
    if (lower.contains('сигнал') || lower.contains('signal')) {
      return true;
    }
    if (lower.contains('возможност') || lower.contains('opportunity')) {
      return true;
    }
    if (lower.contains('посоветуй') ||
        lower.contains('рекомендац') ||
        lower.contains('recommend') ||
        lower.contains('совет')) {
      return true;
    }
    if (lower.contains('анализ рынк') || lower.contains('market analys')) {
      return true;
    }
    if (lower.contains('стратеги') || lower.contains('strategy')) return true;
    if (lower.contains('прогноз') || lower.contains('forecast')) return true;
    if (lower.contains('тренд') || lower.contains('trend')) return true;
    if ((lower.contains('что') ||
            lower.contains('как') ||
            lower.contains('what')) &&
        (lower.contains('купить') ||
            lower.contains('buy') ||
            lower.contains('продать') ||
            lower.contains('sell') ||
            lower.contains('инвестировать') ||
            lower.contains('invest'))) {
      return true;
    }
    return false;
  }

  /// Returns true if the user is giving a direct trading command.
  static bool isTradingCommand(String lower) {
    if (lower.contains('купи') ||
        lower.contains('куплю') ||
        lower.contains('покупай') ||
        lower.contains('покупк')) {
      return true;
    }
    if (lower.contains('buy') || lower.contains('purchase')) return true;
    if (lower.contains('продай') ||
        lower.contains('продать') ||
        lower.contains('продаж')) return true;
    if (lower.contains('sell')) return true;
    if (lower.contains('обменяй') || lower.contains('поменяй')) return true;
    if (lower.contains('вложи') || lower.contains('инвестир')) return true;
    if (lower.contains('invest')) return true;
    return false;
  }

  /// Derives the trading direction from user text.
  static TradingDirection extractTradingDirection(String lower) {
    if (lower.contains('продай') ||
        lower.contains('продать') ||
        lower.contains('продаж') ||
        lower.contains('sell')) {
      return TradingDirection.sell;
    }
    if (lower.contains('обменяй') ||
        lower.contains('поменяй') ||
        lower.contains('swap') ||
        lower.contains('обмен')) {
      return TradingDirection.swap;
    }
    return TradingDirection.buy;
  }

  /// Extracts a USD amount from user text.
  static double? extractAmount(String lower) {
    final dollarMatch =
        RegExp(r'\$\s*(\d+(?:\.\d+)?)|(\d+(?:\.\d+)?)\s*\$').firstMatch(lower);
    if (dollarMatch != null) {
      final val = dollarMatch.group(1) ?? dollarMatch.group(2);
      if (val != null) return double.tryParse(val);
    }
    final ruAmountMatch = RegExp(
      r'(?:на|за)\s+(\d+(?:\.\d+)?)\s*(?:долл|бакс|usd)?',
    ).firstMatch(lower);
    if (ruAmountMatch != null) {
      return double.tryParse(ruAmountMatch.group(1) ?? '');
    }
    final stableMatch =
        RegExp(r'(\d+(?:\.\d+)?)\s*(?:usdt|usdc|busd|dai)').firstMatch(lower);
    if (stableMatch != null) {
      return double.tryParse(stableMatch.group(1) ?? '');
    }
    return null;
  }

  /// Russian market status label for a given 24h change pct.
  static String marketStatusRu(double change24h) {
    if (change24h >= 6) return 'Прорыв';
    if (change24h >= 2) return 'Рост';
    if (change24h <= -6) return 'Обвал';
    if (change24h <= -2) return 'Коррекция';
    return 'Флэт';
  }

  /// Builds a market briefing from ranked signals.
  /// [short] = true: voice-friendly (~10 seconds speech).
  /// [short] = false: full chat message with prices, actions, thesis.
  static String buildMarketBriefing(
    List<MarketOpportunity> signals,
    String lang, {
    bool short = false,
  }) {
    if (signals.isEmpty) {
      final markets = MarketDataService.instance.cachedMarkets;
      final anchors = ['BTC', 'ETH', 'BNB'];
      final found = anchors
          .map((s) => markets.cast<MarketAsset?>().firstWhere(
              (a) => a!.symbol.toUpperCase() == s,
              orElse: () => null))
          .whereType<MarketAsset>()
          .toList();
      if (found.isEmpty) {
        return lang == 'ru'
            ? 'Рыночные данные загружаются.'
            : 'Market data is loading.';
      }
      final buf = StringBuffer();
      if (short) {
        buf.write(lang == 'ru' ? 'Рынок спокоен. ' : 'Market is calm. ');
        for (final a in found) {
          final sign = a.change24h >= 0 ? '+' : '';
          buf.write('${a.symbol} $sign${a.change24h.toStringAsFixed(1)}%. ');
        }
      } else {
        buf.writeln(lang == 'ru'
            ? '📊 Рынок спокоен. Обзор ключевых активов:'
            : '📊 Market is calm. Key assets overview:');
        for (final a in found) {
          final sign = a.change24h >= 0 ? '+' : '';
          final p = a.price >= 1
              ? a.price.toStringAsFixed(2)
              : a.price.toStringAsFixed(4);
          buf.writeln(
              '${a.symbol}: \$$p ($sign${a.change24h.toStringAsFixed(2)}%)');
        }
      }
      return buf.toString().trim();
    }

    final buf = StringBuffer();

    if (short) {
      if (lang == 'ru') {
        buf.write('Топ сигналы: ');
        for (int i = 0; i < signals.length; i++) {
          final s = signals[i];
          final sign = s.asset.change24h >= 0 ? '+' : '';
          buf.write(
              '${s.asset.symbol} $sign${s.asset.change24h.toStringAsFixed(1)}%. ');
        }
        final best = signals.first;
        buf.write(
            'Лучший: ${best.asset.symbol}, ${best.action.toLowerCase()}.');
      } else {
        buf.write('Top signals: ');
        for (int i = 0; i < signals.length; i++) {
          final s = signals[i];
          final sign = s.asset.change24h >= 0 ? '+' : '';
          buf.write(
              '${s.asset.symbol} $sign${s.asset.change24h.toStringAsFixed(1)}%. ');
        }
        final best = signals.first;
        buf.write('Best: ${best.asset.symbol}, ${best.action.toLowerCase()}.');
      }
    } else {
      if (lang == 'ru') {
        buf.writeln('📊 **Обзор рынка — топ ${signals.length} сигналов:**\n');
      } else {
        buf.writeln(
            '📊 **Market Overview — Top ${signals.length} Signals:**\n');
      }

      for (int i = 0; i < signals.length; i++) {
        final s = signals[i];
        final sign = s.asset.change24h >= 0 ? '+' : '';
        final price = s.asset.price >= 1
            ? '\$${s.asset.price.toStringAsFixed(2)}'
            : '\$${s.asset.price.toStringAsFixed(4)}';

        buf.writeln(
            '**${i + 1}. ${s.asset.symbol}** — $price ($sign${s.asset.change24h.toStringAsFixed(2)}% 24ч)');
        buf.writeln('   ${s.action}');
        buf.writeln('   ${s.thesis}');

        if (!s.executableByAi && s.blockReason != null) {
          buf.writeln('   ⚠️ ${s.blockReason}');
        } else if (s.executableByAi) {
          buf.writeln(lang == 'ru'
              ? '   ✅ Готов к исполнению'
              : '   ✅ Ready to execute');
        }
        buf.writeln();
      }

      final capNote = MarketScoutService.instance
          .buildModeCapabilityNote(AiControlService.instance.settings);
      buf.writeln(lang == 'ru' ? '🤖 $capNote' : '🤖 $capNote');
    }

    return buf.toString().trim();
  }

  /// Builds a human-readable trading plan briefing.
  static String buildTradingPlanBriefing(
    TradingPlan plan,
    String lang, {
    bool short = false,
  }) {
    final dirLabel = switch (plan.direction) {
      TradingDirection.buy => lang == 'ru' ? 'Покупка' : 'Buy',
      TradingDirection.sell => lang == 'ru' ? 'Продажа' : 'Sell',
      TradingDirection.swap => lang == 'ru' ? 'Обмен' : 'Swap',
      TradingDirection.swing => lang == 'ru' ? 'Свинг-трейд' : 'Swing Trade',
    };

    final priceStr = plan.entryPrice >= 1
        ? '\$${plan.entryPrice.toStringAsFixed(2)}'
        : '\$${plan.entryPrice.toStringAsFixed(4)}';

    final riskLabel = switch (plan.riskLevel) {
      TradingRisk.low => lang == 'ru' ? 'Низкий' : 'Low',
      TradingRisk.medium => lang == 'ru' ? 'Средний' : 'Medium',
      TradingRisk.high => lang == 'ru' ? 'Высокий' : 'High',
      TradingRisk.excessive => lang == 'ru' ? 'Чрезмерный' : 'Excessive',
    };

    if (short) {
      final sizeStr = '\$${plan.suggestedSizeUsd.toStringAsFixed(0)}';
      if (lang == 'ru') {
        final status =
            plan.executableByAi ? 'готов к исполнению' : 'заблокировано';
        return '$dirLabel ${plan.asset.symbol}. Цена $priceStr. '
            'Объём $sizeStr. Риск: $riskLabel. Статус: $status.';
      } else {
        final status = plan.executableByAi ? 'ready to execute' : 'blocked';
        return '$dirLabel ${plan.asset.symbol}. Price $priceStr. '
            'Size $sizeStr. Risk: $riskLabel. Status: $status.';
      }
    }

    final buf = StringBuffer();
    if (lang == 'ru') {
      buf.writeln('📋 **Торговый план: $dirLabel ${plan.asset.symbol}**\n');
    } else {
      buf.writeln('📋 **Trading Plan: $dirLabel ${plan.asset.symbol}**\n');
    }

    buf.writeln(lang == 'ru'
        ? '**Цена:** $priceStr | **Зона:** ${plan.zone}'
        : '**Price:** $priceStr | **Zone:** ${plan.zone}');

    if (plan.targetPrice != null && plan.stopLossPrice != null) {
      final targetStr = plan.targetPrice! >= 1
          ? '\$${plan.targetPrice!.toStringAsFixed(2)}'
          : '\$${plan.targetPrice!.toStringAsFixed(4)}';
      final stopStr = plan.stopLossPrice! >= 1
          ? '\$${plan.stopLossPrice!.toStringAsFixed(2)}'
          : '\$${plan.stopLossPrice!.toStringAsFixed(4)}';
      buf.writeln(lang == 'ru'
          ? '**Цель:** $targetStr | **Стоп:** $stopStr'
          : '**Target:** $targetStr | **Stop:** $stopStr');
    }

    buf.writeln(lang == 'ru'
        ? '**Объём:** \$${plan.suggestedSizeUsd.toStringAsFixed(0)} '
            '(макс: \$${plan.maxSizeUsd.toStringAsFixed(0)})'
        : '**Size:** \$${plan.suggestedSizeUsd.toStringAsFixed(0)} '
            '(max: \$${plan.maxSizeUsd.toStringAsFixed(0)})');

    buf.writeln(lang == 'ru'
        ? '**Маршрут:** ${plan.routeNote}'
        : '**Route:** ${plan.routeNote}');

    buf.writeln(lang == 'ru'
        ? '**Риск:** $riskLabel — ${plan.riskNote}'
        : '**Risk:** $riskLabel — ${plan.riskNote}');

    buf.writeln(lang == 'ru'
        ? '**Слиппейдж:** ~${plan.estimatedSlippagePct.toStringAsFixed(2)}%'
        : '**Slippage:** ~${plan.estimatedSlippagePct.toStringAsFixed(2)}%');

    buf.writeln();
    buf.writeln(lang == 'ru' ? '💡 ${plan.thesis}' : '💡 ${plan.thesis}');

    buf.writeln();
    if (plan.executableByAi) {
      buf.writeln(lang == 'ru'
          ? '✅ **Готов к исполнению** в текущем режиме.'
          : '✅ **Ready to execute** in current mode.');
    } else {
      buf.writeln(lang == 'ru'
          ? '⛔ **Заблокировано:** ${plan.blockReason ?? "см. мандат"}'
          : '⛔ **Blocked:** ${plan.blockReason ?? "see mandate"}');
    }

    return buf.toString().trim();
  }
}
