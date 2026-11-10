import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/exchanges/api_key_expiry_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('days left count from when the key was connected', () async {
    final connected = DateTime.now().subtract(const Duration(days: 87));
    SharedPreferences.setMockInitialValues({
      'cex_key_started_at_mexc': connected.toIso8601String(),
    });
    final svc = ApiKeyExpiryService.instance;
    await svc.load();

    expect(svc.daysLeft('mexc'), 3);
    expect(svc.expiresAt('mexc'), connected.add(const Duration(days: 90)));
    // Gate.io is tracked but no key date is stored yet.
    expect(svc.daysLeft('gateio'), isNull);
  });

  test('which exchanges expire keys and which can extend them', () {
    final svc = ApiKeyExpiryService.instance;
    expect(svc.tracks('mexc'), isTrue);
    expect(svc.tracks('gateio'), isTrue);
    // OKX/Binance delete keys after inactivity, not on a fixed date.
    expect(svc.tracks('okx'), isFalse);
    expect(svc.tracks('binance'), isFalse);
    expect(svc.canExtend('mexc'), isTrue);
    expect(svc.canExtend('gateio'), isFalse);
  });
}
