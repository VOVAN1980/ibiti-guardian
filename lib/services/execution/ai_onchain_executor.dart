import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web3dart/web3dart.dart';

import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/rpc_simulation_result.dart';
import 'package:ibiti_guardian/models/swap_execution_plan.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/screens/vault/components/privy_auth_modal.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_bus.dart';
import 'package:ibiti_guardian/services/execution/clients/tron_rpc_client.dart';
import 'package:ibiti_guardian/services/execution/guardian_execution_controller.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/services/policy/tx_usd_valuer.dart';
import 'package:ibiti_guardian/services/security/ai_action_gate.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

/// What happened to an on-chain operation the AI tried to run.
class AiExecResult {
  const AiExecResult({
    required this.executed,
    this.cancelled = false,
    required this.message,
    this.txHash,
    this.chainId,
    this.gateOutcome,
  });

  /// The transaction (for a swap: the swap step) was sent to the network.
  final bool executed;

  /// The user said no (card, PIN, sign-in) or withdrew the request.
  final bool cancelled;

  /// User-facing, localized.
  final String message;

  /// Hash of the last transaction sent (the swap step for a swap).
  final String? txHash;
  final int? chainId;

  /// The gate's verdict. [AiGateOutcome.execute] means the gate allowed the
  /// operation; [executed] then tells whether it went through.
  final AiGateOutcome? gateOutcome;

  /// Nothing ran because nobody could be asked right now (app in the
  /// background, no screen) or another AI operation holds the lock. Safe to
  /// try again later.
  bool get deferred =>
      !executed &&
      !cancelled &&
      (gateOutcome == AiGateOutcome.unavailable ||
          gateOutcome == AiGateOutcome.busy);

  /// The gate allowed it, but sending failed.
  bool get failed =>
      !executed && !cancelled && gateOutcome == AiGateOutcome.execute;

  /// Refused: limits, mandate, EPK, mode, wrong network, untrusted target.
  bool get blocked => !executed && !cancelled && !deferred && !failed;
}

enum _Session { ok, declined, unavailable }

/// Runs an on-chain operation the AI prepared (a send / approve / revoke
/// preview or a swap plan) in «Автономный» mode, always through
/// [AiActionGate]:
///
/// controller checks → gate (card + PIN, or no PIN within the D6 rules) →
/// Privy session → [GuardianExecutionController] (approve → own receipt
/// wait → swap) → [AiActionGate.reportExecuted].
///
/// The gate holds one global AI money-action lock from the card to the
/// result, so two AI operations never race for the same daily budget.
/// With no PIN the controller also re-checks, right before signing, that the
/// target is trusted and EPK is on (defense in depth, C4).
class AiOnchainExecutor {
  AiOnchainExecutor._();
  static final AiOnchainExecutor instance = AiOnchainExecutor._();

  static const _log = GuardianLogger('AiExecutor');

  static const Duration _receiptTimeout = Duration(seconds: 120);
  static const Duration _receiptInterval = Duration(seconds: 2);

  static const Set<String> _stablecoins = {
    'USDT', 'USDC', 'DAI', 'BUSD', 'FDUSD', 'TUSD', 'USDD', 'USDE', 'PYUSD',
  };

  // ── Test seams ────────────────────────────────────────────────────────────

  /// Replaces [GuardianExecutionController.orchestrateConfirmation].
  @visibleForTesting
  Future<AssistantResponse> Function(TransactionRequest tx, ExecutionPath path,
      {required bool requireTrustedTarget})? txRunnerOverride;

  /// Replaces [GuardianExecutionController.orchestrateSwapStep].
  @visibleForTesting
  Future<AssistantResponse> Function(
      TransactionRequest step, ExecutionPath path,
      {required bool requireTrustedTarget})? swapStepRunnerOverride;

  /// Replaces [waitForReceipt].
  @visibleForTesting
  Future<bool> Function(TransactionRequest tx, String? txHash)?
      receiptWaiterOverride;

  /// Replaces the Privy session check / sign-in dialog.
  @visibleForTesting
  Future<bool> Function()? privySessionOverride;

  /// Replaces [GuardianExecutionController.aiPreflight].
  @visibleForTesting
  AssistantResponse? Function(TransactionRequest tx)? preflightOverride;

  @visibleForTesting
  void resetForTest() {
    txRunnerOverride = null;
    swapStepRunnerOverride = null;
    receiptWaiterOverride = null;
    privySessionOverride = null;
    preflightOverride = null;
  }

  // ── Public API ────────────────────────────────────────────────────────────

  /// Executes [preview] (a [ResponseType.preview] with a pending transaction
  /// or a swap plan). Never runs outside «Автономный».
  ///
  /// [context]: the caller's screen, when it has one (chat). Voice, market
  /// chat and the delegate queue pass none; the gate then uses the root
  /// navigator. [stillWanted] is asked after the card: false withdraws the
  /// operation (the delegate queue's Cancel wins). [announce] shows the
  /// result as a snack bar; by default only for callers without a context.
  Future<AiExecResult> executePreview(
    AssistantResponse preview, {
    required String source,
    BuildContext? context,
    bool Function()? stillWanted,
    bool? announce,
  }) async {
    final result = await _execute(preview,
        source: source, context: context, stillWanted: stillWanted);
    _log.i('AI exec [$source]: executed=${result.executed} '
        'cancelled=${result.cancelled} gate=${result.gateOutcome?.name} '
        '${result.message}');
    if (announce ?? context == null) _announce(result);
    return result;
  }

  /// The gate card for [preview]: what, amount, target, network, fee.
  static AiActionSummary summaryFor(
    AssistantResponse preview, {
    required String source,
  }) {
    final plan = preview.swapPlan;
    if (plan != null) {
      return _summary(plan.swapStep,
          source: source, feeLabel: _swapFeeLabel(plan));
    }
    final tx = preview.pendingTransaction;
    if (tx != null) {
      return _summary(tx,
          source: source, feeLabel: _rpcFeeLabel(tx, preview.rpcSimulation));
    }
    return AiActionSummary(
      kind: AiActionKind.onChainSend,
      title: _t('aiActUnknownTitle', 'Unknown operation'),
      amountLabel: '?',
      valueUsd: null,
      source: source,
    );
  }

  /// The gate card for a single transaction (sandbox automation path).
  static AiActionSummary summaryForTx(
    TransactionRequest tx, {
    required String source,
  }) =>
      _summary(tx, source: source);

  /// Waits for [txHash] to be mined, with its own RPC loop (not the shared
  /// [TxStatusPoller], which any other transaction would cancel, C7).
  /// True only for a successful receipt. A Tron approval is confirmed by
  /// reading the allowance. Solana / Tron sends have no receipt API here:
  /// an accepted hash counts. [onTick] runs on every poll.
  Future<bool> waitForReceipt(
    TransactionRequest tx,
    String? txHash, {
    Duration timeout = _receiptTimeout,
    void Function()? onTick,
  }) async {
    final override = receiptWaiterOverride;
    if (override != null) return override(tx, txHash);

    if (tx.chainKey == 'tron' && tx.type == TransactionType.approve) {
      return _waitTronAllowance(tx, timeout, onTick);
    }
    if (txHash == null || txHash.isEmpty) return false;
    if (!tx.isEvmChain) return true;

    final rpcUrl = PrivyChainRegistry.getChain(tx.chainKey).rpcUrl;
    if (rpcUrl == null || rpcUrl.isEmpty) return false;
    final client = Web3Client(rpcUrl, http.Client());
    final deadline = DateTime.now().add(timeout);
    try {
      while (DateTime.now().isBefore(deadline)) {
        try {
          final receipt = await client.getTransactionReceipt(txHash);
          if (receipt != null) return receipt.status ?? false;
        } catch (e) {
          // Network hiccup: keep polling until the deadline.
          _log.w('receipt poll failed: $e');
        }
        onTick?.call();
        await Future<void>.delayed(_receiptInterval);
      }
      _log.w('no receipt for $txHash after ${timeout.inSeconds}s');
      return false;
    } finally {
      try {
        await client.dispose();
      } catch (_) {}
    }
  }

  // ── Flow ──────────────────────────────────────────────────────────────────

  Future<AiExecResult> _execute(
    AssistantResponse preview, {
    required String source,
    BuildContext? context,
    bool Function()? stillWanted,
  }) async {
    final plan = preview.swapPlan;
    final tx = plan?.swapStep ?? preview.pendingTransaction;
    final path = preview.executionPath;
    if (preview.type != ResponseType.preview || tx == null || path == null) {
      return _refused(
          _t('aiExecNothing', 'There is nothing to execute in this answer.'));
    }
    if (AiControlService.instance.settings.mode != AiMode.fullAutonomy) {
      return _refused(_t('aiExecOnlyFull',
          'Only the «Autonomous» mode lets the AI carry out operations.'));
    }

    final steps = <TransactionRequest>[
      if (plan?.approveStep != null) plan!.approveStep!,
      tx,
    ];

    // C8: a plan built for another network must never be signed here.
    final activeChain = IBITIVaultService.instance.chainKey;
    for (final step in steps) {
      if (step.chainKey != activeChain) {
        final prepared = step.networkLabel;
        final active = PrivyChainRegistry.getChain(activeChain).displayName;
        return _refused(_t(
          'aiExecWrongNetwork',
          'The AI prepared this on $prepared, but the wallet is on $active '
              'now. Switch the network and ask again.',
          {'prepared': prepared, 'active': active},
        ));
      }
    }

    // C11: the AI runs this itself; a window auto-action left pending for
    // it must not fire later in a window the user opens.
    _dropPendingWindowActions(swap: plan != null);

    // The controller's own AI checks first, so no card is shown for an
    // operation it would refuse anyway.
    for (final step in steps) {
      final stop = (preflightOverride ??
          GuardianExecutionController.instance.aiPreflight)(step);
      if (stop != null) return _refused(_withLimitHint(stop.message, step));
    }

    final summary = summaryFor(preview, source: source);
    final gate = AiActionGate.instance;
    final AiGateDecision decision;
    try {
      decision = await gate.confirm(summary, context: context);
    } catch (e, st) {
      _log.e('gate confirm threw: $e\n$st');
      return AiExecResult(
        executed: false,
        message: _unavailableMessage(),
        gateOutcome: AiGateOutcome.unavailable,
      );
    }

    if (!decision.mayExecute) return _fromGate(decision);

    // From here the gate holds the lock: every exit reports or releases.
    if (!decision.matches(summary)) {
      gate.release(decision);
      return _refused(_t('aiExecNotBound',
          'The confirmation does not match this operation. Nothing was sent.'));
    }
    if (stillWanted != null && !stillWanted()) {
      gate.release(decision);
      return _cancelled();
    }

    final session = await _ensureSession(context);
    if (session != _Session.ok) {
      gate.release(decision);
      final message = _t('aiExecSessionExpired',
          'Sign in again so the AI can sign this operation. Nothing was sent.');
      return session == _Session.declined
          ? AiExecResult(
              executed: false,
              cancelled: true,
              message: message,
              gateOutcome: AiGateOutcome.cancelled,
            )
          : AiExecResult(
              executed: false,
              message: message,
              gateOutcome: AiGateOutcome.unavailable,
            );
    }

    AiExecResult outcome;
    try {
      outcome = plan != null
          ? await _runSwap(plan, path, decision, summary)
          : await _runTx(tx, path, decision, summary);
    } catch (e, st) {
      _log.e('AI exec threw: $e\n$st');
      outcome = _failed(summary, '$e');
    }

    try {
      await gate.reportExecuted(
        summary,
        decision,
        success: outcome.executed,
        detail: _reportDetail(outcome, summary),
        historyId: outcome.txHash,
      );
    } catch (e) {
      _log.w('reportExecuted failed: $e');
      gate.release(decision);
    }
    return outcome;
  }

  Future<AiExecResult> _runTx(
    TransactionRequest tx,
    ExecutionPath path,
    AiGateDecision decision,
    AiActionSummary summary,
  ) async {
    final runner = txRunnerOverride ??
        GuardianExecutionController.instance.orchestrateConfirmation;
    final r = await runner(tx, path, requireTrustedTarget: decision.withoutPin);
    if (r.type == ResponseType.error) return _failed(summary, r.message);
    return _sent(summary, r.detail, tx.chainId);
  }

  /// Approve (when needed) → wait for its receipt → swap, under the one
  /// confirmation the gate already gave.
  Future<AiExecResult> _runSwap(
    SwapExecutionPlan plan,
    ExecutionPath path,
    AiGateDecision decision,
    AiActionSummary summary,
  ) async {
    final runner = swapStepRunnerOverride ??
        GuardianExecutionController.instance.orchestrateSwapStep;
    final approve = plan.approveStep;
    if (approve != null) {
      final a = await runner(approve, path,
          requireTrustedTarget: decision.withoutPin);
      if (a.type == ResponseType.error) return _failed(summary, a.message);
      final mined = await waitForReceipt(approve, a.detail);
      if (!mined) {
        return _failed(
          summary,
          _t('aiExecApproveNotConfirmed',
              'The token approval was not confirmed in time, so the swap was not sent.'),
        );
      }
    }
    final s = await runner(plan.swapStep, path,
        requireTrustedTarget: decision.withoutPin);
    if (s.type == ResponseType.error) return _failed(summary, s.message);
    return _sent(summary, s.detail, plan.swapStep.chainId);
  }

  Future<_Session> _ensureSession(BuildContext? context) async {
    final override = privySessionOverride;
    if (override != null) {
      return await override() ? _Session.ok : _Session.declined;
    }
    try {
      if (await IBITIVaultService.instance.hasPrivySession()) {
        return _Session.ok;
      }
    } catch (e) {
      _log.w('privy session check failed: $e');
    }
    // C17: the sign-in dialog needs a live screen in the foreground.
    final ctx = AiActionGate.instance.resolveContext(context);
    final state = WidgetsBinding.instance.lifecycleState;
    if (ctx == null ||
        !ctx.mounted ||
        (state != null && state != AppLifecycleState.resumed)) {
      return _Session.unavailable;
    }
    return await ensurePrivySession(ctx) ? _Session.ok : _Session.declined;
  }

  Future<bool> _waitTronAllowance(
    TransactionRequest tx,
    Duration timeout,
    void Function()? onTick,
  ) async {
    final spender = tx.spenderAddress;
    final token = tx.tokenContract;
    final needed = tx.rawAmount;
    if (spender == null || token == null || needed == null) return false;
    final client = TronHttpRpcClient(
      baseUrl: PrivyChainRegistry.getChain('tron').rpcUrl ??
          'https://api.trongrid.io',
    );
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final allowance = await client.getAllowance(
          ownerAddress: tx.fromAddress,
          spenderAddress: spender,
          tokenContract: token,
        );
        if (allowance >= needed) return true;
      } catch (e) {
        _log.w('tron allowance poll failed: $e');
      }
      onTick?.call();
      await Future<void>.delayed(_receiptInterval);
    }
    return false;
  }

  void _dropPendingWindowActions({required bool swap}) {
    final bus = UICommandBus.instance;
    final targets = swap
        ? const ['wallet_swap_quote', 'swap_quote', 'swap_preview']
        : const ['wallet_send_preview', 'send_preview'];
    for (final target in targets) {
      bus.consumePendingAction(target);
    }
  }

  void _announce(AiExecResult result) {
    if (result.cancelled || result.deferred) return;
    try {
      final ctx = AiActionGate.instance.resolveContext();
      if (ctx == null || !ctx.mounted) return;
      ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
        SnackBar(
          content: Text(result.message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      _log.w('result snack bar failed: $e');
    }
  }

  // ── Results ───────────────────────────────────────────────────────────────

  AiExecResult _fromGate(AiGateDecision d) {
    switch (d.outcome) {
      case AiGateOutcome.cancelled:
        return _cancelled(d.reason);
      case AiGateOutcome.unavailable:
        return AiExecResult(
          executed: false,
          message: d.reason ?? _unavailableMessage(),
          gateOutcome: AiGateOutcome.unavailable,
        );
      case AiGateOutcome.busy:
        return AiExecResult(
          executed: false,
          message: d.reason ??
              _t('aiExecBusy',
                  'Another AI operation is waiting for confirmation. Finish it first.'),
          gateOutcome: AiGateOutcome.busy,
        );
      case AiGateOutcome.adviseOnly:
      case AiGateOutcome.prepareOnly:
        return AiExecResult(
          executed: false,
          message: d.reason ??
              _t('aiExecOnlyFull',
                  'Only the «Autonomous» mode lets the AI carry out operations.'),
          gateOutcome: d.outcome,
        );
      case AiGateOutcome.blocked:
      case AiGateOutcome.execute:
        return AiExecResult(
          executed: false,
          message: d.reason ??
              _t('aiExecBlocked', 'The AI may not do this operation.'),
          gateOutcome: AiGateOutcome.blocked,
        );
    }
  }

  static AiExecResult _refused(String message) => AiExecResult(
        executed: false,
        message: message,
        gateOutcome: AiGateOutcome.blocked,
      );

  static AiExecResult _cancelled([String? reason]) => AiExecResult(
        executed: false,
        cancelled: true,
        message: reason ?? _t('aiExecCancelled', 'Cancelled. Nothing was sent.'),
        gateOutcome: AiGateOutcome.cancelled,
      );

  static AiExecResult _failed(AiActionSummary s, String reason) =>
      AiExecResult(
        executed: false,
        message: _t('aiExecFailed', 'Not done: ${s.title}. $reason',
            {'what': s.title, 'reason': reason}),
        gateOutcome: AiGateOutcome.execute,
      );

  static AiExecResult _sent(AiActionSummary s, String? hash, int chainId) =>
      AiExecResult(
        executed: true,
        message: _t('aiExecSent', 'Done: ${s.title}. Transaction sent.',
            {'what': s.title}),
        txHash: hash,
        chainId: chainId,
        gateOutcome: AiGateOutcome.execute,
      );

  static String _unavailableMessage() => _t('aiExecUnavailable',
      'The AI could not ask for your confirmation right now. Open the app and try again. Nothing was sent.');

  /// The gate's notification already shows the amount and the network:
  /// the detail adds the transaction (sent on submit, C19) or the failure.
  static String _reportDetail(AiExecResult r, AiActionSummary s) {
    if (!r.executed) return r.message;
    final hash = r.txHash;
    if (hash == null || hash.isEmpty) return '';
    return _t('aiExecSentTx', 'sent, tx ${_short(hash)}',
        {'tx': _short(hash)});
  }

  /// Over-limit refusals carry the way out: raising the threshold needs the
  /// PIN in Policy (D6). Never a bypass.
  static String _withLimitHint(String message, TransactionRequest tx) {
    if (tx.type == TransactionType.approve ||
        tx.type == TransactionType.revoke) {
      return message;
    }
    final usd = TxUsdValuer.limitAmount(tx);
    final cap = AiControlService.instance.settings.mandate.maxPositionUsd;
    final overLimit =
        usd > 0 && (usd > cap || !DelegationController.instance.canSpend(usd));
    if (!overLimit) return message;
    final hint = _t('aiExecLimitHint',
        'Want more? Raise the threshold in «Policy» (PIN needed).');
    return '$message $hint';
  }

  // ── Summary building ──────────────────────────────────────────────────────

  static AiActionSummary _summary(
    TransactionRequest tx, {
    required String source,
    String? feeLabel,
  }) {
    final kind = _kindFor(tx, source);
    final token = tx.tokenSymbol ?? '';
    final isRevoke = kind == AiActionKind.revoke;
    return AiActionSummary(
      kind: kind,
      title: _titleFor(kind, tx),
      amountLabel: isRevoke
          ? (token.isEmpty ? '—' : token)
          : '${_fmtAmount(tx.amount)} $token'.trim(),
      // Revoke only lowers an allowance: no value, no limits (D11).
      valueUsd: isRevoke ? 0.0 : TxUsdValuer.usdValue(tx),
      isBuy: kind != AiActionKind.onChainSell,
      feeLabel: feeLabel,
      toAddress: _targetOf(tx),
      network: tx.chainKey,
      venue: tx.routerAddress ?? tx.spenderAddress,
      assetSymbol: tx.tokenSymbol,
      targetSymbol: tx.targetTokenSymbol,
      source: source,
    );
  }

  static AiActionKind _kindFor(TransactionRequest tx, String source) {
    switch (tx.type) {
      case TransactionType.send:
      case TransactionType.unknown:
        return AiActionKind.onChainSend;
      case TransactionType.approve:
        return AiActionKind.approve;
      case TransactionType.revoke:
        return AiActionKind.revoke;
      case TransactionType.swap:
        if (source == 'delegate') return AiActionKind.delegatedTrade;
        final fromStable = _isStable(tx.tokenSymbol);
        final toStable = _isStable(tx.targetTokenSymbol);
        if (fromStable && !toStable) return AiActionKind.onChainBuy;
        if (!fromStable && toStable) return AiActionKind.onChainSell;
        return AiActionKind.onChainSwap;
    }
  }

  /// sends: the recipient; approve / revoke: the spender; swaps: the router.
  static String _targetOf(TransactionRequest tx) {
    switch (tx.type) {
      case TransactionType.approve:
      case TransactionType.revoke:
        return tx.spenderAddress ?? tx.toAddress;
      case TransactionType.swap:
        return tx.routerAddress ?? tx.toAddress;
      case TransactionType.send:
      case TransactionType.unknown:
        return tx.toAddress;
    }
  }

  static String _titleFor(AiActionKind kind, TransactionRequest tx) {
    final amount = _fmtAmount(tx.amount);
    final token = tx.tokenSymbol ?? '';
    final from = token;
    final to = tx.targetTokenSymbol ?? '';
    switch (kind) {
      case AiActionKind.onChainSend:
        return _t('aiActSendTitle', 'Send $amount $token',
            {'amount': amount, 'token': token});
      case AiActionKind.approve:
        return _t('aiActApproveTitle', 'Allow $token spending',
            {'token': token});
      case AiActionKind.revoke:
        return _t('aiActRevokeTitle', 'Revoke $token approval',
            {'token': token});
      case AiActionKind.onChainBuy:
        return _t('aiActBuyTitle', 'Buy $to for $from',
            {'from': from, 'to': to});
      case AiActionKind.onChainSell:
        return _t('aiActSellTitle', 'Sell $from for $to',
            {'from': from, 'to': to});
      case AiActionKind.delegatedTrade:
        return _t('aiActDelegatedTitle', 'Buy $to (delegated to AI)',
            {'to': to});
      case AiActionKind.onChainSwap:
      case AiActionKind.cexOrder:
        return _t('aiActSwapTitle', 'Swap $from → $to',
            {'from': from, 'to': to});
    }
  }

  static String? _swapFeeLabel(SwapExecutionPlan plan) {
    final step = plan.swapStep;
    if (!step.isEvmChain) return null;
    final gasPrice = BigInt.tryParse(
        plan.quote.extraSummary['gasPriceWei']?.toString() ?? '');
    if (gasPrice == null) return null;
    // quote.gasEstimate is in gas units.
    return _nativeFee(step.chainKey, plan.quote.gasEstimate * gasPrice);
  }

  static String? _rpcFeeLabel(TransactionRequest tx, RpcSimulationResult? rpc) {
    if (!tx.isEvmChain || rpc == null) return null;
    final gas = _parseQuantity(rpc.estimatedGas);
    final price = _parseQuantity(rpc.gasPrice);
    if (gas == null || price == null) return null;
    return _nativeFee(tx.chainKey, gas * price);
  }

  static String _nativeFee(String chainKey, BigInt wei) {
    final symbol = PrivyChainRegistry.getChain(chainKey).nativeSymbol ?? '';
    final fee = wei.toDouble() / 1e18;
    return _t('aiActNetworkFee', 'Network fee ≈ ${_fmtAmount(fee)} $symbol',
            {'fee': '${_fmtAmount(fee)} $symbol'})
        .trim();
  }

  static BigInt? _parseQuantity(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    if (raw.startsWith('0x')) return BigInt.tryParse(raw.substring(2), radix: 16);
    return BigInt.tryParse(raw);
  }

  static bool _isStable(String? symbol) =>
      symbol != null && _stablecoins.contains(symbol.trim().toUpperCase());

  static String _fmtAmount(double? v) {
    if (v == null) return '?';
    if (v == 0) return '0';
    final digits = v.abs() >= 1 ? 4 : 8;
    var s = v.toStringAsFixed(digits);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '');
      if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static String _short(String hash) => hash.length <= 14
      ? hash
      : '${hash.substring(0, 8)}…${hash.substring(hash.length - 4)}';

  static String _t(String key, String fallback,
      [Map<String, dynamic> args = const {}]) {
    return LocalizationService.instance
        .t(key, {...args, 'default': fallback});
  }
}
