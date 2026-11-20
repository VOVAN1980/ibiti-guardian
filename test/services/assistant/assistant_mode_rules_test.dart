import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/app_settings.dart';
import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/portfolio_summary.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/screens/assistant/components/assistant_chat_screen.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/assistant/guardian_assistant_service.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_bus.dart';
import 'package:ibiti_guardian/services/execution/ai_onchain_executor.dart';
import 'package:ibiti_guardian/services/execution/guardian_execution_controller.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/policy/tx_usd_valuer.dart';
import 'package:ibiti_guardian/services/security/ai_action_gate.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/services/swap/zerox_swap_provider.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The assistant's rules for the AI modes that sit outside the gate: which
/// token the AI may trade by itself, which window it may prepare, how it
/// words the card line and the mode texts.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final svc = GuardianAssistantService.instance;

  // The vetted CAKE on BNB Chain (TokenRegistryService) and a look-alike.
  const vettedCake = '0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82';
  const fakeCake = '0x5ca5ca5ca5ca5ca5ca5ca5ca5ca5ca5ca5ca5ca5';
  const self = '0x9999999999999999999999999999999999999999';
  const recipient = '0x1111111111111111111111111111111111111111';

  final dispatched = <UICommand>[];
  StreamSubscription<UICommand>? subscription;

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    SettingsService.instance.settingsForTest = AppSettings(
      languageCode: 'ru',
      openaiApiKey: null,
      isNeuralOperatorEnabled: false,
    );
    // The voice persona (TTS) creates an audio player on first use.
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

  setUp(() {
    dispatched.clear();
    subscription = UICommandBus.instance.commands.listen(dispatched.add);
    AiControlService.instance.setSettingsForTest(
      const AiControlSettings(mode: AiMode.guarded),
    );
  });

  tearDown(() async {
    await subscription?.cancel();
    subscription = null;
  });

  WalletAsset bscToken(String symbol, String address, {double value = 50}) =>
      WalletAsset(
        name: symbol,
        symbol: symbol,
        address: address,
        balance: value,
        priceUsd: 1.0,
        valueUsd: value,
        decimals: 18,
        chainId: 56,
        chainKey: 'bsc',
      );

  void holdOnBsc(List<WalletAsset> assets) {
    VaultPortfolioListener.instance.setSummaryForTest(PortfolioSummary(
      totalBalanceUsd: assets.fold(0.0, (s, a) => s + a.valueUsd),
      assetsCount: assets.length,
      allAssets: assets,
      address: self,
      networkName: 'BSC',
      chainKey: 'bsc',
    ));
  }

  bool sameAddress(String? a, String b) => a?.toLowerCase() == b.toLowerCase();

  /// A real controller refusal outside the «AI Мандат» networks, with the
  /// code the controller gives it.
  AssistantResponse mandateRefusal() {
    final saved = AiControlService.instance.settings;
    AiControlService.instance.setSettingsForTest(const AiControlSettings(
      mode: AiMode.guarded,
      mandate: AutonomyMandate(allowedNetworks: ['tron']),
    ));
    try {
      final refusal = GuardianExecutionController.instance
          .checkAiTransactionControlForTest(const TransactionRequest(
        type: TransactionType.send,
        fromAddress: self,
        toAddress: recipient,
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent:
            IntentData(type: IntentType.sendAsset, rawInput: 'send'),
        tokenSymbol: 'USDT',
        amount: 10,
      ));
      expect(refusal, isNotNull);
      expect(GuardianExecutionController.isRaisableRefusal(refusal!.detail),
          true);
      return refusal;
    } finally {
      AiControlService.instance.setSettingsForTest(saved);
    }
  }

  /// The «Политика» hint the assistant appends, in the app's language.
  String raiseHint() => LocalizationService.instance.t('aiExecLimitHint', {
        'default': 'Want more? Raise the threshold in «Policy» (PIN needed).',
      });

  group('the token the AI trades by itself: the vetted registry first', () {
    test('a look-alike with the same symbol is never bought', () {
      // An airdropped fake "CAKE", priced by its symbol like the real one.
      holdOnBsc([bscToken('CAKE', fakeCake, value: 500)]);
      final side = svc.resolveSwapSideForTest('CAKE', paying: false);
      expect(sameAddress(side?.address, vettedCake), true);
      expect(side?.decimals, 18);
    });

    test('paying with a symbol held only as a look-alike: cannot be '
        'resolved reliably (the prefilled window opens, D17)', () {
      holdOnBsc([bscToken('CAKE', fakeCake, value: 500)]);
      expect(svc.resolveSwapSideForTest('CAKE', paying: true), isNull);
    });

    test('paying with the vetted token works, even next to a look-alike', () {
      holdOnBsc([
        bscToken('CAKE', fakeCake, value: 500),
        bscToken('CAKE', vettedCake.toLowerCase(), value: 20),
      ]);
      final side = svc.resolveSwapSideForTest('CAKE', paying: true);
      expect(sameAddress(side?.address, vettedCake), true);
    });

    test('a coin not vetted on this network is not resolved, held or not',
        () {
      // PEPE is vetted on Ethereum only; the wallet holds a "PEPE" on BSC.
      holdOnBsc([bscToken('PEPE', fakeCake, value: 500)]);
      expect(svc.resolveSwapSideForTest('PEPE', paying: false), isNull);
      expect(svc.resolveSwapSideForTest('PEPE', paying: true), isNull);
      expect(svc.resolveSwapSideForTest('NOSUCHCOIN', paying: false), isNull);
    });

    test('the network\'s native coin needs no contract', () {
      holdOnBsc(const []);
      final side = svc.resolveSwapSideForTest('BNB', paying: true);
      expect(side?.address, ZeroXSwapProvider.nativeTokenSentinel);
      expect(side?.decimals, 18);
    });
  });

  group('the chat line for the card names the amount once', () {
    test('title and amount', () {
      const send = AiActionSummary(
        kind: AiActionKind.onChainSend,
        title: 'Send USDT to 0x1111…1111',
        amountLabel: '5 USDT',
        valueUsd: 5,
      );
      expect(GuardianAssistantService.whatOfForTest(send),
          'Send USDT to 0x1111…1111 — 5 USDT');
    });

    test('a title that already has the amount is not repeated', () {
      const send = AiActionSummary(
        kind: AiActionKind.onChainSend,
        title: 'Send 5 USDT',
        amountLabel: '5 USDT',
        valueUsd: 5,
      );
      expect(GuardianAssistantService.whatOfForTest(send), 'Send 5 USDT');
    });

    test('the executor\'s own send card: «5 USDT» once', () {
      const intent = IntentData(
        type: IntentType.sendAsset,
        rawInput: 'отправь 5 USDT',
        tokenSymbol: 'USDT',
        amount: 5,
        toAddress: recipient,
      );
      const tx = TransactionRequest(
        type: TransactionType.send,
        fromAddress: self,
        toAddress: recipient,
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent: intent,
        tokenSymbol: 'USDT',
        amount: 5,
      );
      final summary = AiOnchainExecutor.summaryFor(
        const AssistantResponse(
          message: '',
          type: ResponseType.preview,
          pendingTransaction: tx,
          executionPath: ExecutionPath.localProtected,
        ),
        source: 'voice',
      );
      final what = GuardianAssistantService.whatOfForTest(summary);
      expect('5 USDT'.allMatches(what), hasLength(1), reason: what);
    });
  });

  group('«Ручной», voice / market chat: the prefilled send window (D3)', () {
    const intent = IntentData(
      type: IntentType.sendAsset,
      rawInput: 'отправь 10 USDT на $recipient',
      tokenSymbol: 'USDT',
      amount: 10,
      toAddress: recipient,
    );
    const ready = AssistantResponse(
      message: 'Please review and confirm this transaction.',
      type: ResponseType.preview,
      pendingTransaction: TransactionRequest(
        type: TransactionType.send,
        fromAddress: self,
        toAddress: recipient,
        chainId: 56,
        chainKey: 'bsc',
        sourceIntent: intent,
        tokenSymbol: 'USDT',
        amount: 10,
      ),
      executionPath: ExecutionPath.localProtected,
    );

    test('an accepted transfer opens the filled send window', () async {
      final r = svc.sendWindowResponseForTest(ready, intent, 'ru');
      await Future<void>.delayed(Duration.zero);
      expect(r.type, ResponseType.info);
      expect(r.message, contains('Открываю заполненное окно отправки'));
      expect(r.message, contains('ПИН'));
      // The window opens first, then its fields are filled; its preview
      // (Confirm + PIN) is requested.
      expect(dispatched.first.type, UICommandType.openModal);
      expect(dispatched.first.target, 'wallet_send');
      expect(
          dispatched.any((c) =>
              c.type == UICommandType.selectToken &&
              c.target == 'send_token' &&
              c.payload?['symbol'] == 'USDT'),
          true);
      expect(
          dispatched.any((c) =>
              c.target == 'send_address' && c.payload?['value'] == recipient),
          true);
      expect(dispatched.any((c) => c.target == 'send_amount'), true);
      expect(
          dispatched.any((c) =>
              c.type == UICommandType.executeAction &&
              c.target == 'wallet_send_preview'),
          true);
      expect(r.uiCommands.first.target, 'wallet_send');
    });

    test('a refused transfer over «AI Мандат»: the reason with the '
        '«Политика» hint, nothing prefilled', () async {
      final refusal = mandateRefusal();
      final r = svc.sendWindowResponseForTest(refusal, intent, 'ru');
      await Future<void>.delayed(Duration.zero);
      expect(r.type, ResponseType.error);
      expect(r.message, contains(refusal.message));
      expect(r.message, contains(raiseHint()));
      expect(dispatched, isEmpty);
      expect(r.uiCommands, isEmpty);
    });

    test('the hint is decided by the refusal\'s code, not its words: in '
        'any language over a limit, never for another refusal', () async {
      // The controller's code with a text in a language the old word list
      // did not know (German).
      final coded = AssistantResponse.error(
        'BSC gehört nicht zu den Netzwerken des „KI-Mandats“.',
        detail: mandateRefusal().detail,
      );
      final r = svc.sendWindowResponseForTest(coded, intent, 'de');
      expect(r.message, contains(raiseHint()));

      // Limit words without the code (not a refusal the user lifts in
      // «Политика»): no hint.
      final plain = svc.sendWindowResponseForTest(
        AssistantResponse.error('Over the per-transfer limit.'),
        intent,
        'ru',
      );
      expect(plain.message, isNot(contains(raiseHint())));
      await Future<void>.delayed(Duration.zero);
      expect(dispatched, isEmpty);
    });

    test('«Открытие окон» off: says so, nothing prefilled', () async {
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.guarded,
        allowedActions: [AiAction.send],
      ));
      final r = svc.sendWindowResponseForTest(ready, intent, 'ru');
      await Future<void>.delayed(Duration.zero);
      expect(r.message, contains('Откройте отправку сами'));
      expect(dispatched, isEmpty);
    });

    test('a send window already open is filled, not opened a second time',
        () async {
      ScreenContextService.instance.setModal('wallet_send');
      addTearDown(ScreenContextService.instance.clearModal);
      final r = svc.sendWindowResponseForTest(ready, intent, 'ru');
      await Future<void>.delayed(Duration.zero);
      expect(r.message, contains('Заполняю окно отправки'));
      expect(dispatched.any((c) => c.type == UICommandType.openModal), false);
      expect(
          dispatched.any((c) =>
              c.target == 'send_address' && c.payload?['value'] == recipient),
          true);
      expect(
          dispatched.any((c) =>
              c.type == UICommandType.executeAction &&
              c.target == 'wallet_send_preview'),
          true);
    });
  });

  group('the general chat shows an AI result that did not run, but did '
      'not fail, as a note — never as an error', () {
    test('done: an action', () {
      expect(
          aiExecResultResponseType(const AiExecResult(
            executed: true,
            message: 'Done.',
            gateOutcome: AiGateOutcome.execute,
          )),
          ResponseType.action);
    });

    test('the card timed out or the app went to the background: a note',
        () {
      const interrupted = AiExecResult(
        executed: false,
        interrupted: true,
        message: 'The confirmation card closed without an answer.',
        gateOutcome: AiGateOutcome.cancelled,
      );
      expect(interrupted.deferred, true);
      expect(aiExecResultResponseType(interrupted), ResponseType.info);
    });

    test('another AI operation was running, or nobody could be asked: a '
        'note', () {
      for (final outcome in [AiGateOutcome.busy, AiGateOutcome.unavailable]) {
        expect(
            aiExecResultResponseType(AiExecResult(
              executed: false,
              message: 'Later.',
              gateOutcome: outcome,
            )),
            ResponseType.info,
            reason: outcome.name);
      }
    });

    test('the user said no: a note', () {
      expect(
          aiExecResultResponseType(const AiExecResult(
            executed: false,
            cancelled: true,
            declined: true,
            message: 'Cancelled.',
            gateOutcome: AiGateOutcome.cancelled,
          )),
          ResponseType.info);
    });

    test('refused or failed: an error', () {
      expect(
          aiExecResultResponseType(const AiExecResult(
            executed: false,
            message: 'Outside the «AI Mandate».',
            gateOutcome: AiGateOutcome.blocked,
          )),
          ResponseType.error);
      expect(
          aiExecResultResponseType(const AiExecResult(
            executed: false,
            message: 'The swap failed.',
            gateOutcome: AiGateOutcome.execute,
          )),
          ResponseType.error);
    });
  });

  test('the model can never mark a window as the user\'s own macro window '
      '(nor fake an order result)', () {
    final guarded = svc.guardLlmUiCommandsForTest(const [
      UICommand(
        type: UICommandType.openModal,
        target: 'panic',
        payload: {'byUserMacro': true},
      ),
      UICommand(
        type: UICommandType.openModal,
        target: 'cex_trade',
        payload: {'symbol': 'SOL', 'isSuccess': true, 'byUserMacro': true},
      ),
    ], userText: 'открой панику');
    expect(guarded, hasLength(2));
    expect(guarded[0].target, 'panic');
    expect(guarded[0].payload?.containsKey('byUserMacro') ?? false, false);
    expect(guarded[1].payload?['symbol'], 'SOL');
    expect(guarded[1].payload?.containsKey('isSuccess'), false);
    expect(guarded[1].payload?.containsKey('byUserMacro'), false);
  });

  group('«Автономный»: the prefilled swap window never opens around «AI '
      'Мандат» or a limit (D6)', () {
    // No amount: the AI cannot run it itself, so it would open the window.
    const noAmount = IntentData(
      type: IntentType.swapAsset,
      rawInput: 'обменяй USDT на CAKE',
      sourceTokenSymbol: 'USDT',
      targetTokenSymbol: 'CAKE',
    );
    const overCap = IntentData(
      type: IntentType.swapAsset,
      rawInput: 'обменяй 500 USDT на CAKE',
      sourceTokenSymbol: 'USDT',
      targetTokenSymbol: 'CAKE',
      amount: 500,
    );

    Future<void> expectRefused(
      IntentData intent,
      AutonomyMandate mandate,
      String why,
    ) async {
      AiControlService.instance.setSettingsForTest(AiControlSettings(
        mode: AiMode.fullAutonomy,
        mandate: mandate,
      ));
      for (final source in [
        AssistantInputSource.voice,
        AssistantInputSource.marketChat,
        AssistantInputSource.generalChat,
      ]) {
        dispatched.clear();
        final r = await svc.swapWindowResponseForTest(intent, 'ru', source);
        await Future<void>.delayed(Duration.zero);
        expect(r.message, contains(why), reason: source.name);
        expect(r.message, contains('Policy'), reason: source.name);
        expect(dispatched, isEmpty, reason: source.name);
        expect(r.uiCommands, isEmpty, reason: source.name);
      }
    }

    test('outside the «AI Мандат» networks', () async {
      await expectRefused(
          noAmount, const AutonomyMandate(allowedNetworks: ['tron']),
          'AI Mandate');
    });

    test('outside the «AI Мандат» assets', () async {
      await expectRefused(
          noAmount, const AutonomyMandate(allowedAssets: ['BNB']),
          'AI Mandate');
    });

    test('a buy paid in a stablecoin over the position cap', () async {
      await expectRefused(
          overCap, const AutonomyMandate(maxPositionUsd: 100),
          'position cap');
    });
  });

  group('general chat, «Автономный»: no USD value opens the filled window '
      'instead of a card the AI would refuse (D17)', () {
    const cakeSend = IntentData(
      type: IntentType.sendAsset,
      rawInput: 'отправь 10 CAKE на $recipient',
      tokenSymbol: 'CAKE',
      amount: 10,
      toAddress: recipient,
    );
    const usdtSend = IntentData(
      type: IntentType.sendAsset,
      rawInput: 'отправь 10 USDT на $recipient',
      tokenSymbol: 'USDT',
      amount: 10,
      toAddress: recipient,
    );
    const usdt = '0x55d398326f99059fF775485246999027B3197955';

    AssistantResponse preview(IntentData intent, String contract) =>
        AssistantResponse(
          message: 'Please review and confirm this transaction.',
          type: ResponseType.preview,
          pendingTransaction: TransactionRequest(
            type: TransactionType.send,
            fromAddress: self,
            toAddress: recipient,
            chainId: 56,
            chainKey: 'bsc',
            sourceIntent: intent,
            tokenSymbol: intent.tokenSymbol,
            tokenContract: contract,
            amount: intent.amount,
          ),
          executionPath: ExecutionPath.localProtected,
        );

    setUp(() async {
      AiControlService.instance.setSettingsForTest(
        const AiControlSettings(mode: AiMode.fullAutonomy),
      );
      // CAKE has no price; stablecoins are 1:1.
      TxUsdValuer.priceOverrideForTest =
          (tx) => tx.tokenSymbol == 'CAKE' ? null : 1.0;
      // An unlocked wallet with EPK on: the gate lets the window open.
      FlutterSecureStorage.setMockInitialValues({});
      IBITIVaultService.instance.setVaultCreatedForTest(evmAddress: self);
      await EPKPolicyManager.instance.resumeProtection();
    });

    tearDown(() => TxUsdValuer.priceOverrideForTest = null);

    test('EPK paused: no window, the reason and the way to do it yourself',
        () async {
      await EPKPolicyManager.instance.emergencyPause();
      addTearDown(EPKPolicyManager.instance.resumeProtection);
      final r = svc.chatUnknownValueWindowForTest(
          preview(cakeSend, vettedCake), cakeSend, 'ru');
      await Future<void>.delayed(Duration.zero);
      expect(r, isNotNull);
      expect(r!.type, ResponseType.info);
      expect(r.message, contains('EPK'));
      expect(r.message, contains('wallet window'));
      expect(r.message, isNot(contains('Открываю заполненное окно')));
      expect(dispatched, isEmpty);
    });

    test('an unpriced transfer: the reason and the filled send window, no '
        'card to run', () async {
      final r = svc.chatUnknownValueWindowForTest(
          preview(cakeSend, vettedCake), cakeSend, 'ru');
      await Future<void>.delayed(Duration.zero);
      expect(r, isNotNull);
      // Not a preview: the chat carries nothing out.
      expect(r!.type, ResponseType.info);
      expect(r.message, contains('CAKE'));
      expect(r.message, contains('Открываю заполненное окно'));
      expect(dispatched.first.target, 'wallet_send');
      expect(
          dispatched.any((c) =>
              c.target == 'send_address' && c.payload?['value'] == recipient),
          true);
    });

    test('a priced transfer keeps its card', () async {
      final r = svc.chatUnknownValueWindowForTest(
          preview(usdtSend, usdt), usdtSend, 'ru');
      await Future<void>.delayed(Duration.zero);
      expect(r, isNull);
      expect(dispatched, isEmpty);
    });

    test('outside «AI Мандат» it opens nothing: the refusal comes first',
        () async {
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.fullAutonomy,
        mandate: AutonomyMandate(allowedNetworks: ['tron']),
      ));
      final r = svc.chatUnknownValueWindowForTest(
          preview(cakeSend, vettedCake), cakeSend, 'ru');
      await Future<void>.delayed(Duration.zero);
      expect(r, isNull);
      expect(dispatched, isEmpty);
    });
  });

  group('no USD value: the AI hands it over in the prefilled window (D17)',
      () {
    const reason = 'CAKE has no price, so the AI will not carry it out.';

    setUp(() {
      AiControlService.instance.setSettingsForTest(
        const AiControlSettings(mode: AiMode.fullAutonomy),
      );
    });

    test('a transfer: the send window with its fields', () async {
      const send = IntentData(
        type: IntentType.sendAsset,
        rawInput: 'отправь 10 CAKE',
        tokenSymbol: 'CAKE',
        amount: 10,
        toAddress: recipient,
      );
      final r = svc.unknownValueWindowForTest(reason, send, 'ru');
      await Future<void>.delayed(Duration.zero);
      expect(r.message, contains(reason));
      expect(r.message, contains('Открываю заполненное окно'));
      expect(dispatched.first.target, 'wallet_send');
      expect(
          dispatched.any((c) =>
              c.target == 'send_address' && c.payload?['value'] == recipient),
          true);
    });

    test('a swap: the swap window with both tokens and the amount', () async {
      const swap = IntentData(
        type: IntentType.swapAsset,
        rawInput: 'обменяй 10 CAKE на USDT',
        sourceTokenSymbol: 'CAKE',
        targetTokenSymbol: 'USDT',
        amount: 10,
      );
      final r = svc.unknownValueWindowForTest(reason, swap, 'en');
      await Future<void>.delayed(Duration.zero);
      expect(r.message, contains('Opening the filled-in window'));
      expect(dispatched.first.target, 'wallet_swap');
      expect(dispatched.any((c) => c.target == 'swap_from_token'), true);
      expect(dispatched.any((c) => c.target == 'swap_to_token'), true);
      expect(dispatched.any((c) => c.target == 'swap_amount'), true);
    });

    test('without the request or with «Открытие окон» off: the reason only',
        () async {
      var r = svc.unknownValueWindowForTest(reason, null, 'ru');
      expect(r.message, reason);
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.fullAutonomy,
        allowedActions: [AiAction.send, AiAction.swap],
      ));
      r = svc.unknownValueWindowForTest(
        reason,
        const IntentData(
          type: IntentType.sendAsset,
          rawInput: 'отправь 10 CAKE',
          tokenSymbol: 'CAKE',
          amount: 10,
          toAddress: recipient,
        ),
        'ru',
      );
      await Future<void>.delayed(Duration.zero);
      expect(r.message, reason);
      expect(dispatched, isEmpty);
    });
  });

  group('Russian texts: «AI Мандата» in the genitive, «ИИ» in sentences', () {
    Future<AssistantResponse> ask(String text) => svc.process(text,
        languageCode: 'ru', source: AssistantInputSource.generalChat);

    test('«Автономный», PIN OFF: the mode and the capabilities answers',
        () async {
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
          mode: AiMode.fullAutonomy, aiPinConfirm: false));
      final mode = await ask('какой режим?');
      expect(mode.message, contains('дневного лимита, «AI Мандата» и EPK'));
      expect(mode.message, isNot(contains('«AI Мандат» и')));
      // An unknown price is never run by the AI: the wallet window.
      expect(mode.message, contains('без известной цены'));
      expect(mode.message, contains('в окне кошелька'));

      // A request (not a question): the capabilities fast path.
      final caps = await ask('покажи, что ты умеешь');
      expect(caps.message, contains('«AI Мандата» и EPK'));
    });

    test('the window permission is named after AI-Центр', () async {
      AiControlService.instance.setSettingsForTest(
        const AiControlSettings(mode: AiMode.manual, allowedActions: []),
      );
      final r = await ask('покажи историю');
      expect(r.message, contains('AI-Центре'));
      expect(r.message, isNot(contains('AI Control')));
    });
  });
}
