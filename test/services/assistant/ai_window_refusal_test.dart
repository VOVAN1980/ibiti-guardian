import 'dart:async';
import 'dart:ui' show Locale;

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/app_settings.dart';
import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/portfolio_summary.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/assistant/guardian_assistant_service.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';
import 'package:ibiti_guardian/services/assistant/swap_voice_orchestrator.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_bus.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/services/policy/tx_usd_valuer.dart';
import 'package:ibiti_guardian/services/security/ai_action_gate.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// «Автономный»: the windows the AI prepares instead of running an
/// operation itself (D17, a balance share, the model's own window
/// commands) are the user's own, so the AI's limits hold before they are
/// prepared (D6):
/// - the USD value comes from the paying side at its portfolio price, so a
///   window is never a way around the position cap or the daily limit;
/// - over a limit or outside «AI Мандат»: refused with the «Политика» hint;
/// - AI permissions off / expired or EPK paused: no window either, but the
///   answer says why, how to let the AI act again and that the user can do
///   it in the wallet window;
/// - the voice says «подтвердите на экране» whenever the gate will ask.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final svc = GuardianAssistantService.instance;
  const self = '0x9999999999999999999999999999999999999999';

  final dispatched = <UICommand>[];
  StreamSubscription<UICommand>? subscription;

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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    // An unlocked wallet on BNB Chain with EPK on.
    IBITIVaultService.instance.setVaultCreatedForTest(evmAddress: self);
    await EPKPolicyManager.instance.resumeProtection();
    DelegationController.instance.resetUsageForTest();
    AiActionGate.instance.resetForTest();
    // Nothing held: prices come from the hook below only.
    VaultPortfolioListener.instance.setSummaryForTest(PortfolioSummary(
      totalBalanceUsd: 0,
      assetsCount: 0,
      allAssets: const [],
      address: self,
      networkName: 'BSC',
      chainKey: 'bsc',
    ));
    // BNB is priced in the portfolio; PEPE and CAKE are not.
    TxUsdValuer.priceOverrideForTest =
        (tx) => tx.tokenSymbol == 'BNB' ? 600.0 : null;
    // No window open, nothing waiting on the bus, no quote approved.
    ScreenContextService.instance.clearModal();
    SwapWindowLink.instance.resetForTest();
    UICommandBus.instance.backdateTimestamps(const Duration(minutes: 5));
    dispatched.clear();
    subscription = UICommandBus.instance.commands.listen(dispatched.add);
  });

  tearDown(() async {
    TxUsdValuer.priceOverrideForTest = null;
    AiActionGate.instance.resetForTest();
    ScreenContextService.instance.clearModal();
    SwapWindowLink.instance.resetForTest();
    await subscription?.cancel();
    subscription = null;
  });

  /// The wallet holds [symbols] on BNB Chain (no price of their own): the
  /// swap and Buy windows can pick them there.
  void holdOnBsc(List<String> symbols) {
    VaultPortfolioListener.instance.setSummaryForTest(PortfolioSummary(
      totalBalanceUsd: 0,
      assetsCount: symbols.length,
      allAssets: [
        for (var i = 0; i < symbols.length; i++)
          WalletAsset(
            name: symbols[i],
            symbol: symbols[i],
            address: '0x${(i + 1).toRadixString(16).padLeft(40, 'a')}',
            balance: 1000,
            priceUsd: 0,
            valueUsd: 0,
            decimals: 18,
            chainId: 56,
            chainKey: 'bsc',
            priceAvailable: false,
          ),
      ],
      address: self,
      networkName: 'BSC',
      chainKey: 'bsc',
    ));
  }

  void autonomous({
    AutonomyMandate mandate = const AutonomyMandate(maxPositionUsd: 10000),
    double dailyLimit = 100000,
    List<AiAction>? allowedActions,
    DateTime? permissionsExpiry,
    bool aiPinConfirm = true,
  }) {
    AiControlService.instance.setSettingsForTest(AiControlSettings(
      mode: AiMode.fullAutonomy,
      mandate: mandate,
      dailyLimit: dailyLimit,
      allowedActions: allowedActions ?? const AiControlSettings().allowedActions,
      permissionsExpiry: permissionsExpiry,
      aiPinConfirm: aiPinConfirm,
    ));
  }

  String raiseHintWords() => 'Raise the';

  IntentData swap(String from, String to, double? amount,
          {AmountMode? amountMode}) =>
      IntentData(
        type: IntentType.swapAsset,
        rawInput: 'обменяй $from на $to',
        sourceTokenSymbol: from,
        targetTokenSymbol: to,
        amount: amount,
        amountMode: amountMode,
      );

  group('the USD value of a swap window is the paying side at its '
      'portfolio price', () {
    test('1 BNB (≈ \$600) for a coin the AI cannot resolve: over the '
        'position cap, refused, no window', () async {
      autonomous(mandate: const AutonomyMandate(maxPositionUsd: 100));
      final r = svc.aiSwapWindowRefusalForTest(
          swap('BNB', 'PEPE', 1), AssistantInputSource.generalChat, 'ru');
      expect(r, isNotNull);
      expect(r!.message, contains('position cap'));
      expect(r.message, contains(r'$600.00'));
      expect(r.message, contains(raiseHintWords()));
      // The same through the window path: nothing is dispatched.
      final w = await svc.swapWindowResponseForTest(
          swap('BNB', 'PEPE', 1), 'ru', AssistantInputSource.voice);
      await Future<void>.delayed(Duration.zero);
      expect(w.message, contains('position cap'));
      expect(dispatched, isEmpty);
      expect(w.uiCommands, isEmpty);
    });

    test('selling 0.5 BNB (≈ \$300) over the daily limit: refused', () {
      autonomous(dailyLimit: 200);
      final r = svc.aiSwapWindowRefusalForTest(
          swap('BNB', 'USDT', 0.5), AssistantInputSource.marketChat, 'ru');
      expect(r, isNotNull);
      expect(r!.message, contains('daily trading limit'));
      expect(r.message, contains(raiseHintWords()));
    });

    test('an exact-out amount is still the paying side\'s: the window fills '
        'it there', () {
      autonomous(mandate: const AutonomyMandate(maxPositionUsd: 100));
      final r = svc.aiSwapWindowRefusalForTest(
          swap('USDT', 'CAKE', 500, amountMode: AmountMode.exactOut),
          AssistantInputSource.generalChat,
          'ru');
      expect(r, isNotNull);
      expect(r!.message, contains('position cap'));
    });

    test('within the cap and the limit: the window may open', () {
      autonomous(mandate: const AutonomyMandate(maxPositionUsd: 1000));
      expect(
          svc.aiSwapWindowRefusalForTest(
              swap('BNB', 'PEPE', 1), AssistantInputSource.voice, 'ru'),
          isNull);
    });

    test('a truly unknown price skips only the dollar checks', () {
      // PEPE is in the wallet (so the window pays with it), without a price.
      holdOnBsc(['PEPE']);
      autonomous(
          mandate: const AutonomyMandate(maxPositionUsd: 1), dailyLimit: 1);
      expect(
          svc.aiSwapWindowRefusalForTest(
              swap('PEPE', 'CAKE', 1000), AssistantInputSource.voice, 'ru'),
          isNull);
      // «AI Мандат» still holds without a price.
      autonomous(mandate: const AutonomyMandate(allowedAssets: ['BNB']));
      final r = svc.aiSwapWindowRefusalForTest(
          swap('PEPE', 'CAKE', 1000), AssistantInputSource.voice, 'ru');
      expect(r, isNotNull);
      expect(r!.message, contains('AI Mandate'));
    });

    test('«Ручной» prepares the window as the user\'s own: no AI check', () {
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.guarded,
        mandate: AutonomyMandate(maxPositionUsd: 1),
      ));
      expect(
          svc.aiSwapWindowRefusalForTest(
              swap('BNB', 'PEPE', 1), AssistantInputSource.voice, 'ru'),
          isNull);
    });
  });

  group('a gate block that is not a limit: no window, but a plain answer '
      'and the way to do it yourself', () {
    final noAmount = swap('USDT', 'BNB', null);

    test('EPK paused: why, how to resume it, and the wallet window',
        () async {
      autonomous();
      await EPKPolicyManager.instance.emergencyPause();
      final r = await svc.swapWindowResponseForTest(
          noAmount, 'ru', AssistantInputSource.voice);
      await Future<void>.delayed(Duration.zero);
      expect(r.message, contains('EPK protection is paused'));
      expect(r.message, contains('EPK screen'));
      expect(r.message, contains('wallet window'));
      expect(r.message, isNot(contains(raiseHintWords())));
      expect(r.speechText, r.message);
      expect(dispatched, isEmpty);
      expect(r.uiCommands, isEmpty);
    });

    test('the AI swap permission off: why, how to allow it, and the wallet '
        'window', () async {
      autonomous(allowedActions: const [AiAction.openWindows, AiAction.send]);
      final r = await svc.swapWindowResponseForTest(
          noAmount, 'ru', AssistantInputSource.marketChat);
      await Future<void>.delayed(Duration.zero);
      expect(r.message, contains('turned off for the AI'));
      expect(r.message, contains('turn this action on'));
      expect(r.message, contains('wallet window'));
      expect(r.message, isNot(contains(raiseHintWords())));
      expect(dispatched, isEmpty);
    });

    test('AI permissions expired: why and the wallet window', () async {
      autonomous(permissionsExpiry: DateTime(2000));
      final r = await svc.swapWindowResponseForTest(
          noAmount, 'ru', AssistantInputSource.generalChat);
      await Future<void>.delayed(Duration.zero);
      expect(r.message, contains('expired'));
      expect(r.message, contains('wallet window'));
      expect(r.message, isNot(contains('turn this action on')));
      expect(dispatched, isEmpty);
    });

    test('outside «AI Мандат» (also with EPK paused): the limit refusal with '
        'the «Политика» hint, no «do it yourself»', () async {
      autonomous(mandate: const AutonomyMandate(allowedNetworks: ['tron']));
      for (final paused in [false, true]) {
        if (paused) await EPKPolicyManager.instance.emergencyPause();
        final r = await svc.swapWindowResponseForTest(
            noAmount, 'ru', AssistantInputSource.voice);
        expect(r.message, contains('AI Mandate'), reason: '$paused');
        expect(r.message, contains(raiseHintWords()), reason: '$paused');
        expect(r.message, isNot(contains('wallet window')), reason: '$paused');
      }
      await Future<void>.delayed(Duration.zero);
      expect(dispatched, isEmpty);
    });
  });

  group('the model\'s own window commands pass the same check', () {
    const buyWindow = [
      UICommand(type: UICommandType.openModal, target: 'wallet_buy'),
      UICommand(
        type: UICommandType.selectToken,
        target: 'swap_from_token',
        payload: {'symbol': 'USDT'},
      ),
      UICommand(
        type: UICommandType.selectToken,
        target: 'swap_to_token',
        payload: {'symbol': 'PEPE'},
      ),
      UICommand(
        type: UICommandType.fillField,
        target: 'swap_amount',
        payload: {'value': '500'},
      ),
      UICommand(
        type: UICommandType.executeAction,
        target: 'wallet_swap_quote',
      ),
    ];

    test('a prefilled Buy window over the position cap is refused', () {
      autonomous(mandate: const AutonomyMandate(maxPositionUsd: 100));
      final r = svc.preparedWindowRefusalForTest(
          buyWindow, AssistantInputSource.generalChat, 'ru');
      expect(r, isNotNull);
      expect(r!.message, contains('position cap'));
      expect(r.message, contains(raiseHintWords()));
    });

    test('within the cap it may be dispatched', () {
      // USDT is in the wallet, so the Buy window pays with it.
      holdOnBsc(['USDT']);
      autonomous(mandate: const AutonomyMandate(maxPositionUsd: 1000));
      expect(
          svc.preparedWindowRefusalForTest(
              buyWindow, AssistantInputSource.generalChat, 'ru'),
          isNull);
    });

    test('a swap window paid in BNB is valued at the BNB price', () {
      autonomous(mandate: const AutonomyMandate(maxPositionUsd: 100));
      final r = svc.preparedWindowRefusalForTest(const [
        UICommand(type: UICommandType.openModal, target: 'wallet_swap'),
        UICommand(
          type: UICommandType.selectToken,
          target: 'swap_from_token',
          payload: {'symbol': 'BNB'},
        ),
        UICommand(
          type: UICommandType.fillField,
          target: 'swap_amount',
          payload: {'value': '1'},
        ),
      ], AssistantInputSource.voice, 'ru');
      expect(r, isNotNull);
      expect(r!.message, contains(r'$600.00'));
    });

    test('a prefilled send window outside the «AI Мандат» networks is '
        'refused', () {
      autonomous(mandate: const AutonomyMandate(allowedNetworks: ['tron']));
      final r = svc.preparedWindowRefusalForTest(const [
        UICommand(type: UICommandType.openModal, target: 'wallet_send'),
        UICommand(
          type: UICommandType.selectToken,
          target: 'send_token',
          payload: {'symbol': 'USDT'},
        ),
        UICommand(
          type: UICommandType.fillField,
          target: 'send_amount',
          payload: {'value': '10'},
        ),
      ], AssistantInputSource.generalChat, 'ru');
      expect(r, isNotNull);
      expect(r!.message, contains('AI Mandate'));
    });

    test('an exchange buy window over the cap or outside the venues is '
        'refused', () {
      const order = [
        UICommand(
          type: UICommandType.openModal,
          target: 'cex_trade',
          payload: {
            'symbol': 'SOL',
            'isBuy': true,
            'exchangeId': 'mexc',
            'initialAmount': 500,
            'price': 100,
          },
        ),
      ];
      autonomous(mandate: const AutonomyMandate(maxPositionUsd: 100));
      expect(
          svc.preparedWindowRefusalForTest(
                  order, AssistantInputSource.generalChat, 'ru')
              ?.message,
          contains('position cap'));
      autonomous(mandate: const AutonomyMandate(allowedVenues: ['okx']));
      expect(
          svc.preparedWindowRefusalForTest(
                  order, AssistantInputSource.generalChat, 'ru')
              ?.message,
          contains('AI Mandate'));
      autonomous();
      expect(
          svc.preparedWindowRefusalForTest(
              order, AssistantInputSource.generalChat, 'ru'),
          isNull);
    });

    test('a window only opened, with nothing filled in, prepares nothing',
        () {
      autonomous(mandate: const AutonomyMandate(allowedNetworks: ['tron']));
      expect(
          svc.preparedWindowRefusalForTest(const [
            UICommand(type: UICommandType.openModal, target: 'wallet_buy'),
          ], AssistantInputSource.generalChat, 'ru'),
          isNull);
    });

    test('«Ручной» and automation: not checked here', () {
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.guarded,
        mandate: AutonomyMandate(maxPositionUsd: 1),
      ));
      expect(
          svc.preparedWindowRefusalForTest(
              buyWindow, AssistantInputSource.voice, 'ru'),
          isNull);
      autonomous(mandate: const AutonomyMandate(maxPositionUsd: 1));
      expect(
          svc.preparedWindowRefusalForTest(
              buyWindow, AssistantInputSource.automated, 'ru'),
          isNull);
    });
  });

  group('whether the gate will show the card for an exchange order', () {
    const order = AiActionSummary(
      kind: AiActionKind.cexOrder,
      title: 'Buy SOL on MEXC',
      amountLabel: '20 USDT',
      valueUsd: 20,
      venue: 'mexc',
      assetSymbol: 'SOL',
    );

    test('PIN setting off, unlocked, EPK on: no card', () {
      autonomous(aiPinConfirm: false);
      expect(GuardianAssistantService.gateWillAskForTest(order), false);
    });

    test('EPK paused: the card (an exchange order asks first)', () async {
      autonomous(aiPinConfirm: false);
      await EPKPolicyManager.instance.emergencyPause();
      expect(GuardianAssistantService.gateWillAskForTest(order), true);
    });

    test('the PIN setting on, or an unknown value: the card', () {
      autonomous();
      expect(GuardianAssistantService.gateWillAskForTest(order), true);
      autonomous(aiPinConfirm: false);
      expect(
          GuardianAssistantService.gateWillAskForTest(const AiActionSummary(
            kind: AiActionKind.cexOrder,
            title: '',
            amountLabel: '',
            valueUsd: null,
          )),
          true);
    });
  });

  group('the «Политика» hint in every language', () {
    test('German: a controller refusal over «AI Мандат» carries the German '
        'hint', () async {
      await LocalizationService.instance.load(const Locale('de'));
      final hint = LocalizationService.instance.t('aiExecLimitHint');
      expect(hint, isNot('aiExecLimitHint'));
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.fullAutonomy,
        mandate: AutonomyMandate(allowedNetworks: ['tron']),
      ));
      final r = await svc.process(
        'отправь 10 USDT на 0x1111111111111111111111111111111111111111',
        languageCode: 'de',
        source: AssistantInputSource.voice,
      );
      expect(r.message, contains(hint));
      expect(dispatched.where((c) => c.target == 'wallet_send'), isEmpty);
    });
  });
}
