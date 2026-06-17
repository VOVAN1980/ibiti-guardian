import 'package:ibiti_guardian/services/market/market_intent_normalizer.dart';

/// A single parsed market action from a compound voice command.
///
/// Example: "поставь TP 5%, SL 5%, алерт 10%"
/// → [MarketAction(set_tp, 5), MarketAction(set_sl, 5), MarketAction(set_alert, 10)]
class MarketAction {
  final MarketActionType type;
  final double? percent;
  final double? absolutePrice;
  final String? symbol;

  const MarketAction({
    required this.type,
    this.percent,
    this.absolutePrice,
    this.symbol,
  });

  @override
  String toString() =>
      'MarketAction($type, pct=$percent, abs=$absolutePrice, sym=$symbol)';
}

enum MarketActionType {
  setTp,
  setSl,
  setAlert,
  addFavorite,
  removeFavorite,
  removeTp,
  removeSl,
  removeAlert,
}

/// Splits a compound voice command into multiple [MarketAction]s.
///
/// Handles patterns like:
/// - "поставь TP 5%, SL 5%, алерт 10%"
/// - "тейк 15 и стоп 5"
/// - "убери TP и поставь новый 20%"
/// - "верхняя планка 10%, нижняя 5%"
class MarketMultiActionParser {
  MarketMultiActionParser._();
  static final instance = MarketMultiActionParser._();

  final _norm = MarketIntentNormalizer.instance;

  /// Parse input into a list of market actions.
  /// Returns empty list if no market actions detected.
  List<MarketAction> parse(String lower) {
    final actions = <MarketAction>[];

    // Split by common separators: и, запятая, точка с запятой, also, and, then
    final parts = _splitIntoParts(lower);

    for (final part in parts) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;

      // Check remove actions first (more specific)
      if (_norm.hasRemoveTpKeyword(trimmed)) {
        actions.add(const MarketAction(type: MarketActionType.removeTp));
        continue;
      }
      if (_norm.hasRemoveSlKeyword(trimmed)) {
        actions.add(const MarketAction(type: MarketActionType.removeSl));
        continue;
      }
      if (_norm.hasRemoveAlertKeyword(trimmed)) {
        actions.add(const MarketAction(type: MarketActionType.removeAlert));
        continue;
      }
      if (_norm.hasRemoveFavoriteKeyword(trimmed)) {
        actions.add(const MarketAction(type: MarketActionType.removeFavorite));
        continue;
      }

      // Then set actions
      if (_norm.hasTpKeyword(trimmed)) {
        final pct = _norm.parsePercent(trimmed);
        actions.add(MarketAction(type: MarketActionType.setTp, percent: pct));
        continue;
      }
      if (_norm.hasSlKeyword(trimmed) ||
          (trimmed.contains('стоп') &&
              (trimmed.contains('%') || RegExp(r'\d').hasMatch(trimmed)))) {
        final pct = _norm.parsePercent(trimmed);
        actions.add(MarketAction(type: MarketActionType.setSl, percent: pct));
        continue;
      }
      if (_norm.hasAlertKeyword(trimmed)) {
        final pct = _norm.parsePercent(trimmed);
        actions
            .add(MarketAction(type: MarketActionType.setAlert, percent: pct));
        continue;
      }
      if (_norm.hasFavoriteKeyword(trimmed)) {
        actions.add(const MarketAction(type: MarketActionType.addFavorite));
        continue;
      }
    }

    // If splitting didn't help, try the whole string as multiple keyword matches
    if (actions.length <= 1) {
      final wholeParse = _parseWhole(lower);
      if (wholeParse.length > 1) return wholeParse;
    }

    return actions;
  }

  /// Try parsing the whole string by scanning for keywords sequentially.
  /// Handles: "TP 5% SL 5% алерт 10%" without explicit separators.
  List<MarketAction> _parseWhole(String lower) {
    final actions = <MarketAction>[];

    // Find all percent values in order
    final pctPattern = RegExp(r'(\d+(?:[.,]\d+)?)\s*%');
    final pctMatches = pctPattern.allMatches(lower).toList();

    if (pctMatches.length < 2) return actions;

    // For each percent, look backwards for the nearest keyword
    for (final match in pctMatches) {
      final before = lower.substring(0, match.start);
      final pct =
          double.tryParse(match.group(1)!.replaceAll(',', '.'))?.abs() ?? 0;
      if (pct <= 0 || pct > 100) continue;

      // Find closest keyword before this number
      if (_lastIndexOfAny(before, _tpWords) >
          _lastIndexOfAny(before, _slWords)) {
        actions.add(MarketAction(type: MarketActionType.setTp, percent: pct));
      } else if (_lastIndexOfAny(before, _slWords) >= 0) {
        actions.add(MarketAction(type: MarketActionType.setSl, percent: pct));
      } else if (_lastIndexOfAny(before, _alertWords) >= 0) {
        actions
            .add(MarketAction(type: MarketActionType.setAlert, percent: pct));
      }
    }

    return actions;
  }

  // Quick keyword lists for positional matching
  static const _tpWords = ['тейк', 'tp', 'тп', 'take profit', 'верхн'];
  static const _slWords = [
    'стоп',
    'sl',
    'stop loss',
    'нижн',
    'стоплос',
  ];
  static const _alertWords = ['алерт', 'alert', 'уведом'];

  /// Split compound command into parts by separators.
  static List<String> _splitIntoParts(String lower) {
    // Common separators in compound commands
    return lower.split(RegExp(r'[,;]\s*|\s+и\s+|\s+and\s+|\s+also\s+|\s+плюс\s+|\s+ещё\s+|\s+еще\s+|\s+потом\s+|\s+then\s+'));
  }

  static int _lastIndexOfAny(String text, List<String> keywords) {
    var best = -1;
    for (final kw in keywords) {
      final idx = text.lastIndexOf(kw);
      if (idx > best) best = idx;
    }
    return best;
  }
}
