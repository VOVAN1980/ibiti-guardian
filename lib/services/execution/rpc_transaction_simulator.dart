import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/models/rpc_simulation_result.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/execution/clients/solana_rpc_client.dart';
import 'package:ibiti_guardian/services/execution/clients/tron_rpc_client.dart';
import 'package:ibiti_guardian/services/execution/native_transaction_builder.dart';

/// Interface for preflight transaction simulation.
abstract class RpcSimulator {
  /// Executes a network-aware preflight check before user confirmation.
  Future<RpcSimulationResult> simulate(TransactionRequest tx);
}

/// Real simulation boundary used by the production execution pipeline.
///
/// EVM:
/// - Builds the same `to/data/value` payload used for execution
/// - Runs `eth_estimateGas` against the active chain RPC
///
/// Solana / Tron:
/// - Performs a chain-specific guarded preflight using the available RPC client
/// - Returns warnings when full contract simulation is not available yet
class RpcTransactionSimulator implements RpcSimulator {
  RpcTransactionSimulator._();
  static final instance = RpcTransactionSimulator._();

  static const Duration _rpcTimeout = Duration(seconds: 12);

  @override
  Future<RpcSimulationResult> simulate(TransactionRequest tx) async {
    try {
      if (tx.isEvmChain) {
        return await _simulateEvm(tx);
      }
      switch (tx.chainKey) {
        case 'solana':
          return await _simulateSolana(tx);
        case 'tron':
          return await _simulateTron(tx);
        default:
          return RpcSimulationResult.ok(
            warnings: const [
              'No dedicated simulator exists for this network yet.',
            ],
          );
      }
    } catch (e) {
      return RpcSimulationResult.revert(_humanizeRpcError(e));
    }
  }

  Future<RpcSimulationResult> _simulateEvm(TransactionRequest tx) async {
    final chain = PrivyChainRegistry.getChain(tx.chainKey);
    final rpcUrl = chain.rpcUrl;
    if (rpcUrl == null || rpcUrl.isEmpty) {
      return RpcSimulationResult.revert(
        'RPC endpoint is missing for ${tx.networkLabel}.',
      );
    }

    final txParams = _buildEvmParams(tx);
    if (txParams == null) {
      return RpcSimulationResult.revert(
        'Could not build a valid transaction payload for simulation.',
      );
    }

    final estimatedGasHex = await _postEvmRpc<String>(
      rpcUrl: rpcUrl,
      method: 'eth_estimateGas',
      params: [txParams],
    ).timeout(_rpcTimeout);

    final warnings = <String>[];
    final value = _parseBigIntValue(txParams['value']?.toString());
    if (value > BigInt.zero) {
      final balanceHex = await _postEvmRpc<String>(
        rpcUrl: rpcUrl,
        method: 'eth_getBalance',
        params: [tx.fromAddress, 'latest'],
      ).timeout(_rpcTimeout);
      final nativeBalance = _parseBigIntValue(balanceHex);
      if (nativeBalance < value) {
        warnings.add('Native balance may be too low for this transfer.');
      }
    }

    return RpcSimulationResult.ok(
      gas: estimatedGasHex,
      warnings: warnings,
    );
  }

  Future<RpcSimulationResult> _simulateSolana(TransactionRequest tx) async {
    if (tx.type != TransactionType.send) {
      return RpcSimulationResult.ok(
        warnings: const [
          'Deep Solana simulation is not available for this action yet.',
        ],
      );
    }

    final rpcUrl = PrivyChainRegistry.getChain('solana').rpcUrl ??
        'https://api.mainnet-beta.solana.com';
    final client = SolanaHttpRpcClient(rpcUrl: rpcUrl);
    final amount = tx.amount;
    if (amount == null || amount <= 0) {
      return RpcSimulationResult.revert('Invalid amount parameter');
    }

    final lamports =
        tx.atomicAmount ?? BigInt.from((amount * 1000000000).round());
    final balance = await client.getBalanceLamports(tx.fromAddress);
    if (balance < lamports) {
      return RpcSimulationResult.revert(
        'Insufficient SOL balance for this transfer.',
      );
    }

    return RpcSimulationResult.ok(
      warnings: const [
        'Solana preflight currently validates balance only before signing.',
      ],
    );
  }

  Future<RpcSimulationResult> _simulateTron(TransactionRequest tx) async {
    if (tx.type != TransactionType.send) {
      return RpcSimulationResult.ok(
        warnings: const [
          'Deep Tron simulation is not available for this action yet.',
        ],
      );
    }

    final amount = tx.amount;
    if (amount == null || amount <= 0) {
      return RpcSimulationResult.revert('Invalid amount parameter');
    }

    final chain = PrivyChainRegistry.getChain('tron');
    final client = TronHttpRpcClient(
      baseUrl: chain.rpcUrl ?? 'https://api.trongrid.io',
    );

    final amountSun =
        tx.atomicAmount ?? BigInt.from((amount * 1000000).round());
    final balance = await client.getBalanceSun(tx.fromAddress);
    if (balance < amountSun) {
      return RpcSimulationResult.revert(
        'Insufficient TRX balance for this transfer.',
      );
    }

    await client.buildTransferTransaction(
      fromAddress: tx.fromAddress,
      toAddress: tx.toAddress,
      amountSun: amountSun,
    );

    return RpcSimulationResult.ok(
      warnings: const [
        'Tron preflight validates transfer construction before signing.',
      ],
    );
  }

  Map<String, dynamic>? _buildEvmParams(TransactionRequest tx) {
    switch (tx.type) {
      case TransactionType.send:
        final amountWei = tx.atomicAmount;
        if (amountWei == null) return null;
        if (tx.tokenContract != null && tx.tokenContract!.isNotEmpty) {
          return NativeTransactionBuilder.buildErc20TransferParams(
            fromAddress: tx.fromAddress,
            tokenContract: tx.tokenContract!,
            toAddress: tx.toAddress,
            amountWei: amountWei,
          );
        }
        return NativeTransactionBuilder.buildNativeTransferParams(
          fromAddress: tx.fromAddress,
          toAddress: tx.toAddress,
          amountWei: amountWei,
        );
      case TransactionType.revoke:
        if (tx.tokenContract == null || tx.spenderAddress == null) return null;
        return NativeTransactionBuilder.buildApproveParams(
          fromAddress: tx.fromAddress,
          tokenContract: tx.tokenContract!,
          spenderAddress: tx.spenderAddress!,
          amountWei: BigInt.zero,
        );
      case TransactionType.approve:
        if (tx.tokenContract == null || tx.spenderAddress == null) return null;
        final amountWei = tx.isUnlimitedApproval
            ? BigInt.parse(
                '115792089237316195423570985008687907853269984665640564039457584007913129639935',
              )
            : (tx.atomicAmount ?? BigInt.zero);
        return NativeTransactionBuilder.buildApproveParams(
          fromAddress: tx.fromAddress,
          tokenContract: tx.tokenContract!,
          spenderAddress: tx.spenderAddress!,
          amountWei: amountWei,
        );
      case TransactionType.swap:
        if (tx.routerAddress == null || tx.calldata == null) return null;
        final nativeValue =
            _parseBigIntValue(tx.quoteSummary?['nativeValue']?.toString());
        return NativeTransactionBuilder.buildSwapParams(
          fromAddress: tx.fromAddress,
          routerAddress: tx.routerAddress!,
          calldata: tx.calldata!,
          nativeValue: nativeValue,
        );
      case TransactionType.unknown:
        return null;
    }
  }

  BigInt _parseBigIntValue(String? raw) {
    if (raw == null || raw.isEmpty) return BigInt.zero;
    if (raw.startsWith('0x')) {
      return BigInt.tryParse(raw.substring(2), radix: 16) ?? BigInt.zero;
    }
    return BigInt.tryParse(raw) ?? BigInt.zero;
  }

  Future<T> _postEvmRpc<T>({
    required String rpcUrl,
    required String method,
    required List<dynamic> params,
  }) async {
    final response = await http
        .post(
          Uri.parse(rpcUrl),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': method,
            'params': params,
          }),
        )
        .timeout(const Duration(seconds: 12));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('RPC HTTP ${response.statusCode}: ${response.body}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    if (decoded['error'] != null) {
      throw Exception(decoded['error'].toString());
    }

    return decoded['result'] as T;
  }

  String _humanizeRpcError(Object error) {
    final raw = error.toString();
    if (raw.contains('insufficient funds')) {
      return 'Insufficient native balance for value and gas.';
    }
    if (raw.contains('execution reverted')) {
      return raw;
    }
    if (raw.contains('estimateGas')) {
      return 'RPC gas estimation failed.';
    }
    if (raw.length > 180) {
      return raw.substring(0, 180);
    }
    return raw;
  }
}

/// Mock simulator kept only for tests and future fixture-based QA.
class MockRpcTransactionSimulator implements RpcSimulator {
  MockRpcTransactionSimulator._();
  static final instance = MockRpcTransactionSimulator._();

  @override
  Future<RpcSimulationResult> simulate(TransactionRequest tx) async {
    await Future.delayed(const Duration(milliseconds: 600));

    if (tx.amount == null && tx.type == TransactionType.send) {
      return RpcSimulationResult.revert('Invalid amount parameter');
    }

    if (tx.amount != null && tx.amount! > 10000000) {
      return RpcSimulationResult.revert(
        'ERC20: transfer amount exceeds balance',
      );
    }

    if (tx.type == TransactionType.approve && tx.spenderAddress == null) {
      return RpcSimulationResult.ok(
        gas: '0x12a54',
        warnings: const [
          'Spender contract ABI could not be resolved on-chain.',
        ],
      );
    }

    return RpcSimulationResult.ok(gas: '0x5208');
  }
}
