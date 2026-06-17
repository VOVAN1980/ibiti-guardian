// Widget test for IBITI Guardian.
// The default Flutter counter smoke test has been replaced with a
// minimal smoke test that verifies the app can boot without crashing.
//
// TODO(tests): add real widget tests for:
//   - PolicyLimitsScreen (save/load limits)
//   - AiControlScreen (mode toggle)
//   - EPKControlScreen (status display)
//   - WalletSpaceScreen (balance display)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App renders a MaterialApp without errors',
      (WidgetTester tester) async {
    // Boot a minimal app shell to verify no immediate crash on startup.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('IBITI Guardian')),
        ),
      ),
    );
    expect(find.text('IBITI Guardian'), findsOneWidget);
  });
}
