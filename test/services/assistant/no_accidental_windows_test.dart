import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_resolver.dart';
import 'package:ibiti_guardian/services/intents/intent_parser.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';

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
}
