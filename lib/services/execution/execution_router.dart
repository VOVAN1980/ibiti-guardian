import 'dart:convert';
import 'dart:typed_data';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/models/send_native_models.dart';
import 'package:ibiti_guardian/services/execution/adapters/evm_execution_adapter.dart';
import 'package:ibiti_guardian/services/execution/adapters/solana_execution_adapter.dart';
import 'package:ibiti_guardian/services/execution/adapters/tron_execution_adapter.dart';
import 'package:ibiti_guardian/services/execution/clients/solana_rpc_client.dart';
import 'package:ibiti_guardian/services/execution/clients/tron_rpc_client.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:privy_flutter/privy_flutter.dart';

// ──────────────────────────────────────────────────────────────────────────────
// ExecutionRouter — singleton that routes SendNativeRequest to the correct adapter.
// Call ExecutionRouter.instance.init() once at app startup (e.g. in main.dart).
// ──────────────────────────────────────────────────────────────────────────────

class ExecutionRouter {
  static final ExecutionRouter instance = ExecutionRouter._internal();
  ExecutionRouter._internal();

  late final SolanaExecutionAdapter solana;
  late final TronExecutionAdapter tron;
  late final EvmExecutionAdapter evm;

  bool _initialized = false;

  void init() {
    if (_initialized) return;

    const tronApiKey = String.fromEnvironment('TRONGRID_API_KEY');
    final tronRpcUrl =
        PrivyChainRegistry.getChain('tron').rpcUrl ?? 'https://api.trongrid.io';
    final solanaRpcUrl = PrivyChainRegistry.getChain('solana').rpcUrl ??
        'https://api.mainnet-beta.solana.com';

    tron = TronExecutionAdapter(
      walletRepo: PrivyTronWalletRepository(),
      rpcClient: TronHttpRpcClient(
        baseUrl: tronRpcUrl,
        apiKey: tronApiKey.isEmpty ? null : tronApiKey,
      ),
      privyRawSigner: PrivyTronExecutionBackend(),
    );

    solana = SolanaExecutionAdapter(
      walletRepo: _PrivySolanaWalletRepository(),
      rpcClient: SolanaHttpRpcClient(rpcUrl: solanaRpcUrl),
      privyExecutor: _PrivySolanaExecutionBackend(),
    );

    evm = EvmExecutionAdapter();

    _initialized = true;
  }

  Future<SendNativeResult> sendNative(SendNativeRequest request) {
    if (!_initialized) {
      throw StateError('[ExecutionRouter] Call init() before sendNative()');
    }
    switch (request.chainKey) {
      case 'solana':
        return solana.sendNative(request);
      case 'tron':
        return tron.sendNative(request);
      default:
        return evm.sendNative(request);
    }
  }

  Future<SendNativeQuote> quoteNative(SendNativeRequest request) {
    if (!_initialized) {
      throw StateError('[ExecutionRouter] Call init() before quoteNative()');
    }
    switch (request.chainKey) {
      case 'solana':
        return solana.quoteNative(request);
      case 'tron':
        return tron.quoteNative(request);
      default:
        return evm.quoteNative(request);
    }
  }

  /// Sends an SPL token on Solana. Only valid for chainKey == 'solana'.
  Future<SendNativeResult> sendSplToken({
    required String fromAddress,
    required String toAddress,
    required String mintAddress,
    required BigInt amount,
  }) {
    if (!_initialized) {
      throw StateError('[ExecutionRouter] Call init() before sendSplToken()');
    }
    return solana.sendSplToken(
      fromAddress: fromAddress,
      toAddress: toAddress,
      mintAddress: mintAddress,
      amount: amount,
    );
  }

  /// Signs a Jupiter V2 swap transaction via Privy.
  ///
  /// Returns the signed base64 transaction string for submission
  /// to Jupiter `/swap/v2/execute`.
  Future<String> signJupiterTransaction(String base64Transaction) {
    if (!_initialized) {
      throw StateError(
          '[ExecutionRouter] Call init() before signJupiterTransaction()');
    }
    return solana.signJupiterTransaction(base64Transaction);
  }

  /// Sends a TRC20 token on Tron. Only valid for chainKey == 'tron'.
  Future<SendNativeResult> sendTrc20Token({
    required String fromAddress,
    required String toAddress,
    required String contractAddress,
    required BigInt amountRaw,
  }) {
    if (!_initialized) {
      throw StateError('[ExecutionRouter] Call init() before sendTrc20Token()');
    }
    return tron.sendTrc20Token(
      fromAddress: fromAddress,
      toAddress: toAddress,
      contractAddress: contractAddress,
      amountRaw: amountRaw,
    );
  }

  /// Approves a TRC20 token for a spender on Tron.
  Future<String> approveTrc20({
    required String ownerAddress,
    required String tokenContract,
    required String spenderAddress,
    required BigInt amount,
  }) {
    if (!_initialized) {
      throw StateError('[ExecutionRouter] Call init() before approveTrc20()');
    }
    return tron.approveTrc20(
      ownerAddress: ownerAddress,
      tokenContract: tokenContract,
      spenderAddress: spenderAddress,
      amount: amount,
    );
  }

  /// Executes a SunSwap V2 swap on Tron.
  Future<SendNativeResult> executeTronSwap({
    required String fromAddress,
    required String routerAddress,
    required String functionSelector,
    required String parameter,
    required int feeLimit,
    BigInt? callValue,
  }) {
    if (!_initialized) {
      throw StateError(
          '[ExecutionRouter] Call init() before executeTronSwap()');
    }
    return tron.executeTronSwap(
      fromAddress: fromAddress,
      routerAddress: routerAddress,
      functionSelector: functionSelector,
      parameter: parameter,
      feeLimit: feeLimit,
      callValue: callValue,
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Privy-backed Solana wallet repository
// ──────────────────────────────────────────────────────────────────────────────

class _PrivySolanaWalletRepository implements SolanaWalletRepository {
  @override
  Future<String?> getEmbeddedWalletAddress() async =>
      IBITIVaultService.instance.solanaAddress;

  @override
  Future<bool> hasEmbeddedWallet() async {
    final addr = IBITIVaultService.instance.solanaAddress;
    return addr != null && addr.isNotEmpty;
  }

  @override
  Future<void> ensureWalletExists() async {
    await IBITIVaultService.instance.ensureAllWallets();
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Privy-backed Solana execution backend
// Tier 3: first-class signAndSendTransaction, falls back via UnimplementedError.
// ──────────────────────────────────────────────────────────────────────────────

class _PrivySolanaExecutionBackend implements SolanaExecutionBackend {
  @override
  Future<String> signAndSendCompiledTx(Uint8List compiledTxBytes) async {
    final user = await IBITIVaultService.instance.getPrivyUser();
    if (user == null || user.embeddedSolanaWallets.isEmpty) {
      throw const WalletUnavailableFailure(
          'No embedded Solana wallet available');
    }
    final wallet = IBITIVaultService.instance.resolveEmbeddedSolanaWallet(user);
    if (wallet == null) {
      throw const WalletUnavailableFailure(
          'No embedded Solana wallet matches the stored active address');
    }

    final rpcUrl = PrivyChainRegistry.getChain('solana').rpcUrl ??
        'https://api.mainnet-beta.solana.com';

    final result = await wallet.provider.signAndSendTransaction(
      transaction: compiledTxBytes,
      rpcUrl: rpcUrl,
    );

    return switch (result) {
      Success(value: final signature) => signature,
      Failure(error: final e) =>
        throw SigningFailedFailure('Solana signAndSend failed: ${e.message}'),
    };
  }

  @override
  Future<String> signTransaction(String base64Transaction) async {
    final user = await IBITIVaultService.instance.getPrivyUser();
    if (user == null || user.embeddedSolanaWallets.isEmpty) {
      throw const WalletUnavailableFailure(
          'No embedded Solana wallet available');
    }
    final wallet = IBITIVaultService.instance.resolveEmbeddedSolanaWallet(user);
    if (wallet == null) {
      throw const WalletUnavailableFailure(
          'No embedded Solana wallet matches the stored active address');
    }

    final result = await wallet.provider.signTransaction(
      base64Decode(base64Transaction),
    );

    return switch (result) {
      Success(value: final signature) => signature,
      Failure(error: final e) => throw SigningFailedFailure(
          'Solana signTransaction failed: ${e.message}'),
    };
  }
}
