/// Model for a single on-chain transaction from Moralis /wallets/{address}/history
class OnChainTx {
  final String hash;
  final OnChainTxType type;
  final String from;
  final String to;
  final double value; // human-readable native value
  final String? tokenSymbol;
  final String? tokenName;
  final String? tokenLogoUrl;
  final String? contractAddress;
  final DateTime blockTimestamp;
  final bool isSuccess;
  final String? gasUsed;
  final String chainKey;
  final String? summary;

  // ── Swap-specific fields ────────────────────────────────────────────────────
  /// Token the user sold (outgoing leg of a swap).
  final String? sellSymbol;
  final double? sellValue;

  /// Token the user received (incoming leg of a swap).
  final String? buySymbol;
  final double? buyValue;

  const OnChainTx({
    required this.hash,
    required this.type,
    required this.from,
    required this.to,
    required this.value,
    this.tokenSymbol,
    this.tokenName,
    this.tokenLogoUrl,
    this.contractAddress,
    required this.blockTimestamp,
    required this.isSuccess,
    this.gasUsed,
    required this.chainKey,
    this.summary,
    this.sellSymbol,
    this.sellValue,
    this.buySymbol,
    this.buyValue,
  });

  bool get isIncoming => type == OnChainTxType.receive;
  bool get isOutgoing => type == OnChainTxType.send;
  bool get isApproval => type == OnChainTxType.approval;
  bool get isSwap => type == OnChainTxType.swap;

  String get shortHash {
    if (hash.length < 16) return hash;
    return '${hash.substring(0, 10)}...${hash.substring(hash.length - 6)}';
  }

  factory OnChainTx.fromMoralisEntry(
      Map<String, dynamic> json, String walletAddress, String chainKey) {
    final from = json['from_address']?.toString() ?? '';
    final to = json['to_address']?.toString() ?? '';
    final wallet = walletAddress.toLowerCase();
    final isSend = from.toLowerCase() == wallet;

    // Parse all ERC-20 transfer events
    final transfers = json['erc20_transfers'] as List? ?? [];

    // ── Swap detection ──────────────────────────────────────────────────────
    // A swap has ≥2 ERC-20 transfers with both outgoing (user → X) and
    // incoming (X → user) legs within the same tx hash.
    _TransferInfo? outgoingLeg;
    _TransferInfo? incomingLeg;
    if (transfers.length >= 2) {
      for (final raw in transfers) {
        final t = raw as Map<String, dynamic>;
        final tFrom = (t['from_address'] ?? '').toString().toLowerCase();
        final tTo = (t['to_address'] ?? '').toString().toLowerCase();
        final info = _parseTransfer(t);
        if (tFrom == wallet && outgoingLeg == null) {
          outgoingLeg = info;
        }
        if (tTo == wallet && incomingLeg == null) {
          incomingLeg = info;
        }
      }
    }

    final bool isSwapTx = outgoingLeg != null && incomingLeg != null;

    // ── Determine type ──────────────────────────────────────────────────────
    OnChainTxType txType;
    if (isSwapTx) {
      txType = OnChainTxType.swap;
    } else if (json['category'] == 'token approval' ||
        json['category'] == 'approve') {
      txType = OnChainTxType.approval;
    } else if (json['category'] == 'token send' ||
        (isSend && json['category'] != 'receive')) {
      txType = OnChainTxType.send;
    } else if (json['category'] == 'token receive' ||
        json['category'] == 'receive') {
      txType = OnChainTxType.receive;
    } else if (json['category'] == 'swap') {
      txType = OnChainTxType.swap;
    } else if (isSend) {
      txType = OnChainTxType.send;
    } else {
      txType = OnChainTxType.receive;
    }

    // ── Token info ──────────────────────────────────────────────────────────
    // For swaps: use the incoming (buy) leg as the primary display token.
    // For non-swaps: use the first transfer (original behavior).
    String? tokenSymbol;
    String? tokenName;
    String? tokenLogoUrl;
    String? contractAddress;
    double tokenValue = 0.0;

    if (isSwapTx) {
      // Primary display = incoming (what user received)
      tokenSymbol = incomingLeg.symbol;
      tokenName = incomingLeg.name;
      tokenLogoUrl = incomingLeg.logoUrl;
      contractAddress = incomingLeg.contractAddress;
      tokenValue = incomingLeg.value;
    } else if (transfers.isNotEmpty) {
      final first = _parseTransfer(transfers.first as Map<String, dynamic>);
      tokenSymbol = first.symbol;
      tokenName = first.name;
      tokenLogoUrl = first.logoUrl;
      contractAddress = first.contractAddress;
      tokenValue = first.value;
    }

    // Native value in ETH-like unit (only used when no ERC20 transfer)
    final nativeRaw = double.tryParse(json['value']?.toString() ?? '0') ?? 0.0;
    final nativeValue = nativeRaw / 1e18;

    // Use token value if available, otherwise native value
    final effectiveValue = tokenValue > 0 ? tokenValue : nativeValue;

    return OnChainTx(
      hash: json['hash']?.toString() ?? '',
      type: txType,
      from: from,
      to: to,
      value: effectiveValue,
      tokenSymbol: tokenSymbol,
      tokenName: tokenName,
      tokenLogoUrl: tokenLogoUrl,
      contractAddress: contractAddress,
      blockTimestamp:
          DateTime.tryParse(json['block_timestamp']?.toString() ?? '') ??
              DateTime.now(),
      isSuccess: json['receipt_status']?.toString() == '1' ||
          json['receipt_status'] == null,
      gasUsed: json['receipt_gas_used']?.toString(),
      chainKey: chainKey,
      summary: json['summary']?.toString(),
      // Swap legs
      sellSymbol: isSwapTx ? outgoingLeg.symbol : null,
      sellValue: isSwapTx ? outgoingLeg.value : null,
      buySymbol: isSwapTx ? incomingLeg.symbol : null,
      buyValue: isSwapTx ? incomingLeg.value : null,
    );
  }

  /// Parse a single ERC-20 transfer entry from Moralis.
  static _TransferInfo _parseTransfer(Map<String, dynamic> t) {
    final symbol = t['token_symbol']?.toString();
    final name = t['token_name']?.toString();
    final logoUrl = t['token_logo']?.toString();
    final contractAddr = t['address']?.toString();

    double value = 0.0;
    final valueDecimal = double.tryParse(t['value_decimal']?.toString() ?? '');
    if (valueDecimal != null) {
      value = valueDecimal;
    } else {
      final rawVal = double.tryParse(t['value']?.toString() ?? '0') ?? 0.0;
      final decimals =
          int.tryParse(t['token_decimals']?.toString() ?? '18') ?? 18;
      if (decimals > 0 && rawVal > 0) {
        value = rawVal / _pow10(decimals);
      }
    }

    return _TransferInfo(
      symbol: symbol,
      name: name,
      logoUrl: logoUrl,
      contractAddress: contractAddr,
      value: value,
    );
  }

  /// 10^n for decimal division.
  static double _pow10(int n) {
    double result = 1.0;
    for (var i = 0; i < n; i++) {
      result *= 10;
    }
    return result;
  }
}

class _TransferInfo {
  final String? symbol;
  final String? name;
  final String? logoUrl;
  final String? contractAddress;
  final double value;
  const _TransferInfo({
    this.symbol,
    this.name,
    this.logoUrl,
    this.contractAddress,
    required this.value,
  });
}

enum OnChainTxType { send, receive, approval, swap, other }
