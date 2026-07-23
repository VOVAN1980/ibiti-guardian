import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/market/wallet_exposure_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';

/// Builds compact market context strings from cached data for LLM enrichment.
///
/// Extracted from [GuardianAssistantService] as part of P3-1 decomposition.
/// No network calls — reads only what is already in memory.
class MarketContextBuilder {
  MarketContextBuilder._();

  static const _marketContextKeywords = [
    'buy',
    'sell',
    'купи',
    'продай',
    'swap',
    'обмен',
    'price',
    'цена',
    'market',
    'рынок',
    'trade',
    'торг',
    'analyze',
    'анализ',
    'route',
    'маршрут',
    'план',
    'plan',
    'trend',
    'тренд',
    'btc',
    'eth',
    'bnb',
    'sol',
    'usdt',
    'usdc',
    'bitcoin',
    'ethereum',
    'solana',
  ];

  /// Returns true if the input looks like it might benefit from market context.
  /// More permissive than market query checks — used for GPT context enrichment.
  static bool isMarketRelatedInput(String input) {
    final lower = input.toLowerCase();
    return _marketContextKeywords.any(lower.contains);
  }

  /// Builds a compact market context string from cached data.
  /// No network calls — reads only what is already in memory.
  /// Returns empty string if no relevant cached data is found.
  static String buildMarketContext(String input) {
    final lower = input.toLowerCase();
    final ai = AiControlService.instance.settings;
    final mode = switch (ai.mode) {
      AiMode.manual => 'Manual (analysis only)',
      AiMode.guarded => 'Guarded (prepare, user confirms)',
      AiMode.fullAutonomy => 'Full Autonomy (execute within limits)',
    };
    final mandate = ai.mandate;

    // Try to find a mentioned token in the cached market list
    final buffer = StringBuffer();

    // Look for a cached asset whose symbol or name appears in the query
    MarketAsset? matchedAsset;
    final cachedMarkets = MarketDataService.instance.cachedMarkets;
    for (final asset in cachedMarkets) {
      if (lower.contains(asset.symbol.toLowerCase()) ||
          lower.contains(asset.name.toLowerCase())) {
        matchedAsset = asset;
        break;
      }
    }

    if (matchedAsset != null) {
      final a = matchedAsset;
      final sign = a.change24h >= 0 ? '+' : '';
      buffer.writeln('[Market Context]');
      buffer.writeln(
          '${a.symbol} (${a.networkGroup}): \$${a.price.toStringAsFixed(a.price >= 1 ? 2 : 4)} '
          '| 24h: $sign${a.change24h.toStringAsFixed(2)}% '
          '| 7d: ${a.change7d >= 0 ? '+' : ''}${a.change7d.toStringAsFixed(2)}% '
          '| Status: ${a.status}');
      buffer.writeln('Volume: \$${(a.volume / 1000000).toStringAsFixed(1)}M '
          '| MCap: \$${(a.marketCap / 1000000000).toStringAsFixed(2)}B');

      // Exposure context — AI knows whether it can/should add, hold, or reduce.
      final exposure = WalletExposureService.instance.snapshotFor(
        a.symbol,
        mandate,
      );
      buffer.writeln(exposure.promptLine);
    } else {
      // Fallback: if user has a focused token on screen (token_detail),
      // use it as market context even when the symbol wasn't mentioned
      // in the query (e.g. "что думаешь?", "какая цена?").
      final ctx = ScreenContextService.instance;
      if (ctx.focusedSymbol != null) {
        final focusedMatch = cachedMarkets
            .where((a) =>
                a.symbol.toLowerCase() == ctx.focusedSymbol!.toLowerCase())
            .firstOrNull;
        if (focusedMatch != null) {
          final a = focusedMatch;
          final sign = a.change24h >= 0 ? '+' : '';
          buffer.writeln('[Market Context — from focused token]');
          buffer.writeln(
              '${a.symbol} (${a.networkGroup}): \$${a.price.toStringAsFixed(a.price >= 1 ? 2 : 4)} '
              '| 24h: $sign${a.change24h.toStringAsFixed(2)}% '
              '| 7d: ${a.change7d >= 0 ? '+' : ''}${a.change7d.toStringAsFixed(2)}% '
              '| Status: ${a.status}');
          buffer.writeln(
              'Volume: \$${(a.volume / 1000000).toStringAsFixed(1)}M '
              '| MCap: \$${(a.marketCap / 1000000000).toStringAsFixed(2)}B');

          final exposure = WalletExposureService.instance.snapshotFor(
            a.symbol,
            mandate,
          );
          buffer.writeln(exposure.promptLine);
        }
      }
    }

    // AI mode + limits always included when market query detected
    buffer.writeln('[AI Context]');
    buffer
        .writeln('Mode: $mode | Daily: \$${ai.dailyLimit.toStringAsFixed(0)}');
    if (mandate.allowedAssets.isNotEmpty) {
      buffer.writeln('Mandate assets: ${mandate.allowedAssets.join(", ")}');
    }
    if (mandate.allowedNetworks.isNotEmpty) {
      buffer.writeln('Mandate networks: ${mandate.allowedNetworks.join(", ")}');
    }
    if (mandate.allowedVenues.isNotEmpty) {
      buffer.writeln('Mandate venues: ${mandate.allowedVenues.join(", ")}');
    }
    // ── Screen Context — what the user is currently looking at ──────────────
    final screenCtx = ScreenContextService.instance.buildContextPrompt();
    if (screenCtx.isNotEmpty) {
      buffer.writeln();
      buffer.writeln(screenCtx);
    }

    return buffer.toString().trim();
  }

  /// Returns the input enriched with compact market context if the query
  /// is market-related and cached data is available. Otherwise returns input as-is.
  static String enrichWithMarketContext(String input) {
    // Always enrich if user is focused on a token (they might ask "what is this?")
    final hasFocus = ScreenContextService.instance.focusedSymbol != null;
    if (!hasFocus && !isMarketRelatedInput(input)) return input;
    final ctx = buildMarketContext(input);
    if (ctx.isEmpty) return input;
    return '$ctx\n\n$input';
  }
}
