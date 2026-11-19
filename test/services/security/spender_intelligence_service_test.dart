import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/models/approval.dart';
import 'package:ibiti_guardian/services/spender_intelligence_service.dart';

void main() {
  final intel = SpenderIntelligenceService.instance;

  test('Multichain routers are flagged and named', () {
    const router = '0xd1C5966f9F5Ee6881Ff6b261BBeDa45972B1B5f3';
    expect(intel.getReputation(56, router), SpenderReputation.flagged);
    expect(intel.getReputation(56, router.toLowerCase()),
        SpenderReputation.flagged);
    expect(intel.getTrustedLabel(56, router), 'Multichain (Anyswap)');
    expect(intel.getReputation(1, '0x6b7a87899490EcE95443e979cA9485CBE7E71522'),
        SpenderReputation.flagged);
  });

  test('Multichain addresses are flagged only on their own chain', () {
    // On Arbitrum this address is an unrelated WETH contract.
    const ethRouter = '0x765277EebeCA2e31912C9946eAe1021199B39C61';
    expect(intel.getReputation(1, ethRouter), SpenderReputation.flagged);
    expect(intel.getReputation(42161, ethRouter), SpenderReputation.unknown);
    expect(intel.getTrustedLabel(42161, ethRouter), isNull);
    expect(intel.getReputation(8453, ethRouter), SpenderReputation.unknown);
  });

  test('a name is shown only where the contract is listed', () {
    // The Smart Router address is a different contract on Base.
    const smart = '0x13f4EA83D0bd40E75C8222255bc855a974568Dd4';
    expect(intel.getTrustedLabel(1, smart), 'PancakeSwap Smart Router');
    expect(intel.getTrustedLabel(8453, smart), isNull);
    const v3 = '0x1b81D678ffb9C0263b24A97847620C99d213eB14';
    for (final chain in [56, 1, 42161, 8453]) {
      expect(intel.getReputation(chain, v3), SpenderReputation.dex);
    }
    const uniV3 = '0xE592427A0AEce92De3Edee1F18E0157C05861564';
    for (final chain in [1, 137, 42161, 10]) {
      expect(intel.getTrustedLabel(chain, uniV3), 'Uniswap V3');
    }
  });

  test('old Multichain entry without contract code is no longer a bridge', () {
    const old = '0xCe710653629DE3484f4E630324707198dD9e7B81';
    expect(intel.getReputation(56, old), SpenderReputation.unknown);
    expect(intel.getTrustedLabel(56, old), isNull);
  });

  test('well-known DEX routers keep their reputation and label', () {
    expect(intel.getReputation(56, '0x10ED43C718714eb63d5aA57B78B54704E256024E'),
        SpenderReputation.dex);
    expect(intel.getTrustedLabel(56, '0x10ed43c718714eb63d5aa57b78b54704e256024e'),
        'PancakeSwap V2');
    expect(intel.getReputation(56, '0x13f4EA83D0bd40E75C8222255bc855a974568Dd4'),
        SpenderReputation.dex);
    expect(intel.getReputation(1, '0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D'),
        SpenderReputation.dex);
    expect(intel.getReputation(8453, '0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24'),
        SpenderReputation.dex);
    expect(intel.getReputation(10, '0x1111111254EEB25477B68fb85Ed929f73A960582'),
        SpenderReputation.dex);
  });

  test('a router listed for one chain is unknown on another', () {
    expect(intel.getReputation(42161, '0x10ED43C718714eb63d5aA57B78B54704E256024E'),
        SpenderReputation.unknown);
  });

  test('Permit2 is labelled as Uniswap Permit2', () {
    const permit2 = '0x000000000022D473030F116dDEE9F6B43aC78BA3';
    expect(intel.getReputation(1, permit2), SpenderReputation.safety);
    expect(intel.getTrustedLabel(1, permit2), 'Uniswap Permit2');
  });

  test('removed placeholder addresses are unknown', () {
    for (final addr in [
      '0x6666666666666666666666666666666666666666',
      '0x2c00000000000000000000000000000000000000',
    ]) {
      expect(intel.getReputation(56, addr), SpenderReputation.unknown);
      expect(intel.getTrustedLabel(56, addr), isNull);
    }
  });
}
