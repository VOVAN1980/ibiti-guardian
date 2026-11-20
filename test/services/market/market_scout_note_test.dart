// MarketScoutService.buildModeCapabilityNote: what the AI says it can do on
// the market in each mode, with the mode names the user sees («Советник» /
// «Ручной» / «Автономный»; EN Advisor / Manual / Autonomous) and, in
// «Автономный», the «Подтверждать действия ИИ ПИН-кодом» setting.
//
// Run: flutter test test/services/market/market_scout_note_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/services/market/market_scout_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final scout = MarketScoutService.instance;
  String note(AiControlSettings s) => scout.buildModeCapabilityNote(s);

  void noOldNamesOrPlaceholders(String text) {
    for (final old in ['Guarded', 'Full Autonomy', 'Руководство']) {
      expect(text, isNot(contains(old)), reason: old);
    }
    expect(text, isNot(contains('{')), reason: 'unfilled placeholder');
    expect(text, isNot(contains('automatically')));
  }

  test('«Советник» only advises and opens nothing', () {
    final text = note(const AiControlSettings(mode: AiMode.manual));
    expect(text, contains('«Advisor»'));
    expect(text, contains('only advise'));
    expect(text, contains('execute nothing'));
    expect(text, isNot(contains('you ask for')));
    noOldNamesOrPlaceholders(text);
  });

  test('«Ручной» prepares; the user confirms with the PIN', () {
    final text = note(const AiControlSettings(
      mode: AiMode.guarded,
      allowedActions: [AiAction.swap],
      mandate: AutonomyMandate(allowedAssets: ['SOL'], allowedNetworks: ['bsc']),
    ));
    expect(text, contains('«Manual»'));
    expect(text, contains('prepare'));
    expect(text, contains('PIN'));
    expect(text, contains('SOL on bsc'));
    expect(text, contains('swap'));
    noOldNamesOrPlaceholders(text);
  });

  test('«Автономный», PIN ON (the default): card + PIN for each trade', () {
    final text = note(const AiControlSettings(mode: AiMode.fullAutonomy));
    expect(text, contains('«Autonomous»'));
    // Trades only on request — never by itself.
    expect(text, contains('you ask for'));
    expect(text, contains('PIN confirmation is on'));
    expect(text, contains('card'));
    expect(text, contains('any asset on any network'));
    noOldNamesOrPlaceholders(text);
  });

  test('«Автономный», PIN OFF: only within limits, notification after', () {
    final text = note(const AiControlSettings(
      mode: AiMode.fullAutonomy,
      aiPinConfirm: false,
      dailyLimit: 250,
    ));
    expect(text, contains('you ask for'));
    expect(text, contains('PIN confirmation is off'));
    expect(text, contains('within the daily limit'));
    expect(text, contains('\$250'));
    expect(text, contains('«AI did: …»'));
    expect(text, contains('never go over a limit'));
    noOldNamesOrPlaceholders(text);
  });

  test('the PIN setting is ignored outside «Автономный»', () {
    final on = note(const AiControlSettings(mode: AiMode.guarded));
    final off = note(
        const AiControlSettings(mode: AiMode.guarded, aiPinConfirm: false));
    expect(off, on);
  });

  test('the «Советник» block reason keeps what the signal lists match on', () {
    const reason = MarketScoutService.advisorBlockReason;
    expect(reason, startsWith('Advisor mode'));
    // priority_signals_list.dart: lower-case 'manual mode' = mode-restricted.
    expect(reason.toLowerCase(), contains('manual mode'));
    // secondary_market_list.dart: 'Manual' = grey dot (not a red block).
    expect(reason, contains('Manual'));
  });
}
