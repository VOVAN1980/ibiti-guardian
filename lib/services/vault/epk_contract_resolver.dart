class EpkContractResolver {
  EpkContractResolver._();
  static final instance = EpkContractResolver._();

  static const String _bscTestnetKernel =
      '0x0beEB0083C576B54DB99B4abEF0Dcbc5Bc70bF82';

  static const String _bscMainnetKernelOverride =
      String.fromEnvironment('EPKERNEL_BSC_MAINNET');
  static const String _ethereumMainnetKernelOverride =
      String.fromEnvironment('EPKERNEL_ETH_MAINNET');
  static const String _polygonMainnetKernelOverride =
      String.fromEnvironment('EPKERNEL_POLYGON_MAINNET');
  static const String _arbitrumMainnetKernelOverride =
      String.fromEnvironment('EPKERNEL_ARBITRUM_MAINNET');
  static const String _baseMainnetKernelOverride =
      String.fromEnvironment('EPKERNEL_BASE_MAINNET');

  String? kernelAddressForChain(int chainId) {
    switch (chainId) {
      case 1:
        return _emptyToNull(_ethereumMainnetKernelOverride);
      case 56:
        return _emptyToNull(_bscMainnetKernelOverride);
      case 97:
        return _bscTestnetKernel;
      case 137:
        return _emptyToNull(_polygonMainnetKernelOverride);
      case 8453:
        return _emptyToNull(_baseMainnetKernelOverride);
      case 42161:
        return _emptyToNull(_arbitrumMainnetKernelOverride);
      default:
        return null;
    }
  }

  BigInt? parsePolicyId(String? rawPolicyId) {
    if (rawPolicyId == null) return null;
    final trimmed = rawPolicyId.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('0x')) {
      return BigInt.tryParse(trimmed.substring(2), radix: 16);
    }
    return BigInt.tryParse(trimmed);
  }

  bool isReady({
    required int chainId,
    required String? rawPolicyId,
  }) {
    return kernelAddressForChain(chainId) != null &&
        parsePolicyId(rawPolicyId) != null;
  }

  String? missingReason({
    required int chainId,
    required String? rawPolicyId,
  }) {
    final kernelAddress = kernelAddressForChain(chainId);
    if (kernelAddress == null) {
      return 'No EPK kernel configured for chainId=$chainId.';
    }
    if (parsePolicyId(rawPolicyId) == null) {
      return 'No numeric EPK policyId is stored for this wallet.';
    }
    return null;
  }

  String? _emptyToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
