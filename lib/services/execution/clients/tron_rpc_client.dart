import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

class TronRpcException implements Exception {
  final String message;
  const TronRpcException(this.message);

  @override
  String toString() => 'TronRpcException: $message';
}

class TronUnsignedTransaction {
  final Map<String, dynamic> rawData;
  final String txId;
  final String rawDataHex;

  const TronUnsignedTransaction({
    required this.rawData,
    required this.txId,
    required this.rawDataHex,
  });
}

class TronSignedTransaction {
  final Map<String, dynamic> rawData;
  final String txId;
  final String rawDataHex;
  final List<String> signaturesHex;
  final bool visible;

  const TronSignedTransaction({
    required this.rawData,
    required this.txId,
    required this.rawDataHex,
    required this.signaturesHex,
    this.visible = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'txID': txId,
      'raw_data': rawData,
      'raw_data_hex': rawDataHex,
      'signature': signaturesHex,
      'visible': visible,
    };
  }
}

abstract class TronRpcClient {
  Future<BigInt> getBalanceSun(String address);

  Future<TronUnsignedTransaction> buildTransferTransaction({
    required String fromAddress,
    required String toAddress,
    required BigInt amountSun,
    String? memo,
  });

  Future<String> broadcastTransaction(TronSignedTransaction signedTx);

  /// Reads a TRC20 token balance via `triggerConstantContract`.
  Future<BigInt> getTrc20Balance(String ownerAddress, String contractAddress);

  /// Builds an unsigned TRC20 transfer transaction.
  Future<TronUnsignedTransaction> buildTrc20Transfer({
    required String ownerAddress,
    required String toAddress,
    required String contractAddress,
    required BigInt amountRaw,
    int feeLimit,
  });

  /// Estimates energy cost for a TRC20 transfer, or null if unavailable.
  Future<int?> estimateEnergy({
    required String ownerAddress,
    required String contractAddress,
    required String toAddress,
    required BigInt amountRaw,
  });

  /// Generic read-only smart contract call via `triggerConstantContract`.
  /// Returns the raw hex result(s) from `constant_result`.
  Future<List<String>> triggerConstantContractRaw({
    required String ownerAddress,
    required String contractAddress,
    required String functionSelector,
    required String parameter,
  });

  /// Builds an unsigned smart contract call tx via `triggerSmartContract`.
  /// Returns the unsigned tx ready for signing.
  Future<TronUnsignedTransaction> buildSmartContractCall({
    required String ownerAddress,
    required String contractAddress,
    required String functionSelector,
    required String parameter,
    int feeLimit,
    BigInt? callValue,
  });

  /// Builds an unsigned TRC20 `approve(spender, amount)` transaction.
  Future<TronUnsignedTransaction> buildTrc20Approve({
    required String ownerAddress,
    required String tokenContract,
    required String spenderAddress,
    required BigInt amount,
    int feeLimit,
  });

  /// Reads current TRC20 allowance via `allowance(owner,spender)`.
  /// Returns raw token amount the spender is allowed to transfer.
  Future<BigInt> getAllowance({
    required String ownerAddress,
    required String spenderAddress,
    required String tokenContract,
  });
}

class TronHttpRpcClient implements TronRpcClient {
  final String baseUrl;
  final String? apiKey;
  final http.Client _http;

  TronHttpRpcClient({
    this.baseUrl = 'https://api.trongrid.io',
    this.apiKey,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  Map<String, String> get _headers {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (apiKey != null && apiKey!.isNotEmpty) {
      headers['TRON-PRO-API-KEY'] = apiKey!;
    }
    return headers;
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final res = await _http
        .post(
          Uri.parse('$baseUrl$path'),
          headers: _headers,
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw TronRpcException('HTTP ${res.statusCode}: ${res.body}');
    }

    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    return decoded;
  }

  @override
  Future<BigInt> getBalanceSun(String address) async {
    final json = await _post('/wallet/getaccount', {
      'address': address,
      'visible': true,
    });

    final balance = json['balance'];
    if (balance == null) {
      // Unactivated Tron account returns essentially an empty object for getaccount.
      return BigInt.zero;
    }
    if (balance is! num) {
      throw const TronRpcException('Invalid getaccount balance response');
    }
    return BigInt.from(balance);
  }

  @override
  Future<TronUnsignedTransaction> buildTransferTransaction({
    required String fromAddress,
    required String toAddress,
    required BigInt amountSun,
    String? memo,
  }) async {
    if (amountSun > BigInt.from(9007199254740991)) {
      throw const TronRpcException(
        'amountSun too large for safe JSON numeric encoding',
      );
    }

    final json = await _post('/wallet/createtransaction', {
      'owner_address': fromAddress,
      'to_address': toAddress,
      'amount': amountSun.toInt(),
      'visible': true,
    });

    final txId = json['txID'];
    final rawData = json['raw_data'];
    final rawDataHex = json['raw_data_hex'];

    if (txId is! String || txId.isEmpty) {
      throw const TronRpcException(
          'Invalid createtransaction response: missing txID');
    }
    if (rawData is! Map<String, dynamic>) {
      throw const TronRpcException(
          'Invalid createtransaction response: missing raw_data');
    }
    if (rawDataHex is! String || rawDataHex.isEmpty) {
      throw const TronRpcException(
          'Invalid createtransaction response: missing raw_data_hex');
    }

    // Memo can be attached later in raw_data, ignored for MVP to avoid broken tx.

    return TronUnsignedTransaction(
      rawData: rawData,
      txId: txId,
      rawDataHex: rawDataHex,
    );
  }

  @override
  Future<String> broadcastTransaction(TronSignedTransaction signedTx) async {
    final json = await _post('/wallet/broadcasttransaction', signedTx.toJson());

    final success = json['result'] == true;
    if (!success) {
      final message = json['message']?.toString() ?? jsonEncode(json);
      throw TronRpcException('Broadcast failed: $message');
    }

    final txId = json['txid']?.toString() ?? signedTx.txId;
    if (txId.isEmpty) {
      throw const TronRpcException('Broadcast succeeded but txid missing');
    }

    return txId;
  }

  // ── TRC20 Smart Contract Calls ────────────────────────────────────────────

  /// Well-known USDT TRC20 contract on Tron mainnet.
  static const String usdtContract = 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t';

  /// USDT has 6 decimals (1 USDT = 1_000_000 raw).
  static const int usdtDecimals = 6;

  /// Default fee_limit for TRC20 transfers: 15 TRX (15_000_000 sun).
  /// Covers energy cost for a standard transfer even without staked TRX.
  static const int defaultTrc20FeeLimit = 15000000;

  @override
  Future<BigInt> getTrc20Balance(
      String ownerAddress, String contractAddress) async {
    // ABI-encode owner address for balanceOf(address)
    final paramHex = abiEncodeAddress(ownerAddress);

    final json = await _post('/wallet/triggerconstantcontract', {
      'owner_address': ownerAddress,
      'contract_address': contractAddress,
      'function_selector': 'balanceOf(address)',
      'parameter': paramHex,
      'visible': true,
    });

    // Check for errors
    final result = json['result'] as Map<String, dynamic>?;
    if (result != null && result['result'] == false) {
      final msg = result['message']?.toString() ?? 'unknown';
      throw TronRpcException('balanceOf failed: $msg');
    }

    final constantResult = json['constant_result'] as List<dynamic>?;
    if (constantResult == null || constantResult.isEmpty) {
      return BigInt.zero; // No token account or uninitialized
    }

    final hex = constantResult[0].toString();
    if (hex.isEmpty || hex == '0' * 64) return BigInt.zero;
    return BigInt.parse(hex, radix: 16);
  }

  @override
  Future<TronUnsignedTransaction> buildTrc20Transfer({
    required String ownerAddress,
    required String toAddress,
    required String contractAddress,
    required BigInt amountRaw,
    int feeLimit = defaultTrc20FeeLimit,
  }) async {
    // ABI-encode: transfer(address,uint256)
    final paramHex =
        '${abiEncodeAddress(toAddress)}${abiEncodeUint256(amountRaw)}';

    final json = await _post('/wallet/triggersmartcontract', {
      'owner_address': ownerAddress,
      'contract_address': contractAddress,
      'function_selector': 'transfer(address,uint256)',
      'parameter': paramHex,
      'fee_limit': feeLimit,
      'visible': true,
    });

    // Check for errors in result
    final result = json['result'] as Map<String, dynamic>?;
    if (result == null || result['result'] != true) {
      final msg = result?['message']?.toString() ?? jsonEncode(json);
      throw TronRpcException('triggerSmartContract failed: $msg');
    }

    final tx = json['transaction'] as Map<String, dynamic>?;
    if (tx == null) {
      throw const TronRpcException(
          'triggerSmartContract: missing transaction in response');
    }

    final txId = tx['txID']?.toString() ?? '';
    final rawData = tx['raw_data'] as Map<String, dynamic>?;
    final rawDataHex = tx['raw_data_hex']?.toString() ?? '';

    if (txId.isEmpty || rawData == null || rawDataHex.isEmpty) {
      throw const TronRpcException(
          'triggerSmartContract: invalid transaction structure');
    }

    return TronUnsignedTransaction(
      rawData: rawData,
      txId: txId,
      rawDataHex: rawDataHex,
    );
  }

  @override
  Future<int?> estimateEnergy({
    required String ownerAddress,
    required String contractAddress,
    required String toAddress,
    required BigInt amountRaw,
  }) async {
    final paramHex =
        '${abiEncodeAddress(toAddress)}${abiEncodeUint256(amountRaw)}';

    try {
      final json = await _post('/wallet/estimateenergy', {
        'owner_address': ownerAddress,
        'contract_address': contractAddress,
        'function_selector': 'transfer(address,uint256)',
        'parameter': paramHex,
        'visible': true,
      });

      final energy = json['energy_required'];
      if (energy is num) return energy.toInt();
      return null;
    } catch (_) {
      return null; // Graceful fallback — not all TronGrid plans support this
    }
  }

  // ── Generic Smart Contract Methods ────────────────────────────────────────

  /// Default fee_limit for TRC20 swap operations: 50 TRX (50_000_000 sun).
  static const int defaultSwapFeeLimit = 50000000;

  /// Default fee_limit for TRC20 approve: 10 TRX (10_000_000 sun).
  static const int defaultApproveFeeLimit = 10000000;

  @override
  Future<List<String>> triggerConstantContractRaw({
    required String ownerAddress,
    required String contractAddress,
    required String functionSelector,
    required String parameter,
  }) async {
    final json = await _post('/wallet/triggerconstantcontract', {
      'owner_address': ownerAddress,
      'contract_address': contractAddress,
      'function_selector': functionSelector,
      'parameter': parameter,
      'visible': true,
    });

    final result = json['result'] as Map<String, dynamic>?;
    if (result != null && result['result'] == false) {
      final msg = result['message']?.toString() ?? 'unknown';
      throw TronRpcException('triggerConstantContract failed: $msg');
    }

    final constantResult = json['constant_result'] as List<dynamic>?;
    if (constantResult == null || constantResult.isEmpty) {
      return [];
    }

    return constantResult.map((e) => e.toString()).toList();
  }

  @override
  Future<TronUnsignedTransaction> buildSmartContractCall({
    required String ownerAddress,
    required String contractAddress,
    required String functionSelector,
    required String parameter,
    int feeLimit = defaultSwapFeeLimit,
    BigInt? callValue,
  }) async {
    final body = <String, dynamic>{
      'owner_address': ownerAddress,
      'contract_address': contractAddress,
      'function_selector': functionSelector,
      'parameter': parameter,
      'fee_limit': feeLimit,
      'visible': true,
    };

    // callValue: native TRX to attach (in sun), for swapExactTRXForTokens
    if (callValue != null && callValue > BigInt.zero) {
      body['call_value'] = callValue.toInt();
    }

    final json = await _post('/wallet/triggersmartcontract', body);

    final result = json['result'] as Map<String, dynamic>?;
    if (result == null || result['result'] != true) {
      final msg = result?['message']?.toString() ?? jsonEncode(json);
      throw TronRpcException('triggerSmartContract failed: $msg');
    }

    final tx = json['transaction'] as Map<String, dynamic>?;
    if (tx == null) {
      throw const TronRpcException(
          'triggerSmartContract: missing transaction in response');
    }

    final txId = tx['txID']?.toString() ?? '';
    final rawData = tx['raw_data'] as Map<String, dynamic>?;
    final rawDataHex = tx['raw_data_hex']?.toString() ?? '';

    if (txId.isEmpty || rawData == null || rawDataHex.isEmpty) {
      throw const TronRpcException(
          'triggerSmartContract: invalid transaction structure');
    }

    return TronUnsignedTransaction(
      rawData: rawData,
      txId: txId,
      rawDataHex: rawDataHex,
    );
  }

  @override
  Future<TronUnsignedTransaction> buildTrc20Approve({
    required String ownerAddress,
    required String tokenContract,
    required String spenderAddress,
    required BigInt amount,
    int feeLimit = defaultApproveFeeLimit,
  }) async {
    // ABI: approve(address,uint256)
    final paramHex =
        '${abiEncodeAddress(spenderAddress)}${abiEncodeUint256(amount)}';

    return buildSmartContractCall(
      ownerAddress: ownerAddress,
      contractAddress: tokenContract,
      functionSelector: 'approve(address,uint256)',
      parameter: paramHex,
      feeLimit: feeLimit,
    );
  }

  @override
  Future<BigInt> getAllowance({
    required String ownerAddress,
    required String spenderAddress,
    required String tokenContract,
  }) async {
    // ABI: allowance(address owner, address spender)
    final paramHex =
        '${abiEncodeAddress(ownerAddress)}${abiEncodeAddress(spenderAddress)}';

    final results = await triggerConstantContractRaw(
      ownerAddress: ownerAddress,
      contractAddress: tokenContract,
      functionSelector: 'allowance(address,address)',
      parameter: paramHex,
    );

    if (results.isEmpty || results.first.isEmpty) {
      return BigInt.zero;
    }

    final hex = results.first.replaceAll(RegExp(r'^0+'), '');
    if (hex.isEmpty) return BigInt.zero;
    return BigInt.parse(hex, radix: 16);
  }

  // ── ABI Encoding Helpers ──────────────────────────────────────────────────

  /// ABI-encodes a Tron base58check address as a 32-byte hex string.
  ///
  /// Validates:
  /// 1. Decoded length == 25 bytes (1 prefix + 20 address + 4 checksum)
  /// 2. Prefix byte == 0x41
  /// 3. Checksum == first 4 bytes of SHA256(SHA256(prefix + address))
  static String abiEncodeAddress(String tronBase58Address) {
    final decoded = _tronBase58Decode(tronBase58Address);
    _validateTronAddress(decoded, tronBase58Address);
    // Extract 20-byte address (skip prefix byte 0x41)
    final addressBytes = decoded.sublist(1, 21);
    final hex =
        addressBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return hex.padLeft(64, '0');
  }

  /// ABI-encodes a uint256 value as a 32-byte hex string.
  static String abiEncodeUint256(BigInt value) {
    return value.toRadixString(16).padLeft(64, '0');
  }

  /// Validates a decoded Tron address: length, prefix, checksum.
  static void _validateTronAddress(List<int> decoded, String original) {
    // 1. Length check: 1 (0x41) + 20 (address) + 4 (checksum) = 25
    if (decoded.length != 25) {
      throw TronRpcException(
        'Invalid Tron address "$original": '
        'expected 25 bytes, got ${decoded.length}',
      );
    }

    // 2. Prefix check: must be 0x41
    if (decoded[0] != 0x41) {
      throw TronRpcException(
        'Invalid Tron address "$original": '
        'prefix byte is 0x${decoded[0].toRadixString(16)}, expected 0x41',
      );
    }

    // 3. Checksum: first 4 bytes of SHA256(SHA256(payload[0..20]))
    final payload = Uint8List.fromList(decoded.sublist(0, 21));
    final hash1 = sha256.convert(payload).bytes;
    final hash2 = sha256.convert(hash1).bytes;
    final expectedChecksum = hash2.sublist(0, 4);
    final actualChecksum = decoded.sublist(21, 25);

    for (int i = 0; i < 4; i++) {
      if (expectedChecksum[i] != actualChecksum[i]) {
        throw TronRpcException(
          'Invalid Tron address "$original": checksum mismatch',
        );
      }
    }
  }

  /// Validates a Tron base58check address without ABI-encoding.
  /// Returns true if the address is valid, throws [TronRpcException] otherwise.
  static bool validateTronAddress(String tronBase58Address) {
    final decoded = _tronBase58Decode(tronBase58Address);
    _validateTronAddress(decoded, tronBase58Address);
    return true;
  }

  /// Decodes a Tron base58check address to raw bytes.
  ///
  /// Returns 25 bytes: 1 (prefix 0x41) + 20 (address) + 4 (checksum).
  static List<int> _tronBase58Decode(String input) {
    const alphabet =
        '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
    BigInt value = BigInt.zero;
    for (int i = 0; i < input.length; i++) {
      final charIndex = alphabet.indexOf(input[i]);
      if (charIndex < 0) {
        throw TronRpcException('Invalid base58 character: ${input[i]}');
      }
      value = (value * BigInt.from(58)) + BigInt.from(charIndex);
    }
    final bytes = <int>[];
    while (value > BigInt.zero) {
      bytes.add((value % BigInt.from(256)).toInt());
      value = value ~/ BigInt.from(256);
    }
    // Leading zeros from base58 '1' chars
    int leadingZeros = 0;
    while (leadingZeros < input.length && input[leadingZeros] == '1') {
      leadingZeros++;
    }
    final result = List<int>.filled(leadingZeros, 0) + bytes.reversed.toList();
    return result;
  }
}
