enum ThreatCategory {
  drainer,
  scamRouter,
  maliciousPermitSpender,
  fakeBridge,
  phishingContract,
}

class ThreatRecord {
  final int chainId;
  final String address;
  final String label;
  final ThreatCategory category;
  final String reasonKey;
  final int baseRiskWeight;

  const ThreatRecord({
    required this.chainId,
    required this.address,
    required this.label,
    required this.category,
    required this.reasonKey,
    required this.baseRiskWeight,
  });
}

/// List of known malicious addresses checked by ThreatFeedBlocklistValidator,
/// the dApp wallet and the approval scan (RiskEngine).
///
/// The list is empty: Guardian has no threat feed. The remote feed inherited
/// from DrainShield never existed (the URL returned 404) and the fallback held
/// only three fake test addresses, so both were removed. [lookup] finds
/// nothing, and every caller treats the address as not flagged.
class ThreatIntelligenceService {
  static final ThreatIntelligenceService instance =
      ThreatIntelligenceService._internal();
  ThreatIntelligenceService._internal();

  static const List<ThreatRecord> _threats = [];

  ThreatRecord? lookup(int chainId, String address) {
    final addr = address.toLowerCase();
    for (final record in _threats) {
      if (record.chainId == chainId && record.address.toLowerCase() == addr) {
        return record;
      }
    }
    return null;
  }
}
