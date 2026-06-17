import 'package:ibiti_guardian/models/send_native_models.dart';
import 'package:ibiti_guardian/services/execution/adapters/native_execution_adapter.dart';
import 'package:ibiti_guardian/services/execution/solana_spl_builder.dart';
import 'package:ibiti_guardian/utils/base58.dart';
import 'dart:typed_data';
import 'dart:convert';

import 'package:ibiti_guardian/services/execution/clients/solana_rpc_client.dart';

abstract class SolanaWalletRepository {
  Future<String?> getEmbeddedWalletAddress();
  Future<bool> hasEmbeddedWallet();
  Future<void> ensureWalletExists();
}

abstract class SolanaExecutionBackend {
  Future<String> signAndSendCompiledTx(Uint8List compiledTxBytes);
  Future<String> signTransaction(String base64Transaction);
}

class SolanaExecutionAdapter implements NativeExecutionAdapter {
  final SolanaWalletRepository walletRepo;
  final SolanaRpcClient rpcClient;
  final SolanaExecutionBackend privyExecutor;

  SolanaExecutionAdapter({
    required this.walletRepo,
    required this.rpcClient,
    required this.privyExecutor,
  });

  void _validateRequest(SendNativeRequest request) {
    if (request.chainKey != 'solana') {
      throw UnsupportedChainFailure(request.chainKey);
    }
    if (request.amount.symbol != 'SOL') {
      throw const InvalidAmountFailure('Symbol must be SOL for native send');
    }
    if (request.amount.atomic <= BigInt.zero) {
      throw const InvalidAmountFailure('Amount must be > 0 lamports');
    }
  }

  @override
  Future<SendNativeQuote> quoteNative(SendNativeRequest request) async {
    _validateRequest(request);

    final balance = await rpcClient.getBalanceLamports(request.fromAddress);
    final feeEstimate = BigInt.from(5000); // placeholder MVP
    final totalDebit = request.amount.atomic + feeEstimate;

    return SendNativeQuote(
      chainKey: 'solana',
      amountAtomic: request.amount.atomic,
      estimatedFeeAtomic: feeEstimate,
      totalDebitAtomic: totalDebit,
      canProceed: balance >= totalDebit,
      warnings: [],
    );
  }

  @override
  Future<SendNativeResult> sendNative(SendNativeRequest request) async {
    _validateRequest(request);

    await walletRepo.ensureWalletExists();

    final walletAddress = await walletRepo.getEmbeddedWalletAddress();
    if (walletAddress == null) {
      throw const WalletUnavailableFailure('Missing embedded Solana wallet');
    }
    if (walletAddress != request.fromAddress) {
      throw const WalletUnavailableFailure(
          'Request sender does not match active Solana wallet');
    }

    final balance = await rpcClient.getBalanceLamports(request.fromAddress);
    final feeEstimate = BigInt.from(5000); // placeholder MVP
    final totalDebit = request.amount.atomic + feeEstimate;

    if (balance < totalDebit) {
      throw InsufficientFundsFailure(
        'Balance $balance is lower than required $totalDebit lamports',
      );
    }

    final recentBlockhash = await rpcClient.getLatestBlockhash();

    final unsignedTxBytes = await _buildUnsignedTransferTx(
      from: request.fromAddress,
      to: request.toAddress,
      lamports: request.amount.atomic,
      recentBlockhash: recentBlockhash,
    );

    try {
      final txHash = await privyExecutor.signAndSendCompiledTx(unsignedTxBytes);

      return SendNativeResult(
        chainKey: 'solana',
        txHash: txHash,
        fromAddress: request.fromAddress,
        toAddress: request.toAddress,
        amountAtomic: request.amount.atomic,
        executionPath: 'privy_sign_and_send',
      );
    } on UnimplementedError {
      final base64Unsigned = base64Encode(unsignedTxBytes);
      final resultBase64 = await privyExecutor.signTransaction(base64Unsigned);
      final resultBytes = base64Decode(resultBase64);

      Uint8List finalSignedTx;

      if (resultBytes.length == 64) {
        // Case A: Privy returned only the raw 64-byte signature
        finalSignedTx = await _attachSolanaSignature(
          unsignedTxBytes: unsignedTxBytes,
          signatureBase64: resultBase64,
        );
      } else if (resultBytes.length == unsignedTxBytes.length) {
        // Case B: Privy returned the full signed transaction
        finalSignedTx = resultBytes;
      } else {
        throw SigningFailedFailure(
          'Unexpected Solana signature length: ${resultBytes.length}. '
          'Expected 64 (signature) or ${unsignedTxBytes.length} (full tx).',
        );
      }

      final base64SignedTx = base64Encode(finalSignedTx);
      final txHash = await rpcClient.sendRawTransaction(base64SignedTx);

      return SendNativeResult(
        chainKey: 'solana',
        txHash: txHash,
        fromAddress: request.fromAddress,
        toAddress: request.toAddress,
        amountAtomic: request.amount.atomic,
        executionPath: 'privy_sign_then_rpc',
      );
    }
  }

  // ── SPL Token Transfer ────────────────────────────────────────────────────

  /// Sends an SPL token (e.g. USDC, USDT) from the embedded Solana wallet.
  ///
  /// [fromAddress]: Solana wallet address of the sender.
  /// [toAddress]: Solana wallet address of the recipient.
  /// [mintAddress]: SPL token mint address.
  /// [amount]: Token amount in atomic units (e.g. 1_000_000 for 1 USDC).
  ///
  /// Source ATA is auto-discovered via getTokenAccountsByOwner(fromAddress).
  Future<SendNativeResult> sendSplToken({
    required String fromAddress,
    required String toAddress,
    required String mintAddress,
    required BigInt amount,
  }) async {
    await walletRepo.ensureWalletExists();

    // Find destination ATA for this mint
    final recipientTokenAccounts =
        await rpcClient.getTokenAccountsByOwner(toAddress);

    // Find sender's ATA for this mint
    final senderTokenAccounts =
        await rpcClient.getTokenAccountsByOwner(fromAddress);
    final senderAtas =
        senderTokenAccounts.where((a) => a.mint == mintAddress).toList();
    if (senderAtas.isEmpty) {
      throw StateError(
        'No token account for mint $mintAddress in wallet $fromAddress. '
        'You do not hold this token.',
      );
    }
    final sourceAtaAddress = senderAtas.first.accountAddress;

    final existingAtas =
        recipientTokenAccounts.where((a) => a.mint == mintAddress).toList();

    final bool destAtaExists = existingAtas.isNotEmpty;
    final String destAtaAddress;

    if (destAtaExists) {
      destAtaAddress = existingAtas.first.accountAddress;
    } else {
      // Derive the canonical ATA address for the recipient
      destAtaAddress = deriveAtaAddress(
        walletAddress: toAddress,
        mintAddress: mintAddress,
      );
    }

    final recentBlockhash = await rpcClient.getLatestBlockhash();

    final unsignedTx = buildSplTransferTransaction(
      fromAddress: fromAddress,
      toAddress: toAddress,
      mintAddress: mintAddress,
      sourceAtaAddress: sourceAtaAddress,
      destinationAtaAddress: destAtaAddress,
      destinationAtaExists: destAtaExists,
      amount: amount,
      recentBlockhash: recentBlockhash,
    );

    try {
      final txHash = await privyExecutor.signAndSendCompiledTx(unsignedTx);
      return SendNativeResult(
        chainKey: 'solana',
        txHash: txHash,
        fromAddress: fromAddress,
        toAddress: toAddress,
        amountAtomic: amount,
        executionPath: 'privy_spl_sign_and_send',
      );
    } on UnimplementedError {
      final base64Unsigned = base64Encode(unsignedTx);
      final resultBase64 = await privyExecutor.signTransaction(base64Unsigned);
      final resultBytes = base64Decode(resultBase64);

      Uint8List finalSignedTx;
      if (resultBytes.length == 64) {
        finalSignedTx = await _attachSolanaSignature(
          unsignedTxBytes: unsignedTx,
          signatureBase64: resultBase64,
        );
      } else {
        finalSignedTx = resultBytes;
      }

      final txHash =
          await rpcClient.sendRawTransaction(base64Encode(finalSignedTx));
      return SendNativeResult(
        chainKey: 'solana',
        txHash: txHash,
        fromAddress: fromAddress,
        toAddress: toAddress,
        amountAtomic: amount,
        executionPath: 'privy_spl_sign_then_rpc',
      );
    }
  }

  // --- Binary Serialization Helpers ---

  Future<Uint8List> _buildUnsignedTransferTx({
    required String from,
    required String to,
    required BigInt lamports,
    required String recentBlockhash,
  }) async {
    final fromPubkey = Base58.decode(from);
    final toPubkey = Base58.decode(to);
    final sysProgramPubkey = Base58.decode('11111111111111111111111111111111');
    final recentHash = Base58.decode(recentBlockhash);

    if (fromPubkey.length != 32 ||
        toPubkey.length != 32 ||
        recentHash.length != 32) {
      throw StateError('Invalid Solana address or blockhash length');
    }

    // Header: [numRequiredSignatures, numReadonlySignedAccounts, numReadonlyUnsignedAccounts]
    final header = Uint8List.fromList([1, 0, 1]);

    // Account Addresses
    // Indices in this list: 0: FROM, 1: TO, 2: SystemProgram
    final accountAddresses = Uint8List(32 * 3);
    accountAddresses.setAll(0, fromPubkey);
    accountAddresses.setAll(32, toPubkey);
    accountAddresses.setAll(64, sysProgramPubkey);

    // Instruction Data: [u32 discriminator (2), u64 lamports]
    final instrData = ByteData(4 + 8);
    instrData.setUint32(0, 2, Endian.little);
    instrData.setUint64(4, lamports.toInt(), Endian.little);

    // Compact-u16 helper for buffer assembly
    Uint8List encodeLength(int len) {
      if (len < 0x80) return Uint8List.fromList([len]);
      if (len < 0x4000) return Uint8List.fromList([len | 0x80, len >> 7]);
      return Uint8List.fromList([len | 0x80, (len >> 7) | 0x80, len >> 14]);
    }

    final messageBuilder = BytesBuilder();
    messageBuilder.add(header);
    messageBuilder.add(encodeLength(3)); // Number of accounts
    messageBuilder.add(accountAddresses);
    messageBuilder.add(recentHash);
    messageBuilder.add(encodeLength(1)); // Number of instructions

    // The Instruction
    messageBuilder.addByte(2); // Program ID Index (SystemProgram is at index 2)
    messageBuilder.add(encodeLength(2)); // Number of account indices
    messageBuilder.addByte(0); // From account index
    messageBuilder.addByte(1); // To account index
    messageBuilder.add(encodeLength(instrData.lengthInBytes));
    messageBuilder.add(instrData.buffer.asUint8List());

    final messageBytes = messageBuilder.toBytes();

    // Now wrap standard Solana Transaction Wire Format:
    // [signatures_count] [signatures] [message]
    final txBuilder = BytesBuilder();
    txBuilder.addByte(1); // Number of signatures
    txBuilder.add(Uint8List(64)); // Placeholder for signature 0
    txBuilder.add(messageBytes);

    return txBuilder.toBytes();
  }

  Future<Uint8List> _attachSolanaSignature({
    required Uint8List unsignedTxBytes,
    required String signatureBase64,
  }) async {
    final signature = base64Decode(signatureBase64);
    // Solana tx format is: [sign_count] [sig1] [sig2] ... [message]
    // Since we know sign_count is 1 and sig is 64 bytes:
    final result = Uint8List.fromList(unsignedTxBytes);
    if (result.length < 65) {
      throw StateError('Invalid unsigned transaction length');
    }
    // Result[0] is the sign_count (1). Result[1..65] is the placeholder.
    result.setAll(1, signature);
    return result;
  }

  /// Signs a Jupiter V2 swap transaction and returns the signed base64 string.
  ///
  /// The caller ([ExecutionRouter] / [GuardianExecutionService]) handles the
  /// `/swap/v2/execute` call via [JupiterSwapProvider.executeSignedSwap].
  ///
  /// Flow:
  /// 1. Jupiter V2 `/order` returned a base64 VersionedTransaction
  /// 2. We sign it via Privy `signTransaction()` — sign-only, no send
  /// 3. Return the signed base64 for submission to `/execute`
  ///
  /// IMPORTANT: We must NOT use signAndSendCompiledTx here because
  /// Jupiter /execute expects a signed base64 transaction, not a txHash.
  /// Sending the tx directly would bypass Jupiter's managed landing.
  Future<String> signJupiterTransaction(String base64Transaction) async {
    await walletRepo.ensureWalletExists();

    final signedBase64 = await privyExecutor.signTransaction(base64Transaction);
    final signedBytes = base64Decode(signedBase64);

    if (signedBytes.length == 64) {
      // Privy returned only the 64-byte signature — attach it to the tx.
      final unsignedBytes = base64Decode(base64Transaction);
      final assembled = Uint8List.fromList(unsignedBytes);
      if (assembled.length >= 65) {
        assembled.setAll(1, signedBytes);
      }
      return base64Encode(assembled);
    }

    // Privy returned the full signed transaction.
    return signedBase64;
  }
}
