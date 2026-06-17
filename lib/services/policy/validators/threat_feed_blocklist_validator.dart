import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/policy/validators/epk_validator.dart';
import 'package:ibiti_guardian/services/policy/validators/epk_validator_result.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/threat_intelligence_service.dart';

class ThreatFeedBlocklistValidator extends EPKValidator {
  const ThreatFeedBlocklistValidator() : super('ThreatFeedBlocklistValidator');

  @override
  Future<EpkValidatorResult> validate(
      TransactionRequest tx, EpkState state) async {
    if (!state.hasThreatFeedBlocklistValidator) {
      return EpkValidatorResult.pass();
    }

    final toAddress = tx.spenderAddress ?? tx.toAddress;

    // Use Threat Intelligence Service
    final threatService = ThreatIntelligenceService.instance;
    final threatRecord = threatService.lookup(tx.chainId, toAddress);

    if (threatRecord != null) {
      return EpkValidatorResult.reject(
        reason: 'THREAT_FEED_MATCH',
        severity: 'danger',
        userMessage:
            'Security Alert: The destination address is flagged in the global threat intelligence feed as a \${threatRecord.category.name}.',
        debugDetails:
            'Matched threat feed record: \${threatRecord.label} (Base Risk \${threatRecord.baseRiskWeight})',
      );
    }

    return EpkValidatorResult.pass();
  }
}
