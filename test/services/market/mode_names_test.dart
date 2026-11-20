// The AI mode names the user sees outside the assistant: «Советник» /
// «Ручной» / «Автономный» (EN Advisor / Manual / Autonomous; the code names
// stay manual / guarded / fullAutonomy). The old names must not reach the
// user: old "Manual" meant advice only (now Advisor), "Guarded" is now
// Manual, "Full Autonomy" is now Autonomous.
//
// Covers the trading plan (block reason shown on the plan card and in chat,
// the plan context the AI reads) and the policy engine's Advisor block.
//
// Run: flutter test test/services/market/mode_names_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/models/rpc_simulation_result.dart';
import 'package:ibiti_guardian/models/simulation_result.dart';
import 'package:ibiti_guardian/models/trading_plan.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/market/trading_plan_builder.dart';
import 'package:ibiti_guardian/services/policy/guardian_policy_engine.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sol = MarketAsset(
  id: 'solana',
  symbol: 'SOL',
  name: 'Solana',
  imageUrl: '',
  price: 100,
  change24h: 1,
  marketCap: 1000000000,
  volume: 50000000,
  rank: 5,
  sparkline: [],
  high24h: 105,
  low24h: 98,
  change7d: 2,
  change30d: 5,
  networkGroup: 'Solana',
);

TradingPlan _plan(AiMode mode) => TradingPlanBuilder.build(
      asset: _sol,
      direction: TradingDirection.buy,
      settings: AiControlSettings(mode: mode),
    );

void _noOldNames(String? text) {
  expect(text, isNotNull);
  for (final old in [
    'Guarded',
    'Full Autonomy',
    'Full Auto',
    'analysis only',
    'Manual mode',
    'Manual (analysis',
    'Руководство',
    'Охраняемый',
    'Полная автономия',
  ]) {
    expect(text, isNot(contains(old)), reason: old);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('trading plan', () {
    test('«Советник»: blocked as advice only, with the new names', () {
      final plan = _plan(AiMode.manual);
      expect(plan.executableByAi, isFalse);
      expect(plan.blockReason, contains('Advisor mode'));
      expect(plan.blockReason, contains('advice only'));
      // How to let the AI act: the new names of the other two modes.
      expect(plan.blockReason, contains('Manual (the AI prepares'));
      expect(plan.blockReason, contains('Autonomous'));
      _noOldNames(plan.blockReason);

      final context = plan.toPromptContext();
      expect(context, contains('Mode: «Советник» (Advisor)'));
      _noOldNames(context);
    });

    test('«Ручной»: the plan context says the AI prepares, PIN confirms', () {
      final context = _plan(AiMode.guarded).toPromptContext();
      expect(context, contains('Mode: «Ручной» (Manual)'));
      expect(context, contains('user confirms with PIN'));
      _noOldNames(context);
    });

    test('«Автономный»: the plan context says it executes within limits', () {
      final context = _plan(AiMode.fullAutonomy).toPromptContext();
      expect(context, contains('Mode: «Автономный» (Autonomous)'));
      expect(context, contains('within limits'));
      _noOldNames(context);
    });

    test('excessive risk no longer says "Manual review" (a mode name now)',
        () {
      const wild = MarketAsset(
        id: 'pepe',
        symbol: 'PEPE',
        name: 'Pepe',
        imageUrl: '',
        price: 1,
        change24h: 25,
        marketCap: 1000000000,
        volume: 50000000,
        rank: 50,
        sparkline: [],
        high24h: 1.3,
        low24h: 0.8,
        change7d: 2,
        change30d: 5,
        networkGroup: 'Ethereum',
      );
      // A gas cap low enough for a viable size, so the risk check is reached.
      final plan = TradingPlanBuilder.build(
        asset: wild,
        direction: TradingDirection.buy,
        settings: const AiControlSettings(
          mode: AiMode.guarded,
          mandate: AutonomyMandate(maxGasUsd: 1),
        ),
      );
      expect(plan.executableByAi, isFalse);
      expect(plan.blockReason, contains('Risk level is excessive'));
      expect(plan.blockReason, isNot(contains('Manual review')));
      _noOldNames(plan.blockReason);
    });
  });

  group('policy engine', () {
    test('«Советник» block reason uses the new names', () {
      AiControlService.instance.setSettingsForTest(
        const AiControlSettings(mode: AiMode.manual),
      );
      final result = GuardianPolicyEngine.checkV3(
        const TransactionRequest(
          type: TransactionType.send,
          fromAddress: '0xSender',
          toAddress: '0xRecipient',
          amount: 10,
          chainId: 56,
          chainKey: 'bsc',
          sourceIntent:
              IntentData(type: IntentType.unknown, rawInput: 'test'),
        ),
        SimulationResult.clean(),
        RpcSimulationResult.ok(),
        PolicyProfile.safe(),
        ExecutionPath.localProtected,
      );
      expect(result.blocked, isTrue);
      // The rule id is a code name and stays.
      expect(result.appliedRules, contains('AI_MODE_MANUAL_BLOCK'));
      expect(result.reason, contains('Advisor'));
      expect(result.reason, contains('only advises'));
      expect(result.reason, contains('Manual or Autonomous'));
      expect(result.reason, isNot(contains('set to Manual')));
      _noOldNames(result.reason);
    });
  });
}
