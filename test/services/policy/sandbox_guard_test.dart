// Unit tests for SandboxGuard.evaluate()
//
// Run: flutter test test/services/policy/sandbox_guard_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/models/simulation_result.dart';
import 'package:ibiti_guardian/models/rpc_simulation_result.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/wallet_context.dart';
import 'package:ibiti_guardian/models/sandbox_decision.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/delegation_scope.dart';
import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/services/policy/sandbox_guard.dart';
import 'package:ibiti_guardian/services/policy/guardian_policy_engine.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';

// ─── Helpers ─────────────────────────────────────────────────────────────────

IntentData _intent([String raw = 'test']) =>
    IntentData(type: IntentType.unknown, rawInput: raw);

TransactionRequest _sendTx({
  double? amount,
  String toAddress = '0xRecipient',
  String chainKey = 'bsc',
  String? tokenSymbol,
  String? targetTokenSymbol,
  String? routerAddress,
  String? spenderAddress,
}) {
  return TransactionRequest(
    type: TransactionType.send,
    fromAddress: '0xSender',
    toAddress: toAddress,
    amount: amount,
    chainId: 56,
    chainKey: chainKey,
    tokenSymbol: tokenSymbol ?? 'BNB',
    targetTokenSymbol: targetTokenSymbol,
    routerAddress: routerAddress,
    spenderAddress: spenderAddress,
    sourceIntent: _intent(),
  );
}

TransactionRequest _swapTx({
  double? amount,
  String chainKey = 'bsc',
  String tokenSymbol = 'USDT',
  String? targetTokenSymbol = 'BNB',
  String? routerAddress = '0xRouter',
  String? spenderAddress,
}) {
  return TransactionRequest(
    type: TransactionType.swap,
    fromAddress: '0xSender',
    toAddress: '0xRouter',
    amount: amount,
    chainId: 56,
    chainKey: chainKey,
    tokenSymbol: tokenSymbol,
    targetTokenSymbol: targetTokenSymbol,
    routerAddress: routerAddress,
    spenderAddress: spenderAddress,
    sourceIntent: _intent(),
  );
}

TransactionRequest _revokeTx({String chainKey = 'bsc'}) {
  return TransactionRequest(
    type: TransactionType.revoke,
    fromAddress: '0xSender',
    toAddress: '0xContract',
    chainId: 56,
    chainKey: chainKey,
    sourceIntent: _intent(),
  );
}

SimulationResult _cleanSim() => SimulationResult.clean();
RpcSimulationResult _rpcOk() => RpcSimulationResult.ok();
RpcSimulationResult _rpcRevert() => RpcSimulationResult.revert('reverted');

PolicyProfile _defiProfile() => PolicyProfile.defi();

WalletContext _normalWallet() => const WalletContext(
      address: '0xSender',
      chainId: 56,
      totalBalance: 1000.0,
      riskScore: 20,
    );

WalletContext _highRiskWallet() => const WalletContext(
      address: '0xSender',
      chainId: 56,
      totalBalance: 1000.0,
      riskScore: 80, // > 75 → isHighRisk
    );

PolicyResult _allowedPolicy() => PolicyResult.confirm(
      'Confirm the transaction.',
      severity: PolicySeverity.info,
      rules: const ['SEND_STANDARD_CONFIRM'],
    );

PolicyResult _blockedPolicy() => PolicyResult.block(
      'Blocked by policy.',
      rules: const ['SOME_BLOCK_RULE'],
    );

/// Sets up AiControlService with full autonomy and all actions enabled,
/// optionally with a custom mandate.
AiControlSettings _fullAutonomySettings({
  List<AiAction>? allowedActions,
  AutonomyMandate? mandate,
}) {
  return AiControlSettings(
    mode: AiMode.fullAutonomy,
    dailyLimit: 50000,
    allowedActions: allowedActions ?? AiAction.values,
    mandate: mandate ?? const AutonomyMandate(),
  );
}

/// Creates a valid, non-expired DelegationScope that authorizes SEND actions.
DelegationScope _validScope({
  double maxAmountUsd = 10000,
  List<String> allowedActions = const ['SEND', 'SWAP', 'REVOKE', 'APPROVE'],
}) {
  return DelegationScope(
    id: 'test-scope',
    maxAmountUsd: maxAmountUsd,
    allowedActions: allowedActions,
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
  );
}

// ─── Tests ───────────────────────────────────────────────────────────────────

void main() {
  final guard = SandboxGuard.instance;

  setUp(() {
    // Reset AI control to full autonomy with all actions, empty mandate.
    AiControlService.instance.setSettingsForTest(_fullAutonomySettings());
    // Reset delegation controller usage and set a valid scope.
    DelegationController.instance.resetUsageForTest();
    DelegationController.instance.store.setScope(_validScope());
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 1. Not fullAutonomy mode → manual
  // ═══════════════════════════════════════════════════════════════════════════
  group('Mode Gate', () {
    test('guarded mode returns manual review', () {
      AiControlService.instance.setSettingsForTest(
        const AiControlSettings(mode: AiMode.guarded),
      );

      final decision = guard.evaluate(
        tx: _sendTx(amount: 10),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.requireManualReview));
      expect(decision.reason, contains('manual confirmation'));
    });

    test('manual mode returns manual review', () {
      AiControlService.instance.setSettingsForTest(
        const AiControlSettings(mode: AiMode.manual),
      );

      final decision = guard.evaluate(
        tx: _sendTx(amount: 10),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.requireManualReview));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 2. scheduledActions not allowed → manual
  // ═══════════════════════════════════════════════════════════════════════════
  group('Scheduled Actions Gate', () {
    test('scheduledActions not in allowedActions returns manual', () {
      // Full autonomy but without scheduledActions
      AiControlService.instance.setSettingsForTest(_fullAutonomySettings(
        allowedActions: [
          AiAction.send,
          AiAction.swap,
          AiAction.approve,
          AiAction.revoke,
          AiAction.openWindows,
          AiAction.closeWindows,
          // Note: AiAction.scheduledActions is intentionally OMITTED
        ],
      ));

      final decision = guard.evaluate(
        tx: _sendTx(amount: 10),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.requireManualReview));
      expect(decision.reason, contains('scheduled actions'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 3. Required action not allowed → block
  // ═══════════════════════════════════════════════════════════════════════════
  group('Required Action Gate', () {
    test('send action not allowed returns block', () {
      AiControlService.instance.setSettingsForTest(_fullAutonomySettings(
        allowedActions: [
          // Include scheduledActions so we pass that gate, but NO send
          AiAction.scheduledActions,
          AiAction.swap,
          AiAction.approve,
          AiAction.revoke,
        ],
      ));

      final decision = guard.evaluate(
        tx: _sendTx(amount: 10),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.blocked));
      expect(decision.reason, contains('send'));
    });

    test('revoke action not allowed returns block', () {
      AiControlService.instance.setSettingsForTest(_fullAutonomySettings(
        allowedActions: [
          AiAction.scheduledActions,
          AiAction.send,
          AiAction.swap,
          AiAction.approve,
          // revoke omitted
        ],
      ));

      final decision = guard.evaluate(
        tx: _revokeTx(),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.blocked));
      expect(decision.reason, contains('revoke'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 4. Fallback path → manual
  // ═══════════════════════════════════════════════════════════════════════════
  group('Fallback Path', () {
    test('fallback execution path returns manual', () {
      final decision = guard.evaluate(
        tx: _sendTx(amount: 10),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.fallback,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.requireManualReview));
      expect(decision.reason, contains('Fallback'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 5. Policy blocked → block
  // ═══════════════════════════════════════════════════════════════════════════
  group('Policy Block Gate', () {
    test('blocked policy result returns block', () {
      final decision = guard.evaluate(
        tx: _sendTx(amount: 10),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _blockedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.blocked));
      expect(decision.reason, contains('blocked'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 6. RPC sim failed → block
  // ═══════════════════════════════════════════════════════════════════════════
  group('RPC Simulation Gate', () {
    test('rpc revert returns block', () {
      final decision = guard.evaluate(
        tx: _sendTx(amount: 10),
        staticSim: _cleanSim(),
        rpcSim: _rpcRevert(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(), // policy itself is allowed
      );

      expect(decision.verdict, equals(SandboxVerdict.blocked));
      expect(decision.reason, contains('RPC simulation revert'));
    });

    test('both policy blocked AND rpc revert returns block', () {
      final decision = guard.evaluate(
        tx: _sendTx(amount: 10),
        staticSim: _cleanSim(),
        rpcSim: _rpcRevert(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _blockedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.blocked));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 7. Network not in mandate → block
  // ═══════════════════════════════════════════════════════════════════════════
  group('Mandate Network Gate', () {
    test('network not in mandate allowedNetworks returns block', () {
      AiControlService.instance.setSettingsForTest(_fullAutonomySettings(
        mandate: const AutonomyMandate(
          allowedNetworks: ['eth'], // Only ETH allowed
        ),
      ));

      final decision = guard.evaluate(
        tx: _sendTx(amount: 10, chainKey: 'bsc'), // BSC not in mandate
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.blocked));
      expect(decision.reason, contains('network'));
    });

    test('empty allowedNetworks means all networks allowed', () {
      AiControlService.instance.setSettingsForTest(_fullAutonomySettings(
        mandate: const AutonomyMandate(
          allowedNetworks: [], // Empty → all allowed
        ),
      ));

      final decision = guard.evaluate(
        tx: _sendTx(amount: 10, chainKey: 'bsc'),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, isNot(equals(SandboxVerdict.blocked)),
          reason: 'Empty network list should allow all');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 8. Asset not in mandate → block
  // ═══════════════════════════════════════════════════════════════════════════
  group('Mandate Asset Gate', () {
    test('token not in mandate allowedAssets returns block', () {
      AiControlService.instance.setSettingsForTest(_fullAutonomySettings(
        mandate: const AutonomyMandate(
          allowedAssets: ['USDT', 'BTC'], // BNB not in list
        ),
      ));

      final decision = guard.evaluate(
        tx: _sendTx(amount: 10, tokenSymbol: 'BNB'),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.blocked));
      expect(decision.reason, contains('asset'));
    });

    test('target token not in mandate blocks swap', () {
      AiControlService.instance.setSettingsForTest(_fullAutonomySettings(
        mandate: const AutonomyMandate(
          allowedAssets: ['USDT'], // BNB target not in list
        ),
      ));

      final decision = guard.evaluate(
        tx: _swapTx(
          amount: 10,
          tokenSymbol: 'USDT',
          targetTokenSymbol: 'BNB',
        ),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.blocked));
      expect(decision.reason, contains('asset'));
    });

    test('empty allowedAssets means all assets allowed', () {
      AiControlService.instance.setSettingsForTest(_fullAutonomySettings(
        mandate: const AutonomyMandate(allowedAssets: []),
      ));

      final decision = guard.evaluate(
        tx: _sendTx(amount: 10, tokenSymbol: 'DOGE'),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, isNot(equals(SandboxVerdict.blocked)));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 9. Venue not in mandate → block
  // ═══════════════════════════════════════════════════════════════════════════
  group('Mandate Venue Gate', () {
    test('router address not in mandate venues returns block', () {
      AiControlService.instance.setSettingsForTest(_fullAutonomySettings(
        mandate: const AutonomyMandate(
          allowedVenues: ['0xapprovedrouter'], // lowercase
        ),
      ));

      final decision = guard.evaluate(
        tx: _swapTx(
          amount: 10,
          routerAddress: '0xUnknownRouter',
        ),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.blocked));
      expect(decision.reason, contains('venue'));
    });

    test('spenderAddress used as venue when routerAddress is null', () {
      AiControlService.instance.setSettingsForTest(_fullAutonomySettings(
        mandate: const AutonomyMandate(
          allowedVenues: ['0xapprovedspender'],
        ),
      ));

      final decision = guard.evaluate(
        tx: _sendTx(
          amount: 10,
          routerAddress: null,
          spenderAddress: '0xUnknownSpender',
        ),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.blocked));
      expect(decision.reason, contains('venue'));
    });

    test('null venue with empty allowedVenues passes', () {
      AiControlService.instance.setSettingsForTest(_fullAutonomySettings(
        mandate: const AutonomyMandate(allowedVenues: []),
      ));

      final decision = guard.evaluate(
        tx: _sendTx(amount: 10), // no router, no spender
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, isNot(equals(SandboxVerdict.blocked)));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 10. High risk wallet context → manual
  // ═══════════════════════════════════════════════════════════════════════════
  group('Wallet Risk Gate', () {
    test('high risk wallet returns manual review', () {
      final decision = guard.evaluate(
        tx: _sendTx(amount: 10),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _highRiskWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.requireManualReview));
      expect(decision.reason, contains('risk'));
    });

    test('borderline risk score 75 is NOT high risk', () {
      final wallet = const WalletContext(
        address: '0xSender',
        chainId: 56,
        totalBalance: 1000.0,
        riskScore: 75,
      );

      final decision = guard.evaluate(
        tx: _sendTx(amount: 10),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: wallet,
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      // 75 is NOT > 75 → should pass the risk check
      expect(decision.verdict, isNot(equals(SandboxVerdict.requireManualReview)),
          reason: 'riskScore 75 is not > 75, should pass');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 11. Delegation not authorized → manual
  // ═══════════════════════════════════════════════════════════════════════════
  group('Delegation Gate', () {
    test('no delegation scope returns manual', () {
      DelegationController.instance.store.clear();

      final decision = guard.evaluate(
        tx: _sendTx(amount: 10),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.requireManualReview));
      expect(decision.reason, contains('delegated constraints'));
    });

    test('delegation scope with wrong actions returns manual', () {
      DelegationController.instance.store.setScope(
        _validScope(allowedActions: ['SWAP']), // SEND not in scope
      );

      final decision = guard.evaluate(
        tx: _sendTx(amount: 10),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.requireManualReview));
      expect(decision.reason, contains('delegated'));
    });

    test('delegation scope amount exceeded returns manual', () {
      DelegationController.instance.store.setScope(
        _validScope(maxAmountUsd: 5), // Only $5 allowed
      );

      final decision = guard.evaluate(
        tx: _sendTx(amount: 100), // Way over the scope limit
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.requireManualReview));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // 12. All checks pass → approved
  // ═══════════════════════════════════════════════════════════════════════════
  group('Happy Path', () {
    test('all checks passing returns approved', () {
      final decision = guard.evaluate(
        tx: _sendTx(amount: 10),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.approvedForAuto));
      expect(decision.reason, contains('delegated boundaries'));
    });

    test('approved with localProtected path (not fallback)', () {
      final decision = guard.evaluate(
        tx: _sendTx(amount: 10),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.localProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.approvedForAuto));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Gate Priority: checks execute in documented order
  // ═══════════════════════════════════════════════════════════════════════════
  group('Gate Priority', () {
    test('mode gate fires before scheduled actions gate', () {
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.guarded,
        allowedActions: [], // scheduledActions also missing
      ));

      final decision = guard.evaluate(
        tx: _sendTx(amount: 10),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      // Should hit mode gate first → manual, not scheduled actions gate
      expect(decision.verdict, equals(SandboxVerdict.requireManualReview));
      expect(decision.reason, contains('manual confirmation'));
      expect(decision.reason, isNot(contains('scheduled')));
    });

    test('scheduled actions gate fires before required action gate', () {
      AiControlService.instance.setSettingsForTest(_fullAutonomySettings(
        allowedActions: [
          // scheduledActions NOT included
          AiAction.openWindows,
          AiAction.closeWindows,
          // send also NOT included → but scheduled should fire first
        ],
      ));

      final decision = guard.evaluate(
        tx: _sendTx(amount: 10),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      expect(decision.verdict, equals(SandboxVerdict.requireManualReview));
      expect(decision.reason, contains('scheduled'));
    });

    test('fallback gate fires before policy gate', () {
      final decision = guard.evaluate(
        tx: _sendTx(amount: 10),
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.fallback,
        policy: _blockedPolicy(), // policy is blocked too
      );

      // Fallback gate (manual) should fire before policy gate (block)
      expect(decision.verdict, equals(SandboxVerdict.requireManualReview));
      expect(decision.reason, contains('Fallback'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // _requiredAction mapping
  // ═══════════════════════════════════════════════════════════════════════════
  group('Action Mapping', () {
    test('swap and approve both map to AiAction.swap', () {
      // If swap is NOT allowed, approve tx should be blocked too
      // because _requiredAction maps approve → AiAction.swap
      AiControlService.instance.setSettingsForTest(_fullAutonomySettings(
        allowedActions: [
          AiAction.scheduledActions,
          AiAction.send,
          AiAction.revoke,
          AiAction.approve, // approve AiAction present
          // AiAction.swap omitted
        ],
      ));

      // approve TransactionType maps to AiAction.swap in SandboxGuard
      final approveTx = TransactionRequest(
        type: TransactionType.approve,
        fromAddress: '0xSender',
        toAddress: '0xContract',
        amount: 10,
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent: _intent(),
      );

      final decision = guard.evaluate(
        tx: approveTx,
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      // approve type → requires AiAction.swap → blocked
      expect(decision.verdict, equals(SandboxVerdict.blocked));
      expect(decision.reason, contains('swap'));
    });

    test('unknown TransactionType returns null action (skips action check)', () {
      AiControlService.instance.setSettingsForTest(_fullAutonomySettings(
        allowedActions: [AiAction.scheduledActions],
      ));

      final unknownTx = TransactionRequest(
        type: TransactionType.unknown,
        fromAddress: '0xSender',
        toAddress: '0xDest',
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent: _intent(),
      );

      // unknown → _requiredAction returns null → skips the action gate
      // Will be caught by later gates (policy, delegation, etc.)
      final decision = guard.evaluate(
        tx: unknownTx,
        staticSim: _cleanSim(),
        rpcSim: _rpcOk(),
        profile: _defiProfile(),
        walletContext: _normalWallet(),
        path: ExecutionPath.epkProtected,
        policy: _allowedPolicy(),
      );

      // Should NOT be blocked by the action gate — but may be manual/blocked later
      expect(decision.verdict, isNot(equals(SandboxVerdict.blocked)),
          reason: 'Unknown type skips action gate');
    });
  });
}
