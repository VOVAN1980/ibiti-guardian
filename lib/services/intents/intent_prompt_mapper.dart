import 'package:ibiti_guardian/models/app_intent.dart';

/// Converts an [AppIntent] into a natural-language prompt
/// that [GuardianAssistantService] can parse directly.
///
/// Rules:
/// - If all fields available → full structured sentence
/// - If partial → partial sentence, AI fills the gaps
/// - Supports 'en' and 'ru'
class IntentPromptMapper {
  IntentPromptMapper._();

  /// Maps [intent] to a human-readable sentence in [lang] ('en' | 'ru').
  static String toPrompt(AppIntent intent, {String lang = 'en'}) {
    final ru = lang == 'ru';

    switch (intent.type) {
      // ── SWAP ────────────────────────────────────────────────────────────────
      case AppIntentType.swap:
        final src = intent.sourceToken;
        final dst = intent.targetToken;
        final amt = intent.amountText;

        if (src != null && dst != null && amt != null) {
          return ru ? 'Поменяй $amt $src на $dst' : 'Swap $amt $src to $dst';
        }
        if (src != null && dst != null) {
          return ru ? 'Поменяй $src на $dst' : 'Swap $src to $dst';
        }
        if (src != null && amt != null) {
          return ru
              ? 'Поменяй $amt $src на другой токен'
              : 'Swap $amt $src to another token';
        }
        if (src != null) {
          return ru ? 'Хочу поменять $src' : 'I want to swap $src';
        }
        return ru ? 'Хочу поменять токены' : 'I want to swap tokens';

      // ── SEND ────────────────────────────────────────────────────────────────
      case AppIntentType.send:
        final src = intent.sourceToken;
        final to = intent.toAddress;
        final amt = intent.amountText;

        if (src != null && amt != null && to != null) {
          return ru ? 'Отправь $amt $src на $to' : 'Send $amt $src to $to';
        }
        if (src != null && amt != null) {
          return ru ? 'Хочу отправить $amt $src' : 'I want to send $amt $src';
        }
        if (src != null) {
          return ru ? 'Хочу отправить $src' : 'I want to send $src';
        }
        return ru ? 'Хочу отправить токены' : 'I want to send tokens';

      // ── RECEIVE ─────────────────────────────────────────────────────────────
      case AppIntentType.receive:
        return ru
            ? 'Покажи мой адрес для получения'
            : 'Show my receive address';

      // ── SCAN ────────────────────────────────────────────────────────────────
      case AppIntentType.scan:
        return ru ? 'Проверь мой кошелёк на риски' : 'Scan my wallet for risks';

      // ── SHOW BALANCE ────────────────────────────────────────────────────────
      case AppIntentType.showBalance:
        return ru ? 'Покажи мой баланс' : 'Show my balance';

      // ── SHOW ADDRESS ────────────────────────────────────────────────────────
      case AppIntentType.showAddress:
        return ru ? 'Покажи мой адрес кошелька' : 'What is my wallet address';

      // ── REVOKE ──────────────────────────────────────────────────────────────
      case AppIntentType.revoke:
        return ru
            ? 'Отзови лишние разрешения токенов'
            : 'Revoke unnecessary token approvals';

      // ── UNKNOWN / BUY ────────────────────────────────────────────────────────
      case AppIntentType.buy:
        final dst = intent.targetToken;
        final amt = intent.amountText;
        final network = intent.network;
        if (dst != null && amt != null && network != null) {
          return ru
              ? 'Хочу купить $amt $dst в сети $network. Построй план входа, риска и следующих шагов.'
              : 'I want to buy $amt $dst on $network. Build an entry plan with risk and next steps.';
        }
        if (dst != null && network != null) {
          return ru
              ? 'Хочу купить $dst в сети $network. Построй осторожный рыночный план.'
              : 'I want to buy $dst on $network. Build a careful market plan.';
        }
        if (dst != null) {
          return ru
              ? 'Хочу купить $dst. Построй план входа, риска и следующих шагов.'
              : 'I want to buy $dst. Build an entry plan with risk and next steps.';
        }
        return ru
            ? 'Хочу купить монету. Построй осторожный рыночный план.'
            : 'I want to buy a coin. Build a careful market plan.';
      case AppIntentType.sell:
        final dst = intent.targetToken;
        final amt = intent.amountText;
        final network = intent.network;
        if (dst != null && amt != null && network != null) {
          return ru
              ? 'Хочу продать $amt $dst в сети $network. Построй план выхода, риска и следующих шагов.'
              : 'I want to sell $amt $dst on $network. Build an exit plan with risk and next steps.';
        }
        if (dst != null && network != null) {
          return ru
              ? 'Хочу продать $dst в сети $network. Построй осторожный план выхода.'
              : 'I want to sell $dst on $network. Build a careful exit plan.';
        }
        if (dst != null) {
          return ru
              ? 'Хочу продать $dst. Построй план выхода, риска и следующих шагов.'
              : 'I want to sell $dst. Build an exit plan with risk and next steps.';
        }
        return ru
            ? 'Хочу продать монету. Построй осторожный план выхода.'
            : 'I want to sell a coin. Build a careful exit plan.';
      case AppIntentType.analyzeMarket:
        final dst = intent.targetToken;
        final network = intent.network;
        if (dst != null && network != null) {
          return ru
              ? 'Проанализируй рынок для $dst в сети $network, сравни маршруты, ликвидность, риск и лучшие точки входа и выхода.'
              : 'Analyze the market for $dst on $network, compare routes, liquidity, risk, and the best entry and exit conditions.';
        }
        if (dst != null) {
          return ru
              ? 'Проанализируй рынок для $dst, сравни маршруты, ликвидность, риск и лучшие точки входа и выхода.'
              : 'Analyze the market for $dst, compare routes, liquidity, risk, and the best entry and exit conditions.';
        }
        return ru
            ? 'Проанализируй рынок, сравни маршруты, ликвидность, риск и лучшие точки входа и выхода.'
            : 'Analyze the market, compare routes, liquidity, risk, and the best entry and exit conditions.';
      case AppIntentType.unknown:
        return '';
    }
  }
}
