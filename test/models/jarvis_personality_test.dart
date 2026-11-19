import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/jarvis_personality.dart';

/// Each personality behaves like its label in Settings («Умный», «Аналитик»,
/// «Дружелюбный», «Тихий»). Style never changes the facts: every one answers
/// app questions from the APP GUIDE, says "не знаю" instead of guessing and
/// gives no investment advice.
void main() {
  // Phrases from the old prompts that made the assistant chat about anything,
  // voice confident opinions or make trade calls.
  const removed = [
    'ANY topic',
    'any topic',
    'confidently',
    'это моё мнение',
    'фиксанул',
    'Я бы',
    'cheeky',
    'sarcastic',
    'кайф',
    'жесть',
    '🚀',
    'Recommendation',
  ];

  for (final p in JarvisPersonality.values) {
    group('${p.name} («${p.nameRu()}»)', () {
      final prompt = p.systemPromptInjection;

      test('has none of the removed phrases', () {
        for (final phrase in removed) {
          expect(prompt, isNot(contains(phrase)), reason: phrase);
        }
      });

      test('names the same style the user picked in Settings', () {
        expect(prompt, contains('YOUR PERSONALITY: ${p.nameEn()} '));
        expect(prompt, contains('«${p.nameRu()}»'));
      });

      test('answers app questions from the APP GUIDE and does not guess', () {
        expect(prompt, contains('APP GUIDE'));
        expect(prompt, contains('не знаю'));
        expect(prompt, contains('Never guess'));
      });

      test('gives no investment advice', () {
        expect(prompt, contains('No investment advice'));
        expect(prompt, contains('never predict prices'));
      });

      test('answers in the language of the user', () {
        expect(prompt, contains('SAME language as the user'));
      });

      test('Settings descriptions are short and present in RU and EN', () {
        for (final d in [p.descriptionRu(), p.descriptionEn()]) {
          expect(d.trim(), isNotEmpty);
          // Two lines of a small card in the Settings grid.
          expect(d.length, lessThanOrEqualTo(45), reason: d);
        }
      });
    });
  }

  test('Smart explains clearly and correctly, with a bit of character', () {
    final prompt = JarvisPersonality.jarvis.systemPromptInjection;
    expect(prompt, contains('Being right comes first'));
    expect(prompt, contains('character'));
    expect(prompt, contains('No emoji'));
    expect(JarvisPersonality.jarvis.descriptionRu(), contains('без выдумок'));
  });

  test('Analyst gives facts, numbers and structure, no small talk', () {
    final prompt = JarvisPersonality.analyst.systemPromptInjection;
    expect(prompt, contains('numbers'));
    expect(prompt, contains('Structure'));
    expect(prompt, contains('no small talk'));
    expect(prompt, contains('never estimate'));
    expect(JarvisPersonality.analyst.descriptionRu(), contains('Факты'));
  });

  test('Friendly is warm and simple, polite, emoji only in text', () {
    final prompt = JarvisPersonality.bro.systemPromptInjection;
    expect(prompt, contains('warm'));
    expect(prompt, contains('Simple everyday words'));
    expect(prompt, contains('no slang'));
    expect(prompt, contains('no profanity'));
    expect(prompt, contains('Never an emoji in speechText'));
    expect(JarvisPersonality.bro.descriptionRu(), contains('Тепло'));
    expect(JarvisPersonality.bro.descriptionEn(), isNot(contains('Informal')));
  });

  test('Silent uses the fewest words, one short sentence when possible', () {
    final prompt = JarvisPersonality.silent.systemPromptInjection;
    expect(prompt, contains('fewest words'));
    expect(prompt, contains('One short sentence'));
    expect(prompt, contains('safety warning'));
    expect(JarvisPersonality.silent.descriptionRu(), contains('Коротко'));
  });

  test('labels and stored names stay as they were', () {
    expect(JarvisPersonality.values.map((p) => p.nameRu()),
        ['Умный', 'Аналитик', 'Дружелюбный', 'Тихий']);
    expect(JarvisPersonality.values.map((p) => p.nameEn()),
        ['Smart', 'Analyst', 'Friendly', 'Silent']);
    // Saved in settings by name: renaming would reset the user's choice.
    expect(JarvisPersonality.values.map((p) => p.name),
        ['jarvis', 'analyst', 'bro', 'silent']);
  });
}
