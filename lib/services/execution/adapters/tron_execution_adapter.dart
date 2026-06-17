import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:privy_flutter/privy_flutter.dart';

import 'package:ibiti_guardian/models/send_native_models.dart';
import 'package:ibiti_guardian/services/execution/adapters/native_execution_adapter.dart';
import 'package:ibiti_guardian/services/execution/clients/tron_rpc_client.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';

// ──────────────────────────────────────────────────────────────────────────────
// Interfaces
// ──────────────────────────────────────────────────────────────────────────────

abstract class TronWalletRepository {
  Future<String?> getEmbeddedWalletAddress();
  Future<bool> hasEmbeddedWallet();
  Future<void> ensureWalletExists();
}

abstract class TronExecutionBackend {
  /// Returns raw hex signature (64 or 65 bytes) over the given SHA-256 hash hex.
  /// No Ethereum message prefix must be applied — it is a raw secp256k1 sign.
  Future<String> rawSignHex({
    required String walletAddress,
    required String payloadHex, // the SHA-256 hash of rawDataHex as hex string
    required String chainKey,
  });
}

// ──────────────────────────────────────────────────────────────────────────────
// PrivyTronWalletRepository — reads cached Tron address from IBITIVaultService.
// ──────────────────────────────────────────────────────────────────────────────

class PrivyTronWalletRepository implements TronWalletRepository {
  @override
  Future<String?> getEmbeddedWalletAddress() async {
    return IBITIVaultService.instance.tronAddress;
  }

  @override
  Future<bool> hasEmbeddedWallet() async {
    final addr = IBITIVaultService.instance.tronAddress;
    return addr != null && addr.isNotEmpty;
  }

  @override
  Future<void> ensureWalletExists() async {
    await IBITIVaultService.instance.ensureAllWallets();
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// PrivyTronExecutionBackend — raw sign via Privy EVM wallet.
//
// Tron signs the SHA-256 hash of rawDataHex using ECDSA secp256k1.
// Privy does NOT expose curve-level raw signing natively in all SDK versions.
// We use the EVM wallet provider with `eth_sign` which is equivalent to
// a bare ECDSA sign over the hash bytes WITHOUT the Ethereum message prefix
// (this is the raw/unprefixed path, distinct from personal_sign).
//
// See Privy docs: "Use eth_sign to sign raw hash bytes for Tier 2 chains."
// ──────────────────────────────────────────────────────────────────────────────

class PrivyTronExecutionBackend implements TronExecutionBackend {
  static const _log = GuardianLogger('TronBackend');
  @override
  Future<String> rawSignHex({
    required String walletAddress,
    required String payloadHex,
    required String chainKey,
  }) async {
    try {
      final user = await IBITIVaultService.instance.getPrivyUser();
      if (user == null || user.embeddedEthereumWallets.isEmpty) {
        throw const SigningFailedFailure(
            'No embedded EVM wallet for Tron raw sign');
      }

      final wallet =
          IBITIVaultService.instance.resolveEmbeddedEthereumWallet(user);
      if (wallet == null) {
        throw const SigningFailedFailure(
            'No embedded EVM wallet for Tron raw sign');
      }

      // Ensure the payload is hex-prefixed
      final hexPayload =
          payloadHex.startsWith('0x') ? payloadHex : '0x$payloadHex';

      // eth_sign = raw ECDSA sign over hash bytes, no Ethereum prefix.
      // This maps to Privy's raw/unprefixed signing path for Tier 2.
      final request = EthereumRpcRequest(
        method: 'eth_sign',
        params: [wallet.address, hexPayload],
      );

      final result = await wallet.provider.request(request);

      String? signature;
      result.fold(
        onSuccess: (response) {
          signature = response.data.toString();
          _log.d('raw sign ok');
        },
        onFailure: (e) {
          _log.e('eth_sign failed', e);
          throw SigningFailedFailure('Privy raw sign rejected: ${e.message}');
        },
      );

      if (signature == null || signature!.isEmpty) {
        throw const SigningFailedFailure('Privy returned empty signature');
      }

      return signature!;
    } catch (e) {
      _log.e('rawSignHex error', e);
      rethrow;
    }
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// TronExecutionAdapter
// ──────────────────────────────────────────────────────────────────────────────

class TronExecutionAdapter implements NativeExecutionAdapter {
  final TronWalletRepository walletRepo;
  final TronRpcClient rpcClient;
  final TronExecutionBackend privyRawSigner;

  TronExecutionAdapter({
    required this.walletRepo,
    required this.rpcClient,
    required this.privyRawSigner,
  });

  static const _log = GuardianLogger('TronAdapter');

  void _validateRequest(SendNativeRequest request) {
    if (request.chainKey != 'tron') {
      throw UnsupportedChainFailure(request.chainKey);
    }
    if (request.amount.symbol != 'TRX') {
      throw const InvalidAmountFailure('Symbol must be TRX for native send');
    }
    if (request.amount.atomic <= BigInt.zero) {
      throw const InvalidAmountFailure('Amount must be > 0 sun');
    }
  }

  @override
  Future<SendNativeQuote> quoteNative(SendNativeRequest request) async {
    _validateRequest(request);

    final balance = await rpcClient.getBalanceSun(request.fromAddress);
    // TRX MVP fee buffer: 2 TRX = 2_000_000 sun (covers bandwidth + energy)
    final feeBuffer = BigInt.from(2000000);
    final totalDebit = request.amount.atomic + feeBuffer;

    return SendNativeQuote(
      chainKey: 'tron',
      amountAtomic: request.amount.atomic,
      estimatedFeeAtomic: feeBuffer,
      totalDebitAtomic: totalDebit,
      canProceed: balance >= totalDebit,
      warnings: [
        'Fee is a conservative estimate. Actual fee depends on Tron bandwidth and energy.'
      ],
    );
  }

  @override
  Future<SendNativeResult> sendNative(SendNativeRequest request) async {
    _validateRequest(request);

    await walletRepo.ensureWalletExists();

    final walletAddress = await walletRepo.getEmbeddedWalletAddress();
    if (walletAddress == null) {
      throw const WalletUnavailableFailure(
          'Missing embedded Tron wallet address');
    }
    if (walletAddress != request.fromAddress) {
      throw const WalletUnavailableFailure(
          'Request sender does not match active Tron wallet');
    }

    // 1. Balance check
    final balance = await rpcClient.getBalanceSun(request.fromAddress);
    final feeBuffer = BigInt.from(2000000);
    final totalDebit = request.amount.atomic + feeBuffer;

    if (balance < totalDebit) {
      throw InsufficientFundsFailure(
        'Balance $balance sun is lower than required $totalDebit sun',
      );
    }

    // 2. Build unsigned transaction via TronGrid
    final unsignedTx = await rpcClient.buildTransferTransaction(
      fromAddress: request.fromAddress,
      toAddress: request.toAddress,
      amountSun: request.amount.atomic,
      memo: request.memo,
    );

    // 3. Hash rawDataHex using SHA-256 (standard Tron signing protocol)
    final rawDataBytes = _hexToBytes(unsignedTx.rawDataHex);
    final txHashBytes = sha256.convert(rawDataBytes).bytes;
    final txHashHex = _bytesToHex(txHashBytes);

    _log.d('tx sha256 hash computed');

    // 4. Raw sign the hash via Privy (NO Ethereum message prefix)
    final rawSignatureHex = await privyRawSigner.rawSignHex(
      walletAddress: request.fromAddress,
      payloadHex: txHashHex,
      chainKey: 'tron',
    );

    // 5. Normalize signature to 65 bytes with correct recovery id
    final normalizedSignature = normalizeTronSignature(
      rawSignatureHex,
      txHashHex,
      request.fromAddress,
    );

    // 6. Assemble signed tx and broadcast
    final signedTx = TronSignedTransaction(
      rawData: unsignedTx.rawData,
      txId: unsignedTx.txId,
      rawDataHex: unsignedTx.rawDataHex,
      signaturesHex: [normalizedSignature],
    );

    final txHash = await rpcClient.broadcastTransaction(signedTx);

    _log.d('broadcast ok');

    return SendNativeResult(
      chainKey: 'tron',
      txHash: txHash,
      fromAddress: request.fromAddress,
      toAddress: request.toAddress,
      amountAtomic: request.amount.atomic,
      executionPath: 'tron_raw_sign_broadcast',
    );
  }

  // ── Signature normalizer ────────────────────────────────────────────────────
  // Tron requires a 65-byte ECDSA signature: r (32) + s (32) + v (1).
  // v is the recovery byte, Tron uses values 27 or 28.
  String normalizeTronSignature(
    String sigHex,
    String txHashHex,
    String expectedAddress,
  ) {
    var raw = sigHex.startsWith('0x') ? sigHex.substring(2) : sigHex;

    final sigBytes = _hexToBytes(raw);

    // Already 65 bytes — strip 0x prefix and return as-is
    if (sigBytes.length == 65) return raw;

    throw TronSignatureFormatFailure(
        'Invalid signature length: ${sigBytes.length} bytes. Expected 65 bytes from eth_sign.');
  }

  // ── Private helpers ─────────────────────────────────────────────────────────

  static Uint8List _hexToBytes(String hex) {
    final h = hex.startsWith('0x') ? hex.substring(2) : hex;
    final length = h.length ~/ 2;
    final result = Uint8List(length);
    for (var i = 0; i < length; i++) {
      result[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  static String _bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // ── TRC20 Token Transfer ──────────────────────────────────────────────────

  /// Sends a TRC20 token (e.g. USDT) on Tron.
  ///
  /// Uses the same sign+broadcast flow as native TRX, but builds the
  /// unsigned tx via `triggerSmartContract` with `transfer(address,uint256)`.
  Future<SendNativeResult> sendTrc20Token({
    required String fromAddress,
    required String toAddress,
    required String contractAddress,
    required BigInt amountRaw,
  }) async {
    await walletRepo.ensureWalletExists();

    final walletAddress = await walletRepo.getEmbeddedWalletAddress();
    if (walletAddress == null) {
      throw const WalletUnavailableFailure(
          'Missing embedded Tron wallet address');
    }
    if (walletAddress != fromAddress) {
      throw const WalletUnavailableFailure(
          'Request sender does not match active Tron wallet');
    }

    if (amountRaw <= BigInt.zero) {
      throw const InvalidAmountFailure('TRC20 amount must be > 0');
    }

    // 1. Energy estimate + TRX balance pre-check
    //    Even though fee_limit is set, the user must have enough TRX to pay.
    final energyEstimate = await rpcClient.estimateEnergy(
      ownerAddress: fromAddress,
      contractAddress: contractAddress,
      toAddress: toAddress,
      amountRaw: amountRaw,
    );

    // Use estimated energy cost, or conservative 15 TRX buffer
    // Energy price is ~420 sun/unit as of 2024, but can fluctuate.
    // Conservative estimate: energyUnits * 420 sun, capped at fee_limit.
    final int feeLimitSun;
    if (energyEstimate != null && energyEstimate > 0) {
      // ~420 sun per energy unit, add 20% safety margin
      final estimatedFee = (energyEstimate * 420 * 1.2).round();
      feeLimitSun =
          estimatedFee.clamp(1000000, TronHttpRpcClient.defaultTrc20FeeLimit);
      _log.d('Energy estimate: $energyEstimate units → $feeLimitSun sun fee');
    } else {
      feeLimitSun = TronHttpRpcClient.defaultTrc20FeeLimit;
      _log.d('Energy estimate unavailable, using default ${feeLimitSun} sun');
    }

    // Check TRX balance covers the fee
    final trxBalance = await rpcClient.getBalanceSun(fromAddress);
    if (trxBalance < BigInt.from(feeLimitSun)) {
      final trxNeeded = (feeLimitSun / 1e6).toStringAsFixed(1);
      final trxAvailable = (trxBalance.toDouble() / 1e6).toStringAsFixed(2);
      throw InsufficientFundsFailure(
        'Not enough TRX for TRC20 network fee. '
        'Need ~$trxNeeded TRX, available: $trxAvailable TRX. '
        'Top up your Tron wallet with TRX before sending USDT.',
      );
    }

    // 2. Build unsigned TRC20 transfer via triggerSmartContract
    final unsignedTx = await rpcClient.buildTrc20Transfer(
      ownerAddress: fromAddress,
      toAddress: toAddress,
      contractAddress: contractAddress,
      amountRaw: amountRaw,
      feeLimit: feeLimitSun,
    );

    // 3. Hash rawDataHex using SHA-256 (standard Tron signing protocol)
    final rawDataBytes = _hexToBytes(unsignedTx.rawDataHex);
    final txHashBytes = sha256.convert(rawDataBytes).bytes;
    final txHashHex = _bytesToHex(txHashBytes);

    _log.d('TRC20 tx sha256 hash computed');

    // 4. Raw sign the hash via Privy (NO Ethereum message prefix)
    final rawSignatureHex = await privyRawSigner.rawSignHex(
      walletAddress: fromAddress,
      payloadHex: txHashHex,
      chainKey: 'tron',
    );

    // 5. Normalize signature to 65 bytes
    final normalizedSignature = normalizeTronSignature(
      rawSignatureHex,
      txHashHex,
      fromAddress,
    );

    // 6. Assemble signed tx and broadcast
    final signedTx = TronSignedTransaction(
      rawData: unsignedTx.rawData,
      txId: unsignedTx.txId,
      rawDataHex: unsignedTx.rawDataHex,
      signaturesHex: [normalizedSignature],
    );

    final txHash = await rpcClient.broadcastTransaction(signedTx);

    _log.d('TRC20 broadcast ok');

    return SendNativeResult(
      chainKey: 'tron',
      txHash: txHash,
      fromAddress: fromAddress,
      toAddress: toAddress,
      amountAtomic: amountRaw,
      executionPath: 'tron_trc20_transfer',
    );
  }

  // ── TRC20 Approve ─────────────────────────────────────────────────────────

  /// Approves a spender to spend TRC20 tokens on behalf of the owner.
  ///
  /// Uses the same sign+broadcast pipeline as all Tron operations.
  Future<String> approveTrc20({
    required String ownerAddress,
    required String tokenContract,
    required String spenderAddress,
    required BigInt amount,
  }) async {
    await walletRepo.ensureWalletExists();

    final unsignedTx = await rpcClient.buildTrc20Approve(
      ownerAddress: ownerAddress,
      tokenContract: tokenContract,
      spenderAddress: spenderAddress,
      amount: amount,
    );

    final txHash = await _signAndBroadcast(unsignedTx, ownerAddress);
    _log.d('TRC20 approve broadcast ok: $txHash');
    return txHash;
  }

  // ── SunSwap Execution ─────────────────────────────────────────────────────

  /// Executes a SunSwap V2 swap on Tron.
  ///
  /// [functionSelector] and [parameter] come from the SunSwapProvider quote.
  /// [callValue] is non-zero for TRX→token swaps (native TRX attached).
  Future<SendNativeResult> executeTronSwap({
    required String fromAddress,
    required String routerAddress,
    required String functionSelector,
    required String parameter,
    required int feeLimit,
    BigInt? callValue,
  }) async {
    await walletRepo.ensureWalletExists();

    final walletAddress = await walletRepo.getEmbeddedWalletAddress();
    if (walletAddress == null || walletAddress != fromAddress) {
      throw const WalletUnavailableFailure(
          'Request sender does not match active Tron wallet');
    }

    // Check TRX balance for fee
    final trxBalance = await rpcClient.getBalanceSun(fromAddress);
    final totalNeeded = BigInt.from(feeLimit) + (callValue ?? BigInt.zero);
    if (trxBalance < totalNeeded) {
      final trxNeeded = (totalNeeded.toDouble() / 1e6).toStringAsFixed(1);
      final trxAvailable = (trxBalance.toDouble() / 1e6).toStringAsFixed(2);
      throw InsufficientFundsFailure(
        'Not enough TRX for swap. '
        'Need ~$trxNeeded TRX (fee + value), have $trxAvailable TRX.',
      );
    }

    // Build swap tx via triggerSmartContract
    final unsignedTx = await rpcClient.buildSmartContractCall(
      ownerAddress: fromAddress,
      contractAddress: routerAddress,
      functionSelector: functionSelector,
      parameter: parameter,
      feeLimit: feeLimit,
      callValue: callValue,
    );

    final txHash = await _signAndBroadcast(unsignedTx, fromAddress);
    _log.d('SunSwap swap broadcast ok: $txHash');

    return SendNativeResult(
      chainKey: 'tron',
      txHash: txHash,
      fromAddress: fromAddress,
      toAddress: routerAddress,
      amountAtomic: callValue ?? BigInt.zero,
      executionPath: 'tron_sunswap_v2',
    );
  }

  // ── Shared Sign + Broadcast ───────────────────────────────────────────────

  /// Signs an unsigned Tron transaction and broadcasts it.
  /// Reused by TRC20 transfer, approve, and swap operations.
  Future<String> _signAndBroadcast(
    TronUnsignedTransaction unsignedTx,
    String signerAddress,
  ) async {
    // SHA-256 hash of rawDataHex
    final rawDataBytes = _hexToBytes(unsignedTx.rawDataHex);
    final txHashBytes = sha256.convert(rawDataBytes).bytes;
    final txHashHex = _bytesToHex(txHashBytes);

    // Raw sign via Privy
    final rawSignatureHex = await privyRawSigner.rawSignHex(
      walletAddress: signerAddress,
      payloadHex: txHashHex,
      chainKey: 'tron',
    );

    // Normalize signature
    final normalizedSignature = normalizeTronSignature(
      rawSignatureHex,
      txHashHex,
      signerAddress,
    );

    // Broadcast
    final signedTx = TronSignedTransaction(
      rawData: unsignedTx.rawData,
      txId: unsignedTx.txId,
      rawDataHex: unsignedTx.rawDataHex,
      signaturesHex: [normalizedSignature],
    );

    return rpcClient.broadcastTransaction(signedTx);
  }
}
