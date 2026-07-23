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
import 'package:ibiti_guardian/services/execution/tx_status_poller.dart';
import 'package:ibiti_guardian/models/tx_status.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/execution/native_transaction_builder.dart';
import 'package:ibiti_guardian/services/execution/clients/solana_rpc_client.dart';
import 'package:ibiti_guardian/services/execution/clients/tron_rpc_client.dart';

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

  // в”Ђв”Ђв”Ђ Phase 6 Orchestration Pipeline в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

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
      return AssistantResponse.error('Could not build this transaction.',
          intent: intent);
    }
    final aiTxGate = _checkAiTransactionControl(
      tx,
      TransactionSimulator.analyze(tx),
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

      switch (decision.verdict) {
        case SandboxVerdict.approvedForAuto:
          // Reserve daily budget BEFORE execution (atomic lock).
          final reservationKey = _delegation.generateReservationKey(tx);
          final txAmount = tx.amount ?? 0.0;
          if (txAmount > 0) {
            final reserved = _delegation.reserveSpend(reservationKey, txAmount);
            if (reserved == null) {
              return AssistantResponse.error(
                'Daily limit would be exceeded. ${_delegation.usageSummary()}',
                intent: intent,
              );
            }
          }

          // Dispatch the transaction.
          final executionResult =
              await _executor.dispatchConfiguredPath(tx, path);

          // If dispatch itself failed (no hash returned), rollback.
          if (executionResult.type == ResponseType.error) {
            _delegation.rollbackReservation(reservationKey);
          } else if (txAmount > 0) {
            // Wire TxStatusPoller: commit on confirmed, rollback on failed/timeout.
            _wireReservationToReceipt(
                reservationKey, executionResult.detail, tx);
          }

          return AssistantResponse(
            message:
                '🤖 Automated Action Succeeded:\n${executionResult.message}\n(Sandbox: ${decision.reason})',
            type: ResponseType.action,
            sourceIntent: intent,
            executionPath: path,
          );

        case SandboxVerdict.requireManualReview:
          // Agent attempted action, but sandbox deemed it too risky for auto.
          // Demote back to the standard User Preview.
          final explanation = TransactionExplainer.explainV3(
              tx, staticSim, rpcSim, policy, profile, path);
          return AssistantResponse.preview(
            transaction: tx,
            explanation: explanation,
            policy:
                policy, // We explicitly don't block, we just require UI confirm
            rpcSimulation: rpcSim,
            executionPath: path,
          );

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
      return AssistantResponse.error(
        'This action requires a successful simulation before it can be confirmed.',
        intent: tx.sourceIntent,
      );
    }

    if (policy.blocked) {
      AuditLogService.instance.recordPolicyBlock(
        intentType: tx.sourceIntent.type,
        actionLabel: tx.typeLabel,
        summary: tx.displaySummary,
        reason: policy.reason ?? 'Transaction blocked by Guardian policy.',
      );
      return AssistantResponse.error(
        policy.reason ?? 'Transaction blocked by Guardian policy.',
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

  /// Execution trigger called ONLY after the UI manual confirmation screen.
  Future<AssistantResponse> orchestrateConfirmation(
      TransactionRequest tx, ExecutionPath path) async {
    // ── P0 Safety: Double-execution guard ──────────────────────────────────
    final key = _executionKey(tx);
    if (!_inFlightKeys.add(key)) {
      return AssistantResponse.error(
        'This transaction is already being processed. Please wait.',
        intent: tx.sourceIntent,
      );
    }

    try {
      if (!_wallet.isConnected) {
        return AssistantResponse.error('Wallet disconnected mid-execution.',
            intent: tx.sourceIntent);
      }

      // ── P0 Safety: Daily limit pre-check ──────────────────────────────────
      final dailyBlock = _checkDailyLimit(tx);
      if (dailyBlock != null) return dailyBlock;

      // Re-run preview immediately before execution to prevent stale confirms:
      // policy/network/path may have changed while the user was reading preview.
      final revalidated = await previewTransaction(tx);
      if (revalidated.type == ResponseType.error) {
        return revalidated;
      }
      final aiGate = _checkAiTransactionControl(
        tx,
        TransactionSimulator.analyze(tx),
      );
      if (aiGate != null) {
        return aiGate;
      }

      final expectedPath = _executor.normalizeExecutionPath(tx, path);
      final resolvedPath = revalidated.executionPath ?? expectedPath;
      if (resolvedPath != expectedPath) {
        return AssistantResponse.error(
          'Execution route changed after preview. Please review and confirm again.',
          intent: tx.sourceIntent,
        );
      }

      return await _executor.dispatchConfiguredPath(tx, resolvedPath);
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
      amountMode: resolvedIntent.amountMode ?? AmountMode.exactIn,
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
      // EVM: gasRequired = gasEstimate (swap) + gasEstimate (approve if needed)
      // WalletAdapter.nativeBalance is in Wei.
      final nativeBalance = _wallet.nativeBalance;
      if (nativeBalance != null) {
        final approveGasEstimate = quote.approvalNeeded
            ? BigInt.from(50000 * 5000000000) // ~50k gas * 5 Gwei
            : BigInt.zero;
        final totalGasRequired =
            quote.gasEstimate + approveGasEstimate + quote.nativeValue;

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
    if (plan.approveStep != null) {
      final approveGate = _checkAiTransactionControl(
        plan.approveStep!,
        TransactionSimulator.analyze(plan.approveStep!),
      );
      if (approveGate != null) {
        return approveGate;
      }
    }

    final staticSim = TransactionSimulator.analyze(plan.swapStep);
    if (kDebugMode)
      print('[SwapOrchestrator] staticSim risk=${staticSim.risk}, '
          'isEvmChain=${plan.swapStep.isEvmChain}');
    final swapGate = _checkAiTransactionControl(plan.swapStep, staticSim);
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
  Future<AssistantResponse> orchestrateSwapStep(
      TransactionRequest step, ExecutionPath path) async {
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

      return await _executor.dispatchConfiguredPath(step, resolvedPath);
    } finally {
      _inFlightKeys.remove(key);
    }
  }

  // ── Reservation → Receipt wiring ─────────────────────────────────────────
  // Connects TxStatusPoller to DelegationController commit/rollback.
  // On confirmed → commit. On failed/timeout → rollback.
  // This ensures daily limit accurately reflects real on-chain outcomes.
  //
  // Fallback: if we can't poll (no hash / non-EVM), we ROLLBACK to be safe.
  // Reason: committing without proof means the budget is lost on a tx that
  // may never have reached the chain. The 120s reservation TTL in
  // DelegationController acts as a second safety net.
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

    // EVM: poll for real on-chain receipt.
    TxStatusPoller.instance.start(
      txHash: txHash,
      chainId: tx.chainId,
      operationLabel: 'Automation: ${tx.typeLabel}',
      assetLabel: tx.displaySummary,
      walletAddress: tx.fromAddress,
      onStatus: (event) {
        if (!event.isTerminal) {
          // Heartbeat: keep reservation alive while poller is running.
          // This prevents adaptive TTL from false-rollback during chain
          // congestion. As long as poller ticks → reservation lives.
          _delegation.touchReservation(reservationKey);
          return;
        }
        if (event.status == TxStatus.confirmed) {
          _delegation.commitReservation(reservationKey);
        } else {
          // failed or timeout → return budget
          _delegation.rollbackReservation(reservationKey);
        }
      },
    );
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
  AssistantResponse? _checkDailyLimit(TransactionRequest tx) {
    final amount = tx.amount ?? 0.0;
    if (amount <= 0) return null;

    // Daily TRADING limit only — plain wallet operations are bounded by their
    // own send/swap limits, not the trading budget.
    if (tx.sourceIntent.origin == IntentOrigin.wallet) return null;

    final settings = AiControlService.instance.settings;
    final dailyLimit = settings.dailyLimit;

    // Check if adding this amount would exceed the daily limit.
    // DelegationController._usedTodayUsd is the authoritative accumulator.
    if (!_delegation.canSpend(amount)) {
      return AssistantResponse.error(
        'This transaction (\$${amount.toStringAsFixed(2)}) would exceed your '
        'daily AI limit of \$${dailyLimit.toStringAsFixed(0)}. '
        '${_delegation.usageSummary()}',
        intent: tx.sourceIntent,
      );
    }
    return null;
  }

  AssistantResponse? _checkAiIntentControl(IntentData intent) {
    if (!intent.isExecutionIntent) return null;

    final settings = AiControlService.instance.settings;
    if (settings.mode == AiMode.manual) {
      return AssistantResponse(
        message:
            'AI execution is locked in Manual mode. Enable Guarded or Full Autonomy in AI Control first.',
        speechText: 'AI execution is locked. Open AI Control to enable it.',
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
      return AssistantResponse(
        message:
            'This AI action is disabled in AI Control. Enable ${requiredAction.name} permissions before continuing.',
        speechText: 'This AI action is disabled in your AI Control settings.',
        type: ResponseType.error,
        sourceIntent: intent,
        uiCommands: const [
          UICommand(type: UICommandType.navigate, target: 'security_center'),
        ],
      );
    }

    return null;
  }

  AssistantResponse? _checkAiTransactionControl(
    TransactionRequest tx,
    SimulationResult staticSim,
  ) {
    final settings = AiControlService.instance.settings;
    final mandate = settings.mandate;
    final profile = _profileStore.current;
    final amount = tx.amount ?? 0.0;

    final requiredAction = _requiredAiActionForTx(tx.type);
    if (requiredAction != null &&
        !settings.allowedActions.contains(requiredAction)) {
      return AssistantResponse(
        message:
            'AI is not allowed to perform ${tx.typeLabel.toLowerCase()} operations under the current AI Control policy.',
        speechText: 'This action is blocked by AI Control.',
        type: ResponseType.error,
        sourceIntent: tx.sourceIntent,
        uiCommands: const [
          UICommand(type: UICommandType.navigate, target: 'security_center'),
        ],
      );
    }

    if (!mandate.allowsNetwork(tx.chainKey)) {
      return AssistantResponse.error(
        'This network is outside the active AI autonomy mandate.',
        intent: tx.sourceIntent,
      );
    }

    final sourceAsset = tx.tokenSymbol;
    final targetAsset = tx.targetTokenSymbol;
    if (!mandate.allowsAsset(sourceAsset) ||
        !mandate.allowsAsset(targetAsset)) {
      return AssistantResponse.error(
        'This asset is outside the active AI autonomy mandate.',
        intent: tx.sourceIntent,
      );
    }

    if (amount > 0 && amount > mandate.maxPositionUsd) {
      return AssistantResponse.error(
        'This action exceeds your autonomy position cap of \$${mandate.maxPositionUsd.toStringAsFixed(2)}.',
        intent: tx.sourceIntent,
      );
    }

    final contractTarget = _contractTarget(tx);
    final venueTarget = tx.routerAddress ?? tx.spenderAddress;
    if (!mandate.allowsVenue(venueTarget)) {
      return AssistantResponse.error(
        'This venue is outside the active AI autonomy mandate.',
        intent: tx.sourceIntent,
      );
    }

    if (settings.mode == AiMode.fullAutonomy &&
        mandate.requireHumanForUnknown &&
        staticSim.flags.contains(SimulationFlag.unknownContract)) {
      return AssistantResponse.error(
        'Full autonomy is blocked for unknown contracts under the current AI mandate.',
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
        .any((trusted) => trusted.toLowerCase() == address.toLowerCase());
  }

  bool _isTrustedContract(String address, PolicyProfile profile) {
    return profile.trustedContracts
        .any((trusted) => trusted.toLowerCase() == address.toLowerCase());
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
