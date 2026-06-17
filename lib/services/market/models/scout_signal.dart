import 'package:ibiti_guardian/services/exchanges/exchange_interface.dart';

/// Базовый класс для всех сигналов скаутера рынка.
abstract class ScoutSignal {
  final DateTime timestamp;
  final String symbol;
  final String exchange;

  /// Уровень уверенности в сигнале от 0.0 до 1.0
  final double confidenceScore;

  const ScoutSignal({
    required this.timestamp,
    required this.symbol,
    required this.exchange,
    this.confidenceScore = 1.0,
  });

  Map<String, dynamic> toJson();
}

/// Анонс листинга (например, "MEXC залистит XYZ через 14 минут").
class ListingAnnouncementSignal extends ScoutSignal {
  final DateTime scheduledListingTime;
  final String sourceUrl;

  const ListingAnnouncementSignal({
    required super.timestamp,
    required super.symbol,
    required super.exchange,
    required this.scheduledListingTime,
    this.sourceUrl = '',
    super.confidenceScore,
  });

  int get minutesUntilListing =>
      scheduledListingTime.difference(timestamp).inMinutes;

  @override
  Map<String, dynamic> toJson() => {
        'event_type': 'ListingAnnouncement',
        'symbol': symbol,
        'exchange': exchange,
        'scheduled_time': scheduledListingTime.toIso8601String(),
        'source': sourceUrl,
        'confidence': confidenceScore,
      };
}

/// Фактическое начало торгов монетой (первые секунды после старта).
class NewListingDetectedSignal extends ScoutSignal {
  final double openPrice;
  final double currentPrice;

  const NewListingDetectedSignal({
    required super.timestamp,
    required super.symbol,
    required super.exchange,
    required this.openPrice,
    required this.currentPrice,
    super.confidenceScore,
  });

  @override
  Map<String, dynamic> toJson() => {
        'event_type': 'NewListingDetected',
        'symbol': symbol,
        'exchange': exchange,
        'open_price': openPrice,
        'current_price': currentPrice,
        'confidence': confidenceScore,
      };
}

/// Аномальный всплеск объема торгов за период.
class VolumeSpikeSignal extends ScoutSignal {
  final double spikeMultiplier; // например 6.2 (в 6.2 раза больше среднего)
  final double currentPrice;
  final String interval; // '1m', '5m'

  const VolumeSpikeSignal({
    required super.timestamp,
    required super.symbol,
    required super.exchange,
    required this.spikeMultiplier,
    required this.currentPrice,
    required this.interval,
    super.confidenceScore,
  });

  @override
  Map<String, dynamic> toJson() => {
        'event_type': 'VolumeSpike',
        'symbol': symbol,
        'exchange': exchange,
        'spike_multiplier': spikeMultiplier,
        'current_price': currentPrice,
        'interval': interval,
        'confidence': confidenceScore,
      };
}

/// Пробой цены на объеме (Breakout).
class PriceBreakoutSignal extends ScoutSignal {
  final double priceDeltaPercentage;
  final double currentPrice;

  const PriceBreakoutSignal({
    required super.timestamp,
    required super.symbol,
    required super.exchange,
    required this.priceDeltaPercentage,
    required this.currentPrice,
    super.confidenceScore,
  });

  @override
  Map<String, dynamic> toJson() => {
        'event_type': 'PriceBreakout',
        'symbol': symbol,
        'exchange': exchange,
        'price_delta_percentage': priceDeltaPercentage,
        'current_price': currentPrice,
        'confidence': confidenceScore,
      };
}

// ─── Risk Engine Context ──────────────────────────────────────────────────

enum RiskLevel { low, medium, high, excessive }

enum LiquidityStatus { strong, acceptable, weak, zero }

/// Статус прохождения риск-гейтов.
class RiskStatus {
  final bool isApproved;
  final String? rejectionReason;

  final RiskLevel riskLevel;
  final LiquidityStatus liquidityStatus;

  /// Сколько максимум можно вложить ($) при текущей ликвидности.
  final double suggestedMaxUsd;

  /// Флаги риска (meme_category, low_volume, etc) для AI.
  final List<String> riskFlags;

  const RiskStatus({
    required this.isApproved,
    this.rejectionReason,
    this.riskLevel = RiskLevel.high,
    this.liquidityStatus = LiquidityStatus.weak,
    this.suggestedMaxUsd = 0.0,
    this.riskFlags = const [],
  });

  static const RiskStatus rejectedBlacklist = RiskStatus(
    isApproved: false,
    rejectionReason: 'Asset Blacklisted',
    riskLevel: RiskLevel.excessive,
  );

  static const RiskStatus rejectedLiquidity = RiskStatus(
    isApproved: false,
    rejectionReason: 'Liquidity too low',
    riskLevel: RiskLevel.excessive,
    liquidityStatus: LiquidityStatus.zero,
  );
}

/// Обертка сигнала после прохождения Risk Engine.
/// Это именно то, что будет получено AI и отправлено в UI.
class ActionableSignal {
  final ScoutSignal rawSignal;
  final RiskStatus riskStatus;
  final LiveTicker currentTicker;

  const ActionableSignal({
    required this.rawSignal,
    required this.riskStatus,
    required this.currentTicker,
  });

  Map<String, dynamic> toAiJson() {
    final Map<String, dynamic> base = rawSignal.toJson();
    base['liquidity_status'] = riskStatus.liquidityStatus.name;
    base['suggested_max_usd'] = riskStatus.suggestedMaxUsd;
    base['risk_level'] = riskStatus.riskLevel.name;
    base['risk_flags'] = riskStatus.riskFlags;
    base['ai_required_action'] = 'explain_and_suggest';
    return base;
  }
}
