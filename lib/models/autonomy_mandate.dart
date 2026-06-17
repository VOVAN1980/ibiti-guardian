enum AutonomyGoal { growth, defense, rebalance, income }

class AutonomyMandate {
  final AutonomyGoal goal;
  final List<String> allowedAssets;
  final List<String> allowedNetworks;
  final List<String> allowedVenues;
  final double maxPositionUsd;
  final double maxSlippageBps;
  final double maxGasUsd;
  final double maxDailyLossUsd;
  final double maxDrawdownPct;
  final int maxOpenPositions;
  final int stopAfterLosses;
  final bool requireHumanForUnknown;
  final bool emergencyStopEnabled;

  // ── Exit / Ratchet policy (user-configurable) ──
  final double disasterStopPct;
  final double ratchetActivationPct;
  final double ratchetDistancePct;
  final double ratchetMinFloorPct;

  const AutonomyMandate({
    this.goal = AutonomyGoal.growth,
    this.allowedAssets = const [],
    this.allowedNetworks = const [],
    this.allowedVenues = const [],
    this.maxPositionUsd = 100.0,
    this.maxSlippageBps = 100.0,
    this.maxGasUsd = 20.0,
    this.maxDailyLossUsd = 100.0,
    this.maxDrawdownPct = 3.0,
    this.maxOpenPositions = 5,
    this.stopAfterLosses = 3,
    this.requireHumanForUnknown = true,
    this.emergencyStopEnabled = true,
    this.disasterStopPct = -5.0,
    this.ratchetActivationPct = 3.0,
    this.ratchetDistancePct = 2.0,
    this.ratchetMinFloorPct = 1.0,
  });

  AutonomyMandate copyWith({
    AutonomyGoal? goal,
    List<String>? allowedAssets,
    List<String>? allowedNetworks,
    List<String>? allowedVenues,
    double? maxPositionUsd,
    double? maxSlippageBps,
    double? maxGasUsd,
    double? maxDailyLossUsd,
    double? maxDrawdownPct,
    int? maxOpenPositions,
    int? stopAfterLosses,
    bool? requireHumanForUnknown,
    bool? emergencyStopEnabled,
    double? disasterStopPct,
    double? ratchetActivationPct,
    double? ratchetDistancePct,
    double? ratchetMinFloorPct,
  }) {
    return AutonomyMandate(
      goal: goal ?? this.goal,
      allowedAssets: allowedAssets ?? this.allowedAssets,
      allowedNetworks: allowedNetworks ?? this.allowedNetworks,
      allowedVenues: allowedVenues ?? this.allowedVenues,
      maxPositionUsd: maxPositionUsd ?? this.maxPositionUsd,
      maxSlippageBps: maxSlippageBps ?? this.maxSlippageBps,
      maxGasUsd: maxGasUsd ?? this.maxGasUsd,
      maxDailyLossUsd: maxDailyLossUsd ?? this.maxDailyLossUsd,
      maxDrawdownPct: maxDrawdownPct ?? this.maxDrawdownPct,
      maxOpenPositions: maxOpenPositions ?? this.maxOpenPositions,
      stopAfterLosses: stopAfterLosses ?? this.stopAfterLosses,
      requireHumanForUnknown:
          requireHumanForUnknown ?? this.requireHumanForUnknown,
      emergencyStopEnabled: emergencyStopEnabled ?? this.emergencyStopEnabled,
      disasterStopPct: disasterStopPct ?? this.disasterStopPct,
      ratchetActivationPct: ratchetActivationPct ?? this.ratchetActivationPct,
      ratchetDistancePct: ratchetDistancePct ?? this.ratchetDistancePct,
      ratchetMinFloorPct: ratchetMinFloorPct ?? this.ratchetMinFloorPct,
    );
  }

  Map<String, dynamic> toJson() => {
        'goal': goal.name,
        'allowedAssets': allowedAssets,
        'allowedNetworks': allowedNetworks,
        'allowedVenues': allowedVenues,
        'maxPositionUsd': maxPositionUsd,
        'maxSlippageBps': maxSlippageBps,
        'maxGasUsd': maxGasUsd,
        'maxDailyLossUsd': maxDailyLossUsd,
        'maxDrawdownPct': maxDrawdownPct,
        'maxOpenPositions': maxOpenPositions,
        'stopAfterLosses': stopAfterLosses,
        'requireHumanForUnknown': requireHumanForUnknown,
        'emergencyStopEnabled': emergencyStopEnabled,
        'disasterStopPct': disasterStopPct,
        'ratchetActivationPct': ratchetActivationPct,
        'ratchetDistancePct': ratchetDistancePct,
        'ratchetMinFloorPct': ratchetMinFloorPct,
      };

  factory AutonomyMandate.fromJson(Map<String, dynamic> json) {
    return AutonomyMandate(
      goal: AutonomyGoal.values.firstWhere(
        (e) => e.name == json['goal'],
        orElse: () => AutonomyGoal.growth,
      ),
      allowedAssets: (json['allowedAssets'] as List?)
              ?.map((e) => e.toString().toUpperCase())
              .toList() ??
          const [],
      allowedNetworks: (json['allowedNetworks'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      allowedVenues: (json['allowedVenues'] as List?)
              ?.map((e) => e.toString().toLowerCase())
              .toList() ??
          const [],
      maxPositionUsd: (json['maxPositionUsd'] ?? 100.0).toDouble(),
      maxSlippageBps: (json['maxSlippageBps'] ?? 100.0).toDouble(),
      maxGasUsd: (json['maxGasUsd'] ?? 20.0).toDouble(),
      maxDailyLossUsd: (json['maxDailyLossUsd'] ?? 100.0).toDouble(),
      maxDrawdownPct: (json['maxDrawdownPct'] ?? 3.0).toDouble(),
      maxOpenPositions: (json['maxOpenPositions'] ?? 5) as int,
      stopAfterLosses: (json['stopAfterLosses'] ?? 3) as int,
      requireHumanForUnknown: json['requireHumanForUnknown'] != false,
      emergencyStopEnabled: json['emergencyStopEnabled'] != false,
      disasterStopPct: (json['disasterStopPct'] ?? -5.0).toDouble(),
      ratchetActivationPct: (json['ratchetActivationPct'] ?? 3.0).toDouble(),
      ratchetDistancePct: (json['ratchetDistancePct'] ?? 2.0).toDouble(),
      ratchetMinFloorPct: (json['ratchetMinFloorPct'] ?? 1.0).toDouble(),
    );
  }

  bool allowsNetwork(String chainKey) {
    if (allowedNetworks.isEmpty) return true;
    return allowedNetworks
        .any((n) => n.toLowerCase() == chainKey.toLowerCase());
  }

  bool allowsAsset(String? symbol) {
    if (symbol == null || symbol.isEmpty) return true;
    if (allowedAssets.isEmpty) return true;
    return allowedAssets.contains(symbol.toUpperCase());
  }

  bool allowsVenue(String? venue) {
    if (venue == null || venue.isEmpty) return true;
    if (allowedVenues.isEmpty) return true;
    return allowedVenues.contains(venue.toLowerCase());
  }
}
