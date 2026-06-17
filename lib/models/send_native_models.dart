import 'package:ibiti_guardian/models/asset_amount.dart';

class SendNativeRequest {
  final String chainKey; // 'solana' | 'tron'
  final String fromAddress;
  final String toAddress;
  final AssetAmount amount;

  /// Optional UX / execution metadata
  final String? memo;
  final String? clientRequestId;
  final bool simulationOnly; // default false

  const SendNativeRequest({
    required this.chainKey,
    required this.fromAddress,
    required this.toAddress,
    required this.amount,
    this.memo,
    this.clientRequestId,
    this.simulationOnly = false,
  });
}

class SendNativeQuote {
  final String chainKey;
  final BigInt amountAtomic;
  final BigInt estimatedFeeAtomic;
  final BigInt totalDebitAtomic;
  final bool canProceed;
  final List<String> warnings;

  const SendNativeQuote({
    required this.chainKey,
    required this.amountAtomic,
    required this.estimatedFeeAtomic,
    required this.totalDebitAtomic,
    required this.canProceed,
    required this.warnings,
  });
}

class SendNativeResult {
  final String chainKey;
  final String txHash; // Solana signature / Tron txid
  final String fromAddress;
  final String toAddress;
  final BigInt amountAtomic;

  /// raw/provider path used for debugging + audit
  final String
      executionPath; // 'privy_sign_and_send' | 'privy_sign_then_rpc' | 'tron_raw_sign_broadcast'

  const SendNativeResult({
    required this.chainKey,
    required this.txHash,
    required this.fromAddress,
    required this.toAddress,
    required this.amountAtomic,
    required this.executionPath,
  });
}

// ──────────────────────────────────────────────────────────────────────────────
// Errors
// ──────────────────────────────────────────────────────────────────────────────

sealed class ExecutionFailure implements Exception {
  final String code;
  final String message;

  const ExecutionFailure(this.code, this.message);

  @override
  String toString() => 'ExecutionFailure[\$code]: \$message';
}

class UnsupportedChainFailure extends ExecutionFailure {
  const UnsupportedChainFailure(String chainKey)
      : super('unsupported_chain', 'Unsupported chain: \$chainKey');
}

class InvalidAddressFailure extends ExecutionFailure {
  const InvalidAddressFailure(String message)
      : super('invalid_address', message);
}

class InvalidAmountFailure extends ExecutionFailure {
  const InvalidAmountFailure(String message) : super('invalid_amount', message);
}

class InsufficientFundsFailure extends ExecutionFailure {
  const InsufficientFundsFailure(String message)
      : super('insufficient_funds', message);
}

class WalletUnavailableFailure extends ExecutionFailure {
  const WalletUnavailableFailure(String message)
      : super('wallet_unavailable', message);
}

class SigningRejectedFailure extends ExecutionFailure {
  const SigningRejectedFailure()
      : super('signing_rejected', 'User rejected signing request');
}

class SigningFailedFailure extends ExecutionFailure {
  const SigningFailedFailure(String message) : super('signing_failed', message);
}

class BroadcastFailedFailure extends ExecutionFailure {
  const BroadcastFailedFailure(String message)
      : super('broadcast_failed', message);
}

class NetworkFailure extends ExecutionFailure {
  const NetworkFailure(String message) : super('network_error', message);
}

class SerializationFailure extends ExecutionFailure {
  const SerializationFailure(String message)
      : super('serialization_failed', message);
}

class PreflightFailure extends ExecutionFailure {
  const PreflightFailure(String message) : super('preflight_failed', message);
}

// ── Solana-specific ──
class SolanaBlockhashExpiredFailure extends ExecutionFailure {
  const SolanaBlockhashExpiredFailure()
      : super('solana_blockhash_expired', 'Recent blockhash expired');
}

class SolanaSimulationFailure extends ExecutionFailure {
  const SolanaSimulationFailure(String message)
      : super('solana_simulation_failed', message);
}

// ── Tron-specific ──
class TronSignatureFormatFailure extends ExecutionFailure {
  const TronSignatureFormatFailure(String message)
      : super('tron_signature_format_invalid', message);
}

class TronBuildTransactionFailure extends ExecutionFailure {
  const TronBuildTransactionFailure(String message)
      : super('tron_build_tx_failed', message);
}
