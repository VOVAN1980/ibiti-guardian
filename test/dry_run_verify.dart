import 'package:ibiti_guardian/services/moralis/moralis_config_service.dart';
import 'package:ibiti_guardian/services/security/approval_scan_service.dart';
import 'package:ibiti_guardian/services/portfolio_service.dart';

void main() async {
  print('--- AI MONEY GUARDIAN DRY-RUN VERIFICATION ---');

  // 1. Verify Config
  print('\n[1/4] Verifying MoralisConfigService...');
  final config = MoralisConfigService.instance;
  await config.init();
  print(' - API Key detected: ${config.apiKey.isNotEmpty ? "YES" : "NO"}');
  print(' - Default Chain: ${config.defaultChain}');

  const String testWallet = "0xd8da6bf26964af9d7eed9e03e53415d37aa96045";

  // 2. Test ApprovalScanService
  print('\n[2/4] Testing ApprovalScanService.scan()...');
  try {
    final approvals = await ApprovalScanService.scan(testWallet);
    print(' - Success: YES');
    print(' - Count: ${approvals.length}');
    if (approvals.isNotEmpty) {
      final a = approvals[0];
      print(' - First Approval: ${a.token} (Spender: ${a.spenderAddress})');
      print(
          ' - Risk Assessment: ${a.assessment.label} (${a.assessment.score})');
    }
  } catch (e) {
    print(' - Error: $e');
  }

  // 3. Test PortfolioService
  print('\n[3/4] Testing PortfolioService.getPortfolio()...');
  try {
    final assets = await PortfolioService().getPortfolio(testWallet);
    print(' - Success: YES');
    print(' - Count: ${assets.length}');
    if (assets.isNotEmpty) {
      final top = assets[0];
      print(' - Top Asset: ${top.name} (${top.balance} ${top.symbol})');
      print(' - Value USD: \$${top.valueUsd.toStringAsFixed(2)}');
    }
  } catch (e) {
    print(' - Error: $e');
  }

  print('\n--- VERIFICATION COMPLETE ---');
}
