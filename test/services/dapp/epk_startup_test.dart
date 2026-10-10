import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
      'vault loading before initialization does not permanently pause protection',
      () async {
    var available = false;
    final manager = EPKPolicyManager.forTesting(vaultCreated: () => available);
    await manager.init();
    expect(manager.state.isActive, isFalse);
    available = true;
    await manager.refreshPolicy();
    expect(manager.state.isActive, isTrue);
    expect(manager.state.hasSpendLimitValidator, isTrue);
    expect(manager.state.hasTargetSelectorGuard, isTrue);
    available = false;
    await manager.refreshPolicy();
    expect(manager.state.isActive, isFalse);
    available = true;
    await manager.refreshPolicy();
    expect(manager.state.isActive, isTrue);
    manager.dispose();
  });
  test('explicit Panic survives refresh and vault reload until explicit resume',
      () async {
    var available = true;
    final manager = EPKPolicyManager.forTesting(vaultCreated: () => available);
    await manager.init();
    await manager.emergencyPause();
    for (final value in [true, false, true]) {
      available = value;
      await manager.refreshPolicy();
      expect(manager.state.isActive, isFalse);
    }
    await manager.resumeProtection();
    expect(manager.state.isActive, isTrue);
    available = false;
    await manager.resumeProtection();
    expect(manager.state.isActive, isFalse);
    manager.dispose();
  });
  test('manual pause and resume survive a full manager restart', () async {
    final first = EPKPolicyManager.forTesting(vaultCreated: () => true);
    await first.init();
    await first.emergencyPause();
    first.dispose();
    final next = EPKPolicyManager.forTesting(vaultCreated: () => true);
    await next.init();
    expect(next.state.isActive, isFalse);
    await next.refreshPolicy();
    expect(next.state.isActive, isFalse);
    await next.resumeProtection();
    next.dispose();
    final resumed = EPKPolicyManager.forTesting(vaultCreated: () => true);
    await resumed.init();
    expect(resumed.state.isActive, isTrue);
    resumed.dispose();
  });
  test('invalid stored pause keeps signing blocked without rewriting it',
      () async {
    FlutterSecureStorage.setMockInitialValues(
        {'guardian_epk_manual_pause_v1': 'invalid'});
    final manager = EPKPolicyManager.forTesting(vaultCreated: () => true);
    await manager.init();
    await manager.refreshPolicy();
    expect(manager.state.isActive, isFalse);
    expect(
        await const FlutterSecureStorage()
            .read(key: 'guardian_epk_manual_pause_v1'),
        'invalid');
    manager.dispose();
  });
  test('overlapping pause after resume cannot reopen signing', () async {
    final manager = EPKPolicyManager.forTesting(vaultCreated: () => true);
    await manager.init();
    final resume = manager.resumeProtection();
    final pause = manager.emergencyPause();
    expect(manager.state.isActive, isFalse);
    await Future.wait([resume, pause]);
    await manager.refreshPolicy();
    expect(manager.state.isActive, isFalse);
    expect(
        await const FlutterSecureStorage()
            .read(key: 'guardian_epk_manual_pause_v1'),
        'true');
    manager.dispose();
  });
}
