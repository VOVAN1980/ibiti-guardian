import "dart:convert";
import "package:http/http.dart" as http;
import "package:ibiti_guardian/models/approval.dart";
import "package:ibiti_guardian/config/chains.dart";
import "package:ibiti_guardian/services/risk_engine.dart";
import "package:ibiti_guardian/services/moralis_parser.dart";
import "package:ibiti_guardian/services/moralis/moralis_config_service.dart";
import "package:ibiti_guardian/services/localization_service.dart";
import "dart:async";
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/services/ankr/ankr_config_service.dart';
import 'package:ibiti_guardian/services/ankr/ankr_approval_source.dart';
import 'package:ibiti_guardian/services/security/approval_source.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

class ApprovalScanService {
  static const _log = GuardianLogger('ApprovalScan');
  @visibleForTesting
  static ApprovalSource? sourceOverride;
  @visibleForTesting
  static http.Client Function()? moralisClientFactory;
  static int? lastRiskScore;
  static bool hasRiskyApprovals = false;
  static List<ApprovalData> lastScannedApprovals = [];
  static DateTime? lastScanTime;

  static Future<List<ApprovalData>> scan(
    String wallet, {
    String? targetTokenAddress,
    int? chainId,
    bool publishResult = true,
  }) async {
    final activeChainId = chainId ?? 56;
    final t = LocalizationService.instance;
    if (ChainConfig.getMoralisChainSlug(activeChainId) == null) {
      throw t.t('errorUnsupportedNetwork', {'id': activeChainId});
    }
    await AnkrConfigService.instance.ensureLoaded();
    final List<ApprovalData> out;
    try {
      final addressPattern = RegExp(r'^0x[0-9a-fA-F]{40}$');
      if (!addressPattern.hasMatch(wallet) ||
          (targetTokenAddress != null &&
              !addressPattern.hasMatch(targetTokenAddress))) {
        throw const ApprovalSourceException('invalid_address');
      }
      final source = sourceOverride ??
          (AnkrConfigService.instance.isConfigured
              ? AnkrApprovalSource()
              : null);
      out = source == null
          ? await _scanMoralis(wallet,
              targetTokenAddress: targetTokenAddress, chainId: activeChainId)
          : await source.fetch(wallet,
              chainId: activeChainId, targetTokenAddress: targetTokenAddress);
    } on ApprovalSourceException catch (e) {
      _log.w('Read failed: ${e.code}');
      throw t.t(e.code == 'scan_timeout' ? 'errorTimeout' : 'errorApiFailed');
    }
    RiskEngine.evaluate(out);
    // Token-only and background scans must not erase the last full UI scan.
    if (publishResult && targetTokenAddress == null) {
      updateScore(out);
      lastScannedApprovals = out;
      lastScanTime = DateTime.now();
    }
    return out;
  }

  static Future<List<ApprovalData>> _scanMoralis(
    String wallet, {
    String? targetTokenAddress,
    required int chainId,
  }) async {
    final apiKey = MoralisConfigService.key;

    // chainId must be provided by caller (WalletAdapter.chainId or explicit).
    // Fallback 56 = BNB Smart Chain (primary target network for IBITI Vault).
    final activeChainId = chainId;
    final t = LocalizationService.instance;

    final currentChain = ChainConfig.getMoralisChainSlug(activeChainId);
    if (currentChain == null) {
      throw t.t('errorUnsupportedNetwork', {'id': activeChainId});
    }

    if (apiKey.isEmpty) {
      throw t.t('errorApiMissingKey');
    }

    final out = <String, ApprovalData>{};
    String? cursor;
    final seenCursors = <String>{};
    const maxAttempts = 3;
    final client = moralisClientFactory?.call() ?? http.Client();
    final budget = Stopwatch()..start();
    try {
      for (var page = 0; page < 40; page++) {
        http.Response? res;
        for (var attempt = 1; attempt <= maxAttempts; attempt++) {
          final remaining = const Duration(seconds: 60) - budget.elapsed;
          if (remaining <= Duration.zero) {
            throw const ApprovalSourceException('scan_timeout');
          }
          final uri = Uri.https(
              'deep-index.moralis.io', '/api/v2.2/wallets/$wallet/approvals', {
            'chain': currentChain,
            'limit': '100',
            if (cursor != null) 'cursor': cursor,
          });
          try {
            res = await client.get(uri, headers: {'X-API-Key': apiKey}).timeout(
                remaining < const Duration(seconds: 10)
                    ? remaining
                    : const Duration(seconds: 10));
          } on TimeoutException {
            if (attempt < maxAttempts) continue;
            throw const ApprovalSourceException('scan_timeout');
          }
          if (res.statusCode == 200) break;
          if ((res.statusCode == 429 || res.statusCode >= 500) &&
              attempt < maxAttempts) {
            await Future.delayed(Duration(milliseconds: 300 * attempt));
            continue;
          }
          throw ApprovalSourceException('http_${res.statusCode}');
        }
        final decoded = jsonDecode(res!.body);
        if (decoded is! Map || decoded['result'] is! List) {
          throw const ApprovalSourceException('invalid_approval_page');
        }
        for (final row in decoded['result']) {
          if (row is! Map<String, dynamic>) {
            throw const ApprovalSourceException('invalid_approval_row');
          }
          final value = BigInt.tryParse(row['value']?.toString() ?? '');
          final token = row['token'];
          final spender = row['spender'];
          final validAddress = RegExp(r'^0x[0-9a-fA-F]{40}$');
          if (value == null ||
              value < BigInt.zero ||
              token is! Map ||
              spender is! Map ||
              !validAddress.hasMatch(token['address']?.toString() ?? '') ||
              !validAddress.hasMatch(spender['address']?.toString() ?? '')) {
            throw const ApprovalSourceException('invalid_approval_row');
          }
          if (targetTokenAddress != null &&
              token['address'].toString().toLowerCase() !=
                  targetTokenAddress.toLowerCase()) {
            continue;
          }
          final parsed = MoralisParser.parseApprovalItem(row, currentChain,
              ownerAddress: wallet);
          final key =
              '${parsed.token.toLowerCase()}_${parsed.spenderAddress.toLowerCase()}';
          if (value == BigInt.zero) {
            out.remove(key);
          } else {
            out[key] = parsed;
          }
        }
        final next = decoded['cursor'];
        if (next != null && next is! String) {
          throw const ApprovalSourceException('invalid_cursor');
        }
        cursor = next == null || next == '' ? null : next as String;
        if (cursor == null) return out.values.toList();
        if (!seenCursors.add(cursor)) {
          throw const ApprovalSourceException('cursor_cycle');
        }
      }
      throw const ApprovalSourceException('page_limit');
    } on ApprovalSourceException {
      rethrow;
    } on FormatException {
      throw const ApprovalSourceException('invalid_json');
    } catch (_) {
      throw const ApprovalSourceException('network_error');
    } finally {
      budget.stop();
      client.close();
    }
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
