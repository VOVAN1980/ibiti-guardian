import 'dart:typed_data';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/services/execution/native_transaction_builder.dart';

/// The type of transaction being built.
enum TransactionType { send, approve, revoke, swap, unknown }

/// A normalized, execution-ready transaction object.
///
/// Created ONLY by [TransactionBuilder] — never constructed directly by the UI.
/// The UI receives this via [AssistantResponse.pendingTransaction] and passes
/// it back to [GuardianExecutionService.executeConfirmed].
class TransactionRequest {
  /// What kind of transaction this is
  final TransactionType type;

  /// Sender — always comes from WalletAdapter (never from user input)
  final String fromAddress;

  /// Destination (recipient for send, contract for approve/revoke)
  final String toAddress;

  /// Human-readable token symbol (e.g. "USDT")
  final String? tokenSymbol;

  /// Token contract address (e.g. "0xdAC17...")
  final String? tokenContract;

  /// Amount in human units (e.g. 20.0 for "20 USDT")
  /// @deprecated for execution — use [rawAmount] or [atomicAmount] instead.
  /// Retained for policy comparisons and display.
  /// double loses precision on large token amounts (e.g. SHIB, PEPE).
  final double? amount;

  /// Amount in atomic units (e.g. 20000000000000000000 for 20 USDT on BSC).
  /// This is the source of truth for on-chain execution.
  /// Set by construction sites; execution MUST use this, never [amount].
  final BigInt? rawAmount;

  /// Token decimals for atomic unit conversion (default 18 for EVM native).
  /// Must be set correctly for non-18-decimal tokens (USDC=6, WBTC=8).
  final int tokenDecimals;

  /// Chain ID the transaction targets
  final int chainId;

  /// Canonical chain snapshot captured when the preview was built.
  final String chainKey;

  /// Spender address — for approve / revoke only
  final String? spenderAddress;

  /// Whether this approval is unlimited (type.approve only)
  final bool isUnlimitedApproval;

  /// Target token symbol (for swap)
  final String? targetTokenSymbol;

  /// Target token contract address (for swap)
  final String? targetTokenAddress;

  /// Raw byte calldata for interacting with contracts (e.g. router)
  final Uint8List? calldata;

  /// Address of the router to execute swap
  final String? routerAddress;

  /// Does this swap require an ERC-20 approve first?
  final bool approvalNeeded;

  /// Information about the swap returned from Provider
  final Map<String, dynamic>? quoteSummary;

  /// The original intent that triggered this transaction (for traceability)
  final IntentData sourceIntent;

  const TransactionRequest({
    required this.type,
    required this.fromAddress,
    required this.toAddress,
    required this.chainId,
    required this.chainKey,
    required this.sourceIntent,
    this.tokenSymbol,
    this.tokenContract,
    this.targetTokenSymbol,
    this.targetTokenAddress,
    this.amount,
    this.rawAmount,
    this.tokenDecimals = 18,
    this.spenderAddress,
    this.isUnlimitedApproval = false,
    this.calldata,
    this.routerAddress,
    this.approvalNeeded = false,
    this.quoteSummary,
  });

  /// Canonical atomic amount for on-chain execution.
  ///
  /// Resolution order:
  /// 1. [rawAmount] if set (already atomic — source of truth)
  /// 2. For **verified native** sends only: computed from [amount] * 10^[tokenDecimals]
  /// 3. null otherwise — caller MUST handle (return error, never assume 18)
  ///
  /// ERC-20 / approve / swap paths MUST have [rawAmount] set explicitly.
  /// Falling back to amount*10^tokenDecimals for tokens is forbidden because
  /// tokenDecimals defaults to 18 and may be wrong for the actual token.
  BigInt? get atomicAmount {
    if (rawAmount != null) return rawAmount;
    if (amount == null) return null;

    // Only native SEND may fallback from human amount.
    // Approve/swap/revoke MUST have rawAmount set explicitly.
    if (type != TransactionType.send) return null;

    final contractEmpty = tokenContract == null || tokenContract!.isEmpty;
    if (!contractEmpty) return null;

    final chain = PrivyChainRegistry.getChain(chainKey);
    final nativeSym = chain.nativeSymbol?.toUpperCase();
    final txSym = tokenSymbol?.toUpperCase();
    if (nativeSym == null || txSym != nativeSym) return null;

    return NativeTransactionBuilder.toWeiFromDouble(
      amount!,
      decimals: tokenDecimals,
    );
  }

  /// Short label for the transaction type — used in preview card headers.
  /// e.g. "SEND", "REVOKE", "APPROVE", "SWAP", "UNKNOWN"
  String get typeLabel {
    switch (type) {
      case TransactionType.send:
        return 'SEND';
      case TransactionType.revoke:
        return 'REVOKE';
      case TransactionType.approve:
        return 'APPROVE';
      case TransactionType.swap:
        return 'SWAP';
      case TransactionType.unknown:
        return 'UNKNOWN';
    }
  }

  String get networkLabel => PrivyChainRegistry.getChain(chainKey).displayName;

  bool get isEvmChain =>
      PrivyChainRegistry.getChain(chainKey).evmChainId != null;

  /// Short display string for UI (used in preview cards)
  String get displaySummary {
    switch (type) {
      case TransactionType.send:
        final amt = amount?.toString() ?? '?';
        final tok = tokenSymbol ?? 'tokens';
        final to = _shortAddress(toAddress);
        return 'Send $amt $tok → $to';
      case TransactionType.revoke:
        final tok = tokenSymbol ?? 'token';
        final sp = _shortAddress(spenderAddress ?? toAddress);
        return 'Revoke $tok approval from $sp';
      case TransactionType.approve:
        final tok = tokenSymbol ?? 'token';
        final limit = isUnlimitedApproval ? 'unlimited' : '${amount ?? '?'}';
        return 'Approve $limit $tok';
      case TransactionType.swap:
        final amt = amount?.toString() ?? '?';
        final fromTok = tokenSymbol ?? 'tokens';
        final toTok = targetTokenSymbol ?? 'other tokens';
        return 'Swap $amt $fromTok → $toTok';
      case TransactionType.unknown:
        return 'Unknown transaction';
    }
  }

  static String _shortAddress(String addr) {
    if (addr.length < 12) return addr;
    return '${addr.substring(0, 6)}...${addr.substring(addr.length - 4)}';
  }
}
