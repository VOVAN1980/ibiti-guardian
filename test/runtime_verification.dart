import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/services/moralis/moralis_config_service.dart';
import 'package:ibiti_guardian/services/security/approval_scan_service.dart';
import 'package:ibiti_guardian/services/portfolio_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String testWallet = "0xd8da6bf26964af9d7eed9e03e53415d37aa96045";

  group('End-to-End Runtime Verification', () {
    setUpAll(() async {
      print('--- INITIALIZING VERIFICATION ---');
      await MoralisConfigService.instance.init();
    });

    test('1. Dashboard Wallet Scan Flow', () async {
      print('\n[VERIFY] Dashboard Wallet Scan');
      try {
        final approvals = await ApprovalScanService.scan(testWallet);
        print(' - Success: YES');
        print(' - Count: ${approvals.length}');
      } catch (e) {
        print(' - Error: $e');
      }
    });

    test('2. Portfolio Load Flow', () async {
      print('\n[VERIFY] Portfolio Load');
      try {
        final assets = await PortfolioService().getPortfolio(testWallet);
        print(' - Success: YES');
        print(' - Count: ${assets.length}');
      } catch (e) {
        print(' - Error: $e');
      }
    });
  });
}
