import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ibiti_guardian/services/security/system_status_service.dart';

/// The wallet's "System status" card is red only for real problems; Safe
/// Scan results are kept per wallet and network and survive a restart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final status = SystemStatusService.instance;
  const wallet = '0xAbC0000000000000000000000000000000000001';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    status.resetForTest();
  });

  test('no scan yet: safe', () async {
    await status.load();
    expect(status.isSafe, true);
    expect(status.problems, isEmpty);
  });

  test('risky approvals on one network make it red until fixed', () async {
    await status.load();
    await status.recordScan(wallet, 56, 2);
    expect(status.problems, [SystemProblem.riskyApprovals]);
    expect(status.riskyApprovals, 2);

    // A clean scan of another network does not hide the BSC problem.
    await status.recordScan(wallet, 1, 0);
    expect(status.riskyApprovals, 2);

    // Rescanning BSC after the revoke clears it.
    await status.recordScan(wallet.toLowerCase(), 56, 0);
    expect(status.isSafe, true);
  });

  test('signing out clears the old wallet results', () async {
    await status.recordScan(wallet, 56, 4);
    await status.clear();
    expect(status.isSafe, true);
    status.resetForTest();
    await status.load();
    expect(status.riskyApprovals, 0);
  });

  test('a scan recorded before load keeps the saved results', () async {
    SharedPreferences.setMockInitialValues({
      'system_status_risky_by_scan': '{"0xabc|56": 2}',
    });
    status.resetForTest();
    await status.recordScan(wallet, 1, 1);
    expect(status.riskyApprovals, 3);
    expect(status.riskyScans.map((s) => s.chainId), containsAll([56, 1]));
  });

  test('the last scan result survives a restart', () async {
    await status.load();
    await status.recordScan(wallet, 137, 3);
    status.resetForTest();
    await status.load();
    expect(status.riskyApprovals, 3);
    expect(status.problems, contains(SystemProblem.riskyApprovals));
  });
}
