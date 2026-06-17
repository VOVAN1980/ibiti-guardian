import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/policy/validators/epk_validator.dart';
import 'package:ibiti_guardian/services/policy/validators/epk_validator_result.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';

class SpendLimitValidator extends EPKValidator {
  const SpendLimitValidator() : super('SpendLimitValidator');

  @override
  Future<EpkValidatorResult> validate(
      TransactionRequest tx, EpkState state) async {
    if (!state.hasSpendLimitValidator) {
      return EpkValidatorResult.pass();
    }

    if (tx.type != TransactionType.send) {
      // Limits generally apply to sending funds, approvals are handled elsewhere
      return EpkValidatorResult.pass();
    }

    final amount = tx.amount ?? 0.0;
    if (amount <= 0) {
      return EpkValidatorResult.pass();
    }

    // HONEST V1 RESTRICTION: We only reliably track stablecoins for USD limits right now.
    // To prevent fake generic math, if it's not a known stablecoin, we map it as 1:1 if it's a stable,
    // or we block it if it's completely unknown without a price oracle.
    final symbol = (tx.tokenSymbol ?? '').toUpperCase();
    final isStable = ['USDT', 'USDC', 'DAI', 'BUSD'].contains(symbol);

    double estimatedUsdValue = 0.0;

    if (isStable) {
      estimatedUsdValue = amount;
    } else if (['BNB', 'ETH', 'MATIC'].contains(symbol)) {
      return EpkValidatorResult.reject(
        reason: 'UNSUPPORTED_TOKEN_PRICING',
        userMessage:
            'SpendLimitValidator V1 only supports stablecoin limits (USDT/USDC/DAI/BUSD). Cannot safely price $symbol without an oracle.',
        debugDetails:
            'Token: $symbol, Oracle integration required for native token pricing.',
      );
    } else {
      return EpkValidatorResult.reject(
        reason: 'UNKNOWN_TOKEN_VALUE',
        userMessage:
            'Cannot send unknown token $symbol — its USD value cannot be verified against your Vault limits.',
      );
    }

    // Per-TX Limit
    if (estimatedUsdValue > state.perTxLimit) {
      return EpkValidatorResult.reject(
        reason: 'PER_TX_LIMIT_EXCEEDED',
        userMessage:
            'Transaction amount (\$${estimatedUsdValue.toStringAsFixed(2)}) exceeds your per-transaction limit of \$${state.perTxLimit.toStringAsFixed(2)}.',
        debugDetails: 'Amount: $estimatedUsdValue, Limit: ${state.perTxLimit}',
      );
    }

    // Daily Limit — compute today's date key
    final today = DateTime.now();
    final dateStr = '${today.year}-${today.month}-${today.day}';
    double currentSpent = state.spentTodayUsd;
    if (state.lastSpendResetDate != dateStr) {
      currentSpent = 0.0;
    }

    if ((currentSpent + estimatedUsdValue) > state.dailyLimit) {
      return EpkValidatorResult.reject(
        reason: 'DAILY_LIMIT_EXCEEDED',
        userMessage:
            'This transaction would exceed your daily Vault limit of \$${state.dailyLimit.toStringAsFixed(2)}.',
        debugDetails:
            'Current: $currentSpent, Attempting: $estimatedUsdValue, Limit: ${state.dailyLimit}',
      );
    }

    return EpkValidatorResult.pass();
  }
}
