import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/dapp/dapp_return_navigation.dart';

void main() {
  const page =
      'https://api.lvs.network/v1/wallet/evm-pay/withdrawal-ab12?auto=1';
  bool allowed(String? source,
          {String target = DappReturnNavigation.lvsReturn,
          bool mainFrame = true}) =>
      DappReturnNavigation.allows(
          source: source, target: target, isMainFrame: mainFrame);

  test('exact LVS status return works for both user and automatic navigation',
      () {
    expect(allowed(page), isTrue);
    expect(
        allowed('https://api.lvs.network:443/v1/wallet/evm-pay/id/'), isTrue);
  });
  test('iframe, foreign origins and unrelated pages cannot open the app', () {
    expect(allowed(page, mainFrame: false), isFalse);
    for (final source in [
      null,
      'http://api.lvs.network/v1/wallet/evm-pay/id',
      'https://api.lvs.network.evil.test/v1/wallet/evm-pay/id',
      'https://evil.test/v1/wallet/evm-pay/id',
      'https://api.lvs.network:8443/v1/wallet/evm-pay/id',
      'https://user@api.lvs.network/v1/wallet/evm-pay/id',
      'https://api.lvs.network/other',
      'https://api.lvs.network/v1/wallet/evm-pay/',
      'https://api.lvs.network/v1/wallet/evm-pay/id/status'
    ]) {
      expect(allowed(source), isFalse, reason: source);
    }
  });
  test('only the exact read-only route is accepted without any payload', () {
    for (final target in [
      'lvs://wallet/withdrawal?send=1',
      'lvs://wallet/withdrawal#payload',
      'lvs://wallet/transfer',
      'lvs://other/withdrawal',
      'intent://wallet/withdrawal',
      'javascript:alert(1)',
      'https://evil.test'
    ]) {
      expect(allowed(page, target: target), isFalse, reason: target);
    }
  });
}
