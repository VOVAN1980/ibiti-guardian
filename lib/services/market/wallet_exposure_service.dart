import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';

// ─── Exposure Labels ───────────────────────────────────────────────────────────

/// AI and UI action hint derived from current exposure vs mandate.
enum ExposureAction {
  /// Position is zero or very small — AI can freely add.
  add,

  /// Position is significant but capacity remains — AI can add with caution.
  addCaution,

  /// Position is at 80–99 % of mandate cap — AI should hold or reduce.
  hold,

  /// Position is at or above mandate cap — AI cannot add, should reduce.
  blockedByExposure,
}

// ─── Exposure Snapshot ─────────────────────────────────────────────────────────

/// Point-in-time exposure for a single asset symbol.
///
/// Computed by [WalletExposureService.snapshotFor] from the current
/// [VaultPortfolioListener.summary] and the active [AutonomyMandate].
class ExposureSnapshot {
  /// Asset symbol this snapshot is for (e.g. "BTC", "ETH").
  final String symbol;

  /// Current token balance (raw units, as-held in wallet).
  final double currentBalanceTokens;

  /// Current position in USD (balance × current price).
  final double currentPositionUsd;

  /// Mandate hard cap for a single-asset position.
  final double mandateLimitUsd;

  /// How much USD can still be added within the mandate cap.
  /// Negative means already over limit.
  final double remainingCapacityUsd;

  /// Percentage of mandate cap already consumed (0–100+).
  final double usedPct;

  /// What the AI should do with this asset right now.
  final ExposureAction action;

  /// Whether the current position is already at or above mandate.maxPositionUsd.
  bool get isOverLimit => remainingCapacityUsd <= 0;

  /// Whether the current position is within 20 % of the mandate limit.
  bool get isNearLimit => usedPct >= 80 && !isOverLimit;

  /// Short note explaining the exposure status. Used in AI context.
  String get concentrationNote {
    if (mandateLimitUsd <= 0) return 'No position limit set in mandate.';
    final pctStr = usedPct.toStringAsFixed(0);
    final capStr = '\$${mandateLimitUsd.toStringAsFixed(0)}';
    final posStr = '\$${currentPositionUsd.toStringAsFixed(2)}';
    return switch (action) {
      ExposureAction.add =>
        'Current $symbol position: $posStr ($pctStr % of $capStr cap). '
            'Capacity available — AI may add.',
      ExposureAction.addCaution =>
        'Current $symbol position: $posStr ($pctStr % of $capStr cap). '
            'Approaching limit — add with caution.',
      ExposureAction.hold =>
        'Current $symbol position: $posStr ($pctStr % of $capStr cap). '
            'Near mandate limit — hold or reduce.',
      ExposureAction.blockedByExposure =>
        'Current $symbol position: $posStr exceeds mandate cap $capStr '
            '($pctStr %). AI cannot add — reduce position first.',
    };
  }

  /// AI context summary line (compact, for prompt injection).
  String get promptLine =>
      'Exposure[$symbol]: pos=\$${currentPositionUsd.toStringAsFixed(2)} '
      '| cap=\$${mandateLimitUsd.toStringAsFixed(0)} '
      '| remaining=\$${remainingCapacityUsd.toStringAsFixed(2)} '
      '| action=${action.name}';

  const ExposureSnapshot({
    required this.symbol,
    required this.currentBalanceTokens,
    required this.currentPositionUsd,
    required this.mandateLimitUsd,
    required this.remainingCapacityUsd,
    required this.usedPct,
    required this.action,
  });
}

// ─── WalletExposureService ─────────────────────────────────────────────────────

/// Computes current position exposure per asset against the active mandate.
///
/// Does NOT make network calls — reads from [VaultPortfolioListener.summary]
/// which is already in-memory. Safe to call synchronously from UI and builders.
///
/// Design notes:
/// - One singleton, no ChangeNotifier — callers read snapshot on demand.
///   Reactive updates come indirectly through VaultPortfolioListener.
/// - Symbol matching is case-insensitive.
/// - If portfolio data is not yet loaded, returns a zero-position snapshot
///   with [ExposureAction.add] so the plan builder doesn't false-block.
class WalletExposureService {
  WalletExposureService._();
  static final WalletExposureService instance = WalletExposureService._();

  /// Returns the current [ExposureSnapshot] for [symbol] against [mandate].
  ///
  /// Pass the mandate from [AiControlService.instance.settings.mandate].
  ExposureSnapshot snapshotFor(String symbol, AutonomyMandate mandate) {
    final portfolio = VaultPortfolioListener.instance.summary;
    final limit = mandate.maxPositionUsd;

    // No portfolio loaded yet — return zero snapshot (non-blocking).
    if (portfolio == null) {
      return _zero(symbol, limit);
    }

    // Find ALL matching wallet assets by symbol (case-insensitive) and sum.
    // A user may hold the same token on multiple chains — we must aggregate.
    double totalBalance = 0;
    double totalPositionUsd = 0;
    for (final a in portfolio.allAssets) {
      if (a.symbol.toLowerCase() == symbol.toLowerCase()) {
        totalBalance += a.balance;
        totalPositionUsd += a.valueUsd;
      }
    }

    if (totalPositionUsd <= 0 && totalBalance <= 0) return _zero(symbol, limit);

    return _compute(
      symbol: symbol,
      balanceTokens: totalBalance,
      positionUsd: totalPositionUsd,
      limitUsd: limit,
    );
  }

  /// Capped addition: how much of [addUsd] can be added without exceeding limit.
  ///
  /// Returns the lesser of [addUsd] and [snapshot.remainingCapacityUsd].
  /// Returns 0 if already over limit.
  double cappedAddition(ExposureSnapshot snapshot, double addUsd) {
    if (snapshot.isOverLimit) return 0;
    return addUsd.clamp(0, snapshot.remainingCapacityUsd);
  }

  // ─── Private ───────────────────────────────────────────────────────────────

  ExposureSnapshot _zero(String symbol, double limitUsd) {
    return _compute(
      symbol: symbol,
      balanceTokens: 0,
      positionUsd: 0,
      limitUsd: limitUsd,
    );
  }

  ExposureSnapshot _compute({
    required String symbol,
    required double balanceTokens,
    required double positionUsd,
    required double limitUsd,
  }) {
    final remaining = limitUsd > 0 ? (limitUsd - positionUsd) : double.infinity;
    final usedPct =
        limitUsd > 0 ? (positionUsd / limitUsd * 100).clamp(0, 999) : 0.0;

    final action = _deriveAction(usedPct.toDouble(), remaining);

    return ExposureSnapshot(
      symbol: symbol,
      currentBalanceTokens: balanceTokens,
      currentPositionUsd: positionUsd,
      mandateLimitUsd: limitUsd,
      remainingCapacityUsd: remaining,
      usedPct: usedPct.toDouble(),
      action: action,
    );
  }

  ExposureAction _deriveAction(double usedPct, double remaining) {
    if (remaining <= 0) return ExposureAction.blockedByExposure;
    if (usedPct >= 80) return ExposureAction.hold;
    if (usedPct >= 40) return ExposureAction.addCaution;
    return ExposureAction.add;
  }
}
