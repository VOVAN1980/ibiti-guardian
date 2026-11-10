// Dollar-denominated limits compare USD value, and temporary limits expire.
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/models/rpc_simulation_result.dart';
import 'package:ibiti_guardian/models/simulation_result.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/policy/guardian_policy_engine.dart';
import 'package:ibiti_guardian/services/policy/tx_usd_valuer.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';

TransactionRequest _send(String symbol, double amount) => TransactionRequest(
      type: TransactionType.send,
      fromAddress: '0xSender',
      toAddress: '0xRecipient',
      tokenSymbol: symbol,
      amount: amount,
      chainId: 56,
      chainKey: 'bsc',
      sourceIntent: const IntentData(type: IntentType.sendAsset, rawInput: 't'),
    );

PolicyResult _check(TransactionRequest tx, PolicyProfile profile) =>
    GuardianPolicyEngine.checkV3(tx, SimulationResult.clean(),
        RpcSimulationResult.ok(), profile, ExecutionPath.localProtected);

void main() {
  setUp(() {
    AiControlService.instance.setSettingsForTest(const AiControlSettings(
      mode: AiMode.guarded,
      allowedActions: [AiAction.send, AiAction.swap, AiAction.approve],
    ));
    // Prices: BNB $600, SOL $150; anything else unknown.
    TxUsdValuer.priceOverrideForTest = (tx) => switch (tx.tokenSymbol) {
          'BNB' => 600.0,
          'SOL' => 150.0,
          _ => null,
        };
  });
  tearDown(() => TxUsdValuer.priceOverrideForTest = null);

  group('TxUsdValuer', () {
    test('stablecoin is worth its quantity, priced coin quantity × price', () {
      expect(TxUsdValuer.usdValue(_send('USDT', 20)), 20);
      expect(TxUsdValuer.usdValue(_send('BNB', 0.5)), 300);
    });

    test('unknown price keeps the old quantity comparison', () {
      expect(TxUsdValuer.usdValue(_send('PEPE', 30)), isNull);
      expect(TxUsdValuer.limitAmount(_send('PEPE', 30)), 30);
    });
  });

  group('Send limit in USD (safe profile: \$50)', () {
    test('0.1 BNB (\$60) is over a \$50 limit — quantity 0.1 used to pass', () {
      final r = _check(_send('BNB', 0.1), PolicyProfile.safe());
      expect(r.blocked, isTrue);
      expect(r.appliedRules, contains('PROFILE_LIMIT_EXCEEDED'));
    });

    test('0.05 BNB (\$30) is within the limit', () {
      expect(_check(_send('BNB', 0.05), PolicyProfile.safe()).blocked, isFalse);
    });
  });

  group('Temporary limits', () {
    test('an expired raised limit falls back to the safe default', () {
      final raised = PolicyProfile.safe().copyWith(
        sendLimitUsd: 1000,
        actionExpiries: {
          'SEND': DateTime.now().subtract(const Duration(minutes: 1)),
        },
      );
      // $300 fits the raised $1000, not the safe $50.
      expect(_check(_send('BNB', 0.5), raised).blocked, isTrue);
    });

    test('an active raised limit applies', () {
      final raised = PolicyProfile.safe().copyWith(
        sendLimitUsd: 1000,
        actionExpiries: {'SEND': DateTime.now().add(const Duration(hours: 1))},
      );
      expect(_check(_send('BNB', 0.5), raised).blocked, isFalse);
    });
  });

  test('unknown stored AI action names are dropped, not turned into send', () {
    final s = AiControlSettings.fromJson({
      'mode': 'guarded',
      'allowedActions': ['swap', 'removedAction'],
    });
    expect(s.allowedActions, [AiAction.swap]);
  });
}
