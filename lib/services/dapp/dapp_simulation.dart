import 'dapp_protocol.dart';

typedef DappRpcRead = Future<dynamic> Function(int, String, List<dynamic>);

class DappGasPlan {
  final Map<String, dynamic> payload;
  final BigInt maxFee;
  DappGasPlan(Map<String, dynamic> payload, this.maxFee)
      : payload = Map.unmodifiable(payload);
}

/// Exact-call RPC preflight only. It cannot sign or submit a transaction, and
/// does not claim to prove token balance changes or smart-contract safety.
Future<DappGasPlan> simulateDappTransaction(DappTransaction tx, DappRpcRead rpc,
    {DappGasPlan? approved}) async {
  final callParams = Map<String, dynamic>.from(tx.params)
    ..remove('chainId')
    ..remove('type');
  await rpc(tx.chainId, 'eth_call', [callParams, 'latest']);
  final gas =
      rpcQuantity(await rpc(tx.chainId, 'eth_estimateGas', [callParams]));
  if (gas <= BigInt.zero) {
    throw const DappError(-32000, 'Invalid gas estimate.');
  }
  final gasLimit = tx.params['gas'] == null
      ? (gas * BigInt.from(120) + BigInt.from(99)) ~/ BigInt.from(100)
      : rpcQuantity(tx.params['gas']);
  if (gasLimit < gas) {
    throw const DappError(-32000, 'The requested gas limit is too low.');
  }
  final gasPrice = tx.params['maxFeePerGas'] != null
      ? rpcQuantity(tx.params['maxFeePerGas'])
      : tx.params['gasPrice'] != null
          ? rpcQuantity(tx.params['gasPrice'])
          : rpcQuantity(await rpc(tx.chainId, 'eth_gasPrice', []));
  if (gasPrice <= BigInt.zero ||
      tx.params['maxPriorityFeePerGas'] != null &&
          rpcQuantity(tx.params['maxPriorityFeePerGas']) > gasPrice) {
    throw const DappError(-32602, 'Invalid gas price.');
  }
  final maxFee = gasLimit * gasPrice;
  final balance =
      rpcQuantity(await rpc(tx.chainId, 'eth_getBalance', [tx.from, 'latest']));
  if (balance < tx.value + maxFee) {
    throw const DappError(
        -32000, 'Not enough native coin to pay value and network fees.');
  }
  if (approved != null) {
    if (maxFee > approved.maxFee) {
      throw const DappError(
          4001, 'Network fee increased. Review a new request.');
    }
    if (rpcQuantity(approved.payload['gas']) < gas ||
        balance < tx.value + approved.maxFee) {
      throw const DappError(
          4001, 'The approved gas or balance is no longer sufficient.');
    }
    return approved;
  }
  final payload = Map<String, dynamic>.from(tx.params)
    ..['gas'] = hexQuantity(gasLimit);
  if (!payload.containsKey('gasPrice') &&
      !payload.containsKey('maxFeePerGas')) {
    payload['gasPrice'] = hexQuantity(gasPrice);
  }
  return DappGasPlan(payload, maxFee);
}
