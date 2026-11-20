// «Делегировать AI» queue: a delegated buy in «Автономный» mode runs through
// AiOnchainExecutor (and so AiActionGate); the user's Cancel always wins.
//
// Run: flutter test test/services/market/automation_dispatch_gate_test.dart

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/models/automation_trigger.dart';
import 'package:ibiti_guardian/models/dispatch_item.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/portfolio_summary.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/execution/ai_onchain_executor.dart';
import 'package:ibiti_guardian/services/market/automation_dispatch_service.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/services/security/ai_action_gate.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _owner = '0x73761dae1912544cbdf2c08129918b83f88d9015';
const _usdtBsc = '0x55d398326f99059fF775485246999027B3197955';

MarketAsset _cake() => MarketAsset(
      id: 'cake-mexc',
      symbol: 'CAKE',
      name: 'PancakeSwap',
      imageUrl: '',
      price: 2.0,
      change24h: 1.0,
      marketCap: 1000000.0,
      volume: 50000.0,
      rank: 90,
      sparkline: const [],
      high24h: 2.1,
      low24h: 1.9,
      change7d: 2.0,
      change30d: 5.0,
      networkGroup: 'BNB Chain',
      sourceId: 'mexc',
      sourcePair: 'CAKEUSDT',
      sourceUpdatedAt: DateTime.now(),
    );

AssistantResponse _swapPreview(IntentData intent) => AssistantResponse(
      message: 'Review the swap',
      type: ResponseType.preview,
      sourceIntent: intent,
      pendingTransaction: TransactionRequest(
        type: TransactionType.swap,
        fromAddress: _owner,
        toAddress: '0x0000000000001fF3684f28c67538d4D072C22734',
        routerAddress: '0x0000000000001fF3684f28c67538d4D072C22734',
        tokenSymbol: intent.sourceTokenSymbol,
        targetTokenSymbol: intent.targetTokenSymbol,
        amount: intent.amount,
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent: intent,
      ),
      executionPath: ExecutionPath.localProtected,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dispatch = AutomationDispatchService.instance;

  late List<IntentData> orchestrated;
  late List<String> executedSources;
  late AiExecResult Function(bool Function()? stillWanted) nextResult;

  DispatchItem enqueue() {
    final trigger = AutomationTrigger(
      id: 'manual_CAKE_${DateTime.now().microsecondsSinceEpoch}',
      assetSymbol: 'CAKE',
      type: TriggerType.manualDelegate,
      requestedAction: TriggerAction.execute,
      createdAt: DateTime.now(),
      label: 'Manual: CAKE',
    );
    final item = dispatch.enqueue(
      trigger: trigger,
      reason: 'test',
      currentPrice: 2.0,
    );
    expect(item, isNotNull);
    return item!;
  }

  DispatchItem current(String id) =>
      dispatch.allItems.firstWhere((i) => i.id == id);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    IBITIVaultService.instance.setVaultCreatedForTest(evmAddress: _owner);
    AiControlService.instance.setSettingsForTest(const AiControlSettings(
      mode: AiMode.fullAutonomy,
      dailyLimit: 10000,
    ));
    DelegationController.instance.resetUsageForTest();
    MarketDataService.instance.clearForTest();
    MarketDataService.instance.mergeExchangeData({'mexc:CAKEUSDT': _cake()});
    VaultPortfolioListener.instance.setSummaryForTest(PortfolioSummary(
      totalBalanceUsd: 500,
      assetsCount: 1,
      allAssets: [
        WalletAsset(
          name: 'Tether USD',
          symbol: 'USDT',
          address: _usdtBsc,
          balance: 500,
          priceUsd: 1.0,
          valueUsd: 500,
          decimals: 18,
          chainId: 56,
          chainKey: 'bsc',
        ),
      ],
      address: _owner,
      networkName: 'BNB Chain',
      chainKey: 'bsc',
    ));

    AiActionGate.instance.resetForTest();
    dispatch.resetForTest();
    orchestrated = [];
    executedSources = [];
    nextResult = (_) => const AiExecResult(
          executed: true,
          message: 'Done: Buy CAKE (delegated to AI). Transaction sent.',
          txHash: '0x5a5',
          chainId: 56,
          gateOutcome: AiGateOutcome.execute,
        );
    dispatch.orchestrateOverride = (action) async {
      orchestrated.add(action.intent);
      return _swapPreview(action.intent);
    };
    dispatch.executeOverride = (preview, {required source, stillWanted}) async {
      executedSources.add(source);
      return nextResult(stillWanted);
    };
  });

  tearDown(() => dispatch.resetForTest());

  test('a delegated buy is quoted on the active network and executed via the gate',
      () async {
    final item = enqueue();
    await dispatch.processNextForTest();

    expect(orchestrated, hasLength(1));
    final intent = orchestrated.single;
    expect(intent.type, IntentType.swapAsset);
    expect(intent.sourceTokenSymbol, 'USDT');
    expect(intent.targetTokenSymbol, 'CAKE');
    expect(intent.amount, 100); // max position $100, USDT at $1
    expect(executedSources, ['delegate']);
    expect(current(item.id).status, DispatchStatus.done);
  });

  test('a declined card marks the item blocked "Declined by user."', () async {
    nextResult = (_) => const AiExecResult(
          executed: false,
          cancelled: true,
          message: 'Cancelled. Nothing was done.',
          gateOutcome: AiGateOutcome.cancelled,
        );
    final item = enqueue();
    await dispatch.processNextForTest();
    final resolved = current(item.id);
    expect(resolved.status, DispatchStatus.blocked);
    expect(resolved.blockReason, 'Declined by user.');
  });

  test('a gate refusal (limit, mandate) keeps its reason', () async {
    nextResult = (_) => const AiExecResult(
          executed: false,
          message: 'Over the daily trading limit.',
          gateOutcome: AiGateOutcome.blocked,
        );
    final item = enqueue();
    await dispatch.processNextForTest();
    final resolved = current(item.id);
    expect(resolved.status, DispatchStatus.blocked);
    expect(resolved.blockReason, 'Over the daily trading limit.');
  });

  test('nobody to ask (app in background / busy): the item stays pending',
      () async {
    nextResult = (_) => const AiExecResult(
          executed: false,
          message: 'Open the app to confirm.',
          gateOutcome: AiGateOutcome.unavailable,
        );
    final item = enqueue();
    await dispatch.processNextForTest();
    expect(current(item.id).status, DispatchStatus.pending);
  });

  test("the user's Cancel while the card is open wins (C18)", () async {
    late DispatchItem item;
    nextResult = (stillWanted) {
      // The user cancels in the queue while the card is still open …
      dispatch.cancelItem(item.id);
      // … so the executor sees the request withdrawn and runs nothing.
      expect(stillWanted, isNotNull);
      expect(stillWanted!(), isFalse);
      return const AiExecResult(
        executed: false,
        cancelled: true,
        message: 'Cancelled. Nothing was sent.',
        gateOutcome: AiGateOutcome.cancelled,
      );
    };
    item = enqueue();
    await dispatch.processNextForTest();
    final resolved = current(item.id);
    expect(resolved.status, DispatchStatus.blocked);
    expect(resolved.blockReason, 'Cancelled by user.');
  });

  test('a mode change before processing still blocks, nothing is quoted',
      () async {
    final item = enqueue();
    AiControlService.instance.setSettingsForTest(const AiControlSettings(
      mode: AiMode.guarded,
      dailyLimit: 10000,
    ));
    await dispatch.processNextForTest();
    expect(current(item.id).status, DispatchStatus.blocked);
    expect(orchestrated, isEmpty);
    expect(executedSources, isEmpty);
  });

  test('a controller answer without a trade is blocked with its reason',
      () async {
    dispatch.orchestrateOverride =
        (action) async => AssistantResponse.info('No route for CAKE.');
    final item = enqueue();
    await dispatch.processNextForTest();
    final resolved = current(item.id);
    expect(resolved.status, DispatchStatus.blocked);
    expect(resolved.blockReason, contains('No route for CAKE.'));
    expect(executedSources, isEmpty);
  });

  test('outside «Автономный» nothing is queued', () {
    AiControlService.instance.setSettingsForTest(const AiControlSettings(
      mode: AiMode.manual,
    ));
    final trigger = AutomationTrigger(
      id: 'manual_CAKE_x',
      assetSymbol: 'CAKE',
      type: TriggerType.manualDelegate,
      requestedAction: TriggerAction.execute,
      createdAt: DateTime.now(),
    );
    expect(
      dispatch.enqueue(trigger: trigger, reason: 'test', currentPrice: 2),
      isNull,
    );
  });
}
