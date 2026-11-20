// Voice «да» / «нет» for an open AI confirmation card (owner decision D5,
// review finding guardian_app_shell.dart:193).
//
// The card (AiActionGate → AiActionConfirmSheet) is a root modal sheet: its
// barrier covers every tab's own mic button — the AI Voice tab's (index 0)
// too — while the card itself says «Можно сказать «да» или «нет»». The
// floating mic bubble is the only voice control drawn above all routes, so
// while a card is open it shows on EVERY tab, with or without a voice
// session. Its tap starts a session and a recording; the spoken «да» /
// «нет» then reaches GuardianAssistantService, which answers the card with
// AiActionGate.answerByVoice.
//
// While a card is open the bubble sits in a strip at the top of the screen,
// above the card (review finding guardian_app_shell.dart:62): at its usual
// spot (bottom right) it covered the card's note and «да» / «нет» hint, and
// a bubble dragged lower could sit on «Подтвердить».
//
// Run: flutter test test/app/guardian_app_shell_mic_bubble_test.dart

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/app/guardian_app_shell.dart';
import 'package:ibiti_guardian/services/security/ai_action_gate.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The main screen's tabs: 0 = AI Voice (its own mic), 1–5 the others.
  const tabs = [0, 1, 2, 3, 4, 5];

  bool visible({required bool session, required int tab, required bool card}) =>
      GuardianAppShell.micBubbleVisible(
        sessionActive: session,
        tabIndex: tab,
        aiCardOpen: card,
      );

  group('when the bubble shows', () {
    test('no card: during a voice session only, never on the AI Voice tab',
        () {
      for (final tab in tabs) {
        expect(visible(session: false, tab: tab, card: false), isFalse,
            reason: 'tab $tab, no session');
        expect(visible(session: true, tab: tab, card: false), tab != 0,
            reason: 'tab $tab, session');
      }
    });

    test('a card is open: on every tab, the AI Voice tab included', () {
      for (final tab in tabs) {
        expect(visible(session: true, tab: tab, card: true), isTrue,
            reason: 'tab $tab, session');
      }
    });

    test(
        'a card is open without a voice session (typed chat, «Делегировать '
        'AI»)', () {
      // The card can come from the typed chat or the delegate queue: no
      // voice session runs, yet the card still offers «да» / «нет».
      for (final tab in tabs) {
        expect(visible(session: false, tab: tab, card: true), isTrue,
            reason: 'tab $tab, no session');
      }
    });
  });

  group('where the bubble goes', () {
    MicBubblePlace place(
            {required bool session, required int tab, required bool card}) =>
        GuardianAppShell.micBubblePlace(
          sessionActive: session,
          tabIndex: tab,
          aiCardOpen: card,
        );

    test('a card is open: above the card, on every tab, session or not', () {
      for (final tab in tabs) {
        for (final session in [true, false]) {
          expect(place(session: session, tab: tab, card: true),
              MicBubblePlace.aboveAiCard,
              reason: 'tab $tab, session $session');
        }
      }
    });

    test('no card: its usual spot during a session, off the AI Voice tab', () {
      for (final tab in tabs) {
        expect(place(session: true, tab: tab, card: false),
            tab == 0 ? MicBubblePlace.hidden : MicBubblePlace.usual,
            reason: 'tab $tab');
        expect(place(session: false, tab: tab, card: false),
            MicBubblePlace.hidden,
            reason: 'tab $tab, no session');
      }
    });

    test('a small phone: the strip still fits the bubble below the status bar',
        () {
      const phone = MediaQueryData(
        size: Size(360, 640),
        padding: EdgeInsets.only(top: 24, bottom: 16),
      );
      final strip = GuardianAppShell.aboveAiCardStripHeight(phone);
      // 4 px below the status bar, the 72 px bubble, 8 px below it.
      expect(strip, 24 + 4 + 72 + 8);
      // The review's case on this phone: the card's note and «да» / «нет»
      // hint start at y≈440, its buttons at y≈564 — far below the strip.
      expect(strip, lessThan(440));
    });

    test('a tall screen: the strip ends where the tallest card can begin', () {
      const tablet = MediaQueryData(
        size: Size(800, 1280),
        padding: EdgeInsets.only(top: 24, bottom: 24),
      );
      // AiActionConfirmSheet: at most 85 % of the screen high, 12 px and
      // the bottom safe area below it.
      const tallestCardTop = 1280 - (1280 * 0.85 + 12 + 24);
      expect(GuardianAppShell.aboveAiCardStripHeight(tablet),
          closeTo(tallestCardTop, 1e-9));
    });

    testWidgets(
        'the bubble is given a screen that ends at the strip: no bottom '
        'inset, no keyboard', (tester) async {
      const phone = MediaQueryData(
        size: Size(360, 640),
        padding: EdgeInsets.only(top: 24, bottom: 16),
        viewPadding: EdgeInsets.only(top: 24, bottom: 16),
        // Even with a keyboard up, the bubble stays in the strip.
        viewInsets: EdgeInsets.only(bottom: 280),
      );
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      const stripKey = ValueKey('strip');
      MediaQueryData? seen;
      // The root overlay's Stack, as in the app.
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: phone,
          child: Stack(children: [
            Builder(
              builder: (context) => GuardianAppShell.aboveAiCard(
                context,
                // Stands for FloatingMicBubble, which places and clamps
                // itself in the screen its MediaQuery describes.
                Positioned.fill(
                  child: Builder(builder: (inner) {
                    seen = MediaQuery.of(inner);
                    return const SizedBox(key: stripKey);
                  }),
                ),
              ),
            ),
          ]),
        ),
      ));

      final strip = GuardianAppShell.aboveAiCardStripHeight(phone);
      expect(tester.getRect(find.byKey(stripKey)),
          Rect.fromLTWH(0, 0, 360, strip));
      expect(seen, isNotNull);
      expect(seen!.size, Size(360, strip));
      expect(seen!.padding.top, 24, reason: 'below the status bar');
      expect(seen!.padding.bottom, 0);
      expect(seen!.viewPadding.bottom, 0);
      expect(seen!.viewInsets, EdgeInsets.zero);
    });
  });

  group('the AI-card watch the main screen listens to', () {
    final gate = AiActionGate.instance;

    /// What a revoke in a window the AI opened asks the card for.
    const revoke = AiActionSummary(
      kind: AiActionKind.revoke,
      title: 'Revoke approvals (1)',
      amountLabel: '1 approvals',
      valueUsd: 0,
      network: 'bsc',
      source: 'ui',
    );

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      gate.resetForTest();
      gate.foregroundOverride = () => true;
      // «Автономный» with «Подтверждать действия ИИ ПИН-кодом» ON (the
      // default): every AI action shows the card first.
      AiControlService.instance.setSettingsForTest(const AiControlSettings(
        mode: AiMode.fullAutonomy,
        allowedActions: AiAction.values,
      ));
    });

    tearDown(() {
      gate.resetForTest();
      AiControlService.instance.setSettingsForTest(const AiControlSettings());
    });

    /// One frame (the card sheet's own animation drives frames in the app).
    Future<void> frame(WidgetTester tester) async {
      tester.binding.scheduleFrame();
      await tester.pump();
    }

    testWidgets('sees the card open and close, one frame later each',
        (tester) async {
      final watch = GuardianAppShell.aiCardOpenWatch();
      await tester.pumpWidget(const SizedBox());
      expect(watch.value, isFalse);

      final answer = Completer<bool>();
      gate.confirmUiOverride = (_) => answer.future;
      final decision = gate.confirm(revoke);
      expect(gate.hasOpenCard, isTrue);

      await frame(tester);
      expect(watch.value, isTrue, reason: 'the card is open');
      expect(
          visible(session: false, tab: 0, card: watch.value), isTrue,
          reason: 'the bubble shows on the AI Voice tab');

      // «нет» by voice (or Cancel): the card closes.
      answer.complete(false);
      await frame(tester);
      expect(gate.hasOpenCard, isFalse);
      expect(watch.value, isFalse, reason: 'the card is closed');
      expect(visible(session: false, tab: 0, card: watch.value), isFalse);

      final d = await decision;
      expect(d.outcome, AiGateOutcome.cancelled);
      expect(d.mayExecute, isFalse);
    });

    testWidgets('tells its listeners only when the card opens or closes',
        (tester) async {
      final watch = GuardianAppShell.aiCardOpenWatch();
      await tester.pumpWidget(const SizedBox());
      var changes = 0;
      void count() => changes++;
      watch.addListener(count);
      addTearDown(() => watch.removeListener(count));

      await frame(tester);
      await frame(tester);
      expect(changes, 0, reason: 'no card: nothing to tell');

      final answer = Completer<bool>();
      gate.confirmUiOverride = (_) => answer.future;
      final decision = gate.confirm(revoke);
      await frame(tester);
      await frame(tester);
      await frame(tester);
      expect(changes, 1, reason: 'opened once');

      answer.complete(false);
      await frame(tester);
      await frame(tester);
      expect(changes, 2, reason: 'closed once');
      await decision;
    });
  });
}
