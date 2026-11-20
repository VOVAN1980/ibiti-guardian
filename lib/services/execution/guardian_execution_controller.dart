import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/sandbox_decision.dart';
import 'package:ibiti_guardian/models/simulation_result.dart';
import 'package:ibiti_guardian/models/swap_execution_plan.dart';
import 'package:ibiti_guardian/models/rpc_simulation_result.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';
import 'package:ibiti_guardian/services/adapters/wallet_orchestrator.dart';
import 'package:ibiti_guardian/services/policy/guardian_policy_engine.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/services/policy/epk_capability_resolver.dart';
import 'package:ibiti_guardian/services/policy/sandbox_guard.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/services/execution/transaction_builder.dart';
import 'package:ibiti_guardian/services/execution/transaction_simulator.dart';
import 'package:ibiti_guardian/services/execution/rpc_transaction_simulator.dart';
import 'package:ibiti_guardian/services/execution/transaction_explainer.dart';
import 'package:ibiti_guardian/services/execution/guardian_execution_service.dart';
import 'package:ibiti_guardian/services/swap/swap_intent_builder.dart';
import 'package:ibiti_guardian/services/swap/swap_provider.dart';
import 'package:ibiti_guardian/services/swap/zerox_swap_provider.dart';
import 'package:ibiti_guardian/services/swap/jupiter_swap_provider.dart';
import 'package:ibiti_guardian/services/swap/sunswap_provider.dart';
import 'package:ibiti_guardian/services/audit_log_service.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/services/execution/ai_onchain_executor.dart';
import 'package:ibiti_guardian/services/security/ai_action_gate.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/policy/tx_usd_valuer.dart';
import 'package:ibiti_guardian/utils/token_symbol_normalizer.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/execution/native_transaction_builder.dart';
import 'package:ibiti_guardian/services/execution/clients/solana_rpc_client.dart';
import 'package:ibiti_guardian/services/execution/clients/tron_rpc_client.dart';
import 'package:ibiti_guardian/utils/address_key.dart';

/// The central "Brain" of the Guardian stack (Phase 6 Orchestration Layer).
///
/// Flow:
/// Intents -> Build -> Static Sim -> RPC Sim -> Path -> Policy
/// IF USER -> Explain -> UI Preview
/// IF AGENT -> SandboxGuard -> [Execute | Demote to Preview | Block]
class GuardianExecutionController {
  GuardianExecutionController._();
  static final instance = GuardianExecutionController._();

  final _wallet = WalletAdapter.instance;
  final _executor = GuardianExecutionService.instance;
  RpcSimulator _rpcSim = RpcTransactionSimulator.instance;
  final _profileStore = PolicyProfileStore.instance;

  void overrideRpcSimulator(RpcSimulator simulator) => _rpcSim = simulator;
  final _capabilityResolver = EpkCapabilityResolver.instance;
  final _sandbox = SandboxGuard.instance;
  final _orchestrator = WalletOrchestrator.instance;
  final _delegation = DelegationController.instance;
  static const Duration _swapQuoteTtl = Duration(minutes: 5);
  static const _log = GuardianLogger('ExecController');

  /// A confirmation that stops before the transaction is dispatched used to
  /// leave no trace: nothing in the journal, nothing in the log. Every such
  /// stop is now written to both.
  ///
  /// [detail] keeps the refusal's code (e.g. [dailyLimitCode]) so the caller
  /// can still tell what it was ([isRaisableRefusal]).
  AssistantResponse _stopBeforeDispatch(
      TransactionRequest tx, String stage, String message,
      {String? detail}) {
    _log.w('confirm stopped [$stage]: $message');
    AuditLogService.instance.recordPolicyBlock(
      intentType: tx.sourceIntent.type,
      actionLabel: tx.typeLabel,
      summary: tx.displaySummary,
      reason: message,
    );
    return AssistantResponse.error(message,
        detail: detail, intent: tx.sourceIntent);
  }

  // ── P0 Safety: Double-execution guard ──────────────────────────────────────
  // Prevents double-tap on Confirm from dispatching the same tx twice.
  // Key = "${tx.type}_${tx.toAddress}_${tx.amount}_${tx.tokenSymbol}".
  final Set<String> _inFlightKeys = {};

  String _executionKey(TransactionRequest tx) =>
      '${tx.type.name}_${tx.toAddress}_${tx.amount}_${tx.tokenSymbol}_${tx.routerAddress ?? ''}';

  // Phase 8: Injected via interface — never reference a concrete provider directly here.
  // Default: 0x AllowanceHolder for EVM chains.
  SwapProvider _evmSwapProvider = ZeroXSwapProvider.instance;

  // Phase U3: Jupiter V2 for Solana swaps.
  SwapProvider _solanaSwapProvider = JupiterSwapProvider.instance;

  // Phase U5: SunSwap V2 for Tron swaps.
  SwapProvider _tronSwapProvider = SunSwapProvider.instance;

  /// Allows test harnesses (or future admin settings) to swap the EVM provider.
  // ignore: use_setters_to_change_properties
  void overrideSwapProvider(SwapProvider provider) =>
      _evmSwapProvider = provider;

  /// Chain-aware swap provider selection.
  ///
  /// Solana → Jupiter V2, Tron → SunSwap V2, EVM → 0x.
  SwapProvider _swapProviderForChain(String chainKey) {
    switch (chainKey) {
      case 'solana':
        return _solanaSwapProvider;
      case 'tron':
        return _tronSwapProvider;
      default:
        return _evmSwapProvider;
    }
  }

  // ─── Phase 6 Orchestration Pipeline ─────────────────────────────────────────

  /// A complete send the builder still refused: the token does not exist on
  /// the active network (e.g. SOL while on BSC). Explain instead of a bare
  /// "could not build".
  AssistantResponse? _unknownSendTokenResponse(IntentData intent) {
    final symbol = intent.tokenSymbol?.trim();
    if (intent.type != IntentType.sendAsset ||
        symbol == null ||
        symbol.isEmpty ||
        (intent.amount ?? 0) <= 0 ||
        (intent.toAddress ?? '').isEmpty) {
      return null;
    }
    final network = PrivyChainRegistry.getChain(_wallet.chainKey).displayName;
    if (!TransactionBuilder.isValidRecipient(
        intent.toAddress!.trim(), _wallet.chainKey)) {
      final message =
          LocalizationService.instance.t('assistantSendInvalidRecipient', {
        'network': network,
        'default':
            'The recipient address is not a valid $network address. Check it and try again.',
      });
      return AssistantResponse.info(message,
          speechText: message, intent: intent);
    }
    final token = TokenSymbolNormalizer.normalize(symbol);
    final message = LocalizationService.instance.t('assistantSendTokenNotOnNetwork', {
      'token': token,
      'network': network,
      'default':
          '$token is not available on $network. Switch the network or pick the token in the send window.',
    });
    return AssistantResponse.info(message, speechText: message, intent: intent);
  }

  Future<AssistantResponse> orchestrate(IntentAction action) async {
    final intent = action.intent;
    final aiIntentGate = _checkAiIntentControl(intent);
    if (aiIntentGate != null) {
      return aiIntentGate;
    }

    // 0. Informational bypass
    if (!action.requiresExecution) {
      return await _executor.handleInformational(intent);
    }
    if (!_wallet.isConnected) {
      return AssistantResponse.error('No wallet connected.', intent: intent);
    }
    if (intent.type == IntentType.scanApprovals) {
      return await _executor.executeScan(intent);
    }

    // ── SWAP: separate quote-first path ────────────────────────────────────
    if (intent.type == IntentType.swapAsset) {
      return await _orchestrateSwap(intent);
    }

    // 1. Build Payload
    final tx = TransactionBuilder.build(intent);
    if (tx == null) {
      final unknownToken = _unknownSendTokenResponse(intent);
      if (unknownToken != null) return unknownToken;
      return AssistantResponse.error('Could not build this transaction.',
          intent: intent);
    }
    // A preview never measures the AI limits in token units: without a
    // price the AI's own run is refused in [aiPreflight], and an operation
    // the user confirms is checked again when it is confirmed.
    final aiTxGate = _checkAiTransactionControl(
      tx,
      TransactionSimulator.analyze(tx),
      quantityFallback: false,
    );
    if (aiTxGate != null) {
      return aiTxGate;
    }

    final preview = await previewTransaction(tx);
    if (preview.type == ResponseType.error) {
      return preview;
    }

    final staticSim = TransactionSimulator.analyze(tx);
    final rpcSim = preview.rpcSimulation!;
    final profile = await _profileStore.load();
    final path = preview.executionPath!;
    final policy = preview.policy!;
    final walletContext = await _orchestrator.getGlobalContext();

    // 5. Check if it's an AI Automation Trigger or a User Input
    if (intent.isAutomated) {
      // 🚨 AUTOMATION PATH
      final decision = _sandbox.evaluate(
        tx: tx,
        staticSim: staticSim,
        rpcSim: rpcSim,
        profile: profile,
        walletContext: walletContext,
        path: path,
        policy: policy,
      );

      // Agent attempted the action but it needs the user's eyes: demote back
      // to the standard user preview (no block, just UI confirmation).
      AssistantResponse demoteToPreview() => AssistantResponse.preview(
            transaction: tx,
            explanation: TransactionExplainer.explainV3(
                tx, staticSim, rpcSim, policy, profile, path),
            policy: policy,
            rpcSimulation: rpcSim,
            executionPath: path,
          );

      switch (decision.verdict) {
        case SandboxVerdict.approvedForAuto:
          return _runApprovedAutomation(
            tx: tx,
            path: path,
            intent: intent,
            sandboxReason: decision.reason,
            demote: demoteToPreview,
          );

        case SandboxVerdict.requireManualReview:
          return demoteToPreview();

        case SandboxVerdict.blocked:
          // Hard block. Do not even show preview.
          return AssistantResponse.error(
            '🤖 Automated task blocked by Sandbox constraints: ${decision.reason}',
            intent: intent,
          );
      }
    } else {
      // 🙋 USER PATH (Default Phase 5 logic)
      if (policy.blocked) {
        AuditLogService.instance.recordPolicyBlock(
          intentType: intent.type,
          actionLabel: tx.typeLabel,
          summary: tx.displaySummary,
          reason: policy.reason ??
              'Transaction blocked by advanced Guardian enforcement.',
        );
        return AssistantResponse.error(
          policy.reason ??
              'Transaction blocked by advanced Guardian enforcement.',
          detail: policyRefusalCode(policy, tx),
          intent: intent,
        );
      }

      final explanation = TransactionExplainer.explainV3(
        tx,
        staticSim,
        rpcSim,
        policy,
        profile,
        path,
      );

      return AssistantResponse.preview(
        transaction: tx,
        explanation: explanation,
        policy: policy,
        rpcSimulation: rpcSim,
        executionPath: path,
      );
    }
  }

  /// Test seam: replaces the dispatch of a sandbox-approved automation.
  @visibleForTesting
  Future<AssistantResponse> Function(TransactionRequest tx, ExecutionPath path)?
      automationDispatchOverride;

  /// A sandbox-approved automated (non-swap) transaction. The AI action gate
  /// comes FIRST (C2), then the budget reservation, the dispatch and
  /// [AiActionGate.reportExecuted]. When the gate does not allow it (card
  /// declined, nobody to ask, another AI action pending) the user reviews
  /// the [demote]d preview instead.
  Future<AssistantResponse> _runApprovedAutomation({
    required TransactionRequest tx,
    required ExecutionPath path,
    required IntentData intent,
    required String sandboxReason,
    required AssistantResponse Function() demote,
  }) async {
    // The AI never acts on an unknown USD value: the daily limit and the
    // position cap are dollars, and a token quantity is not (D7). The user
    // reviews it instead (D17): no card, no lock, nothing reserved.
    if (aiValueUnknown(tx)) {
      _log.w('automation demoted: no USD value for ${tx.displaySummary}');
      return demote();
    }

    // The AI action gate comes FIRST (C2): a card left open must not
    // hold a budget reservation, whose TTL would silently free it.
    // The gate holds the one AI money-action lock until reportExecuted.
    final summary =
        AiOnchainExecutor.summaryForTx(tx, source: 'automation');
    final gate = AiActionGate.instance;
    final aiDecision = await gate.confirm(summary);
    if (!aiDecision.mayExecute) {
      if (aiDecision.outcome == AiGateOutcome.blocked) {
        return AssistantResponse.error(
          aiDecision.reason ?? 'Automated task blocked by AI Control.',
          intent: intent,
        );
      }
      // Cancelled, nobody to ask, another AI action pending, or the
      // mode only prepares: the user reviews it instead.
      return demote();
    }
    if (!aiDecision.matches(summary)) {
      gate.release(aiDecision);
      return AssistantResponse.error(
        'The AI confirmation does not match this transaction.',
        intent: intent,
      );
    }
    if (aiDecision.withoutPin) {
      final noPinBlock = _aiNoPinBlock(tx);
      if (noPinBlock != null) {
        gate.release(aiDecision);
        return AssistantResponse.error(noPinBlock, intent: intent);
      }
    }
    // Signing can take a while: the one AI money-action lock stays with
    // this decision until the result is reported (D13). A decision that is
    // no longer live (timed out, released) sends nothing.
    if (!gate.keepAlive(aiDecision)) {
      gate.release(aiDecision);
      return AssistantResponse.error(
        LocalizationService.instance.t('aiExecNotBound', {
          'default':
              'The confirmation does not match this operation. Nothing was sent.',
        }),
        intent: intent,
      );
    }

    // Reserve daily budget BEFORE execution (atomic lock), in dollars
    // like every other daily-limit check (a token quantity is not $; an
    // unknown value never gets here).
    final reservationKey = _delegation.generateReservationKey(tx);
    final txAmount = TxUsdValuer.usdValue(tx) ?? 0.0;
    if (txAmount > 0) {
      final reserved = _delegation.reserveSpend(reservationKey, txAmount);
      if (reserved == null) {
        gate.release(aiDecision);
        return AssistantResponse.error(
          _dailyLimitMessage(txAmount),
          detail: dailyLimitCode,
          intent: intent,
        );
      }
    }

    // Dispatch the transaction.
    AssistantResponse executionResult;
    try {
      executionResult = await (automationDispatchOverride ??
          _executor.dispatchConfiguredPath)(tx, path);
    } catch (e) {
      executionResult =
          AssistantResponse.error('Send failed: $e', intent: intent);
    }
    final dispatched = executionResult.type != ResponseType.error;

    // If dispatch itself failed (no hash returned), rollback.
    if (!dispatched) {
      _delegation.rollbackReservation(reservationKey);
    } else if (txAmount > 0) {
      // Commit on a confirmed receipt, rollback on failure/timeout.
      _wireReservationToReceipt(
          reservationKey, executionResult.detail, tx);
    }

    try {
      await gate.reportExecuted(
        summary,
        aiDecision,
        success: dispatched,
        detail: dispatched
            ? (executionResult.detail ?? '')
            : executionResult.message,
        historyId: dispatched ? executionResult.detail : null,
      );
    } catch (e) {
      _log.w('reportExecuted failed: $e');
      gate.release(aiDecision);
    }

    if (!dispatched) return executionResult;
    return AssistantResponse(
      message:
          '🤖 Automated Action Succeeded:\n${executionResult.message}\n(Sandbox: $sandboxReason)',
      type: ResponseType.action,
      sourceIntent: intent,
      executionPath: path,
    );
  }

  @visibleForTesting
  Future<AssistantResponse> runApprovedAutomationForTest(
    TransactionRequest tx,
    ExecutionPath path, {
    required AssistantResponse Function() demote,
  }) =>
      _runApprovedAutomation(
        tx: tx,
        path: path,
        intent: tx.sourceIntent,
        sandboxReason: 'test',
        demote: demote,
      );

  Future<AssistantResponse> previewTransaction(TransactionRequest tx) async {
    final staticSim = TransactionSimulator.analyze(tx);
    final rpcSim = await _rpcSim.simulate(tx);
    final profile = await _profileStore.load();
    final requestedPath = await _resolveRequestedPath(tx);
    final path = _executor.normalizeExecutionPath(tx, requestedPath);
    final policy =
        GuardianPolicyEngine.checkV3(tx, staticSim, rpcSim, profile, path);

    if (_requiresSimulationGate(tx, staticSim, policy) &&
        (!rpcSim.success || rpcSim.estimatedGas == null)) {
      return _stopBeforeDispatch(
        tx,
        'simulation',
        'This action requires a successful simulation before it can be '
            'confirmed.${rpcSim.revertReason != null ? ' ${rpcSim.revertReason}' : ''}',
      );
    }

    if (policy.blocked) {
      _log.w('preview blocked by policy: ${policy.reason} '
          'rules=${policy.appliedRules.join(',')}');
      AuditLogService.instance.recordPolicyBlock(
        intentType: tx.sourceIntent.type,
        actionLabel: tx.typeLabel,
        summary: tx.displaySummary,
        reason: policy.reason ?? 'Transaction blocked by Guardian policy.',
      );
      return AssistantResponse.error(
        policy.reason ?? 'Transaction blocked by Guardian policy.',
        detail: policyRefusalCode(policy, tx),
        intent: tx.sourceIntent,
      );
    }

    final explanation = TransactionExplainer.explainV3(
      tx,
      staticSim,
      rpcSim,
      policy,
      profile,
      path,
    );

    return AssistantResponse.preview(
      transaction: tx,
      explanation: explanation,
      policy: policy,
      rpcSimulation: rpcSim,
      executionPath: path,
    );
  }

  bool _requiresSimulationGate(
    TransactionRequest tx,
    SimulationResult staticSim,
    PolicyResult policy,
  ) {
    if (!tx.isEvmChain) return false;
    if (tx.type == TransactionType.revoke) return false;
    if (tx.isUnlimitedApproval) return true;
    if (staticSim.risk == SimulationRisk.warning ||
        staticSim.risk == SimulationRisk.critical) {
      return true;
    }
    return policy.severity == PolicySeverity.warning ||
        policy.severity == PolicySeverity.danger;
  }

  /// Execution trigger called ONLY after the UI manual confirmation screen,
  /// or by [AiOnchainExecutor] after [AiActionGate] allowed it.
  ///
  /// [requireTrustedTarget]: the AI runs this with no PIN. Right before
  /// signing, the target must then be trusted (or the user's own address /
  /// an official swap router), EPK must be on, the network unchanged and the
  /// USD value known — whatever the policy profile (D6, C4).
  Future<AssistantResponse> orchestrateConfirmation(
      TransactionRequest tx, ExecutionPath path,
      {bool requireTrustedTarget = false}) async {
    // ── P0 Safety: Double-execution guard ──────────────────────────────────
    final key = _executionKey(tx);
    if (!_inFlightKeys.add(key)) {
      return _stopBeforeDispatch(tx, 'in_flight',
          'This transaction is already being processed. Please wait.');
    }

    try {
      _log.i('confirm start: ${tx.typeLabel} ${tx.displaySummary} '
          'chain=${tx.chainKey} path=${path.name}');
      if (!_wallet.isConnected) {
        return _stopBeforeDispatch(
            tx, 'wallet', 'Wallet disconnected mid-execution.');
      }

      // ── P0 Safety: Daily limit pre-check ──────────────────────────────────
      final dailyBlock = _checkDailyLimit(tx);
      if (dailyBlock != null) {
        return _stopBeforeDispatch(tx, 'daily_limit', dailyBlock.message,
            detail: dailyBlock.detail);
      }

      // Re-run preview immediately before execution to prevent stale confirms:
      // policy/network/path may have changed while the user was reading preview.
      final revalidated = await previewTransaction(tx);
      if (revalidated.type == ResponseType.error) {
        // previewTransaction journals its policy blocks itself; log the rest.
        _log.w('confirm stopped [revalidate]: ${revalidated.message}');
        return revalidated;
      }
      final aiGate = _checkAiTransactionControl(
        tx,
        TransactionSimulator.analyze(tx),
      );
      if (aiGate != null) {
        return _stopBeforeDispatch(tx, 'ai_gate', aiGate.message,
            detail: aiGate.detail);
      }

      final expectedPath = _executor.normalizeExecutionPath(tx, path);
      final resolvedPath = revalidated.executionPath ?? expectedPath;
      if (resolvedPath != expectedPath) {
        return _stopBeforeDispatch(
          tx,
          'route',
          'Execution route changed after preview '
              '(${expectedPath.name} -> ${resolvedPath.name}). '
              'Please review and confirm again.',
        );
      }

      if (requireTrustedTarget) {
        final noPinBlock = _aiNoPinBlock(tx);
        if (noPinBlock != null) {
          return _stopBeforeDispatch(tx, 'ai_no_pin', noPinBlock);
        }
      }

      final result = await _executor.dispatchConfiguredPath(tx, resolvedPath);
      _log.i('confirm result: ${result.type.name} ${result.message}');
      _commitDailyUsage(tx, result);
      return result;
    } catch (e, st) {
      _log.e('confirm threw: $e\n$st');
      return _stopBeforeDispatch(tx, 'exception', 'Send failed: $e');
    } finally {
      _inFlightKeys.remove(key);
    }
  }

  // ── Public Swap API (for inline UI execution) ─────────────────────────────

  /// Public entry point for swap preview — used by WalletSwapModal
  /// to get a quote + preview without going through AI chat.
  ///
  /// Returns an [AssistantResponse] with [ResponseType.preview] on success,
  /// containing the [SwapExecutionPlan] in `swapPlan`.
  Future<AssistantResponse> requestSwapPreview(IntentData intent) {
    return _orchestrateSwap(intent);
  }

  /// Chain-aware swap preview — used by swap modal with its own local chain.
  /// Does NOT mutate the global wallet active chain.
  Future<AssistantResponse> requestSwapPreviewForChain(
    IntentData intent,
    String chainKey,
  ) {
    return _orchestrateSwap(intent, chainKeyOverride: chainKey);
  }

  // ── Phase 6 Orchestration Pipeline ────────────────────────────────────────────────────────

  /// Phase 8: Builds a [SwapExecutionPlan] and returns a [preview] response.
  ///
  /// Execution only happens AFTER the user confirms via [orchestrateSwapStep].
  /// The AI CANNOT skip straight to execution from here.
  Future<AssistantResponse> _orchestrateSwap(
    IntentData intent, {
    String? chainKeyOverride,
  }) async {
    // Resolve chain context: use override if provided (swap modal),
    // otherwise fall back to global wallet state (AI chat).
    final effectiveChainKey = chainKeyOverride ?? _wallet.chainKey;
    final effectiveChain = PrivyChainRegistry.getChain(effectiveChainKey);
    final effectiveChainId = effectiveChain.evmChainId ?? 56;
    final effectiveAddress = chainKeyOverride != null
        ? IBITIVaultService.instance.addressForChain(effectiveChainKey)
        : _wallet.address;

    // ── Gate 1: Intent fields ───────────────────────────────────────────────
    if (intent.sourceTokenAddress == null ||
        intent.targetTokenAddress == null ||
        intent.amount == null) {
      return AssistantResponse.error(
        'Cannot build swap: source token, target token, or amount is missing.',
        intent: intent,
      );
    }

    // ── Gate 1b: The amount is what the user pays ──────────────────────────
    // The plan, its approve and every USD check (the swap limit, the daily
    // trading limit, «AI Мандат» max position, the AI card) treat the
    // amount as the paying coin's quantity. An exact amount to RECEIVE
    // would be valued at the wrong coin's price, so it is never quoted.
    // No window sends one and LlmIntentGuard drops the model's.
    if (intent.amountMode == AmountMode.exactOut) {
      final token = (intent.sourceTokenSymbol ?? '').trim().toUpperCase();
      final payToken = token.isEmpty ? '?' : token;
      final message =
          LocalizationService.instance.t('swapExactOutUnsupported', {
        'token': payToken,
        'default': 'A swap for an exact amount to receive is not supported. '
            'Say how much $payToken you want to pay.',
      });
      return AssistantResponse.error(message, intent: intent);
    }

    // ── Gate 2: Wallet connected ────────────────────────────────────────────
    if (!_wallet.isConnected) {
      return AssistantResponse.error('No wallet connected.', intent: intent);
    }

    // ── Gate 3: Slippage cap — clamp AI-provided value to policy maximum ────
    final rawSlippage = intent.slippageBps ?? SwapSlippagePolicy.defaultBps;
    final clampedSlippage = rawSlippage.clamp(0, SwapSlippagePolicy.maxBps);

    // ── Gate 4: Resolve path & profile ─────────────────────────────────────
    final profile = await _profileStore.load();
    final requestedPath = await _capabilityResolver.resolvePath(
        effectiveAddress, effectiveChainId);

    // ── Gate 5: Build quote request ─────────────────────────────────────────
    // Resolve raw amount: prefer intent.rawAmount (already atomic).
    // If absent, convert intent.amount using correct token decimals.
    // NEVER assume 18 — wrong decimals = wrong trade size.
    BigInt resolvedAmount;
    if (intent.rawAmount != null) {
      resolvedAmount = intent.rawAmount!;
    } else {
      final decimals = intent.sourceTokenDecimals;
      if (decimals == null) {
        return AssistantResponse.error(
          'Cannot determine decimals for source token '
          '${intent.sourceTokenSymbol ?? intent.sourceTokenAddress}. '
          'Trade blocked for safety.',
          intent: intent,
        );
      }
      resolvedAmount = NativeTransactionBuilder.toWeiFromDouble(intent.amount!,
          decimals: decimals);
    }

    // [Fix] Re-attach the resolved rawAmount back to the intent so SwapIntentBuilder sees it.
    final resolvedIntent = intent.copyWith(rawAmount: resolvedAmount);

    final quoteRequest = QuoteRequest(
      sourceTokenAddress: resolvedIntent.sourceTokenAddress!,
      targetTokenAddress: resolvedIntent.targetTokenAddress!,
      amount: resolvedAmount,
      // Always the amount to pay (Gate 1b refuses an exact output).
      amountMode: AmountMode.exactIn,
      slippageBps: clampedSlippage,
      chainId: effectiveChainId,
      userAddress: effectiveAddress,
    );

    // ── Gate 6: Fetch quote from provider — handle domain errors cleanly ────
    QuoteResponse quote;
    final activeProvider = _swapProviderForChain(effectiveChainKey);
    if (kDebugMode)
      print(
          '[SwapOrchestrator] Fetching quote via ${activeProvider.runtimeType}...');
    try {
      quote = await activeProvider.getQuote(quoteRequest);
      if (kDebugMode)
        print('[SwapOrchestrator] Quote received '
            'provider=${quote.providerName} '
            'approvalNeeded=${quote.approvalNeeded} '
            'expectedOut=${quote.expectedOutputAmount}');
    } on UnsupportedChainException {
      return AssistantResponse.error(
        'This swap is not supported on the current chain (chainId=${_wallet.chainId}).',
        intent: intent,
      );
    } on RouteNotFoundException catch (e) {
      return AssistantResponse.error(
        'No route found for this token pair. $e',
        intent: intent,
      );
    } on IlliquidTokenException catch (e) {
      return AssistantResponse.error(
        'One of the tokens is too illiquid for a reliable quote. $e',
        intent: intent,
      );
    } on JupiterApiKeyMissingException {
      return AssistantResponse.error(
        'Jupiter API key is not configured. '
        'Add your key to secrets/jupiter.json to enable Solana swaps.',
        intent: intent,
      );
    } catch (e) {
      if (kDebugMode) print('[SwapOrchestrator] ❌ Quote fetch failed: $e');
      return AssistantResponse.error(
        'Failed to fetch swap quote: $e',
        intent: intent,
      );
    }

    // ── Gate 7: Stale quote check ───────────────────────────────────────────
    if (quote.isStale) {
      return AssistantResponse.error(
        'The swap quote expired before the plan could be built. Please try again.',
        intent: intent,
      );
    }

    // ── Gate 8: Native gas sufficiency check ────────────────────────────────
    if (effectiveChainKey == 'solana') {
      // Solana: check SOL balance via RPC — Jupiter managed landing still
      // requires the user to pay tx fees in SOL.
      try {
        final solRpcUrl = PrivyChainRegistry.getChain('solana').rpcUrl ??
            'https://api.mainnet-beta.solana.com';
        final solClient = SolanaHttpRpcClient(rpcUrl: solRpcUrl);
        final solBalance = await solClient.getBalanceLamports(effectiveAddress);
        // ~0.01 SOL minimum for fees + rent
        final minRequired = BigInt.from(10000000);
        if (kDebugMode)
          print('[SwapOrchestrator] SOL balance = '
              '${(solBalance.toDouble() / 1e9).toStringAsFixed(4)} SOL');
        if (solBalance < minRequired) {
          return AssistantResponse.error(
            '⛽ Need SOL for network fee. '
            'Minimum ~0.01 SOL required, '
            'available: ${(solBalance.toDouble() / 1e9).toStringAsFixed(4)} SOL. '
            'Please top up your Solana wallet before swapping.',
            intent: intent,
          );
        }
      } catch (e) {
        if (kDebugMode)
          print('[SwapOrchestrator] SOL balance check failed: $e');
        // Non-fatal — proceed anyway, tx will fail at signing if no SOL
      }
    } else if (effectiveChainKey == 'tron') {
      // Tron: log TRX balance at preview time — actual block at confirm/execute.
      // Quote/preview must still work with low TRX so user can see route info.
      try {
        final tronRpcUrl = PrivyChainRegistry.getChain('tron').rpcUrl ??
            'https://api.trongrid.io';
        final tronClient = TronHttpRpcClient(baseUrl: tronRpcUrl);
        final trxBalanceSun = await tronClient.getBalanceSun(effectiveAddress);
        final trxAmount = trxBalanceSun.toDouble() / 1e6;
        if (kDebugMode)
          print('[SwapOrchestrator] TRX balance = '
              '${trxAmount.toStringAsFixed(4)} TRX');
        final minRequired = BigInt.from(10000000); // 10 TRX in SUN
        if (trxBalanceSun < minRequired) {
          if (kDebugMode)
            print(
                '[SwapOrchestrator] ⚠️ Low TRX: ${trxAmount.toStringAsFixed(2)} '
                '(need ~10 TRX for execution). Allowing preview.');
        }
      } catch (e) {
        if (kDebugMode)
          print('[SwapOrchestrator] TRX balance check failed: $e');
      }
    } else {
      // EVM: native needed = swap gas fee + approve gas fee + value sent.
      // quote.gasEstimate is in gas UNITS (0x "gas"); it used to be added to
      // wei as is, so the check could never fail on gas. The balance is the
      // active chain's — skip when the swap modal works on another chain.
      final nativeBalance = effectiveChainKey == _wallet.chainKey
          ? _wallet.nativeBalance
          : null;
      if (nativeBalance != null) {
        final approveGasEstimate = quote.approvalNeeded
            ? BigInt.from(50000 * 5000000000) // ~50k gas * 5 Gwei
            : BigInt.zero;
        final gasPriceWei = BigInt.tryParse(
                quote.extraSummary['gasPriceWei']?.toString() ?? '') ??
            BigInt.from(5000000000); // 5 Gwei fallback
        final totalGasRequired = quote.gasEstimate * gasPriceWei +
            approveGasEstimate +
            quote.nativeValue;

        if (nativeBalance < totalGasRequired) {
          return AssistantResponse.error(
            '⛽ Insufficient native token for gas. '
            'Estimated needed: ~${_formatWei(totalGasRequired)}, '
            'available: ~${_formatWei(nativeBalance)}. '
            'Please top up your gas wallet before swapping.',
            intent: intent,
          );
        }
      }
    }

    // ── Build two-step execution plan ───────────────────────────────────────
    final plan = SwapIntentBuilder.build(
      intent: resolvedIntent,
      quote: quote,
      overrideChainKey: effectiveChainKey,
      overrideFromAddress: effectiveAddress,
    );
    if (plan == null) {
      return AssistantResponse.error(
        'Could not construct swap execution plan.',
        intent: resolvedIntent,
      );
    }
    // A preview never measures the AI limits in token units (see
    // [orchestrate]); the confirmation checks again.
    if (plan.approveStep != null) {
      final approveGate = _checkAiTransactionControl(
        plan.approveStep!,
        TransactionSimulator.analyze(plan.approveStep!),
        quantityFallback: false,
      );
      if (approveGate != null) {
        return approveGate;
      }
    }

    final staticSim = TransactionSimulator.analyze(plan.swapStep);
    if (kDebugMode)
      print('[SwapOrchestrator] staticSim risk=${staticSim.risk}, '
          'isEvmChain=${plan.swapStep.isEvmChain}');
    final swapGate = _checkAiTransactionControl(plan.swapStep, staticSim,
        quantityFallback: false);
    if (swapGate != null) {
      if (kDebugMode)
        print('[SwapOrchestrator] ❌ AI control gate blocked swap preview');
      return swapGate;
    }

    // ── Approval-aware RPC simulation ───────────────────────────────────────
    // When an ERC-20 approve must run first, RPC-simulating the swap step
    // would always revert ("BEP20: transfer amount exceeds allowance")
    // because the allowance hasn't been set yet. This is expected, not an
    // error. We defer the swap simulation until after approval succeeds —
    // orchestrateSwapStep will re-validate via previewTransaction at that
    // point. For the preview we use a synthetic "deferred" result so the
    // policy engine does not block the preview.
    final RpcSimulationResult rpcSim;
    if (plan.requiresApproval) {
      rpcSim = RpcSimulationResult.deferred();
      if (kDebugMode)
        print('[SwapOrchestrator] Approval required — swap RPC simulation '
            'deferred until after approve.');
    } else {
      rpcSim = await _rpcSim.simulate(plan.swapStep);
    }

    final policy = GuardianPolicyEngine.checkV3(
      plan.swapStep,
      staticSim,
      rpcSim,
      profile,
      _executor.normalizeExecutionPath(plan.swapStep, requestedPath),
    );

    if (kDebugMode)
      print('[SwapOrchestrator] Policy: blocked=${policy.blocked}, '
          'severity=${policy.severity}, reason=${policy.reason}');
    if (policy.blocked) {
      if (kDebugMode) print('[SwapOrchestrator] ❌ Policy blocked swap preview');
      return AssistantResponse.error(
        policy.reason ?? 'Swap blocked by Guardian policy.',
        detail: policyRefusalCode(policy, plan.swapStep),
        intent: intent,
      );
    }

    final explanation = TransactionExplainer.explainV3(
      plan.swapStep,
      staticSim,
      rpcSim,
      policy,
      profile,
      _executor.normalizeExecutionPath(plan.swapStep, requestedPath),
    );

    // ── Return Preview — AI stops here. User must confirm. ──────────────────
    // Format minOutputAmount as human-readable tokens, not raw BigInt Wei.
    final targetSymbol = intent.targetTokenSymbol ?? 'tokens';
    final targetDecimals = intent.targetTokenDecimals ??
        plan.swapStep.quoteSummary?['targetDecimals'] as int? ??
        18;
    final minOutputFormatted =
        _formatTokenAmount(quote.minOutputAmount, targetDecimals, targetSymbol);

    return AssistantResponse(
      message: '🔍 Review and confirm the swap.\n'
          'Route: ${quote.routeSummary}\n'
          'Min received: $minOutputFormatted (after ${clampedSlippage / 100}% slippage)\n'
          'Provider: ${quote.providerName}',
      type: ResponseType.preview,
      sourceIntent: intent,
      pendingTransaction: plan.swapStep,
      policy: policy,
      explanation: explanation,
      rpcSimulation: rpcSim,
      executionPath:
          _executor.normalizeExecutionPath(plan.swapStep, requestedPath),
      swapPlan: plan,
    );
  }

  /// Called when user confirms a single step of a SWAP plan.
  ///
  /// [step] is either [plan.approveStep] or [plan.swapStep].
  /// The UI decides which step to pass based on progression state.
  /// [requireTrustedTarget]: see [orchestrateConfirmation].
  Future<AssistantResponse> orchestrateSwapStep(
      TransactionRequest step, ExecutionPath path,
      {bool requireTrustedTarget = false}) async {
    // ── P0 Safety: Double-execution guard ──────────────────────────────────
    final key = _executionKey(step);
    if (!_inFlightKeys.add(key)) {
      return AssistantResponse.error(
        'This swap step is already being processed. Please wait.',
        intent: step.sourceIntent,
      );
    }

    try {
      if (!_wallet.isConnected) {
        return AssistantResponse.error('Wallet disconnected mid-execution.',
            intent: step.sourceIntent);
      }

      // ── Tron: hard TRX fee gate (approve + swap) ──────────────────────
      // Must run before previewTransaction to avoid RPC hangs with low TRX.
      if (step.chainKey == 'tron' &&
          (step.type == TransactionType.approve ||
              step.type == TransactionType.swap)) {
        try {
          final tronRpcUrl = PrivyChainRegistry.getChain('tron').rpcUrl ??
              'https://api.trongrid.io';
          final tronClient = TronHttpRpcClient(baseUrl: tronRpcUrl);
          final trxBalanceSun =
              await tronClient.getBalanceSun(step.fromAddress);
          final minRequired = BigInt.from(10000000); // 10 TRX in SUN
          final trxAmount = trxBalanceSun.toDouble() / 1e6;
          if (kDebugMode)
            print('[SwapOrchestrator] Tron execute gate '
                'step=${step.type.name} from=${step.fromAddress}');
          if (kDebugMode)
            print('[SwapOrchestrator] Tron execute gate '
                'balance=${trxAmount.toStringAsFixed(2)} TRX');
          if (trxBalanceSun < minRequired) {
            return AssistantResponse.error(
              '⛽ Need TRX for network fee. '
              'Minimum ~10 TRX required for swap energy, '
              'available: ${trxAmount.toStringAsFixed(2)} TRX. '
              'Please top up your Tron wallet before swapping.',
              intent: step.sourceIntent,
            );
          }
        } catch (e) {
          if (kDebugMode)
            print('[SwapOrchestrator] TRX execute-gate check failed: $e');
        }
      }

      if (step.type == TransactionType.swap && _isSwapQuoteExpired(step)) {
        return AssistantResponse.error(
          'Swap quote expired. Please request a fresh quote and review the swap again.',
          intent: step.sourceIntent,
        );
      }

      // ── P0 Safety: Daily limit pre-check ──────────────────────────────────
      final dailyBlock = _checkDailyLimit(step);
      if (dailyBlock != null) return dailyBlock;

      final revalidated = await previewTransaction(step);
      if (revalidated.type == ResponseType.error) {
        return revalidated;
      }
      final aiGate = _checkAiTransactionControl(
        step,
        TransactionSimulator.analyze(step),
      );
      if (aiGate != null) {
        return aiGate;
      }

      final expectedPath = _executor.normalizeExecutionPath(step, path);
      final resolvedPath = revalidated.executionPath ?? expectedPath;
      if (resolvedPath != expectedPath) {
        return AssistantResponse.error(
          'Swap route changed after preview. Please review and confirm again.',
          intent: step.sourceIntent,
        );
      }

      if (requireTrustedTarget) {
        final noPinBlock = _aiNoPinBlock(step);
        if (noPinBlock != null) {
          return _stopBeforeDispatch(step, 'ai_no_pin', noPinBlock);
        }
      }

      final result =
          await _executor.dispatchConfiguredPath(step, resolvedPath);
      _commitDailyUsage(step, result);
      return result;
    } finally {
      _inFlightKeys.remove(key);
    }
  }

  // ── Reservation → Receipt wiring ─────────────────────────────────────────
  // Connects the receipt to DelegationController commit/rollback.
  // On confirmed → commit. On failed/timeout → rollback.
  // This ensures daily limit accurately reflects real on-chain outcomes.
  //
  // Fallback: if we can't poll (no hash / non-EVM), we ROLLBACK to be safe.
  // Reason: committing without proof means the budget is lost on a tx that
  // may never have reached the chain. The reservation TTL in
  // DelegationController acts as a second safety net.
  //
  // The wait is the executor's own receipt loop, not the shared
  // TxStatusPoller: the next transaction anywhere in the app restarts that
  // poller, which used to drop the commit (C7).
  void _wireReservationToReceipt(
    String reservationKey,
    String? txHash,
    TransactionRequest tx,
  ) {
    if (txHash == null || txHash.isEmpty) {
      // No hash = dispatch likely failed before signing.
      // Rollback is the safe default — don't consume budget without proof.
      _delegation.rollbackReservation(reservationKey);
      return;
    }

    // Bind the reservation to the actual on-chain hash for traceability.
    _delegation.bindHash(reservationKey, txHash);

    if (!tx.isEvmChain) {
      // Non-EVM: can't poll receipt. Commit as best-effort (we have a hash,
      // so the tx was at least accepted by the network).
      _delegation.commitReservation(reservationKey);
      return;
    }

    // EVM: wait for the real on-chain receipt. Heartbeats keep the
    // reservation alive during chain congestion.
    AiOnchainExecutor.instance
        .waitForReceipt(
          tx,
          txHash,
          onTick: () => _delegation.touchReservation(reservationKey),
        )
        .then((confirmed) {
      if (confirmed) {
        _delegation.commitReservation(reservationKey);
      } else {
        // failed or timeout → return budget
        _delegation.rollbackReservation(reservationKey);
      }
    }).catchError((Object e) {
      _log.w('reservation receipt wait failed: $e');
      _delegation.rollbackReservation(reservationKey);
    });
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  String _formatWei(BigInt wei) {
    final eth = wei.toDouble() / 1e18;
    return '${eth.toStringAsFixed(6)} ETH/BNB';
  }

  /// Format a raw atomic BigInt as human-readable token amount.
  /// E.g. BigInt(41500000000000000), 18, 'USDT' → '0.041500 USDT'
  String _formatTokenAmount(BigInt raw, int decimals, String symbol) {
    if (decimals <= 0) return '$raw $symbol';
    final divisor = BigInt.from(10).pow(decimals);
    final whole = raw ~/ divisor;
    final frac = (raw % divisor).toString().padLeft(decimals, '0');
    final displayDecimals = decimals > 6 ? 6 : decimals;
    return '$whole.${frac.substring(0, displayDecimals)} $symbol';
  }

  Future<ExecutionPath> _resolveRequestedPath(TransactionRequest tx) async {
    final chain = PrivyChainRegistry.getChain(tx.chainKey);
    final evmChainId = chain.evmChainId;
    if (evmChainId == null) {
      return ExecutionPath.localProtected;
    }
    return _capabilityResolver.resolvePath(tx.fromAddress, evmChainId);
  }

  bool _isSwapQuoteExpired(TransactionRequest step) {
    final rawTimestamp = step.quoteSummary?['quoteTimestamp']?.toString();
    // P0 Fix: Missing quoteTimestamp = treat as expired.
    // Previously returned false, silently passing stale quotes.
    if (rawTimestamp == null || rawTimestamp.isEmpty) {
      return true;
    }
    final parsed = DateTime.tryParse(rawTimestamp);
    if (parsed == null) {
      return true;
    }
    return DateTime.now().toUtc().difference(parsed.toUtc()) >= _swapQuoteTtl;
  }

  // ── P0 Safety: Daily limit pre-check ────────────────────────────────────────
  // Enforces AiControlSettings.dailyLimit BEFORE execution, not just after.
  // DelegationController tracks cumulative spend; this gates the pipeline.
  //
  // It bounds every market trade: the AI's (chat, voice, market chat,
  // automation), a «Ручной» chat card the user confirms, and the user's own
  // Buy / Sell window (origin market, GuardianPolicyEngine
  // .isUserTradeWindowTx) — like the user's own exchange buys. Only the
  // user's own Send / Swap window (origin wallet) is bounded by the wallet
  // send / swap / approve limits instead.
  //
  // The limit is in dollars. The AI never runs an operation by itself with
  // an unknown USD value ([aiPreflight] and the automation path refuse it
  // first). An operation the user confirms themselves (the Buy / Sell
  // window, a chat card in «Ручной») keeps the old stand-in when there is
  // no price: the token quantity is compared as if it were dollars — never
  // looser than before — and the message says so instead of showing the
  // quantity as "$". Every refusal carries [dailyLimitCode].
  AssistantResponse? _checkDailyLimit(TransactionRequest tx) {
    // Daily TRADING limit only — the user's own Send / Swap window is
    // bounded by the wallet send/swap/approve limits, not the trading
    // budget. The Buy / Sell window is a trade and is checked here.
    if (GuardianPolicyEngine.isUserWalletTx(tx)) return null;

    final usd = _finiteUsd(TxUsdValuer.usdValue(tx));
    final amount = usd ?? tx.amount ?? 0.0;
    if (amount <= 0) return null;

    // DelegationController is the authoritative accumulator (committed
    // usage + in-flight reservations).
    if (_delegation.canSpend(amount)) return null;

    final String message;
    if (usd != null) {
      message = _dailyLimitMessage(usd);
    } else {
      final remaining = _delegation.remainingBudgetUsd;
      final left = _usd(remaining < 0 ? 0 : remaining);
      final token = _symbolOf(tx);
      final quantity = _fmtQuantity(amount);
      final asUsd = _usd(amount);
      message = LocalizationService.instance.t('aiDailyLimitNoPrice', {
        'token': token,
        'amount': quantity,
        'amountUsd': asUsd,
        'left': left,
        'default': 'Over the daily trading limit: $token has no price, so '
            '$quantity $token is counted as $asUsd; $left left today.',
      });
    }
    return AssistantResponse.error(message,
        detail: dailyLimitCode, intent: tx.sourceIntent);
  }

  /// Over the daily trading limit by [usd] dollars, with what is left today.
  String _dailyLimitMessage(double usd) {
    final remaining = _delegation.remainingBudgetUsd;
    final left = _usd(remaining < 0 ? 0 : remaining);
    final value = _usd(usd);
    return LocalizationService.instance.t('aiGateBlockedDaily', {
      'value': value,
      'left': left,
      'default':
          'Over the daily trading limit: this needs $value, $left left today.',
    });
  }

  AssistantResponse? _checkAiIntentControl(IntentData intent) {
    final settings = AiControlService.instance.settings;
    final loc = LocalizationService.instance;

    // «Советник»: the AI starts no scan either (D2). Only the assistant
    // comes through here; the user runs Safe Scan in «Защита» themselves.
    if (intent.type == IntentType.scanApprovals &&
        settings.mode == AiMode.manual) {
      final message = loc.t('aiAdvisorNoScan', {
        'default': 'The «Advisor» mode is on: I can explain the risks but do '
            'not run the scan. Start Safe Scan in the «Security» tab '
            'yourself, or choose «Manual».',
      });
      return AssistantResponse.info(message, intent: intent);
    }

    if (!intent.isExecutionIntent) return null;

    // The same texts as AiActionGate and [_checkAiTransactionControl], in
    // the user's language («AI-Центр» in Russian).
    if (settings.mode == AiMode.manual) {
      final message = loc.t('aiGateAdvisorOnly', {
        'default': 'In «Advisor» mode the AI only advises: it opens and '
            'prepares nothing. To let it act, choose «Manual» or '
            '«Autonomous» in AI Center.',
      });
      return AssistantResponse(
        message: message,
        speechText: message,
        type: ResponseType.error,
        sourceIntent: intent,
        uiCommands: const [
          UICommand(type: UICommandType.navigate, target: 'security_center'),
        ],
      );
    }

    final requiredAction = _requiredAiActionForIntent(intent.type);
    if (requiredAction != null &&
        !settings.allowedActions.contains(requiredAction)) {
      final message = loc.t('aiGateBlockedPermission', {
        'default': 'This action is turned off for the AI in AI Center.',
      });
      return AssistantResponse(
        message: message,
        speechText: message,
        type: ResponseType.error,
        sourceIntent: intent,
        uiCommands: const [
          UICommand(type: UICommandType.navigate, target: 'security_center'),
        ],
      );
    }

    return null;
  }

  /// A successful market operation counts against the daily trading
  /// budget: the AI's, a «Ручной» chat card and the user's own Buy / Sell
  /// window (as before); not the user's own Send / Swap window. Before,
  /// only the pre-check ran, so every operation saw a fresh budget and the
  /// "daily" limit was really a per-operation one.
  void _commitDailyUsage(TransactionRequest tx, AssistantResponse result) {
    if (result.type == ResponseType.error) return;
    final usd = dailyUsageUsd(tx);
    if (usd != null) {
      _delegation.commitUsage(usd);
    } else if (!GuardianPolicyEngine.isUserWalletTx(tx) &&
        (tx.type == TransactionType.send || tx.type == TransactionType.swap) &&
        (tx.amount ?? 0) > 0) {
      _log.w('daily usage not counted: no USD value for ${tx.displaySummary}');
    }
  }

  /// What a successful [tx] adds to today's trading budget, in dollars, or
  /// null when it adds nothing: the user's own Send / Swap window (origin
  /// wallet), approvals and revokes, and an unknown USD value — a token
  /// quantity is never added to the dollar budget. The user's own Buy / Sell
  /// window is a trade (origin market) and counts.
  @visibleForTesting
  static double? dailyUsageUsd(TransactionRequest tx) {
    if (GuardianPolicyEngine.isUserWalletTx(tx)) return null;
    if (tx.type == TransactionType.approve ||
        tx.type == TransactionType.revoke) {
      return null;
    }
    final usd = _finiteUsd(TxUsdValuer.usdValue(tx));
    return usd != null && usd > 0 ? usd : null;
  }

  /// The daily-limit check of an operation the user confirms (chat card,
  /// Buy / Sell window): see [_checkDailyLimit].
  @visibleForTesting
  AssistantResponse? checkDailyLimitForTest(TransactionRequest tx) =>
      _checkDailyLimit(tx);

  /// AI Control for a preview / an operation the user confirms: see
  /// [_checkAiTransactionControl] (token-quantity stand-in without a price).
  @visibleForTesting
  AssistantResponse? checkAiTransactionControlForTest(TransactionRequest tx) =>
      _checkAiTransactionControl(tx, TransactionSimulator.analyze(tx));

  // ── AI execution checks (public for AiOnchainExecutor) ─────────────────────

  /// `detail` of the [aiPreflight] refusal for an unknown USD value: the
  /// caller hands the operation to the user in the prefilled window
  /// instead (D17).
  static const String aiUnknownValueCode = 'ai_unknown_usd_value';

  // ── Refusals the user can lift in «Политика» (D6) ──────────────────────────
  // Stable, language-independent `detail` codes. Every refusal below carries
  // one, whatever language its message is in, so the assistant can append
  // «поднимите порог в «Политике» (нужен ПИН)» by code, never by wording.

  /// Over the daily trading limit ([_checkDailyLimit], the automation
  /// budget reservation).
  static const String dailyLimitCode = 'limit_daily_trading';

  /// Over «AI Мандат» max position (buys only).
  static const String maxPositionCode = 'limit_ai_max_position';

  /// The network is outside «AI Мандат».
  static const String mandateNetworkCode = 'mandate_network';

  /// An asset (paid or bought) is outside «AI Мандат».
  static const String mandateAssetCode = 'mandate_asset';

  /// The venue (swap router / spender) is outside «AI Мандат».
  static const String mandateVenueCode = 'mandate_venue';

  /// Over the wallet Send limit of the policy profile.
  static const String sendLimitCode = 'limit_wallet_send';

  /// Over the wallet Swap limit of the policy profile.
  static const String swapLimitCode = 'limit_wallet_swap';

  /// Over the Approve limit of the policy profile (a finite approval; an
  /// unlimited one is never lifted by a higher limit and has no code).
  static const String approveLimitCode = 'limit_wallet_approve';

  static const Set<String> _raisableCodes = {
    dailyLimitCode,
    maxPositionCode,
    mandateNetworkCode,
    mandateAssetCode,
    mandateVenueCode,
    sendLimitCode,
    swapLimitCode,
    approveLimitCode,
  };

  /// Whether a refusal with this `detail` is one the user can lift by
  /// raising a threshold in «Политика» with the PIN (D6): the daily trading
  /// limit, «AI Мандат» (max position, networks, assets, venues) or a wallet
  /// send / swap / approve limit. False for everything else — the AI mode,
  /// AI permissions, EPK, an unknown price ([aiUnknownValueCode]), trusted
  /// scope, the simulation, a transaction hash on success, or null.
  static bool isRaisableRefusal(String? detail) =>
      detail != null && _raisableCodes.contains(detail);

  /// The `detail` code of a policy-engine refusal ([PolicyResult.blocked])
  /// over a wallet limit the user can raise in «Политика», else null.
  @visibleForTesting
  static String? policyRefusalCode(PolicyResult policy, TransactionRequest tx) {
    if (!policy.blocked) return null;
    final rules = policy.appliedRules;
    if (rules.contains('PROFILE_LIMIT_EXCEEDED')) return sendLimitCode;
    if (rules.contains('SWAP_PROFILE_LIMIT_EXCEEDED')) return swapLimitCode;
    if (rules.contains('APPROVE_LIMIT_EXCEEDED') && !tx.isUnlimitedApproval) {
      return approveLimitCode;
    }
    return null;
  }

  /// The controller's AI checks for [tx] before the AI runs it by itself
  /// (before any card): AI Control (permissions, «AI Мандат», trusted
  /// scope), then the USD value, then the daily trading limit. Null when
  /// the AI may go on.
  ///
  /// The AI never acts on an unknown USD value: its limits are dollars and
  /// a token quantity is not (D7). That refusal carries [aiUnknownValueCode]
  /// in `detail`, so the caller can open the prefilled window for the user
  /// instead (D17). Permissions and «AI Мандат» are checked first: those
  /// are plain refusals, never a reason to open a window (D6).
  AssistantResponse? aiPreflight(TransactionRequest tx) {
    final control = _checkAiTransactionControl(
      tx,
      TransactionSimulator.analyze(tx),
      quantityFallback: false,
    );
    if (control != null) return control;
    if (aiValueUnknown(tx)) return _aiUnknownValueResponse(tx);
    return _checkDailyLimit(tx);
  }

  /// Whether the AI would act on [tx] without knowing its USD value (no
  /// price, no amount). A revoke moves no money (D11) and never counts.
  static bool aiValueUnknown(TransactionRequest tx) {
    if (tx.type == TransactionType.revoke) return false;
    return _finiteUsd(TxUsdValuer.usdValue(tx)) == null;
  }

  AssistantResponse _aiUnknownValueResponse(TransactionRequest tx) {
    final token = _symbolOf(tx);
    final message = LocalizationService.instance.t('aiExecUnknownValue', {
      'token': token,
      'default': '$token has no price, so the dollar value of this operation '
          'is unknown and the AI will not carry it out by itself. Do it '
          'yourself in the wallet window.',
    });
    _log.w('AI refused: no USD value for ${tx.displaySummary}');
    return AssistantResponse(
      message: message,
      speechText: message,
      type: ResponseType.error,
      detail: aiUnknownValueCode,
      sourceIntent: tx.sourceIntent,
    );
  }

  /// The stablecoins a swap is priced against, as in AiOnchainExecutor: a
  /// swap from a coin into one of them is a sell.
  static const Set<String> _stablecoins = {
    'USDT', 'USDC', 'DAI', 'BUSD', 'FDUSD', 'TUSD', 'USDD', 'USDE', 'PYUSD',
  };

  static bool _isStablecoin(String? symbol) =>
      symbol != null && _stablecoins.contains(symbol.trim().toUpperCase());

  /// Whether «AI Мандат» max position bounds [tx]: buys only (D6), as
  /// ExchangeOrderService and AiActionGate apply it. A buy is any swap that
  /// is not a sell (coin → stablecoin) — the split AiOnchainExecutor makes
  /// for the card. Sends, sells, approvals and revokes are bounded by the
  /// daily trading limit, the policy and EPK, not by the position cap.
  static bool maxPositionAppliesTo(TransactionRequest tx) {
    if (tx.type != TransactionType.swap) return false;
    final sell =
        !_isStablecoin(tx.tokenSymbol) && _isStablecoin(tx.targetTokenSymbol);
    return !sell;
  }

  /// Over «AI Мандат» max position. [priced] false: [value] is the token
  /// quantity stand-in (no USD price), which the message says plainly.
  static String _maxPositionMessage(
    TransactionRequest tx,
    double value, {
    required bool priced,
    required double cap,
  }) {
    final loc = LocalizationService.instance;
    final capLabel = _usd(cap);
    if (priced) {
      final v = _usd(value);
      return loc.t('aiGateBlockedMaxPosition', {
        'value': v,
        'cap': capLabel,
        'default': 'Over the AI position cap: $v, the cap is $capLabel.',
      });
    }
    final token = _symbolOf(tx);
    final quantity = _fmtQuantity(value);
    final asUsd = _usd(value);
    return loc.t('aiMaxPositionNoPrice', {
      'token': token,
      'amount': quantity,
      'amountUsd': asUsd,
      'cap': capLabel,
      'default': 'Over the AI position cap: $token has no price, so '
          '$quantity $token is counted as $asUsd; the cap is $capLabel.',
    });
  }

  static double? _finiteUsd(double? v) =>
      (v == null || v.isNaN || v.isInfinite || v < 0) ? null : v;

  static String _usd(double v) => '\$${v.toStringAsFixed(2)}';

  /// A contract address for a message: '0x0000…2734' (display only).
  static String _shortAddress(String address) {
    final a = address.trim();
    if (a.length <= 14) return a;
    return '${a.substring(0, 6)}…${a.substring(a.length - 4)}';
  }

  static String _symbolOf(TransactionRequest tx) {
    final symbol = (tx.tokenSymbol ?? '').trim().toUpperCase();
    return symbol.isEmpty ? '?' : symbol;
  }

  /// A token quantity without trailing zeros (2.5, 0.00012).
  static String _fmtQuantity(double v) {
    if (v == 0) return '0';
    var s = v.toStringAsFixed(v.abs() >= 1 ? 4 : 8);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '');
      if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// Why the AI may NOT run [tx] without the PIN, or null when it may (D6,
  /// C4). Applied right before signing, whatever the policy profile:
  /// - a revoke only lowers an allowance and is never stopped (D11);
  /// - the network must still be the active one;
  /// - EPK protection must be on;
  /// - a send goes only to a trusted address / contract or the user's own
  ///   address (self, own cards);
  /// - an approve / swap targets only a trusted contract or an official
  ///   swap router ([AiActionGate.isOfficialSwapRouter], D12 — one list);
  /// - a send / swap needs a known USD value (C10).
  @visibleForTesting
  static String? aiNoPinBlockReason(
    TransactionRequest tx, {
    required PolicyProfile profile,
    required bool epkActive,
    required String activeChainKey,
    Iterable<String> ownAddresses = const [],
  }) {
    if (tx.type == TransactionType.revoke) return null;
    final loc = LocalizationService.instance;

    if (tx.chainKey != activeChainKey) {
      return loc.t('aiNoPinWrongNetwork', {
        'default': 'The active network changed. Ask the AI again.',
      });
    }
    if (!epkActive) {
      return loc.t('aiNoPinEpkPaused', {
        'default':
            'EPK protection is paused, so the AI cannot act without the PIN.',
      });
    }

    bool listed(List<String> list, String address) =>
        address.isNotEmpty && list.any((a) => AddressKey.same(a, address));
    bool trustedContract(String? address) =>
        address != null &&
        address.isNotEmpty &&
        (AiActionGate.isOfficialSwapRouter(address) ||
            listed(profile.trustedContracts, address));
    final untrustedContract = loc.t('aiNoPinUntrustedContract', {
      'default':
          'Without the PIN the AI works only with trusted contracts and official swap routers.',
    });
    final noPrice = loc.t('aiNoPinNoPrice', {
      'default':
          'The USD value is unknown, so the AI cannot act without the PIN.',
    });

    switch (tx.type) {
      case TransactionType.send:
        final to = tx.toAddress;
        final own = AddressKey.same(to, tx.fromAddress) ||
            ownAddresses.any((a) => a.isNotEmpty && AddressKey.same(a, to));
        if (!own &&
            !listed(profile.trustedAddresses, to) &&
            !listed(profile.trustedContracts, to)) {
          return loc.t('aiNoPinUntrusted', {
            'default':
                'Without the PIN the AI sends only to trusted addresses. Add this address to trusted addresses or confirm with the PIN.',
          });
        }
        if (TxUsdValuer.usdValue(tx) == null) return noPrice;
        return null;
      case TransactionType.approve:
        return trustedContract(tx.spenderAddress) ? null : untrustedContract;
      case TransactionType.swap:
        if (!trustedContract(tx.routerAddress ?? tx.toAddress)) {
          return untrustedContract;
        }
        if (TxUsdValuer.usdValue(tx) == null) return noPrice;
        return null;
      case TransactionType.revoke:
        return null;
      case TransactionType.unknown:
        return untrustedContract;
    }
  }

  String? _aiNoPinBlock(TransactionRequest tx) {
    final vault = IBITIVaultService.instance;
    return aiNoPinBlockReason(
      tx,
      profile: _profileStore.current,
      epkActive: EPKPolicyManager.instance.state.isActive,
      activeChainKey: vault.chainKey,
      ownAddresses: [
        vault.addressForChain(tx.chainKey),
        ...vault.evmCardAddresses,
      ],
    );
  }

  /// AI Control for a market transaction (the AI, automation, a «Ручной»
  /// chat card, the user's own Buy / Sell window): the AI mode and
  /// permissions, «AI Мандат» (network, assets, max position for buys,
  /// venue), unknown contracts and the trusted scope. Null when it passes.
  ///
  /// The user's own Buy / Sell window
  /// ([GuardianPolicyEngine.isUserTradeWindowTx]) skips ONLY the AI mode
  /// («Советник», emergency stop, expired AI permissions) and the AI
  /// permissions, because it is the user's own action (D2); «AI Мандат»,
  /// unknown contracts and the trusted scope bound it as before.
  ///
  /// [quantityFallback]: without a USD price, compare the token quantity
  /// with the max position as before — only when the user confirms the
  /// operation themselves ([orchestrateConfirmation] / [orchestrateSwapStep]
  /// for the Buy / Sell window or a «Ручной» chat card). False for previews
  /// and for the AI's own execution, which [aiPreflight] refuses on an
  /// unknown value instead of measuring it in token units.
  ///
  /// The refusals over max position or outside «AI Мандат» carry
  /// [maxPositionCode] / [mandateNetworkCode] / [mandateAssetCode] /
  /// [mandateVenueCode] ([isRaisableRefusal]).
  AssistantResponse? _checkAiTransactionControl(
    TransactionRequest tx,
    SimulationResult staticSim, {
    bool quantityFallback = true,
  }) {
    // The AI mandate bounds what the AI does. Operations the user starts in
    // their own Send / Swap window are bounded by the wallet limits in the
    // policy engine; the AI's position cap must not block a manual send.
    if (GuardianPolicyEngine.isUserWalletTx(tx)) return null;

    final settings = AiControlService.instance.settings;

    // A revoke only lowers an allowance (it moves no money and every
    // whitelist passes it). Expired AI permissions, the mandate and the
    // limits never stand between the user and a revoke (D11). A card tap
    // still needs the dialog + PIN; an AI run goes through AiActionGate,
    // which asks for the card + PIN when the AI revoke permission is off.
    if (tx.type == TransactionType.revoke) return null;

    // The user's own Buy / Sell window: not the AI, so the AI mode and the
    // AI permissions below do not apply to it; everything after them does.
    final ownTradeWindow = GuardianPolicyEngine.isUserTradeWindowTx(tx);

    // The refusals use the gate's texts (AiActionGate), so voice, chat and
    // the card say the same thing in the user's language.
    final loc = LocalizationService.instance;
    if (!ownTradeWindow && !settings.isActive) {
      // «Советник» is not an expiry: say which one it is.
      return AssistantResponse.error(
        settings.mode == AiMode.manual
            ? loc.t('aiGateAdvisorOnly', {
                'default': 'In «Advisor» mode the AI only advises: it opens '
                    'and prepares nothing. To let it act, choose «Manual» or '
                    '«Autonomous» in AI Center.',
              })
            : loc.t('aiGateBlockedExpired', {
                'default': 'AI permissions are off or have expired. Renew '
                    'them in AI Center.',
              }),
        intent: tx.sourceIntent,
      );
    }
    final mandate = settings.mandate;
    final profile = _profileStore.current;

    final requiredAction = _requiredAiActionForTx(tx.type);
    if (!ownTradeWindow &&
        requiredAction != null &&
        !settings.allowedActions.contains(requiredAction)) {
      final message = loc.t('aiGateBlockedPermission', {
        'default': 'This action is turned off for the AI in AI Center.',
      });
      return AssistantResponse(
        message: message,
        speechText: message,
        type: ResponseType.error,
        sourceIntent: tx.sourceIntent,
        uiCommands: const [
          UICommand(type: UICommandType.navigate, target: 'security_center'),
        ],
      );
    }

    if (!mandate.allowsNetwork(tx.chainKey)) {
      final name = tx.chainKey.trim().toUpperCase();
      return AssistantResponse.error(
        loc.t('aiGateBlockedMandateNetwork', {
          'network': name,
          'default': '$name is outside the «AI Mandate» networks.',
        }),
        detail: mandateNetworkCode,
        intent: tx.sourceIntent,
      );
    }

    final sourceAsset = tx.tokenSymbol;
    final targetAsset = tx.targetTokenSymbol;
    for (final asset in [sourceAsset, targetAsset]) {
      if (!mandate.allowsAsset(asset)) {
        final name = asset!.trim().toUpperCase();
        return AssistantResponse.error(
          loc.t('aiGateBlockedMandateAsset', {
            'asset': name,
            'default': '$name is outside the «AI Mandate» assets.',
          }),
          detail: mandateAssetCode,
          intent: tx.sourceIntent,
        );
      }
    }

    // «AI Мандат» max position: buys only (D6), in dollars — the value of
    // the coin paid (the swap amount is always what the user pays, see
    // Gate 1b in [_orchestrateSwap]). Sends, sells, approvals and revokes
    // are bounded by the daily trading limit, the policy and EPK instead
    // (as in ExchangeOrderService / AiActionGate).
    if (maxPositionAppliesTo(tx)) {
      final usd = _finiteUsd(TxUsdValuer.usdValue(tx));
      final value = usd ?? (quantityFallback ? tx.amount : null);
      if (value != null && value > 0 && value > mandate.maxPositionUsd) {
        return AssistantResponse.error(
          _maxPositionMessage(tx, value,
              priced: usd != null, cap: mandate.maxPositionUsd),
          detail: maxPositionCode,
          intent: tx.sourceIntent,
        );
      }
    }

    final contractTarget = _contractTarget(tx);
    final venueTarget = tx.routerAddress ?? tx.spenderAddress;
    if (!mandate.allowsVenue(venueTarget)) {
      final name = _shortAddress(venueTarget!);
      return AssistantResponse.error(
        loc.t('aiGateBlockedMandateVenue', {
          'venue': name,
          'default': '$name is outside the «AI Mandate» venues.',
        }),
        detail: mandateVenueCode,
        intent: tx.sourceIntent,
      );
    }

    if (settings.mode == AiMode.fullAutonomy &&
        mandate.requireHumanForUnknown &&
        staticSim.flags.contains(SimulationFlag.unknownContract)) {
      return AssistantResponse.error(
        'Autonomous mode is blocked for unknown contracts under the current AI mandate.',
        intent: tx.sourceIntent,
      );
    }

    switch (settings.trustedScope) {
      case AiTrustedScope.trustedOnly:
        if (tx.type == TransactionType.send &&
            !_isTrustedAddress(tx.toAddress, profile)) {
          return AssistantResponse.error(
            'AI Trusted Scope is set to trusted-only. This recipient is not trusted.',
            intent: tx.sourceIntent,
          );
        }
        if (contractTarget != null &&
            !_isTrustedContract(contractTarget, profile)) {
          return AssistantResponse.error(
            'AI Trusted Scope is set to trusted-only. This contract is not trusted.',
            intent: tx.sourceIntent,
          );
        }
        break;
      case AiTrustedScope.trustedPlusApproved:
        if (contractTarget != null &&
            !_isTrustedContract(contractTarget, profile) &&
            staticSim.flags.contains(SimulationFlag.unknownContract)) {
          return AssistantResponse.error(
            'This contract is not trusted and is not verified enough for the current AI Trusted Scope.',
            intent: tx.sourceIntent,
          );
        }
        break;
      case AiTrustedScope.anyTarget:
        break;
    }

    return null;
  }

  AiAction? _requiredAiActionForIntent(IntentType type) {
    switch (type) {
      case IntentType.sendAsset:
        return AiAction.send;
      case IntentType.receiveAsset:
        return null;
      case IntentType.swapAsset:
      case IntentType.buyAsset:
      case IntentType.sellAsset:
        return AiAction.swap;
      case IntentType.revokeApproval:
        return AiAction.revoke;
      case IntentType.showBalances:
      case IntentType.showWalletCards:
      case IntentType.showRisks:
      case IntentType.scanApprovals:
      case IntentType.showAddress:
      case IntentType.showHistory:
      case IntentType.openAddressBook:
      case IntentType.openWalletSettings:
      case IntentType.openMarket:
      case IntentType.openSecurityCenter:
      case IntentType.unknown:
        return null;
    }
  }

  AiAction? _requiredAiActionForTx(TransactionType type) {
    switch (type) {
      case TransactionType.send:
        return AiAction.send;
      case TransactionType.approve:
        return AiAction.approve;
      case TransactionType.revoke:
        return AiAction.revoke;
      case TransactionType.swap:
        return AiAction.swap;
      case TransactionType.unknown:
        return null;
    }
  }

  bool _isTrustedAddress(String address, PolicyProfile profile) {
    return profile.trustedAddresses
        .any((trusted) => AddressKey.same(trusted, address));
  }

  bool _isTrustedContract(String address, PolicyProfile profile) {
    return profile.trustedContracts
        .any((trusted) => AddressKey.same(trusted, address));
  }

  String? _contractTarget(TransactionRequest tx) {
    switch (tx.type) {
      case TransactionType.approve:
      case TransactionType.revoke:
        return tx.spenderAddress;
      case TransactionType.swap:
        return tx.routerAddress;
      case TransactionType.send:
      case TransactionType.unknown:
        return null;
    }
  }
}
