import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/app_settings.dart';
import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/portfolio_summary.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/assistant/guardian_assistant_service.dart';
import 'package:ibiti_guardian/services/assistant/openai_chat_service.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_bus.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_resolver.dart';
import 'package:ibiti_guardian/services/intents/intent_parser.dart';
import 'package:ibiti_guardian/services/market/market_scout_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/services/voice/ai_voice.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Conversation must not open windows or start money actions; explicit
/// requests still must.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AiControlService.instance.setSettingsForTest(
      const AiControlSettings(mode: AiMode.guarded),
    );
  });

  List<String> windows(String text) => UICommandResolver
      .fallbackUiCommandsForText(text)
      .map((c) => c.target ?? "")
      .toList();

  group('text fallback opens nothing for conversation', () {
    for (final text in [
      'я в панике, рынок падает',
      'что такое политика лимитов?',
      'как обменять BNB',
      'расскажи про EPK',
      'какой адрес у биржи?',
      'мои транзакции не проходят?',
      'не паникуй',
      'стоит ли проверять контракт токена',
      'какие у меня доверенные адреса?',
      'что такое белый список?',
      'доверенные адреса',
    ]) {
      test(text, () => expect(windows(text), isEmpty));
    }
  });

  group('text fallback still opens what is asked for', () {
    final cases = {
      'открой политику': 'policy_limits',
      'покажи историю': 'wallet_history',
      'открой EPK': 'epk_control',
      'включи режим паники': 'panic',
      'отзови все разрешения': 'panic',
      'покажи мой адрес': 'wallet_receive',
      'отправь деньги': 'wallet_send',
      'open market': 'market',
      'просканируй кошелёк': 'safe',
      'открой доверенные адреса': 'trusted_addresses',
      'покажи белый список': 'trusted_addresses',
      'покажи адреса доверенные': 'trusted_addresses',
      'open trusted addresses': 'trusted_addresses',
      'show whitelist': 'trusted_addresses',
      'открой адресную книгу': 'wallet_address_book',
      'покажи контакты': 'wallet_address_book',
    };
    cases.forEach((text, target) {
      test(text, () => expect(windows(text), contains(target)));
    });
  });

  group('trusted addresses never open Receive', () {
    for (final text in [
      'открой доверенные адреса',
      'покажи доверенные адреса',
      'open trusted addresses',
    ]) {
      test(text, () => expect(windows(text), isNot(contains('wallet_receive'))));
    }
  });

  group('trusted-list phrase rule', () {
    for (final text in [
      'доверенные адреса',
      'покажи доверенный адрес',
      'список доверенных',
      'что в белом списке',
      'кому ты можешь переводить',
      'разрешённые адреса',
      'whitelist',
      'show my trusted addresses',
      'добавь этот адрес в доверенные',
      'удали из доверенных',
      'сделай этот адрес доверенным',
      'исключи адрес из белого списка',
      'ты переводишь исключительно на адреса из белого списка',
      'этот адрес разрешен для ии',
      'можешь отправлять токены на адреса из белого списка',
      'which trusted addresses can you send to',
      'who can you send to',
      'додай цю адресу в довірені адреси',
      'покажи доверенные адреса для перевода',
    ]) {
      test('matches: $text',
          () => expect(UICommandResolver.mentionsTrustedList(text), true));
    }
    for (final text in [
      'оформить доверенность',
      'покажи мой адрес',
      'открой адресную книгу',
      'отправь 5 usdt на доверенный адрес',
      'send 5 usdt to my trusted address',
      'ты мне доверяешь?',
      // Other whitelists: exchange IPs, the AI's allowed coins and actions.
      'как добавить ip в белый список mexc?',
      'нужно ли добавлять ip телефона в белый список gate.io?',
      'how do i whitelist my ip on mexc',
      'какие монеты в белом списке?',
      'what actions are whitelisted for you?',
      'какие адреса разрешены для вывода на бирже?',
      'это доверенный контракт?',
      // Transfers that only mention the list keep their money flow.
      'можешь перевести 10 usdt на доверенный адрес',
      'хочу перевести 10 usdt на доверенный адрес',
      'закинь 10 usdt на доверенный адрес',
      'пошли 10 usdt на доверенный адрес mexc',
      'хочу отправить всё на доверенный адрес',
      'pay 10 usdt to my trusted address',
      'відправ 10 usdt на довірену адресу',
      // Exchange whitelists said the Cyrillic way, AI networks and pairs.
      'как настроить вайтлист на бинансе',
      'белый список апи',
      'какие сети в белом списке',
      'какие пары в белом списке',
      // A power of attorney is not a trusted address.
      'нужна доверенность список документов',
      'адрес доверенного лица',
    ]) {
      test('does not match: $text',
          () => expect(UICommandResolver.mentionsTrustedList(text), false));
    }
  });

  group('intent parser: conversation is not a command', () {
    for (final text in [
      'я отправил вчера 100 долларов маме',
      'стоит ли купить BTC?',
      'когда продать ETH',
      'как отправить USDT на биржу',
      'оставлю отзыв о приложении',
      'как получить скидку',
      'I sold 2 SOL yesterday',
    ]) {
      test(text, () {
        final type = IntentParser.parse(text).type;
        expect(type, isNot(IntentType.sendAsset));
        expect(type, isNot(IntentType.swapAsset));
        expect(type, isNot(IntentType.buyAsset));
        expect(type, isNot(IntentType.sellAsset));
        expect(type, isNot(IntentType.revokeApproval));
        expect(type, isNot(IntentType.receiveAsset));
      });
    }
  });

  group('intent parser: commands still work', () {
    test('send with amount', () {
      expect(IntentParser.parse('отправь 5 USDT').type, IntentType.sendAsset);
    });
    test('swap', () {
      expect(IntentParser.parse('обменяй 10 USDT на BNB').type,
          IntentType.swapAsset);
    });
    test('buy', () {
      expect(IntentParser.parse('купи BTC на 10').type, IntentType.buyAsset);
    });
    test('revoke', () {
      expect(IntentParser.parse('отзови разрешения').type,
          IntentType.revokeApproval);
    });
    test('balance question is still answered', () {
      expect(IntentParser.parse('сколько у меня на балансе?').type,
          IntentType.showBalances);
    });
  });

  group('intent parser: the status card is not a wallet card', () {
    for (final text in [
      'Почему карточка статуса красная?',
      'покажи карточку статуса',
      'что значит статус системы',
      'what does the red status card mean?',
      'why is the system status red',
      'discard this',
    ]) {
      test(text, () {
        expect(IntentParser.parse(text).type,
            isNot(IntentType.showWalletCards));
      });
    }
    for (final text in [
      'сколько карт создано',
      'how many cards do i have',
      'покажи мои карты',
      'статус карты',
    ]) {
      test('still wallet cards: $text', () {
        expect(IntentParser.parse(text).type, IntentType.showWalletCards);
      });
    }
  });

  group('limits answer needs a limits question', () {
    bool isLimits(String text) =>
        GuardianAssistantService.instance.isLimitsStatusQuestionForTest(text);
    for (final text in [
      'Что такое разрешение?',
      'что такое разрешения токенов',
      'зачем нужно разрешение на токен',
      'отзови все разрешения',
      'можно ли тебе доверять?',
      'дай токену разрешение',
    ]) {
      test('not limits: $text',
          () => expect(isLimits(text), false));
    }
    for (final text in [
      'какие у тебя лимиты',
      'что тебе разрешено',
      'что тебе можно делать',
      'какие действия тебе разрешены',
      'разрешённые действия',
      'какие сети разрешены',
      'какие токены разрешены?',
      'what are you allowed to do?',
      'what are your limits',
    ]) {
      test('limits: $text',
          () => expect(isLimits(text), true));
    }
  });

  group('chat question guard', () {
    for (final text in [
      'Что такое Safe Scan?',
      'Сколько стоит Safe Scan?',
      'Что такое разрешение?',
      'Почему карточка статуса красная?',
      'What is Safe Scan?',
      'How much does a revoke cost?',
      'Чем отличается режим с подтверждением от автономного?',
      'расскажи про EPK',
      'а почему?',
      'какой курс BTC',
    ]) {
      test('question: $text', () {
        expect(GuardianAssistantService.isChatConversationOnlyForTest(text),
            true);
        expect(
            GuardianAssistantService.isChatConversationOnlyForTest(text,
                source: AssistantInputSource.marketChat),
            true);
      });
    }
    for (final text in [
      'открой отправку',
      'покажи баланс',
      'покажи баланс?',
      'запусти скан',
      'купи BTC на 10\$',
      'можешь открыть обмен?',
      'сколько у меня USDT?',
      'Что такое Safe Scan? Запусти его',
    ]) {
      test('command: $text', () {
        expect(GuardianAssistantService.isChatConversationOnlyForTest(text),
            false);
        expect(
            GuardianAssistantService.isChatConversationOnlyForTest(text,
                source: AssistantInputSource.marketChat),
            false);
      });
    }
    test('voice keeps its own rule', () {
      expect(
          GuardianAssistantService.isChatConversationOnlyForTest(
              'Что такое Safe Scan?',
              source: AssistantInputSource.voice),
          false);
    });
    test('"купи BTC на 10\$" is still a buy', () {
      final intent = IntentParser.parse('купи BTC на 10\$');
      expect(intent.type, IntentType.buyAsset);
      expect(intent.amount, 10);
    });
    test('"покажи баланс" is still a balance command', () {
      expect(IntentParser.parse('покажи баланс').type, IntentType.showBalances);
    });
  });

  group('polite requests are requests, in chat and voice', () {
    for (final text in [
      'Ты можешь открыть отправку?',
      'А можешь купить BTC на 10\$?',
      'Можешь, пожалуйста, открыть отправку?',
      'Could you please open send?',
      'Please could you open send?',
      'Давай купим BTC на 10\$?',
      'Откроешь отправку?',
      'Не могли бы вы открыть отправку?',
    ]) {
      test(text, () {
        expect(IntentParser.isActionRequest(text), true);
        expect(IntentParser.isConversational(text), false);
        expect(GuardianAssistantService.isChatConversationOnlyForTest(text),
            false);
        expect(
            GuardianAssistantService.isChatConversationOnlyForTest(text,
                source: AssistantInputSource.marketChat),
            false);
        expect(GuardianAssistantService.isVoiceActionRequestForTest(text),
            true);
      });
    }
    test('a polite buy is parsed as a buy', () {
      final intent = IntentParser.parse('А можешь купить BTC на 10\$?');
      expect(intent.type, IntentType.buyAsset);
      expect(intent.amount, 10);
    });
    // Ability questions, conditions and "ли" stay questions.
    for (final text in [
      'монеты покупать можешь?',
      'Можешь покупать монеты?',
      'Ты можешь отправлять токены?',
      'Can you explain Safe Scan?',
      'Ты купишь BTC, если он упадёт?',
      'Можешь ли ты открыть отправку?',
      'can i buy BTC here?',
    ]) {
      test('still a question: $text', () {
        expect(IntentParser.isActionRequest(text), false);
        expect(GuardianAssistantService.isChatConversationOnlyForTest(text),
            true);
        expect(GuardianAssistantService.isVoiceActionRequestForTest(text),
            false);
      });
    }
  });

  group('lead-ins like "как обычно" do not make a question', () {
    final cases = {
      'как обычно купи BTC на 10\$': IntentType.buyAsset,
      'как договаривались, отправь 5 USDT Саше': IntentType.sendAsset,
      'ну что, открой отправку': IntentType.sendAsset,
      'что ж, купи BTC на 10\$': IntentType.buyAsset,
    };
    cases.forEach((text, type) {
      test(text, () {
        expect(IntentParser.isConversational(text), false);
        expect(IntentParser.isActionRequest(text), true);
        expect(GuardianAssistantService.isChatConversationOnlyForTest(text),
            false);
        expect(
            GuardianAssistantService.isChatConversationOnlyForTest(text,
                source: AssistantInputSource.marketChat),
            false);
        expect(GuardianAssistantService.isVoiceActionRequestForTest(text),
            true);
        expect(IntentParser.parse(text).type, type);
      });
    });
    test('the send keeps its amount and token', () {
      final intent =
          IntentParser.parse('как договаривались, отправь 5 USDT Саше');
      expect(intent.amount, 5);
      expect(intent.tokenSymbol, 'USDT');
    });
    test('a real question after a lead-in is still a question', () {
      expect(
          GuardianAssistantService.isChatConversationOnlyForTest(
              'как обычно, что на рынке?'),
          true);
      expect(IntentParser.isConversational('ну что, как купить BTC'), true);
    });
  });

  group('commands are never conversation', () {
    final commands = <String, IntentType?>{
      'открой отправку': null,
      'отправь 5 USDT Саше': IntentType.sendAsset,
      'покажи баланс': IntentType.showBalances,
      'запусти скан': null,
      'отзови все разрешения': IntentType.revokeApproval,
      'купи BTC на 10\$': IntentType.buyAsset,
      'покажи историю': IntentType.showHistory,
      'переключи сеть на Polygon': null,
      'покажи мой адрес': IntentType.showAddress,
      'закрой окно': null,
      'open send': null,
      'show balance': IntentType.showBalances,
      'switch network to Polygon': null,
      'close': null,
    };
    commands.forEach((text, type) {
      test(text, () {
        expect(IntentParser.isConversational(text), false);
        expect(GuardianAssistantService.isChatConversationOnlyForTest(text),
            false);
        expect(
            GuardianAssistantService.isChatConversationOnlyForTest(text,
                source: AssistantInputSource.marketChat),
            false);
        expect(GuardianAssistantService.isVoiceActionRequestForTest(text),
            true);
        if (type != null) expect(IntentParser.parse(text).type, type);
      });
    });
  });

  group('stories and "ли" questions are conversation', () {
    for (final text in [
      'Я вчера купил BTC на 10\$',
      'Не знаю, стоит ли купить BTC на 10\$',
    ]) {
      test(text, () {
        expect(IntentParser.isConversational(text), true);
        expect(IntentParser.isActionRequest(text), false);
        expect(GuardianAssistantService.isTradingCommandForTest(text), false);
        expect(GuardianAssistantService.isVoiceActionRequestForTest(text),
            false);
        for (final source in [
          AssistantInputSource.generalChat,
          AssistantInputSource.marketChat,
        ]) {
          expect(
              GuardianAssistantService.isChatConversationOnlyForTest(text,
                  source: source),
              true,
              reason: source.name);
        }
      });
    }
  });

  group('assistant: questions reach the LLM and open nothing', () {
    final dispatched = <UICommand>[];
    StreamSubscription<UICommand>? subscription;
    // With no API key the LLM path answers with its offline text, so that
    // text marks "this turn reached the LLM".
    final offlineAnswers = <String>{};

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      SettingsService.instance.settingsForTest = AppSettings(
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
      // The reply follows the language of the message itself.
      for (final probe in ['пинг', 'ping']) {
        final offline = await OpenAIChatService.instance.solve(probe, 'en');
        offlineAnswers.add(offline['displayMessage'] as String);
      }
      // A funded wallet, so a wrong balance answer would show.
      VaultPortfolioListener.instance.setSummaryForTest(PortfolioSummary(
        totalBalanceUsd: 321.5,
        assetsCount: 1,
        allAssets: [
          WalletAsset(
            name: 'Tether USD',
            symbol: 'USDT',
            address: 'usdt_address',
            balance: 321.5,
            logoUrl: '',
            priceUsd: 1.0,
            valueUsd: 321.5,
            decimals: 6,
            chainId: 56,
            chainKey: 'bsc',
          ),
        ],
        address: '0x9999999999999999999999999999999999999999',
        networkName: 'BSC',
        chainKey: 'bsc',
      ));
    });

    setUp(() {
      dispatched.clear();
      subscription = UICommandBus.instance.commands.listen(dispatched.add);
    });

    tearDown(() async {
      await subscription?.cancel();
      subscription = null;
    });

    Future<AssistantResponse> ask(
      String text, {
      required AssistantInputSource source,
    }) async {
      final lang = RegExp('[а-яё]', caseSensitive: false).hasMatch(text)
          ? 'ru'
          : 'en';
      final r = await GuardianAssistantService.instance
          .process(text, languageCode: lang, source: source);
      await Future<void>.delayed(Duration.zero); // deliver bus events
      return r;
    }

    bool opensWindow(List<UICommand> commands) => commands.any((c) =>
        c.type == UICommandType.openModal ||
        c.type == UICommandType.navigate);

    void expectNoDumps(AssistantResponse r, String text) {
      for (final dump in [
        'Лимит одного перевода',
        'Per-transfer limit',
        'Общий баланс',
        'Total wallet balance',
        '321.5',
      ]) {
        expect(r.message, isNot(contains(dump)), reason: text);
      }
    }

    const questions = [
      'Что такое Safe Scan?',
      'Сколько стоит Safe Scan?',
      'Что такое разрешение?',
      'Почему карточка статуса красная?',
      'What is Safe Scan?',
      'How much does a revoke cost?',
      'Чем отличается режим с подтверждением от автономного?',
    ];

    for (final source in [
      AssistantInputSource.generalChat,
      AssistantInputSource.marketChat,
      AssistantInputSource.voice,
    ]) {
      for (final text in questions) {
        test('${source.name}: $text', () async {
          final r = await ask(text, source: source);
          expect(offlineAnswers, contains(r.message), reason: text);
          expect(r.uiCommands, isEmpty, reason: text);
          expect(opensWindow(dispatched), false, reason: text);
          expectNoDumps(r, text);
        });
      }
    }

    test('chat: naming Safe Scan in a statement does not open it', () async {
      final r = await ask('Safe Scan нашёл странное разрешение',
          source: AssistantInputSource.generalChat);
      expect(opensWindow(r.uiCommands), false);
      expect(dispatched.any((c) => c.target == 'safe'), false);
    });

    test('chat: "сколько" / "how much" alone is not a balance question',
        () async {
      for (final text in ['Safe Scan сколько стоит', 'Safe Scan how much']) {
        final r = await ask(text, source: AssistantInputSource.generalChat);
        expectNoDumps(r, text);
        expect(dispatched.any((c) => c.target == 'safe'), false,
            reason: text);
      }
    });

    test('chat: "открой отправку" opens the send window', () async {
      final r =
          await ask('открой отправку', source: AssistantInputSource.generalChat);
      expect(
          r.uiCommands.any((c) =>
              c.type == UICommandType.openModal && c.target == 'wallet_send'),
          true);
      expect(dispatched.any((c) => c.target == 'wallet_send'), true);
      expect(offlineAnswers, isNot(contains(r.message)));
    });

    test('chat: "запусти скан" opens Safe Scan', () async {
      final r =
          await ask('запусти скан', source: AssistantInputSource.generalChat);
      expect(
          r.uiCommands.any((c) =>
              c.type == UICommandType.openModal && c.target == 'safe'),
          true);
      expect(offlineAnswers, isNot(contains(r.message)));
    });

    test('Manual mode refuses only send and swap windows', () async {
      AiControlService.instance.setSettingsForTest(
        const AiControlSettings(mode: AiMode.manual, allowedActions: []),
      );
      final send =
          await ask('открой отправку', source: AssistantInputSource.generalChat);
      expect(send.message, contains('Manual'));
      expect(send.uiCommands, isEmpty);

      final history =
          await ask('покажи историю', source: AssistantInputSource.generalChat);
      expect(history.message, isNot(contains('перевод или обмен')));
      expect(history.message, contains('Открытие окон и экранов'));
      expect(history.uiCommands, isEmpty);
      expect(opensWindow(dispatched), false);
    });

    test('a canned answer is remembered for follow-ups', () async {
      OpenAIChatService.instance.clearHistory();
      final r =
          await ask('какой режим?', source: AssistantInputSource.generalChat);
      final history = OpenAIChatService.instance.historyForTest;
      expect(history, hasLength(2));
      expect(history.first['content'], 'какой режим?');
      expect(history.last['content'], contains('Guarded'));
      expect(r.message, contains('Guarded'));
    });

    test('an LLM turn is not recorded twice', () async {
      OpenAIChatService.instance.clearHistory();
      await ask('Что такое Safe Scan?',
          source: AssistantInputSource.generalChat);
      // The offline LLM records nothing, and process() adds nothing.
      expect(OpenAIChatService.instance.historyForTest, isEmpty);
    });

    test('Full Autonomy is described as doing what the user asks', () async {
      AiControlService.instance.setSettingsForTest(
        const AiControlSettings(mode: AiMode.fullAutonomy),
      );
      final ru =
          await ask('какой режим?', source: AssistantInputSource.generalChat);
      expect(ru.message, contains('о которых вы просите'));
      expect(ru.message, isNot(contains('расписани')));
      final en =
          await ask('what mode?', source: AssistantInputSource.generalChat);
      expect(en.message, contains('you ask for'));
      expect(en.message, isNot(contains('schedule')));

      final note = MarketScoutService.instance.buildModeCapabilityNote(
          const AiControlSettings(mode: AiMode.fullAutonomy));
      expect(note, contains('you ask for'));
      expect(note, isNot(contains('automatically')));
    });

    test('Full Autonomy: only exchange and delegated trades skip the PIN',
        () async {
      AiControlService.instance.setSettingsForTest(
        const AiControlSettings(mode: AiMode.fullAutonomy),
      );
      final ru =
          await ask('какой режим?', source: AssistantInputSource.generalChat);
      expect(ru.message, isNot(contains('без отдельного окна подтверждения')));
      expect(ru.message, contains('Ордера на биржах'));
      expect(ru.message, contains('«Делегировать AI»'));
      expect(ru.message, contains('подтверждаете их вы, ПИН-кодом'));
      final en =
          await ask('what mode?', source: AssistantInputSource.generalChat);
      expect(en.message,
          isNot(contains('without a separate confirmation window')));
      expect(en.message, contains('Exchange orders'));
      expect(en.message, contains('Delegate to AI'));
      expect(en.message, contains('you confirm them with your PIN'));
    });

    for (final source in [
      AssistantInputSource.generalChat,
      AssistantInputSource.marketChat,
      AssistantInputSource.voice,
    ]) {
      for (final text in [
        'Я вчера купил BTC на 10\$',
        'Не знаю, стоит ли купить BTC на 10\$',
      ]) {
        test('${source.name}: "$text" is only talked about', () async {
          final r = await ask(text, source: source);
          expect(offlineAnswers, contains(r.message), reason: text);
          expect(r.uiCommands, isEmpty, reason: text);
          expect(opensWindow(dispatched), false, reason: text);
        });
      }

      for (final text in [
        'Ты можешь открыть отправку?',
        'Можешь, пожалуйста, открыть отправку?',
        'Could you please open send?',
        'Please could you open send?',
        'Откроешь отправку?',
        'ну что, открой отправку',
      ]) {
        test('${source.name}: "$text" opens the send window', () async {
          final r = await ask(text, source: source);
          expect(
              r.uiCommands.any((c) =>
                  c.type == UICommandType.openModal &&
                  c.target == 'wallet_send'),
              true,
              reason: text);
          expect(offlineAnswers, isNot(contains(r.message)), reason: text);
        });
      }

      test('${source.name}: a stop-loss or alert with a price reaches its '
          'handler', () async {
        for (final text in [
          'поставь стоп-лосс на SOL 120',
          'set stop loss SOL 120',
          'поставь алерт на BTC 70000',
        ]) {
          final r = await ask(text, source: source);
          expect(r.message, isNot(contains('Откройте окно обмена')),
              reason: text);
          expect(r.message, isNot(contains('open the swap or send window')),
              reason: text);
          expect(offlineAnswers, isNot(contains(r.message)), reason: text);
        }
      });
    }

    group('with the send window open', () {
      setUp(() => ScreenContextService.instance.setModal('wallet_send'));
      tearDown(ScreenContextService.instance.clearModal);

      for (final mode in [AiMode.guarded, AiMode.manual]) {
        test('${mode.name}: a question neither fills it nor is refused',
            () async {
          AiControlService.instance.setSettingsForTest(mode == AiMode.manual
              ? const AiControlSettings(mode: AiMode.manual, allowedActions: [])
              : const AiControlSettings(mode: AiMode.guarded));
          final r = await ask('Сколько стоит отправка USDT?',
              source: AssistantInputSource.generalChat);
          expect(offlineAnswers, contains(r.message));
          expect(r.message, isNot(contains('режим Manual')));
          expect(
              dispatched.any((c) =>
                  c.type == UICommandType.selectToken ||
                  c.type == UICommandType.fillField),
              false);
        });
      }

      test('voice "5 USDT" still fills the amount', () async {
        final r = await ask('5 USDT', source: AssistantInputSource.voice);
        expect(
            r.uiCommands.any((c) =>
                c.type == UICommandType.fillField &&
                c.target == 'send_amount'),
            true);
      });
    });

    group('the assistant speaks in the gender of its voice', () {
      void useVoice(String voiceId) {
        SettingsService.instance.settingsForTest = AppSettings(
          languageCode: 'ru',
          openaiApiKey: null,
          isNeuralOperatorEnabled: false,
          preferredAiVoiceId: voiceId,
        );
        addTearDown(() {
          SettingsService.instance.settingsForTest = AppSettings(
            openaiApiKey: null,
            isNeuralOperatorEnabled: false,
          );
        });
      }

      Future<List<String>> cannedAnswers() async {
        AiControlService.instance.setSettingsForTest(
          const AiControlSettings(mode: AiMode.fullAutonomy),
        );
        const chat = AssistantInputSource.generalChat;
        return [
          (await ask('какой режим?', source: chat)).message,
          (await ask('открой EPK', source: chat)).message,
          (await ask('закрой окно', source: chat)).message,
          (await ask('запомни котлета', source: chat)).message,
        ];
      }

      test('female voice (marin) speaks about itself in the feminine',
          () async {
        useVoice(AiVoice.female);
        final a = await cannedAnswers();
        expect(a[0], contains('я выставляю сама,'));
        expect(a[0], contains('Сама, без вашей просьбы'));
        expect(a[1], contains('Открыла EPK'));
        expect(a[2], 'Закрыла.');
        expect(a[3], contains('Не смогла разобрать'));
      });

      test('male voice (cedar) speaks about itself in the masculine',
          () async {
        useVoice(AiVoice.male);
        final a = await cannedAnswers();
        expect(a[0], contains('я выставляю сам,'));
        expect(a[0], contains('Сам, без вашей просьбы'));
        expect(a[1], contains('Открыл EPK'));
        expect(a[2], 'Закрыл.');
        expect(a[3], contains('Не смог разобрать'));
      });
    });
  });
}
