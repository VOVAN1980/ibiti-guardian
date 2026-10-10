import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/screens/dapp/dapp_approval_dialog.dart';

class PopObserver extends NavigatorObserver {
  final popped = <Route<dynamic>>[];
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popped.add(route);
  }
}

const reject = 'Reject';
const approve = 'Authorize this payout';

void main() {
  Future<Future<bool?> Function()> prepare(
      WidgetTester tester, PopObserver observer) async {
    late BuildContext page;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      navigatorObservers: [observer],
      home: Builder(builder: (context) {
        page = context;
        return const Scaffold(body: Text('Browser'));
      }),
    ));
    return () => showDialog<bool>(
          context: page,
          barrierDismissible: false,
          builder: (_) => const DappApprovalDialog(
            title: Text('Receive payout'),
            content: Text('0.5 USDT'),
            rejectLabel: reject,
            approveLabel: approve,
          ),
        );
  }

  for (final first in [false, true]) {
    for (final second in [false, true]) {
      testWidgets(
          '$first then $second before rebuild accepts only first choice',
          (tester) async {
        final observer = PopObserver();
        final open = await prepare(tester, observer);
        final result = open();
        await tester.pumpAndSettle();
        final rejectButton = tester.widget<TextButton>(find.byType(TextButton));
        final approveButton =
            tester.widget<FilledButton>(find.byType(FilledButton));
        final callbacks = {
          false: rejectButton.onPressed!,
          true: approveButton.onPressed!
        };
        // Keep callbacks from the old frame to exercise the underlying guard,
        // not merely the widgets' disabled state after the rebuild.
        callbacks[first]!();
        callbacks[second]!();
        callbacks[first]!();
        await tester.pump();
        expect(tester.widget<TextButton>(find.byType(TextButton)).onPressed,
            isNull);
        expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNull);
        final rejectStyle = tester
            .widget<DefaultTextStyle>(find
                .ancestor(
                    of: find.text(reject),
                    matching: find.byType(DefaultTextStyle))
                .first)
            .style;
        final approveStyle = tester
            .widget<DefaultTextStyle>(find
                .ancestor(
                    of: find.text(approve),
                    matching: find.byType(DefaultTextStyle))
                .first)
            .style;
        final colors =
            Theme.of(tester.element(find.byType(AlertDialog))).colorScheme;
        expect(rejectStyle.color?.toARGB32(),
            colors.onSurface.withValues(alpha: 0.38).toARGB32());
        expect(approveStyle.color?.toARGB32(),
            colors.onSurface.withValues(alpha: 0.38).toARGB32());
        expect(await result, first);
        await tester.pumpAndSettle();
        callbacks[
            !first]!(); // A stale callback after disposal is harmless too.
        expect(observer.popped, hasLength(1));
        expect(find.text('Browser'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('real $first tap disables both buttons during close',
        (tester) async {
      final observer = PopObserver();
      final open = await prepare(tester, observer);
      final result = open();
      await tester.pumpAndSettle();
      await tester.tap(find.text(first ? approve : reject));
      await tester.tap(find.text(first ? reject : approve));
      await tester.pump();
      expect(
          tester.widget<TextButton>(find.byType(TextButton)).onPressed, isNull);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      expect(await result, first);
      await tester.pumpAndSettle();
      expect(observer.popped, hasLength(1));
    });
  }

  testWidgets('external cancellation before repaint never pops the browser',
      (tester) async {
    final observer = PopObserver();
    final open = await prepare(tester, observer);
    final result = open();
    await tester.pumpAndSettle();
    tester.widget<FilledButton>(find.byType(FilledButton)).onPressed!();
    Navigator.of(tester.element(find.byType(AlertDialog))).pop(false);
    await tester.pumpAndSettle();
    expect(await result, false);
    expect(observer.popped, hasLength(1));
    expect(find.text('Browser'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
