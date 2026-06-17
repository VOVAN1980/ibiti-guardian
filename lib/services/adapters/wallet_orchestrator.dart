import 'package:ibiti_guardian/models/wallet_context.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';

/// Aggregates multiple connected wallet identities into a single risk scope.
/// In Phase 6, we pass this unified context down to the PolicyEngine so it can tighten/loosen
/// rules securely based on broader account-level exposure.
class WalletOrchestrator {
  WalletOrchestrator._();
  static final instance = WalletOrchestrator._();

  final WalletAdapter _adapter = WalletAdapter.instance;

  // Stub for multiple connected wallets in the future.
  // For V1 of Phase 6, we map the single primary adapter into a globally-aware Context object.
  Future<WalletContext> getGlobalContext() async {
    if (!_adapter.isConnected) {
      return const WalletContext(
          address: '', chainId: 0, totalBalance: 0, riskScore: 0);
    }

    final addr = _adapter.address;
    final chain = _adapter.chainId;

    // Simulate grabbing total aggregated metrics
    // e.g. querying across chains to see if any other linked addresses are compromised.
    final simulatedRiskScore = await _queryGlobalRiskEngine(addr);

    return WalletContext(
      address: addr,
      chainId: chain,
      totalBalance: 1250.00, // Fixed stub for UI
      riskScore: simulatedRiskScore,
    );
  }

  /// Mock external API query evaluating if this identity cluster is actively monitored
  Future<int> _queryGlobalRiskEngine(String address) async {
    // Arbitrary stub: if the address starts with '0xBAD' we simulate a global risk spike
    if (address.toLowerCase().startsWith('0xbad')) {
      return 85;
    }
    return 10; // normal negligible background risk
  }
}
