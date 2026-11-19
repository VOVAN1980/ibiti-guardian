import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/policy/validators/epk_validator.dart';
import 'package:ibiti_guardian/services/policy/validators/epk_validator_result.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/threat_intelligence_service.dart';

/// Rejects targets listed in ThreatIntelligenceService. That list is empty for
/// now (Guardian has no threat feed), so every address passes this check.
class ThreatFeedBlocklistValidator extends EPKValidator {
  const ThreatFeedBlocklistValidator() : super('ThreatFeedBlocklistValidator');

  @override
  Future<EpkValidatorResult> validate(
      TransactionRequest tx, EpkState state) async {
    if (!state.hasThreatFeedBlocklistValidator) {
      return EpkValidatorResult.pass();
    }

    final toAddress = tx.spenderAddress ?? tx.toAddress;

    final threatService = ThreatIntelligenceService.instance;
    final threatRecord = threatService.lookup(tx.chainId, toAddress);

    if (threatRecord != null) {
      return EpkValidatorResult.reject(
        reason: 'THREAT_FEED_MATCH',
        severity: 'danger',
        userMessage:
            'Security Alert: The destination address is on the blocklist as a ${threatRecord.category.name}.',
        debugDetails:
            'Matched blocklist record: ${threatRecord.label} (Base Risk ${threatRecord.baseRiskWeight})',
      );
    }

    return EpkValidatorResult.pass();
  }
}
