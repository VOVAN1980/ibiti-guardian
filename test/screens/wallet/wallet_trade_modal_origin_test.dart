// The wallet Buy / Sell window (WalletTradeModal) is a trade window. Its swap
// is origin market, as it was before bc286dc: the daily trading limit,
// «AI Мандат» (networks, assets, venues, max position for buys) and the
// trading budget bound the user's own DEX Buy / Sell exactly like any market
// trade and like the user's own exchange buys — never looser than before.
// The wallet swap / approve limits, the slippage cap, unknown contracts and
// the simulation apply too.
//
// The window is still the user's own (owner decisions D2 / D3), so its swap
// carries IntentData.userTradeWindow. That marker lifts ONLY the AI mode
// (Check 0: «Советник», emergency stop, expired AI permissions) and the AI
// permissions (Check 0b) — GuardianPolicyEngine.isUserTradeWindowTx. Only the
// window sets it: the model (LlmIntentGuard, IntentData.fromJson) and
// automation never can, and an automated intent never counts as the window.
//
// Run: flutter test test/screens/wallet/wallet_trade_modal_origin_test.dart

import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/models/rpc_simulation_result.dart';
import 'package:ibiti_guardian/models/simulation_result.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/screens/wallet/components/wallet_trade_modal.dart';
import 'package:ibiti_guardian/services/assistant/llm_intent_guard.dart';
import 'package:ibiti_guardian/services/execution/guardian_execution_controller.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/services/policy/guardian_policy_engine.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/swap/swap_provider.dart'
    show SwapSlippagePolicy;
import 'package:shared_preferences/shared_preferences.dart';

const _owner = '0x73761dae1912544cbdf2c08129918b83f88d9015';
const _usdt = '0x55d398326f99059fF775485246999027B3197955';
const _cake = '0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82';
const _router = '0x0000000000001fF3684f28c67538d4D072C22734';

/// What the window sends for «Купить CAKE за 20 USDT».
IntentData _windowBuy({double amount = 20, double slippagePercent = 0.5}) =>
    WalletTradeModal.swapIntent(
      amount: amount,
      fromSymbol: 'USDT',
      fromAddress: _usdt,
      toSymbol: 'CAKE',
      toAddress: _cake,
      fromDecimals: 18,
      toDecimals: 18,
      slippagePercent: slippagePercent,
    );

/// The same buy asked of the AI (chat, voice): origin market, no marker.
const _aiBuy = IntentData(type: IntentType.swapAsset, rawInput: 'buy CAKE');

/// An automation trade that claims the window's marker: still automation.
const _automationClaimingWindow = IntentData(
  type: IntentType.swapAsset,
  rawInput: '_AUTO_ buy CAKE',
  sourceTrigger: 'rule_1',
  userTradeWindow: true,
);

/// The swap step of the window's plan (it carries the window's intent).
TransactionRequest _swapStep(
  IntentData intent, {
  double amount = 20,
  int slippageBps = 50,
}) =>
    TransactionRequest(
      type: TransactionType.swap,
      fromAddress: _owner,
      toAddress: _router,
      routerAddress: _router,
      tokenSymbol: 'USDT',
      tokenContract: _usdt,
      targetTokenSymbol: 'CAKE',
      amount: amount,
      chainId: 56,
      chainKey: 'bsc',
      quoteSummary: {'slippageBps': slippageBps},
      sourceIntent: intent,
    );

/// The approve step of the window's plan.
TransactionRequest _approveStep(
  IntentData intent, {
  double? amount = 20,
  bool unlimited = false,
}) =>
    TransactionRequest(
      type: TransactionType.approve,
      fromAddress: _owner,
      toAddress: _usdt,
      tokenSymbol: 'USDT',
      tokenContract: _usdt,
      amount: amount,
      isUnlimitedApproval: unlimited,
      spenderAddress: _router,
      chainId: 56,
      chainKey: 'bsc',
      sourceIntent: intent,
    );

/// «Советник».
const _advisor = AiControlSettings(mode: AiMode.manual);

/// After the emergency stop: «Советник» and no AI permissions.
const _emergencyStopped =
    AiControlSettings(mode: AiMode.manual, allowedActions: []);

/// «Ручной» with the AI swap / approve permissions turned off.
const _noAiSwap = AiControlSettings(
  mode: AiMode.guarded,
  allowedActions: [AiAction.openWindows, AiAction.closeWindows],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final controller = GuardianExecutionController.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    DelegationController.instance.resetUsageForTest();
    AiControlService.instance.setSettingsForTest(const AiControlSettings());
  });

  tearDown(() {
    AiControlService.instance.setSettingsForTest(const AiControlSettings());
    DelegationController.instance.resetUsageForTest();
  });

  PolicyResult check(
    TransactionRequest tx, {
    SimulationResult? sim,
    PolicyProfile? profile,
  }) =>
      GuardianPolicyEngine.checkV3(
        tx,
        sim ?? SimulationResult.clean(),
        RpcSimulationResult.ok(),
        profile ?? PolicyProfile.safe(),
        ExecutionPath.localProtected,
      );

  /// Counts a successful [tx] the way the controller does after dispatch.
  void commit(TransactionRequest tx) {
    final usd = GuardianExecutionController.dailyUsageUsd(tx);
    if (usd != null) DelegationController.instance.commitUsage(usd);
  }

  group('the intent the window sends', () {
    test('a trade (origin market) marked as the user\'s own window', () {
      final intent = _windowBuy();
      expect(intent.origin, IntentOrigin.market);
      expect(intent.userTradeWindow, isTrue);
      expect(intent.isAutomated, isFalse);
      expect(intent.type, IntentType.swapAsset);
      expect(intent.amount, 20);
      expect(intent.amountMode, isNull, reason: 'the amount is what is paid');
      expect(intent.sourceTokenSymbol, 'USDT');
      expect(intent.sourceTokenAddress, _usdt);
      expect(intent.targetTokenSymbol, 'CAKE');
      expect(intent.targetTokenAddress, _cake);
      expect(intent.sourceTokenDecimals, 18);
      expect(intent.targetTokenDecimals, 18);
      expect(intent.slippageBps, 50, reason: '0.5 % = 50 bps');
    });

    test('a native coin without an address is named by its symbol', () {
      final intent = WalletTradeModal.swapIntent(
        amount: 0.1,
        fromSymbol: 'BNB',
        fromAddress: '',
        toSymbol: 'USDT',
        toAddress: _usdt,
        fromDecimals: 18,
        toDecimals: 18,
        slippagePercent: 1,
      );
      expect(intent.sourceTokenAddress, 'BNB');
      expect(intent.targetTokenAddress, _usdt);
      expect(intent.slippageBps, 100);
      expect(intent.origin, IntentOrigin.market);
      expect(intent.userTradeWindow, isTrue);
    });

    test('both plan steps are the Buy / Sell window, not the Send / Swap one',
        () {
      final swap = _swapStep(_windowBuy());
      final approve = _approveStep(_windowBuy());
      expect(GuardianPolicyEngine.isUserTradeWindowTx(swap), isTrue);
      expect(GuardianPolicyEngine.isUserTradeWindowTx(approve), isTrue);
      // A trade: never the wallet Send / Swap window (no trading limits).
      expect(GuardianPolicyEngine.isUserWalletTx(swap), isFalse);
      expect(GuardianPolicyEngine.isUserWalletTx(approve), isFalse);
      // The AI's buy is neither.
      expect(GuardianPolicyEngine.isUserTradeWindowTx(_swapStep(_aiBuy)),
          isFalse);
      expect(GuardianPolicyEngine.isUserWalletTx(_swapStep(_aiBuy)), isFalse);
    });

    test('the plan keeps the marker; automation never counts as the window',
        () {
      // _orchestrateSwap re-attaches rawAmount with copyWith.
      final resolved = _windowBuy().copyWith(rawAmount: BigInt.from(20));
      expect(resolved.userTradeWindow, isTrue);
      expect(GuardianPolicyEngine.isUserTradeWindowTx(_swapStep(resolved)),
          isTrue);

      final automated = _windowBuy().copyWith(sourceTrigger: 'rule_1');
      expect(GuardianPolicyEngine.isUserTradeWindowTx(_swapStep(automated)),
          isFalse);
      expect(
          GuardianPolicyEngine.isUserTradeWindowTx(
              _swapStep(_automationClaimingWindow)),
          isFalse);
    });

    test('the marker carries only the swap steps of a swap', () {
      const markedSend = IntentData(
        type: IntentType.sendAsset,
        rawInput: 'send',
        userTradeWindow: true,
      );
      final send = TransactionRequest(
        type: TransactionType.send,
        fromAddress: _owner,
        toAddress: '0x3333333333333333333333333333333333333333',
        tokenSymbol: 'USDT',
        tokenContract: _usdt,
        amount: 10,
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent: markedSend,
      );
      expect(GuardianPolicyEngine.isUserTradeWindowTx(send), isFalse);

      final revoke = TransactionRequest(
        type: TransactionType.revoke,
        fromAddress: _owner,
        toAddress: _usdt,
        tokenSymbol: 'USDT',
        tokenContract: _usdt,
        spenderAddress: _router,
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent: _windowBuy(),
      );
      expect(GuardianPolicyEngine.isUserTradeWindowTx(revoke), isFalse);

      // «Советник»: a marked send is still the AI's and is blocked.
      AiControlService.instance.setSettingsForTest(_advisor);
      final result = check(send);
      expect(result.blocked, isTrue);
      expect(result.appliedRules, contains('AI_MODE_MANUAL_BLOCK'));
    });
  });

  group('only the window sets the marker', () {
    test('model JSON never sets it (IntentData.fromJson / AssistantDirective)',
        () {
      final fromJson = IntentData.fromJson({
        'type': 'swapAsset',
        'params': {
          'sourceTokenSymbol': 'USDT',
          'targetTokenSymbol': 'CAKE',
          'amount': 500,
          'userTradeWindow': true,
          'origin': 'market',
        },
      });
      expect(fromJson.userTradeWindow, isFalse);

      final flat = IntentData.fromJson({
        'type': 'swapAsset',
        'userTradeWindow': true,
        'sourceTokenSymbol': 'USDT',
      });
      expect(flat.userTradeWindow, isFalse);

      final directive = AssistantDirective.fromJson({
        'displayMessage': 'ok',
        'speechText': 'ok',
        'explicitIntent': {
          'type': 'swapAsset',
          'params': {'amount': 500, 'userTradeWindow': true},
        },
      });
      expect(directive.explicitIntent!.userTradeWindow, isFalse);
    });

    test('toJson never writes it, so no round trip can carry it', () {
      final json = _windowBuy().toJson();
      expect((json['params'] as Map).containsKey('userTradeWindow'), isFalse);
      expect(IntentData.fromJson(json).userTradeWindow, isFalse);
    });

    test('LlmIntentGuard drops it from a model intent', () {
      final out = LlmIntentGuard.sanitize(
        const IntentData(
          type: IntentType.swapAsset,
          rawInput: 'model',
          sourceTokenSymbol: 'USDT',
          targetTokenSymbol: 'CAKE',
          amount: 500,
          userTradeWindow: true,
        ),
        userText: 'купи CAKE на 500 USDT',
        untrustedContext: false,
      )!;
      expect(out.userTradeWindow, isFalse);
      expect(out.origin, IntentOrigin.market);
      expect(out.isAutomated, isFalse);
    });

    test('no code but the Buy / Sell window turns it on', () {
      // Every assignment of the marker in lib/: `true` only in the window;
      // anything but a literal `false` only in the window and the model
      // itself (copyWith keeps the value it already has).
      final setter = RegExp(r'userTradeWindow\s*:\s*([^,)\s]+)');
      final turnsOn = <String>[];
      final assigns = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final path = entity.path.replaceAll('\\', '/');
        for (final line in entity.readAsLinesSync()) {
          final code = line.split('//').first;
          for (final m in setter.allMatches(code)) {
            final value = m.group(1)!;
            if (value == 'false') continue;
            if (value == 'true') turnsOn.add(path);
            assigns.add(path);
          }
        }
      }
      expect(turnsOn.toSet(),
          {'lib/screens/wallet/components/wallet_trade_modal.dart'});
      expect(
          assigns.toSet(),
          {
            'lib/screens/wallet/components/wallet_trade_modal.dart',
            'lib/models/intent_data.dart',
          });
      // Automation builds its trades without it.
      final builder =
          File('lib/services/market/automation_intent_builder.dart')
              .readAsStringSync();
      expect(builder.contains('userTradeWindow'), isFalse);
    });
  });

  group('works in every AI mode (D2): skips ONLY the AI mode and permissions',
      () {
    for (final (name, settings) in [
      ('«Советник»', _advisor),
      ('after the emergency stop', _emergencyStopped),
      ('AI swap / approve permissions off', _noAiSwap),
      (
        'expired AI permissions',
        AiControlSettings(
          mode: AiMode.guarded,
          permissionsExpiry: DateTime.now().subtract(const Duration(hours: 1)),
        ),
      ),
    ]) {
      test('$name: the own buy and its approve step pass', () {
        AiControlService.instance.setSettingsForTest(settings);

        final swap = check(_swapStep(_windowBuy()));
        final approve = check(_approveStep(_windowBuy()));

        expect(swap.blocked, isFalse, reason: swap.reason);
        expect(swap.appliedRules, contains('USER_TRADE_WINDOW'));
        expect(swap.appliedRules, isNot(contains('USER_WALLET_ORIGIN')));
        expect(swap.appliedRules, isNot(contains('AI_MODE_MANUAL_BLOCK')));
        expect(swap.appliedRules, isNot(contains('AI_ACTION_NOT_ALLOWED')));
        expect(approve.blocked, isFalse, reason: approve.reason);
        expect(approve.appliedRules, isNot(contains('AI_MODE_MANUAL_BLOCK')));
        expect(approve.appliedRules, isNot(contains('AI_ACTION_NOT_ALLOWED')));

        // The controller's AI checks at the confirmation.
        expect(controller.checkAiTransactionControlForTest(
                _swapStep(_windowBuy())),
            isNull);
        expect(controller.checkAiTransactionControlForTest(
                _approveStep(_windowBuy())),
            isNull);
        expect(controller.checkDailyLimitForTest(_swapStep(_windowBuy())),
            isNull);
      });

      test('$name: the same buy asked of the AI is refused', () {
        AiControlService.instance.setSettingsForTest(settings);

        final ai = controller.checkAiTransactionControlForTest(
            _swapStep(_aiBuy));
        expect(ai, isNotNull);
        expect(GuardianExecutionController.isRaisableRefusal(ai!.detail),
            isFalse,
            reason: 'the AI mode / permissions are not a «Политика» limit');
      });
    }

    test('«Советник»: the AI / automation trade (origin market) is blocked',
        () {
      AiControlService.instance.setSettingsForTest(_advisor);

      for (final intent in [_aiBuy, _automationClaimingWindow]) {
        final policy = check(_swapStep(intent));
        expect(policy.blocked, isTrue, reason: intent.rawInput);
        expect(policy.appliedRules, contains('AI_MODE_MANUAL_BLOCK'));
        expect(policy.appliedRules, isNot(contains('USER_TRADE_WINDOW')));

        final control =
            controller.checkAiTransactionControlForTest(_swapStep(intent));
        expect(control, isNotNull, reason: intent.rawInput);
        expect(control!.message, contains('Advisor'));
      }
    });
  });

  group('the trading limits bound the window as before (never looser)', () {
    test('«Советник»: the own buy within the daily limit passes, over it is '
        'refused', () {
      AiControlService.instance.setSettingsForTest(
          const AiControlSettings(mode: AiMode.manual, dailyLimit: 50));

      // $20: allowed, and it uses the trading budget.
      final first = _swapStep(_windowBuy());
      expect(check(first).blocked, isFalse);
      expect(controller.checkAiTransactionControlForTest(first), isNull);
      expect(controller.checkDailyLimitForTest(first), isNull);
      expect(GuardianExecutionController.dailyUsageUsd(first), 20);
      commit(first);

      // Another $40: $30 left today → refused, with the «Политика» code.
      final second = _swapStep(_windowBuy(amount: 40), amount: 40);
      expect(check(second).blocked, isFalse,
          reason: 'the policy engine lets it through; the daily limit stops it');
      final daily = controller.checkDailyLimitForTest(second);
      expect(daily, isNotNull);
      expect(daily!.message, contains('daily trading limit'));
      expect(daily.message, contains(r'$40.00'));
      expect(daily.message, contains(r'$30.00 left'));
      expect(daily.detail, GuardianExecutionController.dailyLimitCode);
      expect(GuardianExecutionController.isRaisableRefusal(daily.detail),
          isTrue);
    });

    test('the window and the AI share one trading budget', () {
      AiControlService.instance.setSettingsForTest(
          const AiControlSettings(mode: AiMode.guarded, dailyLimit: 50));

      // The user's own $40 buy in the window is counted...
      commit(_swapStep(_windowBuy(amount: 40), amount: 40));
      // ...so the AI's $20 buy no longer fits, and neither does the window's.
      expect(controller.checkDailyLimitForTest(_swapStep(_aiBuy)), isNotNull);
      expect(controller.checkDailyLimitForTest(_swapStep(_windowBuy())),
          isNotNull);
      // $10 still fits both.
      expect(
          controller.checkDailyLimitForTest(
              _swapStep(_windowBuy(amount: 10), amount: 10)),
          isNull);
    });

    test('«AI Мандат» max position bounds the own buy (in dollars)', () {
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.manual,
        mandate: AutonomyMandate(maxPositionUsd: 10),
      ));

      final r = controller.checkAiTransactionControlForTest(
          _swapStep(_windowBuy()));
      expect(r, isNotNull);
      expect(r!.message, contains('position cap'));
      expect(r.message, contains(r'$20.00'));
      expect(r.detail, GuardianExecutionController.maxPositionCode);
      expect(GuardianExecutionController.isRaisableRefusal(r.detail), isTrue);
    });

    test('«AI Мандат» networks / assets / venues bound the own buy', () {
      final cases = <(AutonomyMandate, String)>[
        (
          const AutonomyMandate(allowedNetworks: ['solana']),
          GuardianExecutionController.mandateNetworkCode,
        ),
        (
          const AutonomyMandate(allowedAssets: ['USDT', 'SOL']),
          GuardianExecutionController.mandateAssetCode,
        ),
        (
          const AutonomyMandate(allowedVenues: ['0xother']),
          GuardianExecutionController.mandateVenueCode,
        ),
      ];
      for (final (mandate, code) in cases) {
        AiControlService.instance.setSettingsForTest(
            AiControlSettings(mode: AiMode.manual, mandate: mandate));
        final r = controller.checkAiTransactionControlForTest(
            _swapStep(_windowBuy()));
        expect(r, isNotNull, reason: code);
        expect(r!.detail, code);
        expect(GuardianExecutionController.isRaisableRefusal(r.detail),
            isTrue);
      }
    });
  });

  group('the wallet limits still hold for the window', () {
    for (final (name, settings) in [
      ('«Ручной»', const AiControlSettings(mode: AiMode.guarded)),
      ('«Советник»', _advisor),
      ('after the emergency stop', _emergencyStopped),
    ]) {
      test('$name: over the swap limit is blocked', () {
        AiControlService.instance.setSettingsForTest(settings);

        // PolicyProfile.safe(): swap limit $500.
        final step = _swapStep(_windowBuy(amount: 600), amount: 600);
        final result = check(step);

        expect(result.blocked, isTrue);
        expect(result.appliedRules, contains('SWAP_PROFILE_LIMIT_EXCEEDED'));
        expect(GuardianExecutionController.policyRefusalCode(result, step),
            GuardianExecutionController.swapLimitCode);
      });
    }

    test('over the slippage cap is blocked', () {
      AiControlService.instance.setSettingsForTest(_advisor);

      final result = check(_swapStep(_windowBuy(),
          slippageBps: SwapSlippagePolicy.maxBps + 1));

      expect(result.blocked, isTrue);
      expect(result.appliedRules, contains('SWAP_SLIPPAGE_CAP_EXCEEDED'));
    });

    test('an unlimited approve or an unknown contract is blocked', () {
      AiControlService.instance.setSettingsForTest(_emergencyStopped);

      final unlimited =
          check(_approveStep(_windowBuy(), amount: null, unlimited: true));
      final unknown = check(
        _approveStep(_windowBuy()),
        sim: const SimulationResult(
          risk: SimulationRisk.safe,
          flags: [SimulationFlag.unknownContract],
        ),
      );

      expect(unlimited.blocked, isTrue);
      expect(unlimited.appliedRules, contains('APPROVE_LIMIT_EXCEEDED'));
      expect(unknown.blocked, isTrue);
      expect(unknown.appliedRules, contains('PROFILE_UNKNOWN_CONTRACT_DENIED'));
    });

    test('a failing simulation is blocked', () {
      AiControlService.instance.setSettingsForTest(_advisor);

      final result = GuardianPolicyEngine.checkV3(
        _swapStep(_windowBuy()),
        SimulationResult.clean(),
        RpcSimulationResult.revert('execution reverted'),
        PolicyProfile.safe(),
        ExecutionPath.localProtected,
      );

      expect(result.blocked, isTrue);
      expect(result.appliedRules, contains('RPC_REVERT_DETECTED'));
    });
  });
}
