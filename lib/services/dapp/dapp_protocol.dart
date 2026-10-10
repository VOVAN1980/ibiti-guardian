import 'dart:convert';

/// Only errors safe to return to an untrusted web page. Never include SDK errors.
class DappError implements Exception {
  final int code;
  final String message;
  const DappError(this.code, this.message);
  Map<String, Object> toJson() => {'code': code, 'message': message};
  @override
  String toString() => 'DappError($code): $message';
}

class DappOrigin {
  static Uri httpsUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        value.length > 4096 ||
        // Dart URI parsing percent-encodes Unicode host names. Reject those
        // as well; a browser must display an unambiguous ASCII/punycode host.
        uri.host.contains('%') ||
        uri.host.codeUnits.any((c) => c > 127) ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(value)) {
      throw const DappError(-32602, 'Only valid HTTPS websites are allowed.');
    }
    return uri;
  }

  static String canonical(String value) => httpsUrl(value).origin;

  static Uri? browserLink(Uri link) {
    if (link.scheme != 'ibitiguard' ||
        link.host != 'browser' ||
        (link.path.isNotEmpty && link.path != '/') ||
        link.queryParametersAll['url']?.length != 1) {
      return null;
    }
    try {
      return httpsUrl(link.queryParameters['url']!);
    } on DappError {
      return null;
    }
  }
}

bool isEvmAddress(Object? value) =>
    value is String && RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(value);

BigInt rpcQuantity(Object? value) {
  if (value is! String ||
      !RegExp(r'^0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)$').hasMatch(value)) {
    throw const DappError(-32602, 'Invalid hexadecimal quantity.');
  }
  final result = BigInt.parse(value.substring(2), radix: 16);
  if (result.bitLength > 256) {
    throw const DappError(-32602, 'Quantity exceeds uint256.');
  }
  return result;
}

String hexQuantity(BigInt value) => '0x${value.toRadixString(16)}';

String rpcBytes(Object? value, {int maxBytes = 65536}) {
  if (value is! String ||
      !RegExp(r'^0x(?:[0-9a-fA-F]{2})*$').hasMatch(value) ||
      value.length > maxBytes * 2 + 2) {
    throw const DappError(-32602, 'Invalid or oversized hexadecimal data.');
  }
  return value;
}

class DappRpcRequest {
  final int id;
  final String method;
  final List<dynamic> params;
  const DappRpcRequest(this.id, this.method, this.params);

  factory DappRpcRequest.decode(String raw) {
    if (raw.length > 150000) {
      throw const DappError(-32600, 'Request is too large.');
    }
    try {
      final object = jsonDecode(raw);
      if (object is! Map ||
          object['id'] is! int ||
          object['method'] is! String ||
          (object['params'] != null && object['params'] is! List) ||
          (object['method'] as String).length > 80) {
        throw const DappError(-32600, 'Invalid wallet request.');
      }
      return DappRpcRequest(object['id'] as int, object['method'] as String,
          List.unmodifiable(object['params'] as List? ?? const []));
    } on DappError {
      rethrow;
    } catch (_) {
      throw const DappError(-32700, 'Invalid JSON.');
    }
  }
}

class DappTransaction {
  final String from;
  final String to;
  final int chainId;
  final BigInt value;
  final String data;
  final Map<String, dynamic> params;

  const DappTransaction._(
      this.from, this.to, this.chainId, this.value, this.data, this.params);

  factory DappTransaction.parse(Object? raw, String account, int chainId) {
    if (raw is! Map || raw.keys.any((k) => k is! String)) {
      throw const DappError(-32602, 'Invalid transaction.');
    }
    const allowed = {
      'from',
      'to',
      'value',
      'data',
      'input',
      'chainId',
      'gas',
      'gasPrice',
      'maxFeePerGas',
      'maxPriorityFeePerGas',
      'nonce',
      'type'
    };
    if (raw.keys.any((k) => !allowed.contains(k)) ||
        !isEvmAddress(raw['from']) ||
        (raw['from'] as String).toLowerCase() != account.toLowerCase() ||
        !isEvmAddress(raw['to']) ||
        (raw['to'] as String).toLowerCase() == '0x${'0' * 40}') {
      throw const DappError(
          -32602, 'Invalid sender, target, or transaction fields.');
    }
    if (raw['chainId'] != null &&
        rpcQuantity(raw['chainId']) != BigInt.from(chainId)) {
      throw const DappError(4901, 'Transaction targets a different network.');
    }
    if (raw['input'] != null &&
        raw['data'] != null &&
        raw['input'] != raw['data']) {
      throw const DappError(-32602, 'Conflicting calldata.');
    }
    final value = rpcQuantity(raw['value'] ?? '0x0');
    final data = rpcBytes(raw['data'] ?? raw['input'] ?? '0x');
    final payload = <String, dynamic>{
      'from': account,
      'to': raw['to'],
      'value': hexQuantity(value),
      'data': data,
      'chainId': hexQuantity(BigInt.from(chainId))
    };
    for (final field in [
      'gas',
      'gasPrice',
      'maxFeePerGas',
      'maxPriorityFeePerGas',
      'nonce',
      'type'
    ]) {
      if (raw[field] != null) {
        payload[field] = hexQuantity(rpcQuantity(raw[field]));
      }
    }
    if (payload.containsKey('gasPrice') &&
        (payload.containsKey('maxFeePerGas') ||
            payload.containsKey('maxPriorityFeePerGas'))) {
      throw const DappError(-32602, 'Conflicting gas pricing.');
    }
    if (payload.containsKey('type') &&
        rpcQuantity(payload['type']) > BigInt.two) {
      throw const DappError(4200, 'Unsupported transaction type.');
    }
    if (payload.containsKey('maxPriorityFeePerGas') &&
            !payload.containsKey('maxFeePerGas') ||
        payload['type'] == '0x0' && payload.containsKey('maxFeePerGas') ||
        payload['type'] == '0x2' && payload.containsKey('gasPrice')) {
      throw const DappError(-32602, 'Inconsistent transaction fee fields.');
    }
    return DappTransaction._(account, raw['to'] as String, chainId, value, data,
        Map.unmodifiable(payload));
  }

  bool get isApproval =>
      data.toLowerCase().startsWith('0x095ea7b3') && data.length == 138;
  bool get isTokenTransfer =>
      data.toLowerCase().startsWith('0xa9059cbb') && data.length == 138;
  String? get tokenRecipient =>
      isApproval || isTokenTransfer ? '0x${data.substring(34, 74)}' : null;
  BigInt? get tokenAmount => isApproval || isTokenTransfer
      ? BigInt.parse(data.substring(74), radix: 16)
      : null;
  bool get isUnlimitedApproval =>
      isApproval && tokenAmount == (BigInt.one << 256) - BigInt.one;
}

/// Frozen, request-local input shown in native UI. Web content cannot edit it.
class DappApproval {
  final String origin;
  final String method;
  final String account;
  final int chainId;
  final String content;
  final List<String> warnings;
  final String? fee;
  final Map<String, String> transactionDetails;
  const DappApproval(
      {required this.origin,
      required this.method,
      required this.account,
      required this.chainId,
      required this.content,
      this.warnings = const [],
      this.fee,
      this.transactionDetails = const {}});
}

Map<String, dynamic> validateTypedData(
    Object? raw, String account, int chainId) {
  try {
    final parsed = raw is String ? jsonDecode(raw) : raw;
    if (parsed is! Map<String, dynamic> ||
        parsed['types'] is! Map ||
        parsed['domain'] is! Map ||
        parsed['message'] is! Map ||
        parsed['primaryType'] is! String ||
        parsed['primaryType'] == 'EIP712Domain' ||
        !(parsed['types'] as Map).containsKey(parsed['primaryType']) ||
        jsonEncode(parsed).length > 50000) {
      throw const DappError(-32602, 'Invalid typed data.');
    }
    final domain = parsed['domain'] as Map;
    if (RegExp(r'[\u202a-\u202e\u2066-\u2069]').hasMatch(jsonEncode(parsed))) {
      throw const DappError(
          -32602, 'Typed data contains hidden direction controls.');
    }
    final domainChain = domain['chainId'];
    if (domainChain != null) {
      final cid = domainChain is int
          ? BigInt.from(domainChain)
          : domainChain is String && domainChain.startsWith('0x')
              ? rpcQuantity(domainChain)
              : BigInt.tryParse('$domainChain');
      if (cid != BigInt.from(chainId)) {
        throw const DappError(4901, 'Typed data targets a different network.');
      }
    }
    if (domain['verifyingContract'] != null &&
        !isEvmAddress(domain['verifyingContract'])) {
      throw const DappError(-32602, 'Invalid verifying contract.');
    }
    final message = parsed['message'] as Map;
    for (final field in ['owner', 'holder', 'from']) {
      if (message[field] != null &&
          (!isEvmAddress(message[field]) ||
              (message[field] as String).toLowerCase() !=
                  account.toLowerCase())) {
        throw const DappError(4100, 'Typed data account is not authorized.');
      }
    }
    // JSON round trip prevents a caller from changing the data during approval.
    return jsonDecode(jsonEncode(parsed)) as Map<String, dynamic>;
  } on DappError {
    rethrow;
  } catch (_) {
    throw const DappError(-32602, 'Invalid typed data.');
  }
}
