import 'dart:typed_data';
import 'package:ibiti_guardian/models/transaction_request.dart';

/// Builds ABI calldata and minimal tx params (`to`, `data`, `value`) for on-chain execution.
///
/// Design contract:
/// - No nonce, no gasPrice, no gasLimit — Privy provider handles all of that.
/// - Swap calldata is ALWAYS taken from [TransactionRequest.calldata] (injected by 0x quote).
///   This builder never assembles swap calldata manually.
/// - Returns `Map<String, dynamic>` ready for `eth_sendTransaction`.
class NativeTransactionBuilder {
  NativeTransactionBuilder._();

  // ── ERC-20 function selectors (first 4 bytes of keccak256 of signature) ──────
  // transfer(address,uint256)  → 0xa9059cbb
  static const _kTransfer = [0xa9, 0x05, 0x9c, 0xbb];
  // approve(address,uint256)   → 0x095ea7b3
  static const _kApprove = [0x09, 0x5e, 0xa7, 0xb3];

  // ── Calldata Builders ─────────────────────────────────────────────────────────

  /// Encodes `transfer(toAddress, amountWei)` calldata.
  static Uint8List buildTransferCalldata(String toAddress, BigInt amountWei) =>
      _encodeAddressUint256(_kTransfer, toAddress, amountWei);

  /// Encodes `approve(spenderAddress, amountWei)` calldata.
  static Uint8List buildApproveCalldata(
          String spenderAddress, BigInt amountWei) =>
      _encodeAddressUint256(_kApprove, spenderAddress, amountWei);

  // ── Tx Params Builders (passed directly to eth_sendTransaction) ───────────────

  /// Native token transfer (ETH / BNB / MATIC).
  /// `data` is `0x` — just value transfer.
  static Map<String, dynamic> buildNativeTransferParams({
    required String fromAddress,
    required String toAddress,
    required BigInt amountWei,
  }) =>
      {
        'from': fromAddress,
        'to': toAddress,
        'value': _toHex(amountWei),
        'data': '0x',
      };

  /// ERC-20 token transfer via `transfer(address,uint256)`.
  static Map<String, dynamic> buildErc20TransferParams({
    required String fromAddress,
    required String tokenContract,
    required String toAddress,
    required BigInt amountWei,
  }) {
    final data = buildTransferCalldata(toAddress, amountWei);
    return {
      'from': fromAddress,
      'to': tokenContract,
      'value': '0x0',
      'data': _bytesToHexPrefixed(data),
    };
  }

  /// ERC-20 approve via `approve(address,uint256)`.
  ///
  /// [spenderAddress] should be `quote.allowanceTarget` (0x AllowanceHolder),
  /// NOT the router address.
  static Map<String, dynamic> buildApproveParams({
    required String fromAddress,
    required String tokenContract,
    required String spenderAddress,
    required BigInt amountWei,
  }) {
    final data = buildApproveCalldata(spenderAddress, amountWei);
    return {
      'from': fromAddress,
      'to': tokenContract,
      'value': '0x0',
      'data': _bytesToHexPrefixed(data),
    };
  }

  /// Swap tx params using REAL calldata from [TransactionRequest.calldata].
  ///
  /// Calldata is NEVER built here — it comes verbatim from the 0x quote.
  /// [nativeValue] is the native token amount to attach (non-zero only when selling native).
  ///
  /// Throws [ArgumentError] if calldata fails basic sanity checks:
  ///   - must not be empty
  ///   - must be at least 4 bytes (function selector)
  static Map<String, dynamic> buildSwapParams({
    required String fromAddress,
    required String routerAddress,
    required Uint8List calldata,
    required BigInt nativeValue,
  }) {
    // ── Calldata sanity gate ─────────────────────────────────────────────────
    if (calldata.isEmpty) {
      throw ArgumentError(
          'Swap calldata is empty. Quote may be stale or provider returned no data.');
    }
    if (calldata.length < 4) {
      throw ArgumentError(
          'Swap calldata is too short (${calldata.length} bytes). '
          'A valid call must have at least a 4-byte function selector.');
    }
    // ────────────────────────────────────────────────────────────────────────

    return {
      'from': fromAddress,
      'to': routerAddress,
      'value': _toHex(nativeValue),
      'data': _bytesToHexPrefixed(calldata),
    };
  }

  // ── Token Amount Helper ───────────────────────────────────────────────────────

  /// Converts a human-unit amount expressed as a [String] to Wei.
  ///
  /// Uses pure BigInt arithmetic — no floating-point, no precision loss.
  /// Safe for 18-decimal tokens and for very small fractional amounts.
  ///
  /// Examples:
  ///   toWei('10.5')        → 10500000000000000000
  ///   toWei('0.000001', decimals: 6) → 1
  ///   toWei('1')           → 1000000000000000000
  static BigInt toWei(String humanAmount, {int decimals = 18}) {
    final parts = humanAmount.trim().split('.');
    final whole = BigInt.parse(parts[0].isEmpty ? '0' : parts[0]);
    final rawFrac = parts.length > 1 ? parts[1] : '';
    // Pad or truncate fractional part to exactly [decimals] digits
    final paddedFrac = rawFrac.padRight(decimals, '0').substring(0, decimals);
    final frac = BigInt.parse(paddedFrac.isEmpty ? '0' : paddedFrac);
    return whole * BigInt.from(10).pow(decimals) + frac;
  }

  /// Convenience overload for callers that already have a [double].
  ///
  /// Uses [toString] (shortest exact representation) to avoid IEEE 754 noise.
  /// Falls back to [toStringAsFixed] only for scientific notation (e.g. 1e-7).
  static BigInt toWeiFromDouble(double humanAmount, {int decimals = 18}) {
    // toString() gives clean "0.05", not "0.050000000000000003"
    String s = humanAmount.toString();
    // Handle scientific notation (e.g. 1e-7 → "0.0000001")
    if (s.contains('e') || s.contains('E')) {
      s = humanAmount.toStringAsFixed(decimals.clamp(0, 20));
    }
    return toWei(s, decimals: decimals);
  }

  // ── Private Helpers ───────────────────────────────────────────────────────────

  /// Encodes `selector(address, uint256)` — covers transfer and approve.
  static Uint8List _encodeAddressUint256(
      List<int> selector, String address, BigInt value) {
    final buf = Uint8List(4 + 32 + 32);
    for (var i = 0; i < 4; i++) {
      buf[i] = selector[i];
    }

    // Address: right-aligned in 32-byte word (12 zero bytes + 20 address bytes)
    final addrClean =
        (address.startsWith('0x') ? address.substring(2) : address)
            .padLeft(40, '0')
            .toLowerCase();
    final addrBytes = _hexToBytes(addrClean);
    for (var i = 0; i < addrBytes.length; i++) {
      buf[4 + 12 + i] = addrBytes[i];
    }

    // uint256: big-endian in 32 bytes
    final valHex = value.toRadixString(16).padLeft(64, '0');
    final valBytes = _hexToBytes(valHex);
    for (var i = 0; i < valBytes.length && i < 32; i++) {
      buf[4 + 32 + i] = valBytes[i];
    }

    return buf;
  }

  static String _toHex(BigInt value) =>
      value == BigInt.zero ? '0x0' : '0x${value.toRadixString(16)}';

  static String _bytesToHexPrefixed(Uint8List bytes) =>
      '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

  static List<int> _hexToBytes(String hex) {
    final clean = hex.length.isOdd ? '0$hex' : hex;
    return List.generate(
      clean.length ~/ 2,
      (i) => int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16),
    );
  }
}

/// Thrown by [IBITIVaultSigner.sendTransaction] when local EPK policy blocks execution.
/// Contains a [reason] that is safe to display directly in the UI.
class EPKValidationException implements Exception {
  final String reason;
  const EPKValidationException(this.reason);

  @override
  String toString() => reason;
}
