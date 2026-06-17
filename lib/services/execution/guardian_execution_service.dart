import 'dart:typed_data';

import 'package:ibiti_guardian/models/asset_amount.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/execution_result.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/send_native_models.dart';
import 'package:ibiti_guardian/services/adapters/security_adapter.dart';
import 'package:ibiti_guardian/services/adapters/portfolio_adapter.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';
import 'package:ibiti_guardian/services/audit_log_service.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_signer.dart';
import 'package:ibiti_guardian/services/vault/epk_contract_resolver.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/services/execution/native_transaction_builder.dart';
import 'package:ibiti_guardian/services/execution/execution_router.dart';
import 'package:ibiti_guardian/services/swap/jupiter_swap_provider.dart';
import 'package:ibiti_guardian/services/swap/sunswap_provider.dart';
import 'package:ibiti_guardian/services/execution/clients/tron_rpc_client.dart';
import 'package:ibiti_guardian/services/execution/tx_status_poller.dart';
import 'package:ibiti_guardian/services/assistant/voice_script_mapper.dart';

import 'package:ibiti_guardian/utils/guardian_logger.dart';

/// The "Hands" of the Guardian stack.
///
/// Responsibility: Receive a decided path and fully validated TransactionRequest,
/// dispatch to the correct low-level adapter (Privy via IBITIVaultSigner),
/// run local EPK enforcement, and return standard UI + voice responses.
///
/// Phase 9: All methods use "local policy-enforced execution" (Variant A).
/// Phase 11: All action responses now carry speechText from VoiceScriptMapper.
class GuardianExecutionService {
  GuardianExecutionService._();
  static final instance = GuardianExecutionService._();

  static const _log = GuardianLogger('ExecutionService');

  final _wallet = WalletAdapter.instance;
  final _security = SecurityAdapter.instance;
  final _portfolio = PortfolioAdapter.instance;

  /// Executes an already-decided operation through the provided path.
  Future<AssistantResponse> dispatchConfiguredPath(
      TransactionRequest tx, ExecutionPath path) async {
    final effectivePath = normalizeExecutionPath(tx, path);
    switch (tx.type) {
      case TransactionType.send:
        return await _executeSend(tx, effectivePath);
      case TransactionType.revoke:
        return await _executeRevoke(tx, effectivePath);
      case TransactionType.approve:
        return await _executeApprove(tx, effectivePath);
      case TransactionType.swap:
        return await _executeSwap(tx, effectivePath);
      case TransactionType.unknown:
        return AssistantResponse.error(
          'Cannot dispatch unknown transaction type.',
          intent: tx.sourceIntent,
        );
    }
  }

  ExecutionPath normalizeExecutionPath(
      TransactionRequest tx, ExecutionPath requestedPath) {
    if (requestedPath != ExecutionPath.epkProtected) {
      return requestedPath;
    }
    if (_supportsOnChainEpk(tx)) {
      return requestedPath;
    }
    return ExecutionPath.localProtected;
  }

  // ─── Send / Approve / Swap — Local Policy-Enforced Execution ────────────────
  //
  // All methods:
  //   1. Build minimal tx params (to, data, value) via NativeTransactionBuilder.
  //   2. IBITIVaultSigner.sendTransaction() enforces CompositeValidator then
  //      calls Privy eth_sendTransaction.
  //   3. Return AssistantResponse with both message (UI) and speechText (voice).
  //      speechText comes exclusively from VoiceScriptMapper — never from message.

  /// Language detection helper — infers language from the raw user input
  /// stored on the source intent. Falls back to 'en'.
  VoiceScriptMapper _voice(TransactionRequest tx) =>
      VoiceScriptMapper.forLang(detectLangFromText(tx.sourceIntent.rawInput));

  Future<AssistantResponse> _executeSend(
      TransactionRequest tx, ExecutionPath path) async {
    final voice = _voice(tx);
    try {
      _assertExecutionContext(tx);
      final isNative = tx.tokenContract == null || tx.tokenContract!.isEmpty;
      final amountWei = tx.atomicAmount;
      if (amountWei == null) {
        return AssistantResponse.error(
          'Send failed: missing amount.',
          intent: tx.sourceIntent,
        );
      }

      String? hash;
      if (isNative && !tx.isEvmChain) {
        // ── Non-EVM native send (SOL, TRX) ──
        final result = await ExecutionRouter.instance.sendNative(
          SendNativeRequest(
            chainKey: tx.chainKey,
            fromAddress: tx.fromAddress,
            toAddress: tx.toAddress,
            amount: AssetAmount(
              symbol: tx.tokenSymbol ?? 'NATIVE',
              decimals: _nativeDecimals(tx.chainKey),
              atomic: amountWei,
            ),
          ),
        );
        hash = result.txHash;
      } else if (!isNative && tx.chainKey == 'solana') {
        // ── Solana SPL token send ──
        // Source ATA is auto-discovered by the adapter via RPC.
        final result = await ExecutionRouter.instance.sendSplToken(
          fromAddress: tx.fromAddress,
          toAddress: tx.toAddress,
          mintAddress: tx.tokenContract!,
          amount: amountWei,
        );
        hash = result.txHash;
      } else if (!isNative && tx.chainKey == 'tron') {
        // ── Tron TRC20 token send ──
        final result = await ExecutionRouter.instance.sendTrc20Token(
          fromAddress: tx.fromAddress,
          toAddress: tx.toAddress,
          contractAddress: tx.tokenContract!,
          amountRaw: amountWei,
        );
        hash = result.txHash;
      } else {
        // ── EVM native or ERC-20 send ──
        final txParams = isNative
            ? NativeTransactionBuilder.buildNativeTransferParams(
                fromAddress: tx.fromAddress,
                toAddress: tx.toAddress,
                amountWei: amountWei,
              )
            : NativeTransactionBuilder.buildErc20TransferParams(
                fromAddress: tx.fromAddress,
                tokenContract: tx.tokenContract!,
                toAddress: tx.toAddress,
                amountWei: amountWei,
              );

        hash = await _dispatchEvmWrite(
          tx: tx,
          path: path,
          txParams: txParams,
        );
      }

      if (hash == null) {
        _log.w('executeSend: hash returned was null. tx: toAddress=${tx.toAddress}, amount=${tx.amount}, chain=${tx.chainId}');
        _recordFailure(
          tx: tx,
          path: path,
          message: 'Transaction was rejected. Please try again.',
        );
        return AssistantResponse(
          message: 'Transaction was rejected. Please try again.',
          speechText: voice.rejected(),
          type: ResponseType.error,
          sourceIntent: tx.sourceIntent,
        );
      }

      _recordSuccess(
        tx: tx,
        path: path,
        txHash: hash,
        message: 'Transaction submitted to mempool.',
      );

      // P0 Fix: Start receipt polling — track real on-chain confirmation.
      _startReceiptPolling(hash, tx, 'Sending ${tx.tokenSymbol ?? "tokens"}');

      return AssistantResponse(
        message: tx.isEvmChain
            ? '✉️ Submitted — confirming on-chain...\n${tx.displaySummary}\n${_explorerLink(hash, tx.chainId)}'
            : '✉️ Submitted — confirming...\n${tx.displaySummary}\nTransaction: $hash',
        speechText: voice.sendSent(),
        type: ResponseType.action,
        sourceIntent: tx.sourceIntent,
        detail: hash,
      );
    } on EPKValidationException catch (e) {
      _recordPolicyBlock(tx, e.reason);
      return AssistantResponse(
        message: 'Blocked by policy: $e',
        speechText: _policyVoice(e.reason, voice),
        type: ResponseType.error,
        sourceIntent: tx.sourceIntent,
      );
    } catch (e) {
      _recordFailure(
        tx: tx,
        path: path,
        message: _humanizeError(e),
      );
      return AssistantResponse(
        message: 'Send failed: ${_humanizeError(e)}',
        speechText: voice.sendFailed(),
        type: ResponseType.error,
        sourceIntent: tx.sourceIntent,
      );
    }
  }

  Future<AssistantResponse> _executeRevoke(
      TransactionRequest tx, ExecutionPath path) async {
    final voice = _voice(tx);
    try {
      _assertExecutionContext(tx);
      if (tx.tokenContract == null || tx.spenderAddress == null) {
        return AssistantResponse.error(
          'Revoke failed: missing token contract or spender.',
          intent: tx.sourceIntent,
        );
      }

      final txParams = NativeTransactionBuilder.buildApproveParams(
        fromAddress: tx.fromAddress,
        tokenContract: tx.tokenContract!,
        spenderAddress: tx.spenderAddress!,
        amountWei: BigInt.zero,
      );

      final hash = await _dispatchEvmWrite(
        tx: tx,
        path: path,
        txParams: txParams,
      );

      if (hash == null) {
        _recordFailure(
          tx: tx,
          path: path,
          message: 'Revocation rejected.',
        );
        return AssistantResponse(
          message: 'Revocation rejected.',
          speechText: voice.rejected(),
          type: ResponseType.error,
          sourceIntent: tx.sourceIntent,
        );
      }

      _recordSuccess(
        tx: tx,
        path: path,
        txHash: hash,
        message: 'Revocation submitted to mempool.',
      );

      _startReceiptPolling(hash, tx, 'Revoking approval');

      return AssistantResponse(
        message:
            '✉️ Revocation submitted — confirming...\n${tx.displaySummary}\n${_explorerLink(hash, tx.chainId)}',
        speechText: voice.revokeSent(),
        type: ResponseType.action,
        sourceIntent: tx.sourceIntent,
        detail: hash,
      );
    } on EPKValidationException catch (e) {
      _recordPolicyBlock(tx, e.reason);
      return AssistantResponse(
        message: 'Blocked by policy: $e',
        speechText: _policyVoice(e.reason, voice),
        type: ResponseType.error,
        sourceIntent: tx.sourceIntent,
      );
    } catch (e) {
      _recordFailure(
        tx: tx,
        path: path,
        message: _humanizeError(e),
      );
      return AssistantResponse(
        message: 'Revoke failed: ${_humanizeError(e)}',
        speechText: voice.sendFailed(),
        type: ResponseType.error,
        sourceIntent: tx.sourceIntent,
      );
    }
  }

  Future<AssistantResponse> _executeApprove(
      TransactionRequest tx, ExecutionPath path) async {
    final voice = _voice(tx);
    try {
      _assertExecutionContext(tx);
      if (tx.tokenContract == null || tx.spenderAddress == null) {
        return AssistantResponse.error(
          'Approve failed: missing token contract or spender.',
          intent: tx.sourceIntent,
        );
      }

      // Approval amount: exact or unlimited (uint256 max)
      final BigInt amountWei;
      if (tx.isUnlimitedApproval) {
        amountWei = BigInt.parse(
            '115792089237316195423570985008687907853269984665640564039457584007913129639935');
      } else {
        amountWei = tx.atomicAmount ?? BigInt.zero;
      }

      // spenderAddress MUST be allowanceTarget (0x AllowanceHolder), NOT the router
      final txParams = NativeTransactionBuilder.buildApproveParams(
        fromAddress: tx.fromAddress,
        tokenContract: tx.tokenContract!,
        spenderAddress: tx.spenderAddress!,
        amountWei: amountWei,
      );

      final hash = await _dispatchEvmWrite(
        tx: tx,
        path: path,
        txParams: txParams,
      );

      if (hash == null) {
        _recordFailure(
          tx: tx,
          path: path,
          message: 'Approval rejected.',
        );
        return AssistantResponse(
          message: 'Approval rejected.',
          speechText: voice.rejected(),
          type: ResponseType.error,
          sourceIntent: tx.sourceIntent,
        );
      }

      _recordSuccess(
        tx: tx,
        path: path,
        txHash: hash,
        message: 'Approval submitted to mempool.',
      );

      _startReceiptPolling(hash, tx, 'Approving ${tx.tokenSymbol ?? "token"}');

      return AssistantResponse(
        message:
            '✉️ Approval submitted — confirming...\n${tx.displaySummary}\n${_explorerLink(hash, tx.chainId)}',
        speechText: voice.approveSent(),
        type: ResponseType.action,
        sourceIntent: tx.sourceIntent,
        detail: hash,
      );
    } on EPKValidationException catch (e) {
      _recordPolicyBlock(tx, e.reason);
      return AssistantResponse(
        message: 'Blocked by policy: $e',
        speechText: _policyVoice(e.reason, voice),
        type: ResponseType.error,
        sourceIntent: tx.sourceIntent,
      );
    } catch (e) {
      _recordFailure(
        tx: tx,
        path: path,
        message: _humanizeError(e),
      );
      return AssistantResponse(
        message: 'Approve failed: ${_humanizeError(e)}',
        speechText: voice.sendFailed(),
        type: ResponseType.error,
        sourceIntent: tx.sourceIntent,
      );
    }
  }

  Future<AssistantResponse> _executeSwap(
      TransactionRequest tx, ExecutionPath path) async {
    final voice = _voice(tx);
    try {
      _assertExecutionContext(tx);
      // Calldata comes verbatim from 0x quote — never assembled here
      if (tx.calldata == null || tx.routerAddress == null) {
        return AssistantResponse(
          message:
              'Swap failed: quote calldata or router missing. Please re-request the swap.',
          speechText: voice.swapNoRoute(),
          type: ResponseType.error,
          sourceIntent: tx.sourceIntent,
        );
      }

      String? hash;

      if (tx.chainKey == 'solana') {
        // ── Solana Jupiter V2 swap ──
        // calldata = raw bytes of serialized VersionedTransaction from /order
        // Sign via Privy, then submit to Jupiter /execute for managed landing.
        final transactionBase64 =
            tx.quoteSummary?['transactionBase64']?.toString() ?? '';
        print(
            '[SolanaSwap] swap tx base64 received (len=${transactionBase64.length})');
        if (transactionBase64.isEmpty) {
          return AssistantResponse(
            message:
                'Swap failed: Jupiter transaction data missing. Please re-request the swap.',
            speechText: voice.swapNoRoute(),
            type: ResponseType.error,
            sourceIntent: tx.sourceIntent,
          );
        }

        final requestId = tx.quoteSummary?['requestId']?.toString() ?? '';
        print('[SolanaSwap] requestId = $requestId');

        // Sign the transaction via Privy (sign-only, no send)
        print('[SolanaSwap] signing via Privy...');
        final signedBase64 = await ExecutionRouter.instance
            .signJupiterTransaction(transactionBase64);
        print('[SolanaSwap] signed tx ready (len=${signedBase64.length})');

        // Submit signed tx to Jupiter for managed landing
        print('[SolanaSwap] submitting to Jupiter /execute...');
        hash = await JupiterSwapProvider.instance.executeSignedSwap(
          requestId: requestId,
          signedTransactionBase64: signedBase64,
        );
        print('[SolanaSwap] ✅ tx hash = $hash');
      } else if (tx.chainKey == 'tron') {
        // ── Tron SunSwap V2 swap ──
        final funcSelector =
            tx.quoteSummary?['functionSelector']?.toString() ?? '';
        final parameter = tx.quoteSummary?['parameter']?.toString() ?? '';
        final feeLimit = (tx.quoteSummary?['feeLimit'] as num?)?.toInt() ??
            TronHttpRpcClient.defaultSwapFeeLimit;

        if (funcSelector.isEmpty || parameter.isEmpty) {
          return AssistantResponse(
            message:
                'Swap failed: SunSwap transaction data missing. Please re-request.',
            speechText: voice.swapNoRoute(),
            type: ResponseType.error,
            sourceIntent: tx.sourceIntent,
          );
        }

        // Step 1: Check allowance → approve if needed (standard DEX flow)
        if (tx.approvalNeeded) {
          final sourceToken =
              tx.quoteSummary?['sourceTokenForApprove']?.toString() ?? '';
          if (sourceToken.isNotEmpty && tx.rawAmount != null) {
            // Read current allowance on-chain
            final rpcClient = TronHttpRpcClient();
            final currentAllowance = await rpcClient.getAllowance(
              ownerAddress: tx.fromAddress,
              spenderAddress: sunswapV2Router,
              tokenContract: sourceToken,
            );

            // Only approve if current allowance is insufficient
            if (currentAllowance < tx.rawAmount!) {
              await ExecutionRouter.instance.approveTrc20(
                ownerAddress: tx.fromAddress,
                tokenContract: sourceToken,
                spenderAddress: sunswapV2Router,
                amount: tx.rawAmount!, // exact amount, not unlimited
              );
            }
          }
        }

        // Step 2: Execute swap
        final nativeValueStr =
            tx.quoteSummary?['nativeValue']?.toString() ?? '0';
        final callValue = BigInt.tryParse(nativeValueStr) ?? BigInt.zero;

        final result = await ExecutionRouter.instance.executeTronSwap(
          fromAddress: tx.fromAddress,
          routerAddress: sunswapV2Router,
          functionSelector: funcSelector,
          parameter: parameter,
          feeLimit: feeLimit,
          callValue: callValue > BigInt.zero ? callValue : null,
        );
        hash = result.txHash;
      } else {
        // ── EVM swap (0x / AllowanceHolder) ──
        // Native value to attach (non-zero only when selling native token)
        final nativeValueStr =
            tx.quoteSummary?['nativeValue']?.toString() ?? '0';
        final BigInt nativeValue;
        if (nativeValueStr.startsWith('0x')) {
          nativeValue =
              BigInt.tryParse(nativeValueStr.substring(2), radix: 16) ??
                  BigInt.zero;
        } else {
          nativeValue = BigInt.tryParse(nativeValueStr) ?? BigInt.zero;
        }

        final txParams = NativeTransactionBuilder.buildSwapParams(
          fromAddress: tx.fromAddress,
          routerAddress: tx.routerAddress!,
          calldata: tx.calldata!,
          nativeValue: nativeValue,
        );

        hash = await _dispatchEvmWrite(
          tx: tx,
          path: path,
          txParams: txParams,
        );
      }

      if (hash == null) {
        _recordFailure(
          tx: tx,
          path: path,
          message: 'Swap rejected. Please try again.',
        );
        return AssistantResponse(
          message: 'Swap rejected. Please try again.',
          speechText: voice.swapFailed(),
          type: ResponseType.error,
          sourceIntent: tx.sourceIntent,
        );
      }

      final provider = tx.quoteSummary?['provider']?.toString() ?? 'DEX';
      final routeSummary = tx.quoteSummary?['routeSummary']?.toString() ?? '';
      _recordSuccess(
        tx: tx,
        path: path,
        txHash: hash,
        message: 'Swap submitted to mempool.',
      );

      _startReceiptPolling(
        hash,
        tx,
        'Swapping ${tx.tokenSymbol ?? "?"} → ${tx.targetTokenSymbol ?? "?"}',
      );

      return AssistantResponse(
        message: '✉️ Swap via $provider submitted — confirming...\n'
            '${tx.displaySummary}\n'
            '${routeSummary.isNotEmpty ? "Route: $routeSummary\n" : ""}'
            '${_explorerLink(hash, tx.chainId)}',
        speechText: voice.swapSent(),
        type: ResponseType.action,
        sourceIntent: tx.sourceIntent,
        detail: hash,
      );
    } on EPKValidationException catch (e) {
      _recordPolicyBlock(tx, e.reason);
      return AssistantResponse(
        message: 'Blocked by policy: $e',
        speechText: _policyVoice(e.reason, voice),
        type: ResponseType.error,
        sourceIntent: tx.sourceIntent,
      );
    } catch (e) {
      _recordFailure(
        tx: tx,
        path: path,
        message: _humanizeError(e),
      );
      return AssistantResponse(
        message: 'Swap failed: ${_humanizeError(e)}',
        speechText: voice.swapFailed(),
        type: ResponseType.error,
        sourceIntent: tx.sourceIntent,
      );
    }
  }

  // ── P0 Fix: Honest tx status — start receipt polling after dispatch ─────
  //
  // Kicks off TxStatusPoller to track real on-chain confirmation.
  // The initial response says "Submitted — confirming...", and the poller
  // updates TxRegistry with confirmed/failed/timeout status.
  // TxStatusCard in the UI reacts to TxRegistry changes automatically.
  void _startReceiptPolling(
    String hash,
    TransactionRequest tx,
    String operationLabel,
  ) {
    if (!tx.isEvmChain) return; // Poller only supports EVM chains

    TxStatusPoller.instance.start(
      txHash: hash,
      chainId: tx.chainId,
      operationLabel: operationLabel,
      assetLabel: tx.displaySummary,
      walletAddress: tx.fromAddress,
      onStatus: (event) {
        // TxRegistry is updated inside the poller itself.
        // This callback is available for future use (e.g. push notification).
      },
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────────

  /// Maps an EPKValidationException reason to the appropriate voice phrase.
  String _policyVoice(String reason, VoiceScriptMapper voice) {
    if (reason.contains('limit') || reason.contains('лимит')) {
      return voice.policyLimitExceeded();
    }
    if (reason.contains('slippage') || reason.contains('проскальз')) {
      return voice.policySlippageTooHigh();
    }
    if (reason.contains('address') || reason.contains('адрес')) {
      return voice.policyAddressBlocked();
    }
    return voice.policyBlocked();
  }

  /// Block explorer tx link for the current chain.
  String _explorerLink(String hash, int chainId) {
    const explorers = <int, String>{
      1: 'https://etherscan.io/tx/',
      56: 'https://bscscan.com/tx/',
      137: 'https://polygonscan.com/tx/',
      42161: 'https://arbiscan.io/tx/',
      10: 'https://optimistic.etherscan.io/tx/',
      8453: 'https://basescan.org/tx/',
      43114: 'https://snowtrace.io/tx/',
    };
    final base = explorers[chainId] ?? 'https://bscscan.com/tx/';
    return 'Explorer: $base$hash';
  }

  /// Converts raw exceptions into short, human-readable UI strings.
  /// Does NOT use these for voice — voice uses VoiceScriptMapper exclusively.
  String _humanizeError(Object e) {
    final msg = e.toString();
    if (msg.contains('insufficient funds')) {
      return 'Insufficient funds for gas.';
    }
    if (msg.contains('user rejected')) return 'Rejected in wallet.';
    if (msg.contains('nonce too low')) return 'Nonce conflict — try again.';
    if (msg.contains('gas required exceeds')) return 'Gas limit too low.';
    if (msg.length > 120) return '${msg.substring(0, 120)}…';
    return msg;
  }

  // ─── Informational & Context ───────────────────────────────────────────────
  // Phase 4 specific legacy code bridging (intents read directly)

  bool _supportsOnChainEpk(TransactionRequest tx) {
    final epkState = EPKPolicyManager.instance.state;
    if (!epkState.isActive || !epkState.isDeployed) {
      return false;
    }

    if (!EpkContractResolver.instance.isReady(
      chainId: tx.chainId,
      rawPolicyId: _wallet.policyId,
    )) {
      return false;
    }

    switch (tx.type) {
      case TransactionType.send:
        final isNative = tx.tokenContract == null || tx.tokenContract!.isEmpty;
        return !isNative;
      case TransactionType.revoke:
      case TransactionType.approve:
        return tx.tokenContract != null &&
            tx.tokenContract!.isNotEmpty &&
            tx.spenderAddress != null &&
            tx.spenderAddress!.isNotEmpty;
      case TransactionType.swap:
        return tx.routerAddress != null &&
            tx.routerAddress!.isNotEmpty &&
            tx.calldata != null &&
            tx.calldata!.length >= 4;
      case TransactionType.unknown:
        return false;
    }
  }

  Future<String?> _dispatchEvmWrite({
    required TransactionRequest tx,
    required ExecutionPath path,
    required Map<String, dynamic> txParams,
  }) async {
    if (path != ExecutionPath.epkProtected) {
      return IBITIVaultSigner.instance
          .sendTransaction(txParams: txParams, txContext: tx);
    }

    final kernelAddress =
        EpkContractResolver.instance.kernelAddressForChain(tx.chainId);
    final policyId =
        EpkContractResolver.instance.parsePolicyId(_wallet.policyId);
    if (kernelAddress == null || policyId == null) {
      throw const EPKValidationException(
        'On-chain EPK is not configured for this wallet/network.',
      );
    }

    final target = txParams['to']?.toString() ?? '';
    if (target.isEmpty) {
      throw const EPKValidationException('Missing EPK execution target.');
    }

    return IBITIVaultSigner.instance.executeEPKTransaction(
      txContext: tx,
      epkAddress: kernelAddress,
      policyId: policyId,
      target: target,
      value: _parseBigIntValue(txParams['value']?.toString()),
      data: _decodeTxData(txParams['data']?.toString()),
    );
  }

  BigInt _parseBigIntValue(String? raw) {
    if (raw == null || raw.isEmpty) return BigInt.zero;
    if (raw.startsWith('0x')) {
      return BigInt.tryParse(raw.substring(2), radix: 16) ?? BigInt.zero;
    }
    return BigInt.tryParse(raw) ?? BigInt.zero;
  }

  Uint8List _decodeTxData(String? dataHex) {
    if (dataHex == null || dataHex.isEmpty || dataHex == '0x') {
      return Uint8List(0);
    }
    final clean = dataHex.startsWith('0x') ? dataHex.substring(2) : dataHex;
    final normalized = clean.length.isOdd ? '0$clean' : clean;
    return Uint8List.fromList(List<int>.generate(
      normalized.length ~/ 2,
      (i) => int.parse(
        normalized.substring(i * 2, i * 2 + 2),
        radix: 16,
      ),
    ));
  }

  Future<AssistantResponse> executeScan(IntentData intent) async {
    try {
      final approvals =
          await _security.startScan(_wallet.address, _wallet.chainId);
      final riskyCount =
          approvals.where((a) => a.assessment.shouldRevoke).length;

      final t = LocalizationService.instance;
      final voice =
          VoiceScriptMapper.forLang(detectLangFromText(intent.rawInput));

      if (riskyCount == 0) {
        return AssistantResponse(
          message: t.t('scanNoRisky'),
          speechText: voice.scanClean(),
          sourceIntent: intent,
        );
      }
      return AssistantResponse(
        message: '${t.t('panicDangerousFound', {
              'count': riskyCount
            })} ${t.t('scanAnalyzingTitle')}.',
        speechText: voice.scanThreats(riskyCount),
        type: ResponseType.warning,
        sourceIntent: intent,
      );
    } catch (e) {
      return AssistantResponse.error(
          LocalizationService.instance.t('scanFailed'),
          intent: intent);
    }
  }

  Future<AssistantResponse> handleInformational(IntentData intent) async {
    switch (intent.type) {
      case IntentType.showBalances:
        return await _fetchBalances(intent);
      case IntentType.showWalletCards:
        return _showWalletCards(intent);
      case IntentType.showAddress:
        return _showAddress(intent);
      case IntentType.receiveAsset:
        return AssistantResponse.info(
          'Opening receive flow.',
          intent: intent,
        );
      case IntentType.showHistory:
        return AssistantResponse.info(
          'Opening transaction history.',
          intent: intent,
        );
      case IntentType.openAddressBook:
        return AssistantResponse.info(
          'Opening address book.',
          intent: intent,
        );
      case IntentType.openWalletSettings:
        return AssistantResponse.info(
          'Opening wallet settings.',
          intent: intent,
        );
      case IntentType.openMarket:
        return AssistantResponse.info(
          'Opening market.',
          intent: intent,
        );
      case IntentType.openSecurityCenter:
        return AssistantResponse.info(
          'Opening security center.',
          intent: intent,
        );
      case IntentType.showRisks:
        return await _fetchRisks(intent);
      case IntentType.unknown:
        return AssistantResponse.unknown();
      default:
        return AssistantResponse.unknown();
    }
  }

  Future<AssistantResponse> _fetchBalances(IntentData intent) async {
    final t = LocalizationService.instance;
    final voice =
        VoiceScriptMapper.forLang(detectLangFromText(intent.rawInput));
    try {
      final summary =
          await _portfolio.fetchSummary(_wallet.address, _wallet.chainKey);
      if (summary.assetsCount == 0) {
        return AssistantResponse(
          message: t.t('walletNoAssetsFound'),
          speechText: voice.noBalance(),
          sourceIntent: intent,
        );
      }
      final totalStr = summary.totalBalanceUsd.toStringAsFixed(2);
      return AssistantResponse(
        message:
            '${t.t('portfolioTotalValue')}: \$$totalStr. ${t.t('portfolioTokensCount', {
              'count': summary.assetsCount
            })}.',
        speechText: voice.balanceFetched(totalStr),
        sourceIntent: intent,
        detail: summary.topAssets
            .map((a) => '${a.symbol}: \$${a.valueUsd.toStringAsFixed(2)}')
            .join(' · '),
      );
    } catch (e) {
      return AssistantResponse.error(t.t('errorApiFailed'), intent: intent);
    }
  }

  AssistantResponse _showAddress(IntentData intent) {
    final t = LocalizationService.instance;
    final activeAddress = IBITIVaultService.instance.activeAddress;
    if (activeAddress.isEmpty) {
      return AssistantResponse.error(t.t('walletNoConnection'), intent: intent);
    }
    return AssistantResponse.info(
      '${t.t('cmdMyAddress')}: $activeAddress',
      intent: intent,
      detail: activeAddress,
    );
  }

  /// Wallet cards info — returns card count, tiers, per-card balances.
  AssistantResponse _showWalletCards(IntentData intent) {
    final vault = IBITIVaultService.instance;
    final isRu = detectLangFromText(intent.rawInput) == 'ru';

    if (!vault.isVaultCreated || vault.activeAddress.isEmpty) {
      return AssistantResponse.error(
        isRu ? 'Кошелёк не подключён.' : 'Wallet is not connected.',
        intent: intent,
      );
    }

    final cards = vault.evmCardAddresses;
    final total = cards.length;
    final max = vault.maxEvmCards;
    final primaryAddress = vault.evmAddress ?? '';

    // Card tier names — order matches creation: Black, Silver, Gold, Platinum.
    // TTS-safe RU names: avoid words that GPT-4o TTS mispronounces.
    const tiers = ['Black', 'Silver', 'Gold', 'Platinum'];
    const tiersRu = ['Чёрная', 'Серебро', 'Золотая', 'Платина'];
    // TTS-spoken names — short, clear, pronounceable
    const tiersSpeechRu = ['чёрная', 'серебро', 'золотая', 'платина'];
    const tiersSpeechEn = ['Black', 'Silver', 'Gold', 'Platinum'];

    final displayLines = <String>[];
    final speechLines = <String>[];

    for (var i = 0; i < total; i++) {
      final addr = cards[i];
      final tierDisplay =
          i < tiers.length ? (isRu ? tiersRu[i] : tiers[i]) : '#${i + 1}';
      final tierSpeech = i < tiers.length
          ? (isRu ? tiersSpeechRu[i] : tiersSpeechEn[i])
          : '#${i + 1}';
      final isPrimary = addr.toLowerCase() == primaryAddress.toLowerCase();
      final summary = VaultPortfolioListener.instance
          .summaryForAddress(addr, vault.chainKey);

      // Display string uses '$' symbol
      final balanceDisplayStr = summary != null
          ? '\$${summary.totalBalanceUsd.toStringAsFixed(2)}'
          : '...';

      // Speech string explicitly uses 'долларов' to prevent TTS saying 'доляровая'
      final balanceSpeechStr = summary != null
          ? '${summary.totalBalanceUsd.toStringAsFixed(2)} ${isRu ? 'долларов' : 'dollars'}'
          : '';

      final primaryTag = isPrimary ? (isRu ? ' ★ основная' : ' ★ primary') : '';

      // Removed addresses ($short) per user request to keep UI and speech clean
      displayLines.add('$tierDisplay: $balanceDisplayStr$primaryTag');

      // Speech: ONLY tier + balance
      if (summary != null) {
        speechLines.add(isRu
            ? '$tierSpeech: $balanceSpeechStr$primaryTag'
            : '$tierSpeech card: $balanceSpeechStr$primaryTag');
      }
    }

    final headerMsg = isRu
        ? 'В вашем кошельке $total из $max карт:'
        : 'Your wallet has $total of $max cards:';
    final canAdd = vault.canCreateAdditionalEvmCard;
    final footerMsg = canAdd
        ? (isRu
            ? 'Вы можете создать ещё ${max - total}.'
            : 'You can create ${max - total} more.')
        : (isRu ? 'Лимит карт достигнут.' : 'Card limit reached.');

    final displayMessage = '$headerMsg\n${displayLines.join('\n')}\n$footerMsg';

    // Speech: short summary only, no addresses, only loaded cards
    final loadedCount = speechLines.length;
    final speechText = loadedCount == 0
        ? (isRu
            ? 'Всего у вас $total карт, их балансы ещё подгружаются.'
            : 'You have $total cards in total, balances are still loading.')
        : (isRu
            ? 'Всего у вас $total карт. Из них с балансом $loadedCount: ${speechLines.join(', ')}.'
            : 'You have $total cards. $loadedCount loaded: ${speechLines.join(', ')}.');

    return AssistantResponse.info(
      displayMessage,
      speechText: speechText,
      intent: intent,
      detail: displayLines.join(' · '),
    );
  }

  Future<AssistantResponse> _fetchRisks(IntentData intent) async {
    final t = LocalizationService.instance;
    final voice =
        VoiceScriptMapper.forLang(detectLangFromText(intent.rawInput));
    try {
      final summary =
          await _security.getSummary(_wallet.address, _wallet.chainId);
      if (summary.riskyApprovalsCount == 0) {
        return AssistantResponse(
          message: t.t('scanNoRisky'),
          speechText: voice.scanClean(),
          sourceIntent: intent,
        );
      }
      return AssistantResponse(
        message:
            t.t('panicDangerousFound', {'count': summary.riskyApprovalsCount}),
        speechText: voice.scanThreats(summary.riskyApprovalsCount),
        type: ResponseType.warning,
        sourceIntent: intent,
        detail: summary.warnings.take(3).join(' · '),
      );
    } catch (e) {
      return AssistantResponse.error(t.t('scanFailed'), intent: intent);
    }
  }

  void _assertExecutionContext(TransactionRequest tx) {
    final vault = IBITIVaultService.instance;
    if (!vault.isVaultCreated || !vault.isUnlocked) {
      throw StateError('Vault is not ready for execution.');
    }
    if (vault.chainKey != tx.chainKey) {
      throw StateError(
        'Active network changed from ${tx.networkLabel} to '
        '${_wallet.chainKey.toUpperCase()}. Review the transaction again.',
      );
    }
    if (vault.activeAddress.toLowerCase() != tx.fromAddress.toLowerCase()) {
      throw StateError(
        'Active wallet changed after preview. Review the transaction again.',
      );
    }
  }

  int _nativeDecimals(String chainKey) {
    switch (chainKey) {
      case 'solana':
        return 9;
      case 'tron':
        return 6;
      default:
        return 18;
    }
  }

  BigInt _nativeAtomic(double amount, String chainKey) {
    final decimals = _nativeDecimals(chainKey);
    return NativeTransactionBuilder.toWeiFromDouble(amount, decimals: decimals);
  }

  void _recordSuccess({
    required TransactionRequest tx,
    required ExecutionPath path,
    required String txHash,
    required String message,
  }) {
    AuditLogService.instance.record(
      intentType: tx.sourceIntent.type,
      actionLabel: tx.typeLabel,
      summary: tx.displaySummary,
      result: ExecutionResult.success(
        txHash: txHash,
        pathLabel: path.label,
        message: message,
      ),
    );
  }

  void _recordFailure({
    required TransactionRequest tx,
    required ExecutionPath path,
    required String message,
  }) {
    AuditLogService.instance.record(
      intentType: tx.sourceIntent.type,
      actionLabel: tx.typeLabel,
      summary: tx.displaySummary,
      result: ExecutionResult.failure(
        message: message,
        pathLabel: path.label,
      ),
    );
  }

  void _recordPolicyBlock(TransactionRequest tx, String reason) {
    AuditLogService.instance.recordPolicyBlock(
      intentType: tx.sourceIntent.type,
      actionLabel: tx.typeLabel,
      summary: tx.displaySummary,
      reason: reason,
    );
  }
}
