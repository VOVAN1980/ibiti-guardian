import 'dart:convert';
import 'dart:typed_data';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:web3dart/web3dart.dart';
import 'dapp_protocol.dart';
import 'dapp_simulation.dart';

const _withdrawSelector = '0x4093ae3e';
const _implementationSlot =
    '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
const _withdrawTopic =
    '0xa6786aab7dbbc48b4b0387488b407bd81448030ab207b50bea7dbb5fbc1cd9eb';
const _transferTopic =
    '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
const _reader = '0x0000000000000000000000000000000000000000';
const _nativeTrace = '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

String _hash(String data) =>
    bytesToHex(keccak256(hexToBytes(data)), include0x: true);
String _addressWord(String address) =>
    address.substring(2).toLowerCase().padLeft(64, '0');
String _wordAddress(String word) {
  if (!RegExp(r'^0{24}[0-9a-f]{40}$').hasMatch(word) || word == '0' * 64) {
    throw const DappError(4100, 'Invalid verified withdrawal address.');
  }
  return '0x${word.substring(24)}';
}

/// Exact ABI, not a heuristic on a method name. No signing authorization is
/// created here. A match still requires runtime-code proofs AND simulation.
class DappReceiveCall {
  final String token;
  final String recipient;
  final BigInt amount;
  final String operation;
  final BigInt deadline;
  final List<String> sources;
  const DappReceiveCall._(this.token, this.recipient, this.amount,
      this.operation, this.deadline, this.sources);

  static bool recognizes(DappTransaction tx) =>
      tx.data.toLowerCase().startsWith(_withdrawSelector);

  static DappReceiveCall parse(DappTransaction tx) {
    if (!recognizes(tx) || tx.value != BigInt.zero) {
      throw const DappError(4100, 'Unsupported verified withdrawal.');
    }
    final data = tx.data.substring(10).toLowerCase();
    if (data.length < 7 * 64 || data.length % 64 != 0) {
      throw const DappError(4100, 'Invalid verified withdrawal encoding.');
    }
    String word(int index) {
      if (index < 0 || (index + 1) * 64 > data.length) {
        throw const DappError(4100, 'Invalid verified withdrawal encoding.');
      }
      return data.substring(index * 64, (index + 1) * 64);
    }

    BigInt number(int index) => BigInt.parse(word(index), radix: 16);
    final token = _wordAddress(word(0));
    final recipient = _wordAddress(word(1));
    final amount = number(2);
    // V4 is the reviewed two-authority protocol. Older 65-byte certificates
    // deliberately do not qualify; neither do arbitrary ABI offsets/padding.
    if (recipient != tx.from.toLowerCase() ||
        amount <= BigInt.zero ||
        number(5) != BigInt.from(224) ||
        number(6) != BigInt.from(544) ||
        number(7) != BigInt.from(258) ||
        word(16).substring(4) != '0' * 60) {
      throw const DappError(4100, 'Invalid verified withdrawal encoding.');
    }
    final count = number(17);
    if (count > BigInt.from(32) || data.length != (18 + count.toInt()) * 64) {
      throw const DappError(4100, 'Withdrawal source count is unsupported.');
    }
    return DappReceiveCall._(
        token,
        recipient,
        amount,
        '0x${word(3)}',
        number(4),
        List.unmodifiable(
            [for (var i = 0; i < count.toInt(); i++) '0x${word(18 + i)}']));
  }
}

class _CodeFingerprint {
  final int bytes;
  final String hash;
  final List<int> immutableOffsets;
  _CodeFingerprint(Map data)
      : bytes = data['bytes'] as int,
        hash = data['hash'] as String,
        immutableOffsets =
            List<int>.unmodifiable(data['immutableOffsets'] as List);

  void verify(Object? raw, {String? immutableAddress}) {
    final code = Uint8List.fromList(hexToBytes(rpcBytes(raw)));
    if (code.length != bytes ||
        immutableOffsets.isNotEmpty && !isEvmAddress(immutableAddress)) {
      throw const DappError(4100, 'Contract code is not a reviewed receiver.');
    }
    for (final offset in immutableOffsets) {
      final expected = _addressWord(immutableAddress!);
      if (offset < 0 ||
          offset + 32 > code.length ||
          bytesToHex(code.sublist(offset, offset + 32)) != expected) {
        throw const DappError(4100, 'Receiver dependency binding changed.');
      }
      code.fillRange(offset, offset + 32, 0);
    }
    if (bytesToHex(keccak256(code), include0x: true) != hash) {
      throw const DappError(4100, 'Contract code is not a reviewed receiver.');
    }
  }
}

/// Release-safe reviewed bytecode fingerprints. A website, ABI or function
/// selector cannot register itself. New receiver families require code review
/// and another shipped manifest entry, not an EPK exemption.
class DappReceiverRegistry {
  final Map<String, _CodeFingerprint> _code;
  DappReceiverRegistry.fromJson(String json) : _code = _decode(json);
  static Map<String, _CodeFingerprint> _decode(String json) {
    final data = jsonDecode(json) as Map;
    if (data['version'] != 1) {
      throw const DappError(4100, 'Unsupported receiver registry.');
    }
    return Map.unmodifiable({
      for (final key in ['proxy', 'receiver', 'book', 'forwarder'])
        key: _CodeFingerprint(data['code'][key] as Map)
    });
  }

  Future<void> verify(DappTransaction tx, DappReceiveCall call, DappRpcRead rpc,
      String block) async {
    final chain = tx.chainId;
    Future<String> code(String address) async =>
        rpcBytes(await rpc(chain, 'eth_getCode', [address, block]));
    Future<String> address(String target, String selector) async {
      final raw = rpcBytes(await rpc(chain, 'eth_call', [
        {'to': target, 'data': selector},
        block
      ]));
      if (raw.length != 66) {
        throw const DappError(4100, 'Invalid receiver dependency response.');
      }
      return _wordAddress(raw.substring(2).toLowerCase());
    }

    _code['proxy']!.verify(await code(tx.to));
    final slot = rpcBytes(await rpc(
        chain, 'eth_getStorageAt', [tx.to, _implementationSlot, block]));
    if (slot.length != 66) {
      throw const DappError(4100, 'Invalid receiver implementation.');
    }
    final implementation = _wordAddress(slot.substring(2).toLowerCase());
    _code['receiver']!.verify(await code(implementation));
    if (call.sources.isEmpty) return;
    final book = await address(tx.to, '0x05a8da72');
    final forwarder = await address(book, '0xf645d4f9');
    _code['book']!.verify(await code(book), immutableAddress: forwarder);
    _code['forwarder']!.verify(await code(forwarder), immutableAddress: book);
    if (await address(book, '0xb269681d') != tx.to.toLowerCase()) {
      throw const DappError(4100, 'Receiver destination changed.');
    }
    final cloneRuntime =
        '0x363d3d373d3d3d363d73${forwarder.substring(2)}5af43d82803e903d91602b57fd5bf3';
    final cloneInit = '0x3d602d80600a3d3981f3${cloneRuntime.substring(2)}';
    // Known CREATE2 derivation; do not trust a site-supplied source address.
    // Bound fan-out to four read RPCs at a time.
    final sources = call.sources.toSet().toList(growable: false);
    for (var start = 0; start < sources.length; start += 4) {
      final end = (start + 4).clamp(0, sources.length);
      await Future.wait(sources.sublist(start, end).map((salt) async {
        final digest = _hash(
            '0xff${book.substring(2)}${salt.substring(2)}${_hash(cloneInit).substring(2)}');
        final deposit = '0x${digest.substring(digest.length - 40)}';
        if (deposit == tx.from.toLowerCase()) {
          throw const DappError(4100, 'Withdrawal cannot collect this wallet.');
        }
        final existing = (await code(deposit)).toLowerCase();
        if (existing != '0x' && existing != cloneRuntime) {
          throw const DappError(4100, 'Deposit forwarder code changed.');
        }
      }));
    }
  }
}

/// Host-owned evidence. Not constructed from website fields or transfer logs
/// alone. Valid only for this exact request and a short pre-signing interval.
class DappReceiveEvidence {
  final DappReceiveCall call;
  final String block;
  final DateTime checkedAt;
  final String _requestHash;
  final String _payloadHash;
  final DappTransaction _transaction;
  DappReceiveEvidence._(this.call, this.block, this.checkedAt,
      this._transaction, DappGasPlan gas)
      : _requestHash = _hashRequest(_transaction),
        _payloadHash = _hashPayload(gas.payload);

  bool _fresh(DateTime? now) {
    final instant = now ?? DateTime.now();
    final age = instant.difference(checkedAt);
    return age >= Duration.zero && age <= const Duration(seconds: 30) &&
        BigInt.from(instant.millisecondsSinceEpoch ~/ 1000) < call.deadline;
  }

  bool matches(DappTransaction tx, {DateTime? now}) =>
      _fresh(now) && _requestHash == _hashRequest(tx);

  /// The exact gas-inclusive payload checked in the simulation, not just a
  /// target address or selector. Rechecked immediately before the provider.
  bool matchesPayload(Map<String, dynamic> payload, {DateTime? now}) =>
      _fresh(now) && _payloadHash == _hashPayload(payload);

  bool matchesContext(TransactionRequest context, {DateTime? now}) =>
      _fresh(now) && context.type == TransactionType.unknown &&
      context.chainId == _transaction.chainId &&
      context.fromAddress.toLowerCase() == _transaction.from.toLowerCase() &&
      context.toAddress.toLowerCase() == _transaction.to.toLowerCase() &&
      context.rawAmount == BigInt.zero && context.amount == 0 &&
      context.spenderAddress == null && !context.isUnlimitedApproval &&
      context.calldata != null &&
      bytesToHex(context.calldata!, include0x: true).toLowerCase() ==
          _transaction.data.toLowerCase();

  static String _hashPayload(Map<String, dynamic> payload) {
    final keys = payload.keys.toList()..sort();
    return bytesToHex(keccak256(utf8.encode(jsonEncode({
      for (final key in keys) key: payload[key],
    }))), include0x: true);
  }

  static String _hashRequest(DappTransaction tx) =>
      bytesToHex(keccak256(utf8.encode(jsonEncode(tx.params))),
          include0x: true);

  bool confirmsReceipt(Map receipt, DappTransaction tx) =>
      receipt['from']?.toString().toLowerCase() == tx.from.toLowerCase() &&
      receipt['to']?.toString().toLowerCase() == tx.to.toLowerCase() &&
      _confirmsWithdrawal(receipt['logs'], tx, call);
}

bool _confirmsWithdrawal(
    Object? rawLogs, DappTransaction tx, DappReceiveCall call) {
  if (rawLogs is! List || rawLogs.length > 2048) return false;
  var withdrawalCount = 0;
  var received = BigInt.zero;
  for (final log in rawLogs) {
    if (log is! Map || log['removed'] == true || log['topics'] is! List) {
      return false;
    }
    final topics =
        (log['topics'] as List).map((e) => e.toString().toLowerCase()).toList();
    final emitter = log['address']?.toString().toLowerCase();
    if (emitter == tx.to.toLowerCase() &&
        topics.length == 4 &&
        topics[0] == _withdrawTopic &&
        topics[1] == call.operation &&
        topics[2] == '0x${_addressWord(call.token)}' &&
        topics[3] == '0x${_addressWord(call.recipient)}' &&
        log['data']?.toString().toLowerCase() ==
            '0x${call.amount.toRadixString(16).padLeft(64, '0')}') {
      withdrawalCount++;
    }
    if (emitter == call.token &&
        topics.length == 3 &&
        topics[0] == _transferTopic &&
        topics[1] == '0x${_addressWord(tx.to)}' &&
        topics[2] == '0x${_addressWord(call.recipient)}') {
      final raw = log['data'];
      if (raw is! String || !RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(raw)) {
        return false;
      }
      received += BigInt.parse(raw.substring(2), radix: 16);
    }
  }
  return withdrawalCount == 1 && received == call.amount;
}

/// Three calls in one simulated state: balance -> exact transaction -> balance.
/// No state overrides, no funded fake wallet, no signature, no broadcast.
/// Only reviewed receiving code can reduce unknown-spend to verified zero.
Future<DappReceiveEvidence> simulateVerifiedReceive(DappTransaction tx,
    DappGasPlan gas, DappReceiverRegistry registry, DappRpcRead rpc,
    {required bool Function(String) isVerifiedToken, DateTime? now}) async {
  final instant = now ?? DateTime.now();
  final call = DappReceiveCall.parse(tx);
  if (!isVerifiedToken(call.token) ||
      call.deadline <= BigInt.from(instant.millisecondsSinceEpoch ~/ 1000)) {
    throw const DappError(4100, 'Withdrawal token or deadline is invalid.');
  }
  final block =
      hexQuantity(rpcQuantity(await rpc(tx.chainId, 'eth_blockNumber', [])));
  await registry.verify(tx, call, rpc, block);
  final balance = {
    'from': _reader,
    'to': call.token,
    'gas': '0x186a0',
    'data': '0x70a08231${_addressWord(tx.from)}'
  };
  final transaction = Map<String, dynamic>.from(gas.payload)
    ..remove('chainId')
    ..remove('type');
  final result = await rpc(tx.chainId, 'eth_simulateV1', [
    {
      'blockStateCalls': [
        {
          'calls': [balance, transaction, balance]
        }
      ],
      'validation': false,
      'traceTransfers': true
    },
    block
  ]);
  if (result is! List || result.length != 1 || result.single is! Map) {
    throw const DappError(4100, 'Complete asset simulation is unavailable.');
  }
  final calls = result.single['calls'];
  if (calls is! List ||
      calls.length != 3 ||
      calls.any(
          (c) => c is! Map || c['status'] != '0x1' || c['error'] != null)) {
    throw const DappError(4100, 'Withdrawal asset simulation failed.');
  }
  BigInt balanceResult(Map result) {
    final raw = rpcBytes(result['returnData']);
    if (raw.length != 66) {
      throw const DappError(4100, 'Invalid simulated token balance.');
    }
    return BigInt.parse(raw.substring(2), radix: 16);
  }

  if (balanceResult(calls[2] as Map) - balanceResult(calls[0] as Map) !=
          call.amount ||
      !_confirmsWithdrawal(calls[1]['logs'], tx, call)) {
    throw const DappError(
        4100, 'The simulated withdrawal does not match its payout.');
  }
  // Defense in depth: reviewed code cannot debit the caller. Reject any native
  // transfer or token authorization/debit emitted for this account anyway.
  for (final log in calls[1]['logs'] as List) {
    final topics = log['topics'] as List;
    if (topics.length >= 2 &&
        topics[1].toString().toLowerCase() == '0x${_addressWord(tx.from)}') {
      final native = log['address']?.toString().toLowerCase() == _nativeTrace;
      throw DappError(
          4100,
          native
              ? 'Withdrawal unexpectedly spends native coins.'
              : 'Withdrawal unexpectedly changes spending permissions or tokens.');
    }
  }
  final completed = now ?? DateTime.now();
  if (completed.difference(instant) > const Duration(seconds: 30)) {
    throw const DappError(4100, 'Withdrawal simulation is no longer fresh.');
  }
  return DappReceiveEvidence._(call, block, instant, tx, gas);
}
