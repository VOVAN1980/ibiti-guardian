/// Clean market memory entry — records every user market command and its result.
///
/// NO old JARVIS brain/gate/debate imports.
/// NO strategy_knowledge, counterfactual, eternal_memory, shadow_only.
/// Only user commands + outcomes.
class MarketMemoryEntry {
  final int? id;
  final DateTime timestamp;
  final String action; // buy, sell, tp, sl, alert, favorite, rocket
  final String symbol;
  final String source; // voice, chat, ui
  final String aiMode; // manual, guarded, fullAutonomy
  final String result; // opened_form, blocked, failed, confirmed, notified
  final double? amount;
  final double? priceThen; // price at time of command
  final String? reason; // why failed/blocked (null if ok)
  final String rawInput; // original user input

  const MarketMemoryEntry({
    this.id,
    required this.timestamp,
    required this.action,
    required this.symbol,
    required this.source,
    required this.aiMode,
    required this.result,
    this.amount,
    this.priceThen,
    this.reason,
    required this.rawInput,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'timestamp': timestamp.toIso8601String(),
        'action': action,
        'symbol': symbol,
        'source': source,
        'ai_mode': aiMode,
        'result': result,
        'amount': amount,
        'price_then': priceThen,
        'reason': reason,
        'raw_input': rawInput,
      };

  factory MarketMemoryEntry.fromMap(Map<String, dynamic> m) {
    return MarketMemoryEntry(
      id: m['id'] as int?,
      timestamp: DateTime.parse(m['timestamp'] as String),
      action: m['action'] as String,
      symbol: m['symbol'] as String,
      source: m['source'] as String,
      aiMode: m['ai_mode'] as String,
      result: m['result'] as String,
      amount: (m['amount'] as num?)?.toDouble(),
      priceThen: (m['price_then'] as num?)?.toDouble(),
      reason: m['reason'] as String?,
      rawInput: m['raw_input'] as String,
    );
  }

  /// One-line summary for "покажи историю" voice response.
  String get summary {
    final dir = switch (action) {
      'buy' => '📈 Buy',
      'sell' => '📉 Sell',
      'tp' => '✅ TP',
      'sl' => '🛡 SL',
      'alert' => '🔔 Alert',
      'favorite' => '⭐ Fav',
      'rocket' => '🚀 Rocket',
      _ => action,
    };
    final amt = amount != null ? ' \$${amount!.toStringAsFixed(0)}' : '';
    return '$dir $symbol$amt → $result';
  }
}
