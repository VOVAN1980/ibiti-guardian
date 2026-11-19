import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';

/// What the assistant is told about the screen the user is looking at. It
/// must match the app as it is now: the System status card on the wallet,
/// the current Settings, and nothing that was removed (PRO, background
/// monitoring, threat feed, the "Recent" list, a manual update check).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ctx = ScreenContextService.instance;

  String promptFor(String screen) {
    ctx.clearFocusedToken();
    ctx.setScreen(screen);
    return ctx.buildContextPrompt();
  }

  test('the wallet screen describes the System status card', () {
    final prompt = promptFor('wallet');
    expect(prompt, contains('«Статус системы»'));
    expect(prompt, contains('System status'));
    expect(prompt, contains('green «Безопасно»'));
    expect(prompt, contains('red «Опасно»'));
    expect(prompt, contains('«Что не так»'));
    expect(prompt, contains('NOT a wallet card'));
    // The three problems and their buttons.
    expect(prompt, contains('Safe Scan'));
    expect(prompt, contains('«Войти»'));
    expect(prompt, contains('«Разрешить»'));
  });

  test('the settings screen lists today\'s settings, no update check', () {
    final prompt = promptFor('settings');
    expect(prompt, isNot(contains('check updates')));
    expect(prompt.toLowerCase(), isNot(contains('check for updates')));
    expect(prompt, contains('«Результаты отзыва»'));
    expect(prompt, contains('single vibration'));
    expect(prompt, contains('double vibration'));
    expect(prompt, contains('coin sound'));
    expect(prompt, contains('start-up sound'));
    expect(prompt, contains('personality'));
    expect(prompt, contains('voice'));
    expect(prompt, contains('Language'));
    expect(prompt, contains('info@ibiticoin.com'));
    expect(prompt, contains('Privacy'));
    expect(prompt, contains('Terms'));
    expect(prompt, contains('greyed out until the app is published'));
  });

  test('no screen mentions a removed feature', () {
    const removed = [
      'monitoring',
      'Monitoring',
      'threat feed',
      'Threat feed',
      'Recent list',
      '«Recent»',
      'check updates',
    ];
    for (final screen in [
      'ai',
      'chat',
      'security',
      'wallet',
      'market',
      'settings',
    ]) {
      final prompt = promptFor(screen);
      for (final phrase in removed) {
        expect(prompt, isNot(contains(phrase)), reason: '$screen: $phrase');
      }
      expect(RegExp(r'\bPRO\b').hasMatch(prompt), false,
          reason: '$screen: PRO');
    }
  });

  test('token detail lists only the buttons it has', () {
    ctx.setScreen('market');
    ctx.setFocusedToken('BTC', price: 1);
    final prompt = ctx.buildContextPrompt();
    expect(prompt, contains('Buy, Sell'));
    expect(prompt, isNot(contains('Swap')));
    expect(prompt, contains('price alert'));
    ctx.clearFocusedToken(symbol: 'BTC');
  });
}
