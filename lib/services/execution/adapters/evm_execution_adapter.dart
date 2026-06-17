import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/models/send_native_models.dart';
import 'package:ibiti_guardian/services/execution/adapters/native_execution_adapter.dart';
import 'package:ibiti_guardian/services/execution/native_transaction_builder.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_signer.dart';

/// EVM native-token execution adapter.
///
/// Handles sending native ETH/BNB/MATIC through IBITIVaultSigner,
/// using the same Privy `eth_sendTransaction` path that powers
/// all other EVM operations (swap, approve, revoke, ERC-20 transfer).
///
/// This adapter is used only by [ExecutionRouter.sendNative] for EVM chains.
/// All other EVM operations bypass this adapter entirely and go through
/// [GuardianExecutionService._dispatchEvmWrite].
class EvmExecutionAdapter implements NativeExecutionAdapter {
  @override
  Future<SendNativeQuote> quoteNative(SendNativeRequest request) async {
    final chain = PrivyChainRegistry.getChain(request.chainKey);
    final rpcUrl = chain.rpcUrl;
    if (rpcUrl == null || rpcUrl.isEmpty) {
      throw UnsupportedChainFailure(request.chainKey);
    }

    // Fetch balance via raw JSON-RPC (no web3dart dependency needed)
    final balance = await _ethGetBalance(rpcUrl, request.fromAddress);

    // Estimate gas for a simple native transfer (21000 is the EVM standard)
    final gasEstimate = BigInt.from(21000);
    final gasPrice = await _ethGasPrice(rpcUrl);
    final estimatedFee = gasEstimate * gasPrice;

    final totalDebit = request.amount.atomic + estimatedFee;
    final canProceed = balance >= totalDebit;

    final warnings = <String>[];
    if (!canProceed) {
      warnings.add(
        'Insufficient balance. Need ${_formatWei(totalDebit)}, '
        'have ${_formatWei(balance)}.',
      );
    }

    return SendNativeQuote(
      chainKey: request.chainKey,
      amountAtomic: request.amount.atomic,
      estimatedFeeAtomic: estimatedFee,
      totalDebitAtomic: totalDebit,
      canProceed: canProceed,
      warnings: warnings,
    );
  }

  @override
  Future<SendNativeResult> sendNative(SendNativeRequest request) async {
    // Pre-flight: run quote to verify funds
    final quote = await quoteNative(request);
    if (!quote.canProceed) {
      throw InsufficientFundsFailure(
        'Cannot send: ${quote.warnings.join('; ')}',
      );
    }

    // Build tx params using the same builder all EVM ops use
    final txParams = NativeTransactionBuilder.buildNativeTransferParams(
      fromAddress: request.fromAddress,
      toAddress: request.toAddress,
      amountWei: request.amount.atomic,
    );

    // Send through the exact same Privy path as swaps/approves
    final hash = await IBITIVaultSigner.instance.sendTransaction(
      txParams: txParams,
    );

    if (hash == null) {
      throw const SigningRejectedFailure();
    }

    return SendNativeResult(
      chainKey: request.chainKey,
      txHash: hash,
      fromAddress: request.fromAddress,
      toAddress: request.toAddress,
      amountAtomic: request.amount.atomic,
      executionPath: 'privy_eth_sendTransaction',
    );
  }

  // ── Raw JSON-RPC helpers (no web3dart dependency) ──────────────────────────

  static Future<BigInt> _ethGetBalance(String rpcUrl, String address) async {
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'method': 'eth_getBalance',
      'params': [address, 'latest'],
      'id': 1,
    });
    final resp = await http.post(
      Uri.parse(rpcUrl),
      headers: {'Content-Type': 'application/json'},
      body: body,
    );
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final hex = json['result']?.toString() ?? '0x0';
    return _hexToBigInt(hex);
  }

  static Future<BigInt> _ethGasPrice(String rpcUrl) async {
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'method': 'eth_gasPrice',
      'params': <String>[],
      'id': 1,
    });
    final resp = await http.post(
      Uri.parse(rpcUrl),
      headers: {'Content-Type': 'application/json'},
      body: body,
    );
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final hex = json['result']?.toString() ?? '0x0';
    return _hexToBigInt(hex);
  }

  static BigInt _hexToBigInt(String hex) {
    final clean = hex.startsWith('0x') ? hex.substring(2) : hex;
    if (clean.isEmpty) return BigInt.zero;
    return BigInt.parse(clean, radix: 16);
  }

  static String _formatWei(BigInt wei) {
    final eth = wei.toDouble() / 1e18;
    return eth.toStringAsFixed(6);
  }
}
