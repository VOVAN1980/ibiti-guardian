import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/screens/security/epk_control_screen.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pausing EPK switches protection off, so on the EPK screen it needs the
/// PIN (as in Policy). Without a PIN / biometrics set up it cannot happen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    // A vault without a PIN or biometrics.
    IBITIVaultService.instance.setVaultCreatedForTest(
        evmAddress: '0x9999999999999999999999999999999999999999');
    await EPKPolicyManager.instance.resumeProtection();
  });

  Future<void> openPauseTile(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: EPKControlScreen()));
    await tester.pumpAndSettle();
    expect(EPKPolicyManager.instance.state.isActive, isTrue);
    await tester.ensureVisible(find.text('epkPauseAction'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('epkPauseAction'));
    await tester.pumpAndSettle();
    expect(find.text('epkDangerPauseTitle'), findsOneWidget);
  }

  testWidgets('the danger tile asks to confirm, then the PIN', (tester) async {
    await openPauseTile(tester);
    await tester.tap(find.text('aiControlConfirm'));
    await tester.pumpAndSettle();

    // No PIN set up: requireAuth asks to set one up and refuses.
    expect(find.text('securityRequiredTitle'), findsOneWidget);
    await tester.tap(find.text('swapCancel'));
    await tester.pumpAndSettle();
    expect(EPKPolicyManager.instance.state.isActive, isTrue);
  });

  testWidgets('cancelling the confirmation changes nothing', (tester) async {
    await openPauseTile(tester);
    await tester.tap(find.text('policyEditCancel'));
    await tester.pumpAndSettle();
    expect(find.text('securityRequiredTitle'), findsNothing);
    expect(EPKPolicyManager.instance.state.isActive, isTrue);
  });
}
