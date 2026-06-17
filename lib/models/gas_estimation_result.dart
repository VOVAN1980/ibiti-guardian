class GasEstimationResult {
  final BigInt estimatedGas;
  final BigInt estimatedGasPrice;
  final String symbol;

  const GasEstimationResult({
    required this.estimatedGas,
    required this.estimatedGasPrice,
    this.symbol = 'BNB',
  });

  /// Total cost in wei
  BigInt get estimatedNativeCost => estimatedGas * estimatedGasPrice;

  /// Returns the estimated cost in native token (assuming 18 decimals)
  double get estimatedCostNative =>
      estimatedNativeCost / BigInt.from(10).pow(18);

  /// Returns a formatted string like "0.0008 BNB"
  String get formattedCost {
    final cost = estimatedCostNative;
    String formatted;
    if (cost < 0.0001) {
      formatted = "<0.0001";
    } else {
      formatted = cost.toStringAsFixed(4);
    }
    return "$formatted $symbol";
  }
}
