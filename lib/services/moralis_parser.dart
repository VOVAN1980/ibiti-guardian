import 'package:ibiti_guardian/utils/guardian_logger.dart';
import "package:ibiti_guardian/models/approval.dart";
import "package:ibiti_guardian/config/chains.dart";
import "package:ibiti_guardian/services/token_metadata_cache.dart";
import "package:ibiti_guardian/services/spender_intelligence_service.dart";

class MoralisParser {
  /// Maps a Moralis API result JSON item into an [ApprovalData] object.
  static ApprovalData parseApprovalItem(
    Map<String, dynamic> item,
    String currentChain, {
    String? ownerAddress,
  }) {
    final token = (item["token"] as Map?) ?? const {};
    final spender = (item["spender"] as Map?) ?? const {};

    final tokenAddr = (token["address"] ?? "").toString();
    final spenderAddr = (spender["address"] ?? "").toString();

    final valueStr = (item["value"] ?? "0").toString();
    BigInt allowance;
    try {
      allowance = BigInt.parse(valueStr);
    } catch (_) {
      allowance = BigInt.zero;
    }

    final spenderLabel =
        (spender["address_label"] ?? spender["entity"] ?? "Unknown").toString();
    final verified = (token["verified_contract"] == true);

    // Get metadata from cache or JSON
    final cache = TokenMetadataCache();
    final cached = cache.get(currentChain, tokenAddr);

    String tokenName;
    String tokenSymbol;
    int decimals;

    if (cached != null) {
      tokenName = cached.name;
      tokenSymbol = cached.symbol;
      decimals = cached.decimals;
    } else {
      tokenName = (token["name"] ?? "Unknown").toString();
      tokenSymbol = (token["symbol"] ?? "???").toString();
      decimals = token["decimals"] is int
          ? token["decimals"] as int
          : int.tryParse(token["decimals"]?.toString() ?? "18") ?? 18;

      // Save to cache
      if (tokenAddr.isNotEmpty) {
        cache.set(
          currentChain,
          tokenAddr,
          TokenMetadata(
            tokenAddress: tokenAddr,
            name: tokenName,
            symbol: tokenSymbol,
            decimals: decimals,
            logoUrl:
                token["thumbnail"]?.toString() ?? token["logo"]?.toString(),
          ),
        );
      }
    }

    final chainId = ChainConfig.getChainId(currentChain);
    final reputation = SpenderIntelligenceService.instance.getReputation(
      chainId,
      spenderAddr,
    );
    final trustedLabel = SpenderIntelligenceService.instance.getTrustedLabel(
      chainId,
      spenderAddr,
    );

    final finalSpenderLabel =
        trustedLabel ?? (spenderLabel.isNotEmpty ? spenderLabel : spenderAddr);

    // Heuristic for contract age:
    // Moralis sometimes provides 'contract_created_at' in spender/token metadata.
    // As a fallback, we use the approval block_timestamp if it's very recent,
    // though that's technically 'approval age'.
    // To be strictly 'contractAgeDays', we check 'contract_created_at'.
    int ageDays = 365; // Default to old/safe
    final createdAt =
        spender["contract_created_at"] ?? token["contract_created_at"];
    if (createdAt != null) {
      try {
        final createdDate = DateTime.parse(createdAt.toString());
        ageDays = DateTime.now().difference(createdDate).inDays;
      } catch (e) {
        const log = GuardianLogger('MoralisParser');
        log.e('Caught', e);
      }
    } else if (item["block_timestamp"] != null) {
      // If we don't have contract age but the approval is extremely new,
      // we can optionally use it as a signal, but strictly per requirements
      // we'll stick to provided contract metadata if possible.
      // For now, let's keep it 365 if unknown to avoid false Criticals.
    }

    return ApprovalData(
      chainId: chainId,
      token: tokenAddr,
      tokenName: tokenName,
      tokenSymbol: tokenSymbol,
      spenderAddress: spenderAddr,
      spender: finalSpenderLabel,
      allowance: allowance,
      decimals: decimals,
      isKnownDex: reputation == SpenderReputation.dex,
      isVerified: verified,
      contractAgeDays: ageDays,
      reputation: reputation,
      walletAddress: ownerAddress,
    );
  }
}
