import 'dart:math';

class WalletTransaction {
  final String hash;
  final String fromAddress;
  final String? toAddress;
  final double value;
  final String symbol;
  final DateTime timestamp;
  final bool isIncoming;
  final String? type; // 'send', 'receive', 'interact', etc.

  WalletTransaction({
    required this.hash,
    required this.fromAddress,
    this.toAddress,
    required this.value,
    required this.symbol,
    required this.timestamp,
    required this.isIncoming,
    this.type,
  });

  factory WalletTransaction.fromMoralisNative(
      Map<String, dynamic> json, String walletAddress, String nativeSymbol) {
    final from = json['from_address']?.toString() ?? '';
    final to = json['to_address']?.toString() ?? '';
    final isIncoming = to.toLowerCase() == walletAddress.toLowerCase();

    // Value is in wei for native
    final valueRaw = double.tryParse(json['value']?.toString() ?? '0') ?? 0.0;
    final value = valueRaw / 1e18;

    return WalletTransaction(
      hash: json['hash']?.toString() ?? '',
      fromAddress: from,
      toAddress: to,
      value: value,
      symbol: nativeSymbol,
      timestamp: DateTime.parse(json['block_timestamp']?.toString() ??
          DateTime.now().toIso8601String()),
      isIncoming: isIncoming,
      type: isIncoming ? 'receive' : 'send',
    );
  }

  factory WalletTransaction.fromMoralisErc20(
      Map<String, dynamic> json, String walletAddress) {
    final from = json['from_address']?.toString() ?? '';
    final to = json['to_address']?.toString() ?? '';
    final isIncoming = to.toLowerCase() == walletAddress.toLowerCase();

    final valueRaw = double.tryParse(json['value']?.toString() ?? '0') ?? 0.0;
    final decimals =
        int.tryParse(json['token_decimals']?.toString() ?? '18') ?? 18;
    // For ERC20 transfers endpoint, Moralis usually provides raw value
    // We need to divide by 10^decimals manually if value_formatted is not present
    double value = valueRaw;
    if (json.containsKey('value_formatted')) {
      value = double.tryParse(json['value_formatted'].toString()) ?? 0.0;
    } else {
      // Simple fallback if decimals are known
      value = valueRaw / pow(10, decimals).toDouble();
    }

    return WalletTransaction(
      hash: json['transaction_hash']?.toString() ?? '',
      fromAddress: from,
      toAddress: to,
      value: value,
      symbol: json['token_symbol']?.toString() ?? '???',
      timestamp: DateTime.parse(json['block_timestamp']?.toString() ??
          DateTime.now().toIso8601String()),
      isIncoming: isIncoming,
      type: isIncoming ? 'receive' : 'send',
    );
  }
}
