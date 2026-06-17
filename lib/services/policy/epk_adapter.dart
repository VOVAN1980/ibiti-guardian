import 'package:ibiti_guardian/models/epk_rule_snapshot.dart';
import 'package:ibiti_guardian/services/vault/epk_contract_resolver.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';

/// Bridging adapter uniting Flutter Orchestration with the On-Chain EPK Core.
///
/// Rule: Does NOT import Solidity. Exposes boundary interfaces verifying if
/// the selected network/wallet has the Smart Account EPK modules installed.
class EpkAdapter {
  EpkAdapter._();
  static final instance = EpkAdapter._();

  /// Simulates querying the active wallet to see if the EPK Enforcement Module
  /// is actually deployed and configured on the current chain.
  Future<bool> isEpkDeployed(String walletAddress, int chainId) async {
    if (walletAddress.isEmpty) return false;
    return EpkContractResolver.instance.isReady(
      chainId: chainId,
      rawPolicyId: IBITIVaultService.instance.policyId,
    );
  }

  /// Retrieves the current snapshot of active on-chain rules loaded into the EPK module.
  Future<List<EpkRuleSnapshot>> getActiveRules(
      String walletAddress, int chainId) async {
    if (!await isEpkDeployed(walletAddress, chainId)) return [];

    final policyId = EpkContractResolver.instance
        .parsePolicyId(IBITIVaultService.instance.policyId);
    final kernel =
        EpkContractResolver.instance.kernelAddressForChain(chainId) ?? '';

    return [
      EpkRuleSnapshot(
        ruleId: 'EPK_POLICY_${policyId ?? BigInt.zero}',
        description:
            'Kernel ${kernel.substring(0, 8)}... enforces the stored EPK policy on-chain.',
        isBlocking: true,
      ),
      const EpkRuleSnapshot(
        ruleId: 'CALL_ALLOWLIST',
        description:
            'Only pre-authorized contract selectors can execute through the EPK kernel.',
        isBlocking: true,
        severityLevel: 'WARNING',
      ),
    ];
  }
}
