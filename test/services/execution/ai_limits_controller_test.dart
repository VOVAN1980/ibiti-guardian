// GuardianExecutionController AI limits:
// - «AI Мандат» max position bounds buys only (D6), like ExchangeOrderService
//   and AiActionGate: sends and sells are bounded by the daily limit only;
// - the AI never acts on an unknown USD value (D7) and never measures its
//   limits in token units: it refuses so the caller can hand the operation
//   to the user in the prefilled window (D17); the automation path demotes
//   it to a preview; a token quantity is never added to the dollar budget;
// - «Советник» starts no scan (D2);
// - every refusal the user can lift in «Политика» (daily limit, max
//   position, «AI Мандат» network / asset / venue, a wallet send / swap /
//   approve limit) carries a stable detail code (isRaisableRefusal), so the
//   «поднимите порог» hint never depends on the wording or the language;
// - the AI mode / permission refusals of an assistant intent are localized
//   (no English «AI Control» name);
// - a swap amount is always what is paid: an exact amount to receive is
//   never quoted, so the AI limits measure the dollars actually spent.
//
// Run: flutter test test/services/execution/ai_limits_controller_test.dart

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/models/rpc_simulation_result.dart';
import 'package:ibiti_guardian/models/simulation_result.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/execution/ai_onchain_executor.dart';
import 'package:ibiti_guardian/services/execution/guardian_execution_controller.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/services/policy/guardian_policy_engine.dart';
import 'package:ibiti_guardian/services/policy/tx_usd_valuer.dart';
import 'package:ibiti_guardian/services/security/ai_action_gate.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _owner = '0x73761dae1912544cbdf2c08129918b83f88d9015';
const _friend = '0x3333333333333333333333333333333333333333';
const _usdt = '0x55d398326f99059fF775485246999027B3197955';
const _cake = '0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82';
const _allowanceHolder = '0x0000000000001fF3684f28c67538d4D072C22734';

/// Symbols without a price in these tests.
const _unpriced = {'CAKE', 'PEPE'};

/// The words that make the assistant append «raise the threshold in
/// Policy» (GuardianAssistantService._limitWords). An unknown-value refusal
/// is not a limit and must not get that hint.
final _limitWords = RegExp(
  r'limit|budget|mandate|position cap|лимит|бюджет|мандат|позици',
  caseSensitive: false,
);

const _aiSendIntent = IntentData(type: IntentType.sendAsset, rawInput: 'send');
const _aiSwapIntent = IntentData(type: IntentType.swapAsset, rawInput: 'swap');

TransactionRequest _send({
  String symbol = 'USDT',
  double? amount = 10,
  IntentData intent = _aiSendIntent,
}) =>
    TransactionRequest(
      type: TransactionType.send,
      fromAddress: _owner,
      toAddress: _friend,
      tokenSymbol: symbol,
      tokenContract: symbol == 'USDT' ? _usdt : _cake,
      amount: amount,
      chainId: 56,
      chainKey: 'bsc',
      sourceIntent: intent,
    );

TransactionRequest _swap({
  required String from,
  required String to,
  double amount = 20,
  IntentData intent = _aiSwapIntent,
}) =>
    TransactionRequest(
      type: TransactionType.swap,
      fromAddress: _owner,
      toAddress: _allowanceHolder,
      routerAddress: _allowanceHolder,
      tokenSymbol: from,
      tokenContract: from == 'USDT' ? _usdt : _cake,
      targetTokenSymbol: to,
      amount: amount,
      chainId: 56,
      chainKey: 'bsc',
      sourceIntent: intent,
    );

TransactionRequest _approve({double amount = 20}) => TransactionRequest(
      type: TransactionType.approve,
      fromAddress: _owner,
      toAddress: _usdt,
      tokenSymbol: 'USDT',
      tokenContract: _usdt,
      amount: amount,
      spenderAddress: _allowanceHolder,
      chainId: 56,
      chainKey: 'bsc',
      sourceIntent: _aiSwapIntent,
    );

TransactionRequest _revoke() => const TransactionRequest(
      type: TransactionType.revoke,
      fromAddress: _owner,
      toAddress: _usdt,
      tokenSymbol: 'USDT',
      tokenContract: _usdt,
      spenderAddress: _friend,
      chainId: 56,
      chainKey: 'bsc',
      sourceIntent: IntentData(
        type: IntentType.revokeApproval,
        rawInput: 'revoke',
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final controller = GuardianExecutionController.instance;
  final gate = AiActionGate.instance;

  void useSettings({
    AiMode mode = AiMode.fullAutonomy,
    double dailyLimit = 1000,
    double maxPositionUsd = 100,
    List<String> allowedNetworks = const [],
    List<String> allowedAssets = const [],
    List<String> allowedVenues = const [],
    List<AiAction>? allowedActions,
  }) {
    const defaults = AiControlSettings();
    AiControlService.instance.setSettingsForTest(AiControlSettings(
      mode: mode,
      dailyLimit: dailyLimit,
      allowedActions: allowedActions ?? defaults.allowedActions,
      mandate: AutonomyMandate(
        maxPositionUsd: maxPositionUsd,
        allowedNetworks: allowedNetworks,
        allowedAssets: allowedAssets,
        allowedVenues: allowedVenues,
      ),
    ));
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    DelegationController.instance.resetUsageForTest();
    // Every coin is $1, except the unpriced ones (stablecoins are 1:1).
    TxUsdValuer.priceOverrideForTest =
        (tx) => _unpriced.contains(tx.tokenSymbol) ? null : 1.0;
    useSettings();
  });

  tearDown(() {
    TxUsdValuer.priceOverrideForTest = null;
  });

  group('«AI Мандат» max position: buys only (D6)', () {
    test('which operations the cap bounds', () {
      expect(GuardianExecutionController.maxPositionAppliesTo(_send()),
          isFalse);
      expect(GuardianExecutionController.maxPositionAppliesTo(_approve()),
          isFalse);
      expect(GuardianExecutionController.maxPositionAppliesTo(_revoke()),
          isFalse);
      // stablecoin → coin: a buy.
      expect(
          GuardianExecutionController.maxPositionAppliesTo(
              _swap(from: 'USDT', to: 'BNB')),
          isTrue);
      // coin → stablecoin: a sell.
      expect(
          GuardianExecutionController.maxPositionAppliesTo(
              _swap(from: 'BNB', to: 'USDT')),
          isFalse);
      // coin → coin and stable → stable count as buys (as on the card).
      expect(
          GuardianExecutionController.maxPositionAppliesTo(
              _swap(from: 'BNB', to: 'CAKE')),
          isTrue);
      expect(
          GuardianExecutionController.maxPositionAppliesTo(
              _swap(from: 'USDT', to: 'USDC')),
          isTrue);
    });

    test('the same buy / sell split as the AI card (AiOnchainExecutor)', () {
      const pairs = [
        ['USDT', 'BNB'],
        ['BNB', 'USDT'],
        ['BNB', 'CAKE'],
        ['USDC', 'USDT'],
        ['CAKE', 'usdc'],
        ['DAI', 'ETH'],
        ['ETH', 'FDUSD'],
        ['TUSD', 'PYUSD'],
        ['WBTC', 'USDD'],
        ['USDE', 'SOL'],
        ['SOL', 'BUSD'],
      ];
      for (final p in pairs) {
        final tx = _swap(from: p[0], to: p[1]);
        final card = AiOnchainExecutor.summaryForTx(tx, source: 'voice');
        expect(GuardianExecutionController.maxPositionAppliesTo(tx),
            card.isBuy,
            reason: '${p[0]} → ${p[1]}');
      }
    });

    test('an AI send over the cap is not refused by it', () {
      final stop = controller.aiPreflight(_send(amount: 150));
      expect(stop, isNull);
    });

    test('an AI sell over the cap is not refused by it', () {
      final stop = controller.aiPreflight(_swap(from: 'BNB', to: 'USDT',
          amount: 150));
      expect(stop, isNull);
    });

    test('an AI buy over the cap is refused, in dollars', () {
      final stop = controller.aiPreflight(_swap(from: 'USDT', to: 'BNB',
          amount: 150));
      expect(stop, isNotNull);
      expect(stop!.type, ResponseType.error);
      expect(stop.message, contains('position cap'));
      expect(stop.message, contains(r'$150.00'));
      expect(stop.message, contains(r'$100.00'));
      expect(stop.detail, GuardianExecutionController.maxPositionCode);
    });

    test('an AI buy within the cap passes', () {
      final stop = controller.aiPreflight(_swap(from: 'USDT', to: 'BNB',
          amount: 100));
      expect(stop, isNull);
    });

    test('the daily trading limit still bounds sends and sells', () {
      useSettings(dailyLimit: 100);
      final send = controller.aiPreflight(_send(amount: 150));
      final sell = controller.aiPreflight(_swap(from: 'BNB', to: 'USDT',
          amount: 150));
      for (final stop in [send, sell]) {
        expect(stop, isNotNull);
        expect(stop!.message, contains('daily trading limit'));
        expect(stop.message, contains(r'$150.00'));
        expect(stop.message, contains(r'$100.00 left'));
        expect(stop.detail, GuardianExecutionController.dailyLimitCode);
      }
    });
  });

  group('unknown USD value: the AI does not act (D7, D17)', () {
    test('aiValueUnknown', () {
      expect(GuardianExecutionController.aiValueUnknown(_send()), isFalse);
      expect(
          GuardianExecutionController.aiValueUnknown(_send(symbol: 'CAKE')),
          isTrue);
      expect(GuardianExecutionController.aiValueUnknown(_send(amount: null)),
          isTrue);
      // A revoke moves no money (D11).
      expect(GuardianExecutionController.aiValueUnknown(_revoke()), isFalse);
    });

    test('an AI send without a price is refused with a clear reason', () {
      final stop = controller.aiPreflight(_send(symbol: 'CAKE', amount: 2));
      expect(stop, isNotNull);
      expect(stop!.type, ResponseType.error);
      expect(stop.detail, GuardianExecutionController.aiUnknownValueCode);
      expect(stop.message, contains('CAKE'));
      expect(stop.message, contains('no price'));
      expect(stop.message, contains('wallet window'));
      // Not a limit: the assistant must not add «raise the threshold».
      expect(_limitWords.hasMatch(stop.message), isFalse,
          reason: stop.message);
    });

    test('never measured in token units (no false limit refusal)', () {
      useSettings(dailyLimit: 100, maxPositionUsd: 100);
      // 1,000,000 unpriced tokens: used to be compared as $1,000,000.
      final send =
          controller.aiPreflight(_send(symbol: 'PEPE', amount: 1000000));
      final buy = controller.aiPreflight(
          _swap(from: 'CAKE', to: 'BNB', amount: 1000000));
      for (final stop in [send, buy]) {
        expect(stop, isNotNull);
        expect(stop!.detail, GuardianExecutionController.aiUnknownValueCode);
        expect(stop.message, isNot(contains('position cap')));
        expect(stop.message, isNot(contains('daily trading limit')));
      }
      // And 2 unpriced tokens never pass as "$2".
      final small = controller.aiPreflight(_send(symbol: 'CAKE', amount: 2));
      expect(small?.detail, GuardianExecutionController.aiUnknownValueCode);
    });

    test('a mandate or permission refusal comes first (never a window)', () {
      const code = GuardianExecutionController.aiUnknownValueCode;
      useSettings(allowedNetworks: const ['eth']);
      final outside = controller.aiPreflight(_send(symbol: 'CAKE', amount: 2));
      expect(outside, isNotNull);
      expect(outside!.detail, isNot(code));
      expect(outside.message, contains('BSC'));
      expect(outside.message, contains('«AI Mandate»'));
      // A mandate refusal is a limit: the assistant adds «raise it in
      // Policy» to it (D6) — by its code, whatever the language.
      expect(_limitWords.hasMatch(outside.message), isTrue);
      expect(outside.detail, GuardianExecutionController.mandateNetworkCode);
      expect(GuardianExecutionController.isRaisableRefusal(outside.detail),
          isTrue);

      useSettings(allowedActions: const [AiAction.swap]);
      final noSend = controller.aiPreflight(_send(symbol: 'CAKE', amount: 2));
      expect(noSend, isNotNull);
      expect(noSend!.detail, isNot(code));
      expect(GuardianExecutionController.isRaisableRefusal(noSend.detail),
          isFalse);
    });

    test('«Советник» and expired permissions are told apart', () {
      useSettings(mode: AiMode.manual);
      final advisor = controller.aiPreflight(_send(amount: 10));
      expect(advisor, isNotNull);
      expect(advisor!.message, contains('Advisor'));
      expect(advisor.message, isNot(contains('expired')));

      AiControlService.instance.setSettingsForTest(AiControlSettings(
        mode: AiMode.fullAutonomy,
        permissionsExpiry: DateTime.now().subtract(const Duration(hours: 1)),
      ));
      final expired = controller.aiPreflight(_send(amount: 10));
      expect(expired, isNotNull);
      expect(expired!.message, contains('expired'));
    });

    test('a revoke is never refused for its value', () {
      expect(controller.aiPreflight(_revoke()), isNull);
    });

    test('an operation the user confirms keeps the old stand-in, said plainly',
        () {
      // The Buy / Sell window and the «Ручной» chat card are confirmed by the
      // user with the PIN: without a price the token quantity is compared as
      // before (never looser), and the message does not pass it off as "$".
      useSettings(dailyLimit: 100, maxPositionUsd: 100);
      final daily = controller.checkDailyLimitForTest(
          _swap(from: 'CAKE', to: 'USDT', amount: 1000));
      expect(daily, isNotNull);
      expect(daily!.message, contains('CAKE has no price'));
      expect(daily.message, contains('1000 CAKE'));
      expect(daily.message, contains(r'$100.00 left'));
      expect(daily.detail, GuardianExecutionController.dailyLimitCode);

      final cap = controller.checkAiTransactionControlForTest(
          _swap(from: 'CAKE', to: 'BNB', amount: 1000));
      expect(cap, isNotNull);
      expect(cap!.message, contains('CAKE has no price'));
      expect(cap.message, contains(r'the cap is $100.00'));
      expect(cap.detail, GuardianExecutionController.maxPositionCode);

      // Within the stand-in: passes, as before.
      expect(
          controller.checkDailyLimitForTest(
              _swap(from: 'CAKE', to: 'USDT', amount: 50)),
          isNull);
      expect(
          controller.checkAiTransactionControlForTest(
              _swap(from: 'CAKE', to: 'BNB', amount: 50)),
          isNull);
    });

    test('the user\'s own wallet window skips the trading checks', () {
      useSettings(mode: AiMode.manual, dailyLimit: 1, maxPositionUsd: 1);
      const own = IntentData(
        type: IntentType.swapAsset,
        rawInput: 'swap',
        origin: IntentOrigin.wallet,
      );
      final tx = _swap(from: 'USDT', to: 'BNB', amount: 500, intent: own);
      expect(controller.checkDailyLimitForTest(tx), isNull);
      expect(controller.checkAiTransactionControlForTest(tx), isNull);
    });

    test('a token quantity is never added to the dollar budget', () {
      expect(GuardianExecutionController.dailyUsageUsd(_send(amount: 10)),
          10);
      expect(
          GuardianExecutionController.dailyUsageUsd(
              _swap(from: 'BNB', to: 'USDT', amount: 30)),
          30);
      expect(
          GuardianExecutionController.dailyUsageUsd(
              _send(symbol: 'CAKE', amount: 2)),
          isNull);
      expect(GuardianExecutionController.dailyUsageUsd(_approve()), isNull);
      expect(GuardianExecutionController.dailyUsageUsd(_revoke()), isNull);
      // The user's own wallet window does not use the trading budget.
      expect(
        GuardianExecutionController.dailyUsageUsd(_send(
          amount: 10,
          intent: const IntentData(
            type: IntentType.sendAsset,
            rawInput: 'send',
            origin: IntentOrigin.wallet,
          ),
        )),
        isNull,
      );
    });

    group('automation path', () {
      late int cards;
      late int dispatches;
      final demoted = AssistantResponse.info('demoted to preview');

      setUp(() {
        cards = 0;
        dispatches = 0;
        gate.resetForTest();
        gate.confirmUiOverride = (s) async {
          cards++;
          return true;
        };
        gate.notifyOverride = (title, body) {};
        controller.automationDispatchOverride = (tx, path) async {
          dispatches++;
          return const AssistantResponse(
            message: 'sent',
            type: ResponseType.action,
            detail: '0xfeed',
          );
        };
      });

      tearDown(() {
        controller.automationDispatchOverride = null;
        gate.resetForTest();
      });

      test('no price: the user reviews it — no card, no lock, no reservation',
          () async {
        final tx = _send(
          symbol: 'CAKE',
          amount: 2,
          intent: const IntentData(
            type: IntentType.sendAsset,
            rawInput: '_AUTO_ send',
            sourceTrigger: 'rule_1',
          ),
        );
        final r = await controller.runApprovedAutomationForTest(
            tx, ExecutionPath.localProtected,
            demote: () => demoted);
        expect(identical(r, demoted), isTrue);
        expect(cards, 0);
        expect(dispatches, 0);
        expect(gate.isBusy, isFalse);
        expect(DelegationController.instance.reservedUsd, 0);
        expect(DelegationController.instance.usedTodayUsd, 0);
      });
    });
  });

  group('«Советник» starts no scan (D2)', () {
    test('an AI scan request is answered, not run', () async {
      useSettings(mode: AiMode.manual);
      final r = await controller.orchestrate(const IntentAction(
        intent: IntentData(
          type: IntentType.scanApprovals,
          rawInput: 'scan wallet',
        ),
        requiresExecution: true,
      ));
      expect(r.type, ResponseType.info);
      expect(r.message, contains('Advisor'));
      expect(r.message, contains('Safe Scan'));
      expect(r.uiCommands, isEmpty);
    });
  });

  group('refusals the user can lift in «Политика» carry a code (D6)', () {
    const raisable = GuardianExecutionController.isRaisableRefusal;

    test('daily limit, max position and every «AI Мандат» refusal', () {
      useSettings(dailyLimit: 100);
      final daily = controller.aiPreflight(_send(amount: 150));
      expect(daily!.detail, GuardianExecutionController.dailyLimitCode);

      useSettings(maxPositionUsd: 50);
      final cap =
          controller.aiPreflight(_swap(from: 'USDT', to: 'BNB', amount: 60));
      expect(cap!.detail, GuardianExecutionController.maxPositionCode);

      useSettings(allowedNetworks: const ['eth']);
      final network = controller.aiPreflight(_send(amount: 10));
      expect(network!.detail, GuardianExecutionController.mandateNetworkCode);

      useSettings(allowedAssets: const ['BNB']);
      final asset = controller.aiPreflight(_send(amount: 10));
      expect(asset!.detail, GuardianExecutionController.mandateAssetCode);

      useSettings(allowedVenues: const ['0xother']);
      final venue =
          controller.aiPreflight(_swap(from: 'USDT', to: 'BNB', amount: 10));
      expect(venue!.detail, GuardianExecutionController.mandateVenueCode);

      for (final r in <AssistantResponse?>[daily, cap, network, asset, venue]) {
        expect(raisable(r!.detail), isTrue, reason: r.message);
        expect(r.type, ResponseType.error);
      }
    });

    test('the same refusals at the confirmation keep their code', () {
      useSettings(dailyLimit: 100, maxPositionUsd: 50);
      final daily = controller.checkDailyLimitForTest(_send(amount: 150));
      final cap = controller.checkAiTransactionControlForTest(
          _swap(from: 'USDT', to: 'BNB', amount: 60));
      expect(daily!.detail, GuardianExecutionController.dailyLimitCode);
      expect(cap!.detail, GuardianExecutionController.maxPositionCode);
    });

    test('nothing else is raisable', () {
      // The AI mode, an AI permission, an unknown price.
      useSettings(mode: AiMode.manual);
      final advisor = controller.aiPreflight(_send(amount: 10));
      useSettings(allowedActions: const [AiAction.swap]);
      final permission = controller.aiPreflight(_send(amount: 10));
      useSettings();
      final noPrice = controller.aiPreflight(_send(symbol: 'CAKE', amount: 2));
      for (final r in [advisor, permission, noPrice]) {
        expect(r, isNotNull);
        expect(raisable(r!.detail), isFalse, reason: r.message);
      }
      expect(raisable(null), isFalse);
      expect(raisable(''), isFalse);
      expect(raisable(GuardianExecutionController.aiUnknownValueCode),
          isFalse);
      // A transaction hash in `detail` (a success) is not a refusal.
      expect(raisable('0xfeed'), isFalse);
    });

    test('a wallet send / swap / approve limit of the policy profile', () {
      PolicyResult policy(TransactionRequest tx) => GuardianPolicyEngine.checkV3(
            tx,
            SimulationResult.clean(),
            RpcSimulationResult.ok(),
            PolicyProfile.safe(),
            ExecutionPath.localProtected,
          );
      final profile = PolicyProfile.safe();

      final send = _send(amount: profile.sendLimitUsd + 1);
      final swap = _swap(
          from: 'USDT', to: 'BNB', amount: profile.swapLimitUsd + 1);
      final approve = _approve(amount: profile.approveLimitUsd + 1);
      final unlimited = TransactionRequest(
        type: TransactionType.approve,
        fromAddress: _owner,
        toAddress: _usdt,
        tokenSymbol: 'USDT',
        tokenContract: _usdt,
        isUnlimitedApproval: true,
        spenderAddress: _allowanceHolder,
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent: _aiSwapIntent,
      );

      expect(GuardianExecutionController.policyRefusalCode(policy(send), send),
          GuardianExecutionController.sendLimitCode);
      expect(GuardianExecutionController.policyRefusalCode(policy(swap), swap),
          GuardianExecutionController.swapLimitCode);
      expect(
          GuardianExecutionController.policyRefusalCode(
              policy(approve), approve),
          GuardianExecutionController.approveLimitCode);
      for (final code in [
        GuardianExecutionController.sendLimitCode,
        GuardianExecutionController.swapLimitCode,
        GuardianExecutionController.approveLimitCode,
      ]) {
        expect(raisable(code), isTrue, reason: code);
      }

      // An unlimited approval is never lifted by a higher limit.
      final unlimitedPolicy = policy(unlimited);
      expect(unlimitedPolicy.blocked, isTrue);
      expect(
          GuardianExecutionController.policyRefusalCode(
              unlimitedPolicy, unlimited),
          isNull);
      // A policy that allows, or blocks for another reason: no code.
      expect(
          GuardianExecutionController.policyRefusalCode(
              policy(_send(amount: 1)), _send(amount: 1)),
          isNull);
      useSettings(mode: AiMode.manual);
      final advisorPolicy = policy(_send(amount: 1));
      expect(advisorPolicy.blocked, isTrue);
      expect(
          GuardianExecutionController.policyRefusalCode(
              advisorPolicy, _send(amount: 1)),
          isNull);
    });
  });

  group('assistant intents: AI mode / permission refusals are localized', () {
    Future<AssistantResponse> orchestrateSend() =>
        controller.orchestrate(const IntentAction(
          intent: IntentData(
            type: IntentType.sendAsset,
            rawInput: 'send 10 USDT to 0x3333',
            tokenSymbol: 'USDT',
            amount: 10,
            toAddress: _friend,
          ),
          requiresExecution: true,
        ));

    test('«Советник»: the gate\'s text, named after AI Center', () async {
      useSettings(mode: AiMode.manual);
      final r = await orchestrateSend();
      expect(r.type, ResponseType.error);
      expect(r.message, contains('«Advisor»'));
      expect(r.message, contains('AI Center'));
      expect(r.message, isNot(contains('AI Control')));
      expect(r.speechText, r.message);
      expect(r.uiCommands.single.target, 'security_center');
      expect(GuardianExecutionController.isRaisableRefusal(r.detail), isFalse);
    });

    test('a turned-off AI permission: the gate\'s text, no English name',
        () async {
      useSettings(allowedActions: const [AiAction.swap]);
      final r = await orchestrateSend();
      expect(r.type, ResponseType.error);
      expect(r.message, 'This action is turned off for the AI in AI Center.');
      expect(r.message, isNot(contains('AI Control')));
      expect(r.message, isNot(contains('send permissions')));
      expect(r.speechText, r.message);
      expect(r.uiCommands.single.target, 'security_center');
    });
  });

  group('a swap amount is always what is paid', () {
    test('an exact amount to receive is refused before any quote', () async {
      final r = await controller.requestSwapPreview(const IntentData(
        type: IntentType.swapAsset,
        rawInput: 'buy 0.5 ETH with BNB',
        sourceTokenSymbol: 'BNB',
        sourceTokenAddress: 'BNB',
        targetTokenSymbol: 'ETH',
        targetTokenAddress: '0x2170Ed0880ac9A755fd29B2688956BD959F933F8',
        amount: 0.5,
        amountMode: AmountMode.exactOut,
        sourceTokenDecimals: 18,
        targetTokenDecimals: 18,
      ));
      expect(r.type, ResponseType.error);
      expect(r.message, contains('exact amount to receive'));
      expect(r.message, contains('BNB'));
      expect(r.swapPlan, isNull);
    });
  });
}
