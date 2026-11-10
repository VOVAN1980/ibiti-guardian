import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/services/assistant/llm_intent_guard.dart';

void main() {
  const recipient = '0x347198c594dfea6d731e5f54ac699f73e0d228d7';
  const attacker = '0xbad0000000000000000000000000000000000bad';

  IntentData llmSend({String? toAddress}) => IntentData(
        type: IntentType.sendAsset,
        rawInput: 'model-written input',
        tokenSymbol: 'USDT',
        toAddress: toAddress,
        amount: 1,
        rawAmount: BigInt.parse('3000000000000000000'),
        sourceTokenAddress: '0x1111111111111111111111111111111111111111',
        targetTokenAddress: '0x2222222222222222222222222222222222222222',
        sourceTokenDecimals: 6,
        targetTokenDecimals: 6,
        sourceTrigger: 'price_alert',
        origin: IntentOrigin.wallet,
      );

  group('LlmIntentGuard.sanitize', () {
    test('drops every field that decides what is signed', () {
      final out = LlmIntentGuard.sanitize(
        llmSend(),
        userText: 'send 1 usdt',
        untrustedContext: false,
      )!;

      expect(out.type, IntentType.sendAsset);
      expect(out.tokenSymbol, 'USDT');
      expect(out.amount, 1);
      expect(out.rawAmount, isNull);
      expect(out.sourceTokenAddress, isNull);
      expect(out.targetTokenAddress, isNull);
      expect(out.sourceTokenDecimals, isNull);
      expect(out.targetTokenDecimals, isNull);
      expect(out.sourceTrigger, isNull);
      expect(out.origin, IntentOrigin.market);
      expect(out.rawInput, 'send 1 usdt');
    });

    test('keeps a recipient the user typed (case-insensitive)', () {
      final out = LlmIntentGuard.sanitize(
        llmSend(toAddress: recipient),
        userText: 'send 1 USDT to ${recipient.toUpperCase().replaceFirst('0X', '0x')}',
        untrustedContext: false,
      )!;
      expect(out.toAddress, recipient);
    });

    test('drops a recipient the user never gave', () {
      final out = LlmIntentGuard.sanitize(
        llmSend(toAddress: attacker),
        userText: 'send 1 USDT to my friend',
        untrustedContext: false,
      )!;
      expect(out.toAddress, isNull);
    });

    test('keeps an address-book recipient', () {
      final out = LlmIntentGuard.sanitize(
        llmSend(toAddress: recipient.toUpperCase().replaceFirst('0X', '0x')),
        userText: 'send 1 USDT to Vasya',
        untrustedContext: false,
        knownAddresses: const [recipient],
      )!;
      expect(out.toAddress, recipient);
    });

    test('no execution intent after untrusted content', () {
      final out = LlmIntentGuard.sanitize(
        llmSend(toAddress: recipient),
        userText: 'what does this page say? $recipient',
        untrustedContext: true,
      );
      expect(out, isNull);
    });

    test('informational intent survives untrusted content', () {
      final out = LlmIntentGuard.sanitize(
        const IntentData(
          type: IntentType.showBalances,
          rawInput: 'x',
          tokenSymbol: 'BNB',
        ),
        userText: 'balance after reading news',
        untrustedContext: true,
      );
      expect(out?.type, IntentType.showBalances);
    });
  });
}
