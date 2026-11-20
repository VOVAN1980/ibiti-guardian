// Unit tests for GuardianPolicyEngine.checkV3()
//
// Run: flutter test test/services/policy/guardian_policy_engine_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/models/simulation_result.dart';
import 'package:ibiti_guardian/models/rpc_simulation_result.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/services/policy/guardian_policy_engine.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/swap/swap_provider.dart'
    show SwapSlippagePolicy;

// ─── Helpers ─────────────────────────────────────────────────────────────────

IntentData _intent([String raw = 'test']) =>
    IntentData(type: IntentType.unknown, rawInput: raw);

/// The user's own Send / Swap window (wallet_send_modal / wallet_swap_modal).
const _walletSend = IntentData(
  type: IntentType.sendAsset,
  rawInput: 'send',
  origin: IntentOrigin.wallet,
);
const _walletSwap = IntentData(
  type: IntentType.swapAsset,
  rawInput: 'swap',
  origin: IntentOrigin.wallet,
);

/// The AI (chat, voice, market chat) — origin market, the default.
const _aiSend = IntentData(type: IntentType.sendAsset, rawInput: 'send');
const _aiSwap = IntentData(type: IntentType.swapAsset, rawInput: 'swap');

/// The user's own Buy / Sell window (wallet_trade_modal): a trade (origin
/// market) marked as the user's own window.
const _tradeWindowSwap = IntentData(
  type: IntentType.swapAsset,
  rawInput: 'swap',
  userTradeWindow: true,
);

/// «Советник» after the emergency stop: mode manual, no AI permissions.
AiControlSettings _emergencyStopped() =>
    const AiControlSettings(mode: AiMode.manual, allowedActions: []);

/// Default AI settings: guarded mode with all relevant actions allowed.
AiControlSettings _guardedSettings({
  List<AiAction>? allowedActions,
  AiMode mode = AiMode.guarded,
}) {
  return AiControlSettings(
    mode: mode,
    allowedActions: allowedActions ??
        const [
          AiAction.send,
          AiAction.swap,
          AiAction.approve,
          AiAction.revoke,
          AiAction.openWindows,
          AiAction.closeWindows,
          AiAction.contactPayments,
          AiAction.scheduledActions,
        ],
  );
}

TransactionRequest _sendTx({
  double? amount,
  String toAddress = '0xRecipient',
  IntentData? intent,
}) {
  return TransactionRequest(
    type: TransactionType.send,
    fromAddress: '0xSender',
    toAddress: toAddress,
    amount: amount,
    chainId: 56,
    chainKey: 'bsc',
    sourceIntent: intent ?? _intent(),
  );
}

TransactionRequest _swapTx({
  double? amount,
  Map<String, dynamic>? quoteSummary,
  String? routerAddress,
  IntentData? intent,
}) {
  return TransactionRequest(
    type: TransactionType.swap,
    fromAddress: '0xSender',
    toAddress: '0xRouter',
    amount: amount,
    chainId: 56,
    chainKey: 'bsc',
    tokenSymbol: 'USDT',
    targetTokenSymbol: 'BNB',
    routerAddress: routerAddress,
    quoteSummary: quoteSummary,
    sourceIntent: intent ?? _intent(),
  );
}

TransactionRequest _approveTx({
  double? amount,
  bool isUnlimited = false,
  String? spenderAddress,
  IntentData? intent,
}) {
  return TransactionRequest(
    type: TransactionType.approve,
    fromAddress: '0xSender',
    toAddress: '0xContract',
    amount: amount,
    isUnlimitedApproval: isUnlimited,
    spenderAddress: spenderAddress,
    chainId: 56,
    chainKey: 'bsc',
    sourceIntent: intent ?? _intent(),
  );
}

TransactionRequest _revokeTx() {
  return TransactionRequest(
    type: TransactionType.revoke,
    fromAddress: '0xSender',
    toAddress: '0xContract',
    chainId: 56,
    chainKey: 'bsc',
    sourceIntent: _intent(),
  );
}

TransactionRequest _unknownTx() {
  return TransactionRequest(
    type: TransactionType.unknown,
    fromAddress: '0xSender',
    toAddress: '0xDest',
    chainId: 56,
    chainKey: 'bsc',
    sourceIntent: _intent(),
  );
}

SimulationResult _cleanSim() => SimulationResult.clean();

SimulationResult _criticalSim() => const SimulationResult(
      risk: SimulationRisk.critical,
      flags: [],
    );

SimulationResult _warningSim() => const SimulationResult(
      risk: SimulationRisk.warning,
      flags: [],
    );

SimulationResult _unknownContractSim() => const SimulationResult(
      risk: SimulationRisk.safe,
      flags: [SimulationFlag.unknownContract],
    );

RpcSimulationResult _rpcOk() => RpcSimulationResult.ok();
RpcSimulationResult _rpcRevert([String reason = 'execution reverted']) =>
    RpcSimulationResult.revert(reason);

PolicyProfile _safeProfile() => PolicyProfile.safe();
PolicyProfile _defiProfile() => PolicyProfile.defi();

// ─── Tests ───────────────────────────────────────────────────────────────────

void main() {
  // Reset singleton state before each test so AI gate checks are predictable.
  setUp(() {
    AiControlService.instance.setSettingsForTest(_guardedSettings());
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 1. «Советник» (code name manual) → blocks every AI / market transaction
  //    (the user's own wallet window: see 2b)
  // ═══════════════════════════════════════════════════════════════════════════
  group('AI Mode Gate', () {
    test('manual mode blocks any transaction type', () {
      AiControlService.instance.setSettingsForTest(
        _guardedSettings(mode: AiMode.manual),
      );

      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 10),
        _cleanSim(),
        _rpcOk(),
        _safeProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isTrue, reason: 'Manual mode must block');
      expect(result.allowed, isFalse);
      expect(result.appliedRules, contains('AI_MODE_MANUAL_BLOCK'));
      expect(result.severity, equals(PolicySeverity.warning));
    });

    test('manual mode blocks swap transactions too', () {
      AiControlService.instance.setSettingsForTest(
        _guardedSettings(mode: AiMode.manual),
      );

      final result = GuardianPolicyEngine.checkV3(
        _swapTx(amount: 100),
        _cleanSim(),
        _rpcOk(),
        _defiProfile(),
        ExecutionPath.epkProtected,
      );

      expect(result.blocked, isTrue);
      expect(result.appliedRules, contains('AI_MODE_MANUAL_BLOCK'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 2. Action not in allowedActions → blocks
  // ═══════════════════════════════════════════════════════════════════════════
  group('Allowed Actions Check', () {
    test('send blocked when not in allowedActions', () {
      AiControlService.instance.setSettingsForTest(
        _guardedSettings(allowedActions: [AiAction.swap, AiAction.approve]),
      );

      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 10),
        _cleanSim(),
        _rpcOk(),
        _safeProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isTrue);
      expect(result.appliedRules, contains('AI_ACTION_NOT_ALLOWED'));
    });

    test('swap blocked when not in allowedActions', () {
      AiControlService.instance.setSettingsForTest(
        _guardedSettings(allowedActions: [AiAction.send]),
      );

      final result = GuardianPolicyEngine.checkV3(
        _swapTx(amount: 10),
        _cleanSim(),
        _rpcOk(),
        _defiProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isTrue);
      expect(result.appliedRules, contains('AI_ACTION_NOT_ALLOWED'));
    });

    test('unknown tx type bypasses action check (no AiAction mapping)', () {
      AiControlService.instance.setSettingsForTest(
        _guardedSettings(allowedActions: []),
      );

      final result = GuardianPolicyEngine.checkV3(
        _unknownTx(),
        _cleanSim(),
        _rpcOk(),
        _safeProfile(),
        ExecutionPath.localProtected,
      );

      // Unknown type → no AiAction mapping → skips action gate → blocked by
      // TransactionType.unknown handler at the bottom of checkV3.
      expect(result.blocked, isTrue);
      expect(result.appliedRules, isNot(contains('AI_ACTION_NOT_ALLOWED')));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 2a. The user's own Buy / Sell window (origin market + userTradeWindow):
  //     only the AI mode and the AI permissions (Check 0 / 0b) are skipped;
  //     the trading limits of GuardianExecutionController and every wallet
  //     check here still apply (test/screens/wallet/
  //     wallet_trade_modal_origin_test.dart covers the trading limits).
  // ═══════════════════════════════════════════════════════════════════════════
  group('User Buy / Sell window (origin market, userTradeWindow)', () {
    PolicyResult check(TransactionRequest tx) => GuardianPolicyEngine.checkV3(
          tx,
          _cleanSim(),
          _rpcOk(),
          _safeProfile(),
          ExecutionPath.localProtected,
        );

    test('isUserTradeWindowTx: only the window\'s swap steps', () {
      expect(
          GuardianPolicyEngine.isUserTradeWindowTx(
              _swapTx(amount: 1, intent: _tradeWindowSwap)),
          isTrue);
      expect(
          GuardianPolicyEngine.isUserTradeWindowTx(_approveTx(
              amount: 1, spenderAddress: '0xSpender', intent: _tradeWindowSwap)),
          isTrue);
      // Never the Send / Swap window: the trading limits stay.
      expect(
          GuardianPolicyEngine.isUserWalletTx(
              _swapTx(amount: 1, intent: _tradeWindowSwap)),
          isFalse);
      // The AI's swap, automation claiming the marker, a marked send.
      expect(
          GuardianPolicyEngine.isUserTradeWindowTx(
              _swapTx(amount: 1, intent: _aiSwap)),
          isFalse);
      expect(
        GuardianPolicyEngine.isUserTradeWindowTx(_swapTx(
          amount: 1,
          intent: const IntentData(
            type: IntentType.swapAsset,
            rawInput: '_AUTO_ swap',
            sourceTrigger: 'rule_1',
            userTradeWindow: true,
          ),
        )),
        isFalse,
      );
      expect(
        GuardianPolicyEngine.isUserTradeWindowTx(_sendTx(
          amount: 1,
          intent: const IntentData(
            type: IntentType.sendAsset,
            rawInput: 'send',
            userTradeWindow: true,
          ),
        )),
        isFalse,
      );
    });

    test('«Советник» / emergency stop / AI permissions off: it passes', () {
      for (final settings in [
        _guardedSettings(mode: AiMode.manual),
        _emergencyStopped(),
        _guardedSettings(allowedActions: []),
      ]) {
        AiControlService.instance.setSettingsForTest(settings);
        final swap = check(_swapTx(
          amount: 100,
          quoteSummary: {'slippageBps': 50},
          intent: _tradeWindowSwap,
        ));
        final approve = check(_approveTx(
          amount: 50,
          spenderAddress: '0xSpender',
          intent: _tradeWindowSwap,
        ));
        for (final r in [swap, approve]) {
          expect(r.blocked, isFalse, reason: '${settings.mode} ${r.reason}');
          expect(r.appliedRules, contains('USER_TRADE_WINDOW'));
          expect(r.appliedRules, isNot(contains('USER_WALLET_ORIGIN')));
          expect(r.appliedRules, isNot(contains('AI_MODE_MANUAL_BLOCK')));
          expect(r.appliedRules, isNot(contains('AI_ACTION_NOT_ALLOWED')));
        }

        // The AI's swap (origin market, no marker) is still blocked.
        final ai = check(_swapTx(
          amount: 100,
          quoteSummary: {'slippageBps': 50},
          intent: _aiSwap,
        ));
        expect(ai.blocked, isTrue, reason: settings.mode.name);
        expect(ai.appliedRules, isNot(contains('USER_TRADE_WINDOW')));
      }
    });

    test('the swap limit and the slippage cap still hold', () {
      AiControlService.instance
          .setSettingsForTest(_guardedSettings(mode: AiMode.manual));

      final overLimit = check(_swapTx(
        amount: 600, // safe profile swap limit is 500
        quoteSummary: {'slippageBps': 50},
        intent: _tradeWindowSwap,
      ));
      final overSlippage = check(_swapTx(
        amount: 10,
        quoteSummary: {'slippageBps': SwapSlippagePolicy.maxBps + 1},
        intent: _tradeWindowSwap,
      ));

      expect(overLimit.blocked, isTrue);
      expect(overLimit.appliedRules, contains('SWAP_PROFILE_LIMIT_EXCEEDED'));
      expect(overSlippage.blocked, isTrue);
      expect(overSlippage.appliedRules, contains('SWAP_SLIPPAGE_CAP_EXCEEDED'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 2b. The user's own wallet window (origin wallet) is not the AI (D2): the
  //     AI mode and the AI permissions never stop it; the wallet limits do.
  // ═══════════════════════════════════════════════════════════════════════════
  group('User wallet window (origin wallet)', () {
    PolicyResult check(
      TransactionRequest tx, {
      SimulationResult? sim,
      RpcSimulationResult? rpc,
      PolicyProfile? profile,
      ExecutionPath path = ExecutionPath.localProtected,
    }) =>
        GuardianPolicyEngine.checkV3(
          tx,
          sim ?? _cleanSim(),
          rpc ?? _rpcOk(),
          profile ?? _safeProfile(),
          path,
        );

    test('isUserWalletTx: only the wallet window, never automation', () {
      expect(
          GuardianPolicyEngine.isUserWalletTx(
              _sendTx(amount: 1, intent: _walletSend)),
          isTrue);
      expect(
          GuardianPolicyEngine.isUserWalletTx(
              _swapTx(amount: 1, intent: _walletSwap)),
          isTrue);
      expect(
          GuardianPolicyEngine.isUserWalletTx(
              _sendTx(amount: 1, intent: _aiSend)),
          isFalse);
      expect(GuardianPolicyEngine.isUserWalletTx(_sendTx(amount: 1)), isFalse);
      // An automation intent that claims the wallet origin is still the AI.
      expect(
        GuardianPolicyEngine.isUserWalletTx(_sendTx(
          amount: 1,
          intent: const IntentData(
            type: IntentType.sendAsset,
            rawInput: '_AUTO_ send',
            origin: IntentOrigin.wallet,
            sourceTrigger: 'rule_1',
          ),
        )),
        isFalse,
      );
    });

    test('«Советник»: the own send within the send limit is allowed', () {
      AiControlService.instance
          .setSettingsForTest(_guardedSettings(mode: AiMode.manual));

      final result = check(_sendTx(amount: 10, intent: _walletSend));

      expect(result.blocked, isFalse);
      expect(result.allowed, isTrue);
      expect(result.requiresConfirmation, isTrue);
      expect(result.appliedRules, contains('USER_WALLET_ORIGIN'));
      expect(result.appliedRules, contains('SEND_STANDARD_CONFIRM'));
      expect(result.appliedRules, isNot(contains('AI_MODE_MANUAL_BLOCK')));
    });

    test('«Советник»: the own swap within the swap limit is allowed', () {
      AiControlService.instance
          .setSettingsForTest(_guardedSettings(mode: AiMode.manual));

      final result = check(_swapTx(
        amount: 100,
        quoteSummary: {'slippageBps': 50},
        intent: _walletSwap,
      ));

      expect(result.blocked, isFalse);
      expect(result.appliedRules, contains('SWAP_STANDARD_CONFIRM'));
      expect(result.appliedRules, isNot(contains('AI_MODE_MANUAL_BLOCK')));
    });

    test('«Советник»: the approve step of the own swap is allowed', () {
      AiControlService.instance
          .setSettingsForTest(_guardedSettings(mode: AiMode.manual));

      final result = check(_approveTx(
        amount: 50,
        spenderAddress: '0xSpender',
        intent: _walletSwap,
      ));

      expect(result.blocked, isFalse);
      expect(result.appliedRules, contains('APPROVE_CONFIRM'));
    });

    test('after the emergency stop the own send and swap still work', () {
      AiControlService.instance.setSettingsForTest(_emergencyStopped());

      final send = check(_sendTx(amount: 10, intent: _walletSend));
      final swap = check(_swapTx(
        amount: 100,
        quoteSummary: {'slippageBps': 50},
        intent: _walletSwap,
      ));

      expect(send.blocked, isFalse);
      expect(send.appliedRules, isNot(contains('AI_MODE_MANUAL_BLOCK')));
      expect(send.appliedRules, isNot(contains('AI_ACTION_NOT_ALLOWED')));
      expect(swap.blocked, isFalse);
      expect(swap.appliedRules, isNot(contains('AI_MODE_MANUAL_BLOCK')));
      expect(swap.appliedRules, isNot(contains('AI_ACTION_NOT_ALLOWED')));
    });

    test('AI permissions off: the own send passes, the AI send is blocked',
        () {
      AiControlService.instance
          .setSettingsForTest(_guardedSettings(allowedActions: []));

      final own = check(_sendTx(amount: 10, intent: _walletSend));
      final ai = check(_sendTx(amount: 10, intent: _aiSend));

      expect(own.blocked, isFalse);
      expect(own.appliedRules, isNot(contains('AI_ACTION_NOT_ALLOWED')));
      expect(ai.blocked, isTrue);
      expect(ai.appliedRules, contains('AI_ACTION_NOT_ALLOWED'));
    });

    test('«Советник»: the AI send and swap are still blocked', () {
      AiControlService.instance
          .setSettingsForTest(_guardedSettings(mode: AiMode.manual));

      final send = check(_sendTx(amount: 10, intent: _aiSend));
      final swap = check(_swapTx(
        amount: 100,
        quoteSummary: {'slippageBps': 50},
        intent: _aiSwap,
      ));

      expect(send.blocked, isTrue);
      expect(send.appliedRules, contains('AI_MODE_MANUAL_BLOCK'));
      expect(send.appliedRules, isNot(contains('USER_WALLET_ORIGIN')));
      expect(swap.blocked, isTrue);
      expect(swap.appliedRules, contains('AI_MODE_MANUAL_BLOCK'));
    });

    test('«Советник»: automation claiming the wallet origin is still blocked',
        () {
      AiControlService.instance
          .setSettingsForTest(_guardedSettings(mode: AiMode.manual));

      final result = check(_sendTx(
        amount: 10,
        intent: const IntentData(
          type: IntentType.sendAsset,
          rawInput: '_AUTO_ send',
          origin: IntentOrigin.wallet,
          sourceTrigger: 'rule_1',
        ),
      ));

      expect(result.blocked, isTrue);
      expect(result.appliedRules, contains('AI_MODE_MANUAL_BLOCK'));
    });

    test('the own send still obeys the send limit (in every mode)', () {
      for (final settings in [
        _guardedSettings(),
        _guardedSettings(mode: AiMode.manual),
        _emergencyStopped(),
      ]) {
        AiControlService.instance.setSettingsForTest(settings);
        final result = check(_sendTx(amount: 100, intent: _walletSend));
        expect(result.blocked, isTrue, reason: settings.mode.name);
        expect(result.appliedRules, contains('PROFILE_LIMIT_EXCEEDED'));
      }
    });

    test('the own swap still obeys the swap limit and the slippage cap', () {
      AiControlService.instance.setSettingsForTest(_emergencyStopped());

      final overLimit = check(_swapTx(
        amount: 600, // safe profile swap limit is 500
        quoteSummary: {'slippageBps': 50},
        intent: _walletSwap,
      ));
      final overSlippage = check(_swapTx(
        amount: 10,
        quoteSummary: {'slippageBps': SwapSlippagePolicy.maxBps + 1},
        intent: _walletSwap,
      ));

      expect(overLimit.blocked, isTrue);
      expect(overLimit.appliedRules, contains('SWAP_PROFILE_LIMIT_EXCEEDED'));
      expect(overSlippage.blocked, isTrue);
      expect(overSlippage.appliedRules, contains('SWAP_SLIPPAGE_CAP_EXCEEDED'));
    });

    test('the own approve: unlimited and unknown contracts still blocked', () {
      AiControlService.instance.setSettingsForTest(_emergencyStopped());

      final unlimited =
          check(_approveTx(isUnlimited: true, intent: _walletSwap));
      final unknown = check(
        _approveTx(
          amount: 10,
          spenderAddress: '0xUnknownSpender',
          intent: _walletSwap,
        ),
        sim: _unknownContractSim(),
      );

      expect(unlimited.blocked, isTrue);
      expect(unlimited.appliedRules, contains('APPROVE_LIMIT_EXCEEDED'));
      expect(unknown.blocked, isTrue);
      expect(unknown.appliedRules, contains('PROFILE_UNKNOWN_CONTRACT_DENIED'));
    });

    test('the own send: simulation and critical risk still block', () {
      AiControlService.instance.setSettingsForTest(_emergencyStopped());

      final reverted = check(
        _sendTx(amount: 10, intent: _walletSend),
        rpc: _rpcRevert('ERC20: transfer amount exceeds balance'),
      );
      final critical = check(
        _sendTx(amount: 10, toAddress: '0xUntrusted', intent: _walletSend),
        sim: _criticalSim(),
      );

      expect(reverted.blocked, isTrue);
      expect(reverted.appliedRules, contains('RPC_REVERT_DETECTED'));
      expect(critical.blocked, isTrue);
      expect(critical.appliedRules, contains('STATIC_CRITICAL_BLOCK'));
    });

    test('the own send over \$1000 still needs EPK', () {
      AiControlService.instance.setSettingsForTest(_emergencyStopped());

      final result = check(
        _sendTx(amount: 1500, intent: _walletSend),
        profile: _defiProfile().copyWith(sendLimitUsd: 5000),
      );

      expect(result.blocked, isTrue);
      expect(result.appliedRules, contains('EPK_REQUIRED_UNAVAILABLE'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 3. (Removed) The generic AI per-transaction limit was retired — each action
  //    type is now bounded by its own send/swap/approve limit instead.
  // ═══════════════════════════════════════════════════════════════════════════
  // 4. RPC simulation failure → blocks
  // ═══════════════════════════════════════════════════════════════════════════
  group('RPC Simulation', () {
    test('rpc revert blocks the transaction', () {
      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 10),
        _cleanSim(),
        _rpcRevert('ERC20: transfer amount exceeds balance'),
        _defiProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isTrue);
      expect(result.appliedRules, contains('RPC_REVERT_DETECTED'));
      expect(result.reason, contains('ERC20: transfer amount exceeds balance'));
    });

    test('rpc revert without reason still blocks', () {
      final rpc = const RpcSimulationResult(success: false);

      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 10),
        _cleanSim(),
        rpc,
        _defiProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isTrue);
      expect(result.reason, contains('Execution reverted.'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 5. Static critical risk (untrusted) → blocks
  // ═══════════════════════════════════════════════════════════════════════════
  group('Static Critical Risk', () {
    test('critical risk with untrusted address blocks', () {
      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 10, toAddress: '0xUntrustedAddr'),
        _criticalSim(),
        _rpcOk(),
        _safeProfile(), // trustedAddresses is empty
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isTrue);
      expect(result.appliedRules, contains('STATIC_CRITICAL_BLOCK'));
      expect(result.severity, equals(PolicySeverity.danger));
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 6. Static critical risk + trusted address → downgrades to warning
    // ═════════════════════════════════════════════════════════════════════════
    test('critical risk with trusted address downgrades and continues', () {
      final profile = _safeProfile().copyWith(
        trustedAddresses: ['0xtrustedaddr'], // lowercase for matching
        sendLimitUsd: 10000,
      );

      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 10, toAddress: '0xTrustedAddr'), // mixed case
        _criticalSim(),
        _rpcOk(),
        profile,
        ExecutionPath.localProtected,
      );

      // Should NOT be blocked — downgraded to warning and continued.
      expect(result.blocked, isFalse);
      expect(result.appliedRules, contains('STATIC_CRITICAL_TRUST_DOWNGRADE'));
      expect(result.appliedRules, isNot(contains('STATIC_CRITICAL_BLOCK')));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 7. Send amount exceeds profile limit → blocks
  // ═══════════════════════════════════════════════════════════════════════════
  group('Send V3', () {
    test('send exceeding profile sendLimitUsd blocks', () {
      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 100), // safe profile limit is 50
        _cleanSim(),
        _rpcOk(),
        _safeProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isTrue);
      expect(result.appliedRules, contains('PROFILE_LIMIT_EXCEEDED'));
    });

    test('send at exactly the profile limit is NOT blocked', () {
      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 50), // safe profile limit is 50
        _cleanSim(),
        _rpcOk(),
        _safeProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isFalse);
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 8. Send with static warning → requires confirmation with danger severity
    // ═════════════════════════════════════════════════════════════════════════
    test('send with static warning requires danger confirmation', () {
      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 10),
        _warningSim(),
        _rpcOk(),
        _safeProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isFalse);
      expect(result.requiresConfirmation, isTrue);
      expect(result.severity, equals(PolicySeverity.danger));
      expect(result.appliedRules, contains('STATIC_WARNING_CONFIRM'));
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 9. Send standard → requires confirmation with info severity
    // ═════════════════════════════════════════════════════════════════════════
    test('clean send requires standard confirmation', () {
      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 10),
        _cleanSim(),
        _rpcOk(),
        _safeProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isFalse);
      expect(result.requiresConfirmation, isTrue);
      expect(result.severity, equals(PolicySeverity.info));
      expect(result.appliedRules, contains('SEND_STANDARD_CONFIRM'));
    });

    test('send > \$1000 marks epkRequired', () {
      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 1500),
        _cleanSim(),
        _rpcOk(),
        _defiProfile(), // sendLimitUsd = 1000 → need higher
        ExecutionPath.epkProtected,
      );

      // amount 1500 > 1000 threshold → epkRequired should be true
      // But profile limit is 1000, amount 1500 > 1000 → blocks by profile limit
      // Use a custom profile with higher limit
      final customProfile = _defiProfile().copyWith(sendLimitUsd: 5000);

      final result2 = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 1500),
        _cleanSim(),
        _rpcOk(),
        customProfile,
        ExecutionPath.epkProtected,
      );

      expect(result2.epkRequired, isTrue);
      expect(result2.epkAvailable, isTrue,
          reason: 'EPK path → epkAvailable should be true');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 10. Swap slippage exceeds cap → blocks
  // ═══════════════════════════════════════════════════════════════════════════
  group('Swap V3', () {
    test('swap slippage exceeding maxBps blocks', () {
      final result = GuardianPolicyEngine.checkV3(
        _swapTx(
          amount: 10,
          quoteSummary: {'slippageBps': SwapSlippagePolicy.maxBps + 1},
        ),
        _cleanSim(),
        _rpcOk(),
        _defiProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isTrue);
      expect(result.appliedRules, contains('SWAP_SLIPPAGE_CAP_EXCEEDED'));
    });

    test('swap slippage at exactly maxBps is NOT blocked', () {
      final result = GuardianPolicyEngine.checkV3(
        _swapTx(
          amount: 10,
          quoteSummary: {'slippageBps': SwapSlippagePolicy.maxBps},
        ),
        _cleanSim(),
        _rpcOk(),
        _defiProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.appliedRules, isNot(contains('SWAP_SLIPPAGE_CAP_EXCEEDED')),
          reason: 'Exact boundary should pass');
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 11. Swap amount exceeds profile limit → blocks
    // ═════════════════════════════════════════════════════════════════════════
    test('swap exceeding profile swapLimitUsd blocks', () {
      final result = GuardianPolicyEngine.checkV3(
        _swapTx(amount: 600),
        _cleanSim(),
        _rpcOk(),
        _safeProfile(), // swapLimitUsd = 500
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isTrue);
      expect(result.appliedRules, contains('SWAP_PROFILE_LIMIT_EXCEEDED'));
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 12. Swap high price impact (>5%) → danger confirmation
    // ═════════════════════════════════════════════════════════════════════════
    test('swap high price impact (>5%) returns danger confirmation', () {
      final result = GuardianPolicyEngine.checkV3(
        _swapTx(
          amount: 100,
          quoteSummary: {'priceImpactPct': 7.5, 'slippageBps': 50},
        ),
        _cleanSim(),
        _rpcOk(),
        _defiProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isFalse);
      expect(result.requiresConfirmation, isTrue);
      expect(result.severity, equals(PolicySeverity.danger));
      expect(result.appliedRules, contains('SWAP_HIGH_PRICE_IMPACT'));
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 13. Swap moderate price impact (1-5%) → warning confirmation
    // ═════════════════════════════════════════════════════════════════════════
    test('swap moderate price impact (1-5%) returns warning confirmation', () {
      final result = GuardianPolicyEngine.checkV3(
        _swapTx(
          amount: 100,
          quoteSummary: {'priceImpactPct': 3.0, 'slippageBps': 50},
        ),
        _cleanSim(),
        _rpcOk(),
        _defiProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isFalse);
      expect(result.requiresConfirmation, isTrue);
      expect(result.severity, equals(PolicySeverity.warning));
      expect(result.appliedRules, contains('SWAP_MODERATE_PRICE_IMPACT'));
      expect(result.appliedRules, contains('SWAP_STANDARD_CONFIRM'));
    });

    test('swap with no price impact has info severity', () {
      final result = GuardianPolicyEngine.checkV3(
        _swapTx(
          amount: 100,
          quoteSummary: {'priceImpactPct': 0.5, 'slippageBps': 50},
        ),
        _cleanSim(),
        _rpcOk(),
        _defiProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.severity, equals(PolicySeverity.info));
      expect(result.appliedRules, contains('SWAP_STANDARD_CONFIRM'));
      expect(result.appliedRules, isNot(contains('SWAP_MODERATE_PRICE_IMPACT')));
    });

    test('swap with null quoteSummary treats slippage/impact as zero', () {
      final result = GuardianPolicyEngine.checkV3(
        _swapTx(amount: 100, quoteSummary: null),
        _cleanSim(),
        _rpcOk(),
        _defiProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isFalse);
      expect(result.appliedRules, contains('SWAP_STANDARD_CONFIRM'));
    });

    test('swap > \$1000 marks epkRequired', () {
      final customProfile = _defiProfile().copyWith(swapLimitUsd: 5000);

      final result = GuardianPolicyEngine.checkV3(
        _swapTx(amount: 1500, quoteSummary: {'slippageBps': 50}),
        _cleanSim(),
        _rpcOk(),
        customProfile,
        ExecutionPath.epkProtected,
      );

      expect(result.epkRequired, isTrue);
    });

    test('swap unknown router adds warning rule', () {
      final profile = _safeProfile(); // allowUnknownContracts = false

      final result = GuardianPolicyEngine.checkV3(
        _swapTx(
          amount: 100,
          routerAddress: '0xUnknownRouter',
          quoteSummary: {'slippageBps': 50},
        ),
        _cleanSim(),
        _rpcOk(),
        profile,
        ExecutionPath.localProtected,
      );

      expect(result.appliedRules, contains('SWAP_UNKNOWN_ROUTER_WARN'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 14. Approve unlimited when disabled → blocks
  // ═══════════════════════════════════════════════════════════════════════════
  group('Approve V3', () {
    test('unlimited approve is always blocked by the approve limit', () {
      final result = GuardianPolicyEngine.checkV3(
        _approveTx(isUnlimited: true),
        _cleanSim(),
        _rpcOk(),
        _safeProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isTrue);
      expect(result.appliedRules, contains('APPROVE_LIMIT_EXCEEDED'));
    });

    test('unlimited approve blocked even on a permissive profile', () {
      // The old allowUnlimitedApprove escape hatch was removed: an infinite
      // allowance always exceeds the approve limit, so it is always blocked.
      final result = GuardianPolicyEngine.checkV3(
        _approveTx(isUnlimited: true),
        _cleanSim(),
        _rpcOk(),
        _defiProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isTrue);
      expect(result.appliedRules, contains('APPROVE_LIMIT_EXCEEDED'));
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 15. Approve amount exceeds profile limit → blocks
    // ═════════════════════════════════════════════════════════════════════════
    test('approve exceeding profile approveLimitUsd blocks', () {
      final result = GuardianPolicyEngine.checkV3(
        _approveTx(amount: 200), // safe profile limit is 100
        _cleanSim(),
        _rpcOk(),
        _safeProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isTrue);
      expect(result.appliedRules, contains('APPROVE_LIMIT_EXCEEDED'));
    });

    test('approve at profile limit is NOT blocked', () {
      final result = GuardianPolicyEngine.checkV3(
        _approveTx(amount: 100),
        _cleanSim(),
        _rpcOk(),
        _safeProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isFalse);
      expect(result.appliedRules, contains('APPROVE_CONFIRM'));
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 16. Approve unknown contract when disabled → blocks
    // ═════════════════════════════════════════════════════════════════════════
    test('approve unknown contract blocked when profile disallows', () {
      final result = GuardianPolicyEngine.checkV3(
        _approveTx(amount: 10, spenderAddress: '0xUnknownSpender'),
        _unknownContractSim(),
        _rpcOk(),
        _safeProfile(), // allowUnknownContracts = false
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isTrue);
      expect(result.appliedRules, contains('PROFILE_UNKNOWN_CONTRACT_DENIED'));
    });

    test('approve unknown contract passes when contract is trusted', () {
      final profile = _safeProfile().copyWith(
        trustedContracts: ['0xknownspender'],
      );

      final result = GuardianPolicyEngine.checkV3(
        _approveTx(amount: 10, spenderAddress: '0xKnownSpender'),
        _unknownContractSim(),
        _rpcOk(),
        profile,
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isFalse);
      expect(result.appliedRules, contains('APPROVE_CONFIRM'));
    });

    test('approve unknown contract passes when profile allows unknowns', () {
      final result = GuardianPolicyEngine.checkV3(
        _approveTx(amount: 10, spenderAddress: '0xRandom'),
        _unknownContractSim(),
        _rpcOk(),
        _defiProfile(), // allowUnknownContracts = true
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isFalse);
    });

    test('approve standard flow requires confirmation', () {
      final result = GuardianPolicyEngine.checkV3(
        _approveTx(amount: 50),
        _cleanSim(),
        _rpcOk(),
        _safeProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.requiresConfirmation, isTrue);
      expect(result.severity, equals(PolicySeverity.warning));
      expect(result.appliedRules, contains('APPROVE_CONFIRM'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 17. Revoke → always confirmation
  // ═══════════════════════════════════════════════════════════════════════════
  group('Revoke V3', () {
    test('revoke always returns confirmation', () {
      final result = GuardianPolicyEngine.checkV3(
        _revokeTx(),
        _cleanSim(),
        _rpcOk(),
        _safeProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isFalse);
      expect(result.requiresConfirmation, isTrue);
      expect(result.severity, equals(PolicySeverity.warning));
      expect(result.appliedRules, contains('REVOKE_CONFIRM'));
    });

    test('revoke ignores static simulation state', () {
      // Even with a critical sim, revoke should just confirm because
      // it reaches _checkRevokeV3() — but note: critical sim would be
      // caught earlier by Check 2 unless address is trusted.
      // So we use a clean sim here and verify the revoke path always confirms.
      final result = GuardianPolicyEngine.checkV3(
        _revokeTx(),
        _cleanSim(),
        _rpcOk(),
        _defiProfile(),
        ExecutionPath.epkProtected,
      );

      expect(result.requiresConfirmation, isTrue);
      expect(result.appliedRules, contains('REVOKE_CONFIRM'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 18. Unknown transaction type → blocks
  // ═══════════════════════════════════════════════════════════════════════════
  group('Unknown TX Type', () {
    test('unknown transaction type is blocked', () {
      final result = GuardianPolicyEngine.checkV3(
        _unknownTx(),
        _cleanSim(),
        _rpcOk(),
        _safeProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isTrue);
      expect(result.reason, contains('Unknown transaction type'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 19. EPK enforcement: result needs EPK but EPK unavailable → blocks
  // ═══════════════════════════════════════════════════════════════════════════
  group('EPK Enforcement', () {
    test('epkRequired + localProtected path blocks (EPK unavailable)', () {
      // Send > $1000 requires EPK; localProtected means epkAvailable = false.
      final profile = _defiProfile().copyWith(sendLimitUsd: 5000);

      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 1500),
        _cleanSim(),
        _rpcOk(),
        profile,
        ExecutionPath.localProtected, // ← NOT epkProtected
      );

      expect(result.blocked, isTrue);
      expect(result.appliedRules, contains('EPK_REQUIRED_UNAVAILABLE'));
      expect(result.epkRequired, isTrue);
      expect(result.epkAvailable, isFalse);
    });

    test('epkRequired + epkProtected path passes', () {
      final profile = _defiProfile().copyWith(sendLimitUsd: 5000);

      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 1500),
        _cleanSim(),
        _rpcOk(),
        profile,
        ExecutionPath.epkProtected, // ← EPK is available
      );

      expect(result.blocked, isFalse);
      expect(result.requiresConfirmation, isTrue);
      expect(result.epkRequired, isTrue);
      expect(result.epkAvailable, isTrue);
    });

    test('amount <= \$1000 does not require EPK', () {
      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 500),
        _cleanSim(),
        _rpcOk(),
        _defiProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isFalse);
      expect(result.epkRequired, isFalse);
    });

    test('EPK enforcement on swap: > \$1000 on local path blocks', () {
      final profile = _defiProfile().copyWith(swapLimitUsd: 5000);

      final result = GuardianPolicyEngine.checkV3(
        _swapTx(amount: 2000, quoteSummary: {'slippageBps': 50}),
        _cleanSim(),
        _rpcOk(),
        profile,
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isTrue);
      expect(result.appliedRules, contains('EPK_REQUIRED_UNAVAILABLE'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Rule prefix: every result contains EVAL_<MODE> rule
  // ═══════════════════════════════════════════════════════════════════════════
  group('Applied Rules', () {
    test('result always contains EVAL_<MODE> rule tag', () {
      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 10),
        _cleanSim(),
        _rpcOk(),
        _safeProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.appliedRules, contains('EVAL_SAFE'));
    });

    test('defi profile includes EVAL_DEFI tag', () {
      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 10),
        _cleanSim(),
        _rpcOk(),
        _defiProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.appliedRules, contains('EVAL_DEFI'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Execution path: epkAvailable flag set correctly
  // ═══════════════════════════════════════════════════════════════════════════
  group('Execution Path', () {
    test('epkProtected path sets epkAvailable = true', () {
      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 10),
        _cleanSim(),
        _rpcOk(),
        _safeProfile(),
        ExecutionPath.epkProtected,
      );

      expect(result.epkAvailable, isTrue);
    });

    test('localProtected path sets epkAvailable = false', () {
      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 10),
        _cleanSim(),
        _rpcOk(),
        _safeProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.epkAvailable, isFalse);
    });

    test('fallback path sets epkAvailable = false', () {
      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 10),
        _cleanSim(),
        _rpcOk(),
        _safeProfile(),
        ExecutionPath.fallback,
      );

      expect(result.epkAvailable, isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Priority ordering: earlier gates take precedence
  // ═══════════════════════════════════════════════════════════════════════════
  group('Gate Priority', () {
    test('manual mode blocks before per-tx limit check', () {
      AiControlService.instance.setSettingsForTest(
        _guardedSettings(mode: AiMode.manual),
      );

      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 1000),
        _criticalSim(),
        _rpcRevert(),
        _safeProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.appliedRules, contains('AI_MODE_MANUAL_BLOCK'));
      expect(result.appliedRules, isNot(contains('AI_PER_TX_LIMIT_EXCEEDED')));
      expect(result.appliedRules, isNot(contains('RPC_REVERT_DETECTED')));
    });

    test('action not allowed blocks before RPC check', () {
      AiControlService.instance.setSettingsForTest(
        _guardedSettings(allowedActions: []),
      );

      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 10),
        _criticalSim(),
        _rpcRevert(),
        _safeProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.appliedRules, contains('AI_ACTION_NOT_ALLOWED'));
      expect(result.appliedRules, isNot(contains('RPC_REVERT_DETECTED')));
    });

    test('RPC revert blocks before static critical check', () {
      final result = GuardianPolicyEngine.checkV3(
        _sendTx(amount: 10),
        _criticalSim(),
        _rpcRevert(),
        _safeProfile(),
        ExecutionPath.localProtected,
      );

      expect(result.appliedRules, contains('RPC_REVERT_DETECTED'));
      expect(result.appliedRules, isNot(contains('STATIC_CRITICAL_BLOCK')));
    });
  });
}
