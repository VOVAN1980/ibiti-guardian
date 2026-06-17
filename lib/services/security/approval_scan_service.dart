import "dart:convert";
import "package:http/http.dart" as http;
import "package:ibiti_guardian/models/approval.dart";
import "package:ibiti_guardian/config/chains.dart";
import "package:ibiti_guardian/services/risk_engine.dart";
import "package:ibiti_guardian/services/moralis_parser.dart";
import "package:ibiti_guardian/services/moralis/moralis_config_service.dart";
import "package:ibiti_guardian/services/localization_service.dart";
import "dart:async";

class ApprovalScanService {
  static int? lastRiskScore;
  static bool hasRiskyApprovals = false;
  static List<ApprovalData> lastScannedApprovals = [];
  static DateTime? lastScanTime;

  static Future<List<ApprovalData>> scan(
    String wallet, {
    String? targetTokenAddress,
    int? chainId,
  }) async {
    final apiKey = MoralisConfigService.key;

    // chainId must be provided by caller (WalletAdapter.chainId or explicit).
    // Fallback 56 = BNB Smart Chain (primary target network for IBITI Vault).
    final activeChainId = chainId ?? 56;
    final t = LocalizationService.instance;

    final currentChain = ChainConfig.getMoralisChainSlug(activeChainId);
    if (currentChain == null) {
      throw t.t('errorUnsupportedNetwork', {'id': activeChainId});
    }

    if (apiKey.isEmpty) {
      throw t.t('errorApiMissingKey');
    }

    final out = <ApprovalData>[];
    int attempts = 0;
    const maxAttempts = 3;

    while (attempts < maxAttempts) {
      try {
        attempts++;
        final uri = Uri.parse(
          "https://deep-index.moralis.io/api/v2.2/wallets/$wallet/approvals?chain=$currentChain&limit=100",
        );
        final res = await http.get(uri, headers: {"X-API-Key": apiKey}).timeout(
            const Duration(seconds: 10));

        if (res.statusCode == 200) {
          final json = jsonDecode(res.body) as Map<String, dynamic>;
          final result = (json["result"] as List?) ?? const [];
          for (final it in result) {
            final m = it as Map<String, dynamic>;
            final parsed = MoralisParser.parseApprovalItem(m, currentChain);
            if (parsed.token.isEmpty || parsed.spenderAddress.isEmpty) continue;

            if (targetTokenAddress != null &&
                parsed.token.toLowerCase() !=
                    targetTokenAddress.toLowerCase()) {
              continue;
            }
            out.add(parsed);
          }
          break; // Success
        } else if (res.statusCode == 429 || res.statusCode >= 500) {
          // Rate limit or server error: retry with delay
          if (attempts < maxAttempts) {
            await Future.delayed(Duration(milliseconds: 300 * attempts));
            continue;
          }
          throw t.t('errorApiFailed', {'status': res.statusCode});
        } else {
          throw t.t('errorApiFailed', {'status': res.statusCode});
        }
      } on TimeoutException {
        if (attempts < maxAttempts) continue;
        throw t.t('errorTimeout');
      } catch (e) {
        if (attempts < maxAttempts) continue;
        throw e.toString();
      }
    }

    RiskEngine.evaluate(out);
    updateScore(out);
    lastScannedApprovals = out;
    lastScanTime = DateTime.now();
    return out;
  }

  static void updateScore(List<ApprovalData> approvals) {
    if (approvals.isEmpty) {
      lastRiskScore = 100;
      hasRiskyApprovals = false;
      return;
    }

    // Use the new RiskEngine assessment to update global dashboard state
    final walletAssessment = RiskEngine.computeWalletAssessment(approvals);
    lastRiskScore = 100 - walletAssessment.score;

    // Check if any approval requires revocation according to new logic
    hasRiskyApprovals = approvals.any((a) => a.assessment.shouldRevoke);
  }
}
