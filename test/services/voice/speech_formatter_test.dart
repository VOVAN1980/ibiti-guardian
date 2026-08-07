import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/voice/speech_formatter.dart';
import 'package:ibiti_guardian/services/voice/tts_service.dart';

void main() {
  group('SpeechFormatter', () {
    test('uses the approved conversational speech rate', () {
      expect(TtsService.speechRate, 0.98);
    });

    test('speaks Russian balances entirely as words', () {
      final result = SpeechFormatter.normalize(
        'Баланс: 1250.75 USDT.',
        lang: 'ru',
      );

      expect(
        result,
        'Баланс: одна тысяча двести пятьдесят целых семьдесят пять сотых ю эс ди ти.',
      );
      expect(result, isNot(matches(RegExp(r'\d'))));
    });

    test('understands a Russian decimal comma', () {
      final result = SpeechFormatter.normalize('12,5 USDT', lang: 'ru');

      expect(
        result,
        'двенадцать целых пять десятых ю эс ди ти',
      );
    });

    test('speaks small crypto fractions without swallowing digits', () {
      final result = SpeechFormatter.normalize('0.00045 BTC', lang: 'ru');

      expect(
        result,
        'ноль целых сорок пять стотысячных биткоина',
      );
      expect(result, isNot(matches(RegExp(r'\d'))));
    });

    test('speaks formatted dollar amounts as natural money', () {
      final result = SpeechFormatter.normalize(r'$12,450.75', lang: 'ru');

      expect(
        result,
        'двенадцать тысяч четыреста пятьдесят долларов семьдесят пять центов',
      );
    });

    test('speaks percentages and large integers as words', () {
      final result = SpeechFormatter.normalize(
        'Рост +12.5%, объём 65000.',
        lang: 'ru',
      );

      expect(
        result,
        'Рост плюс двенадцать целых пять десятых процента, объём шестьдесят пять тысяч.',
      );
      expect(result, isNot(matches(RegExp(r'\d'))));
    });

    test('does not read wallet addresses or transaction hashes', () {
      final result = SpeechFormatter.normalize(
        'Адрес 0x1111111111111111111111111111111111111111',
        lang: 'ru',
      );

      expect(result, 'Адрес адрес кошелька');
      expect(result, isNot(contains('1111')));
    });

    test('speaks English numbers naturally', () {
      final result = SpeechFormatter.normalize(
        'Balance: 1234.50 USDT and +2.5%.',
        lang: 'en',
      );

      expect(
        result,
        'Balance: one thousand two hundred thirty four point five U S D T and plus two point five percent.',
      );
      expect(result, isNot(matches(RegExp(r'\d'))));
    });
  });
}
