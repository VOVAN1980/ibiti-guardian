class AssetAmount {
  final String symbol; // SOL / TRX
  final int decimals; // 9 for SOL, 6 for TRX
  final BigInt atomic; // lamports / sun

  const AssetAmount({
    required this.symbol,
    required this.decimals,
    required this.atomic,
  });
}
