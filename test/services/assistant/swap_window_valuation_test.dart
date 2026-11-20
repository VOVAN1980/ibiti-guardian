import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/app_settings.dart';
import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/portfolio_summary.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/screens/wallet/components/wallet_swap_modal.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/assistant/guardian_assistant_service.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';
import 'package:ibiti_guardian/services/assistant/swap_voice_orchestrator.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_bus.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/services/policy/tx_usd_valuer.dart';
import 'package:ibiti_guardian/services/security/ai_action_gate.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// «Автономный»: the AI may prepare the wallet Swap window, whose swap then
/// counts as the user's own. So the check before it is prepared values what
/// the window will REALLY pay, not only what the commands name:
/// (a) a named paying coin the window cannot pick on the active network
///     (not held there): the window keeps its own coin (WalletSwapModal also
///     keeps the amount out and quotes nothing) — that coin is valued;
/// (b) no paying coin named: the window keeps its own coin (e.g. ETH), not
///     "native or a stablecoin";
/// (c) no amount in the commands: the amount waiting on the bus (60 s) or
///     the open window's field.
/// A quote the window asks for by itself runs only for the coin and up to
/// the amount that check valued; an unknown value leaves it to the user.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final svc = GuardianAssistantService.instance;
  const self = '0x9999999999999999999999999999999999999999';
  const source = AssistantInputSource.generalChat;
  final windowOwner = Object();

  setUpAll(() {
    SettingsService.instance.settingsForTest = AppSettings(
      languageCode: 'ru',
      openaiApiKey: null,
      isNeuralOperatorEnabled: false,
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers',
    ]) {
      messenger.setMockMethodCallHandler(
          MethodChannel(name), (MethodCall call) async => null);
    }
  });

  WalletAsset bscAsset(
    String symbol, {
    String address = '',
    bool native = false,
    bool priced = true,
  }) =>
      WalletAsset(
        name: symbol,
        symbol: symbol,
        address: address,
        balance: 1000,
        priceUsd: 0,
        valueUsd: 0,
        decimals: 18,
        isNative: native,
        chainId: 56,
        chainKey: 'bsc',
        priceAvailable: priced,
      );

  final bnb = bscAsset('BNB', native: true);
  final eth =
      bscAsset('ETH', address: '0x2170Ed0880ac9A755fd29B2688956BD959F933F8');
  final usdt =
      bscAsset('USDT', address: '0x55d398326f99059fF775485246999027B3197955');
  final pepe = bscAsset('PEPE',
      address: '0x25d887Ce7a35172C62FeBFD67a1856F20FaEbB00', priced: false);

  /// What the wallet holds on BNB Chain — what the windows can pick there.
  void hold(List<WalletAsset> assets) {
    VaultPortfolioListener.instance.setSummaryForTest(PortfolioSummary(
      totalBalanceUsd: 0,
      assetsCount: assets.length,
      allAssets: assets,
      address: self,
      networkName: 'BSC',
      chainKey: 'bsc',
    ));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    // An unlocked wallet on BNB Chain with EPK on.
    IBITIVaultService.instance.setVaultCreatedForTest(evmAddress: self);
    await EPKPolicyManager.instance.resumeProtection();
    DelegationController.instance.resetUsageForTest();
    AiActionGate.instance.resetForTest();
    // BNB (native) and ETH (a token) are held and priced; no USDT.
    hold([bnb, eth]);
    TxUsdValuer.priceOverrideForTest = (tx) => switch (tx.tokenSymbol) {
          'BNB' => 600.0,
          'ETH' => 3000.0,
          _ => null,
        };
    // «Автономный»: position cap $1000, a large daily limit.
    AiControlService.instance.setSettingsForTest(const AiControlSettings(
      mode: AiMode.fullAutonomy,
      mandate: AutonomyMandate(maxPositionUsd: 1000),
      dailyLimit: 100000,
    ));
    // No window open, nothing waiting on the bus, no quote approved.
    ScreenContextService.instance.clearModal();
    SwapWindowLink.instance.resetForTest();
    UICommandBus.instance.backdateTimestamps(const Duration(minutes: 5));
  });

  tearDown(() {
    TxUsdValuer.priceOverrideForTest = null;
    AiActionGate.instance.resetForTest();
    ScreenContextService.instance.clearModal();
    SwapWindowLink.instance.resetForTest();
  });

  /// The Swap window is open on BNB Chain, paying [paying], with [amount]
  /// in its field.
  void openSwapWindow(String paying, {String amount = ''}) {
    ScreenContextService.instance.setModal('wallet_swap');
    ScreenContextService.instance.setSelectedFromSymbol(paying);
    SwapWindowLink.instance.publish(
      windowOwner,
      chainKey: 'bsc',
      payingSymbol: paying,
      amountText: amount,
    );
  }

  const openSwap =
      UICommand(type: UICommandType.openModal, target: 'wallet_swap');
  const quote =
      UICommand(type: UICommandType.executeAction, target: 'wallet_swap_quote');
  UICommand from(String symbol) => UICommand(
        type: UICommandType.selectToken,
        target: 'swap_from_token',
        payload: {'symbol': symbol},
      );
  UICommand to(String symbol) => UICommand(
        type: UICommandType.selectToken,
        target: 'swap_to_token',
        payload: {'symbol': symbol},
      );
  UICommand amount(String value) => UICommand(
        type: UICommandType.fillField,
        target: 'swap_amount',
        payload: {'value': value},
      );

  AssistantResponse? check(List<UICommand> commands) =>
      svc.preparedWindowRefusalForTest(commands, source, 'ru');

  bool aiQuoteRuns(String paying, double value, {String chainKey = 'bsc'}) =>
      WalletSwapModal.mayQuoteForAi(
        mode: AiMode.fullAutonomy,
        held: false,
        chainKey: chainKey,
        payingSymbol: paying,
        amount: value,
      );

  group('the normal case', () {
    test('USDT held: 500 USDT is \$500, within the cap; the window may quote '
        'exactly that once', () {
      hold([bnb, eth, usdt]);
      expect(check([openSwap, from('USDT'), to('CAKE'), amount('500'), quote]),
          isNull);
      // Another coin, a larger amount or another network: not this check.
      expect(aiQuoteRuns('BNB', 500), isFalse);
      expect(aiQuoteRuns('USDT', 600), isFalse);
      expect(aiQuoteRuns('USDT', 500, chainKey: 'ethereum'), isFalse);
      // What was checked: once.
      expect(aiQuoteRuns('USDT', 500), isTrue);
      expect(aiQuoteRuns('USDT', 500), isFalse);
    });

    test('the swap window SwapVoiceOrchestrator prepares: the same', () {
      hold([bnb, eth, usdt]);
      final r = svc.aiSwapWindowRefusalForTest(
        const IntentData(
          type: IntentType.swapAsset,
          rawInput: 'обменяй 500 USDT на CAKE',
          sourceTokenSymbol: 'USDT',
          targetTokenSymbol: 'CAKE',
          amount: 500,
        ),
        AssistantInputSource.voice,
        'ru',
      );
      expect(r, isNull);
      expect(aiQuoteRuns('USDT', 500), isTrue);
    });

    test('over the cap it is refused, and nothing is approved', () {
      hold([bnb, eth, usdt]);
      final r =
          check([openSwap, from('USDT'), to('CAKE'), amount('1500'), quote]);
      expect(r, isNotNull);
      expect(r!.message, contains('position cap'));
      expect(aiQuoteRuns('USDT', 1500), isFalse);
    });

    test('«Ручной»: the window quotes as before; a held window never does',
        () {
      expect(
          WalletSwapModal.mayQuoteForAi(
            mode: AiMode.guarded,
            held: false,
            chainKey: 'bsc',
            payingSymbol: 'BNB',
            amount: 1,
          ),
          isTrue);
      for (final mode in AiMode.values) {
        expect(
            WalletSwapModal.mayQuoteForAi(
              mode: mode,
              held: true,
              chainKey: 'bsc',
              payingSymbol: 'BNB',
              amount: 1,
            ),
            isFalse,
            reason: mode.name);
      }
    });
  });

  group('(a) a named paying coin the window cannot pick on this network', () {
    test('no window open: the swap window keeps the native coin — 500 BNB is '
        'over the cap', () {
      // 500 USDT alone would be \$500, within the cap.
      final r =
          check([openSwap, from('USDT'), to('CAKE'), amount('500'), quote]);
      expect(r, isNotNull);
      expect(r!.message, contains('position cap'));
      expect(r.message, contains(r'$300000.00'));
    });

    test('the open window keeps its own coin (ETH): 100 ETH is over the cap',
        () {
      openSwapWindow('ETH');
      final r = check([from('USDT'), amount('100'), quote]);
      expect(r, isNotNull);
      expect(r!.message, contains(r'$300000.00'));
    });

    test('the swap window SwapVoiceOrchestrator prepares: the same', () {
      final r = svc.aiSwapWindowRefusalForTest(
        const IntentData(
          type: IntentType.swapAsset,
          rawInput: 'обменяй 500 USDT на CAKE',
          sourceTokenSymbol: 'USDT',
          targetTokenSymbol: 'CAKE',
          amount: 500,
        ),
        AssistantInputSource.voice,
        'ru',
      );
      expect(r, isNotNull);
      expect(r!.message, contains(r'$300000.00'));
    });

    test('a Buy window that cannot pick USDT pays with its first held coin',
        () {
      hold([bnb]);
      final r = check([
        const UICommand(type: UICommandType.openModal, target: 'wallet_buy'),
        from('USDT'),
        to('CAKE'),
        amount('500'),
        quote,
      ]);
      expect(r, isNotNull);
      expect(r!.message, contains(r'$300000.00'));
    });
  });

  group('(b) no paying coin named: the window keeps its own', () {
    test('the open window pays ETH: 1 ETH (\$3000) is over the cap, not '
        '"native or a stablecoin" (\$600)', () {
      openSwapWindow('ETH');
      final r = check([to('CAKE'), amount('1'), quote]);
      expect(r, isNotNull);
      expect(r!.message, contains(r'$3000.00'));
    });

    test('within the cap: the window may quote that ETH amount', () {
      openSwapWindow('ETH');
      expect(check([to('CAKE'), amount('0.1'), quote]), isNull);
      expect(aiQuoteRuns('BNB', 0.1), isFalse);
      expect(aiQuoteRuns('ETH', 0.1), isTrue);
    });

    test('an open Buy window paying ETH: the same', () {
      ScreenContextService.instance.setModal('wallet_buy');
      ScreenContextService.instance.setSelectedFromSymbol('ETH');
      final r = check([amount('1'), quote]);
      expect(r, isNotNull);
      expect(r!.message, contains(r'$3000.00'));
    });
  });

  group('(c) no amount in the commands: the amount the window will use', () {
    test('the amount waiting on the bus: 2 BNB (\$1200) is over the cap', () {
      UICommandBus.instance.dispatch(amount('2'));
      final r = check([openSwap, to('CAKE'), quote]);
      expect(r, isNotNull);
      expect(r!.message, contains(r'$1200.00'));
    });

    test('the open window\'s field: 5 BNB (\$3000) is over the cap', () {
      openSwapWindow('BNB', amount: '5');
      final r = check([quote]);
      expect(r, isNotNull);
      expect(r!.message, contains(r'$3000.00'));
    });

    test('the field within the cap: the window may quote that amount', () {
      openSwapWindow('BNB', amount: '1');
      expect(check([quote]), isNull);
      expect(aiQuoteRuns('BNB', 1.5), isFalse);
      expect(aiQuoteRuns('BNB', 1), isTrue);
    });
  });

  group('an unknown value: the window does not quote by itself', () {
    test('a coin without a price: no dollar check, and no quote approved', () {
      hold([bnb, eth, pepe]);
      expect(check([openSwap, from('PEPE'), to('CAKE'), amount('1000'), quote]),
          isNull);
      expect(aiQuoteRuns('PEPE', 1000), isFalse);
    });

    test('no amount anywhere: no quote approved', () {
      hold([bnb, eth, usdt]);
      expect(check([openSwap, from('USDT'), to('CAKE'), quote]), isNull);
      expect(aiQuoteRuns('USDT', 1), isFalse);
    });
  });

  group('SwapWindowLink', () {
    test('an approval waits 60 s for its window', () {
      final at = DateTime(2026, 11, 20, 12);
      final link = SwapWindowLink.instance;
      link.approveAiQuote(chainKey: 'bsc', amounts: {'USDT': 10}, now: at);
      expect(
          link.takeAiQuoteApproval(
            chainKey: 'bsc',
            payingSymbol: 'USDT',
            amount: 10,
            now: at.add(const Duration(seconds: 61)),
          ),
          isFalse);
      link.approveAiQuote(chainKey: 'bsc', amounts: {'USDT': 10}, now: at);
      expect(
          link.takeAiQuoteApproval(
            chainKey: 'bsc',
            payingSymbol: 'usdt',
            amount: 10,
            now: at.add(const Duration(seconds: 59)),
          ),
          isTrue);
    });

    test('the open window\'s amount; only that window clears itself', () {
      final link = SwapWindowLink.instance;
      link.publish(windowOwner,
          chainKey: 'bsc', payingSymbol: 'bnb', amountText: ' 1,5 ');
      expect(link.isOpen, isTrue);
      expect(link.payingSymbol, 'BNB');
      expect(link.amount, 1.5);
      link.clear(Object());
      expect(link.isOpen, isTrue);
      link.clear(windowOwner);
      expect(link.isOpen, isFalse);
      expect(link.amount, isNull);
    });
  });

  group('the Swap window picks only a coin it can pick (never a silent '
      'switch)', () {
    final synthetic = bscAsset('BNB', native: true);
    WalletAsset nativeAsset() => synthetic;

    test('a coin of its list', () {
      final pick = WalletSwapModal.pickForAiCommand(
        symbol: 'USDT',
        pickerAssets: [bnb, usdt],
        current: null,
        isFrom: true,
        nativeSymbol: 'BNB',
        nativeAsset: nativeAsset,
      );
      expect(pick, isNotNull);
      expect(pick!.asset, same(usdt));
    });

    test('the native coin: kept as "no coin" on the paying side, the native '
        'entry on the receiving side', () {
      final paying = WalletSwapModal.pickForAiCommand(
        symbol: 'BNB',
        pickerAssets: const [],
        current: null,
        isFrom: true,
        nativeSymbol: 'BNB',
        nativeAsset: nativeAsset,
      );
      expect(paying, isNotNull);
      expect(paying!.asset, isNull);
      final receiving = WalletSwapModal.pickForAiCommand(
        symbol: 'BNB',
        pickerAssets: const [],
        current: null,
        isFrom: false,
        nativeSymbol: 'BNB',
        nativeAsset: nativeAsset,
      );
      expect(receiving, isNotNull);
      expect(receiving!.asset, same(synthetic));
    });

    test('the coin the window already has on that side', () {
      final cake = bscAsset('CAKE', address: '0xcake');
      final pick = WalletSwapModal.pickForAiCommand(
        symbol: 'CAKE',
        pickerAssets: [bnb],
        current: cake,
        isFrom: false,
        nativeSymbol: 'BNB',
        nativeAsset: nativeAsset,
      );
      expect(pick, isNotNull);
      expect(pick!.asset, same(cake));
    });

    test('a coin it cannot pick: none (the window keeps its coins)', () {
      for (final isFrom in [true, false]) {
        expect(
            WalletSwapModal.pickForAiCommand(
              symbol: 'USDT',
              pickerAssets: [bnb, eth],
              current: eth,
              isFrom: isFrom,
              nativeSymbol: 'BNB',
              nativeAsset: nativeAsset,
            ),
            isNull,
            reason: 'isFrom: $isFrom');
      }
    });
  });
}
