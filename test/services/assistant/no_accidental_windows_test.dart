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
    };
    cases.forEach((text, target) {
      test(text, () => expect(windows(text), contains(target)));
    });
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
