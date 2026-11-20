// The wallet Buy / Sell window (WalletTradeModal) is the user's own window
// (owner decisions D2 / D3). It used to send its swap as origin market, so
// in «Советник» and after the emergency stop the user's own Buy / Sell was
// blocked like an AI trade, and it was held to «AI Мандат» and the daily
// trading limit. Its swap is now origin wallet, like the Send and Swap
// windows (GuardianPolicyEngine.isUserWalletTx): the AI mode, the AI
// permissions, «AI Мандат» and the daily trading limit never stop it, while
// the wallet swap / approve limits, the slippage cap, unknown contracts and
// the simulation still apply. The AI's own trades never go through this
// window: they are built with origin market and stay bound by every AI rule.
//
// Run: flutter test test/screens/wallet/wallet_trade_modal_origin_test.dart

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/models/rpc_simulation_result.dart';
import 'package:ibiti_guardian/models/simulation_result.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/screens/wallet/components/wallet_trade_modal.dart';
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

/// The same buy asked of the AI (chat, voice, automation): origin market.
const _aiBuy = IntentData(type: IntentType.swapAsset, rawInput: 'buy CAKE');

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

/// «Автономный» with a tiny mandate and daily limit the window's buy is over.
const _tinyAutonomous = AiControlSettings(
  mode: AiMode.fullAutonomy,
  dailyLimit: 5,
  mandate: AutonomyMandate(
    maxPositionUsd: 5,
    allowedAssets: ['SOL'],
    allowedNetworks: ['solana'],
  ),
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

  group('the intent the window sends', () {
    test('is the user\'s own (origin wallet), never automation', () {
      final intent = _windowBuy();
      expect(intent.origin, IntentOrigin.wallet);
      expect(intent.isAutomated, isFalse);
      expect(intent.type, IntentType.swapAsset);
      expect(intent.amount, 20);
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
      expect(intent.origin, IntentOrigin.wallet);
    });

    test('both plan steps count as the user\'s own wallet window', () {
      expect(GuardianPolicyEngine.isUserWalletTx(_swapStep(_windowBuy())),
          isTrue);
      expect(GuardianPolicyEngine.isUserWalletTx(_approveStep(_windowBuy())),
          isTrue);
      // The AI's buy stays the AI's.
      expect(GuardianPolicyEngine.isUserWalletTx(_swapStep(_aiBuy)), isFalse);
    });
  });

  group('works in every AI mode (D2)', () {
    for (final (name, settings) in [
      ('«Советник»', _advisor),
      ('after the emergency stop', _emergencyStopped),
    ]) {
      test('$name: the own buy and its approve step pass the policy', () {
        AiControlService.instance.setSettingsForTest(settings);

        final swap = check(_swapStep(_windowBuy()));
        final approve = check(_approveStep(_windowBuy()));

        expect(swap.blocked, isFalse);
        expect(swap.appliedRules, contains('USER_WALLET_ORIGIN'));
        expect(swap.appliedRules, isNot(contains('AI_MODE_MANUAL_BLOCK')));
        expect(swap.appliedRules, isNot(contains('AI_ACTION_NOT_ALLOWED')));
        expect(approve.blocked, isFalse);
        expect(approve.appliedRules, isNot(contains('AI_MODE_MANUAL_BLOCK')));
        expect(approve.appliedRules, isNot(contains('AI_ACTION_NOT_ALLOWED')));
      });
    }

    test('«Советник»: the same buy asked of the AI is still blocked', () {
      AiControlService.instance.setSettingsForTest(_advisor);

      final ai = check(_swapStep(_aiBuy));

      expect(ai.blocked, isTrue);
      expect(ai.appliedRules, contains('AI_MODE_MANUAL_BLOCK'));
    });

    test('«AI Мандат» and the daily trading limit bound the AI, not the window',
        () {
      AiControlService.instance.setSettingsForTest(_tinyAutonomous);

      final own = _swapStep(_windowBuy());
      expect(controller.checkDailyLimitForTest(own), isNull);
      expect(controller.checkAiTransactionControlForTest(own), isNull);
      // The user's own buy does not use up the AI's trading budget.
      expect(GuardianExecutionController.dailyUsageUsd(own), isNull);

      // The same $20 buy by the AI: over the $5 daily limit, outside the
      // mandate (assets SOL, network solana) and over the $5 position cap.
      final ai = _swapStep(_aiBuy);
      expect(controller.checkDailyLimitForTest(ai), isNotNull);
      expect(controller.checkAiTransactionControlForTest(ai), isNotNull);
      expect(GuardianExecutionController.dailyUsageUsd(ai), 20);
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
        final result = check(_swapStep(_windowBuy(amount: 600), amount: 600));

        expect(result.blocked, isTrue);
        expect(result.appliedRules, contains('SWAP_PROFILE_LIMIT_EXCEEDED'));
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
