import "package:ibiti_guardian/models/approval.dart";
import "package:ibiti_guardian/models/gas_estimation_result.dart";
import "package:ibiti_guardian/models/transaction_request.dart";
import "package:ibiti_guardian/models/intent_data.dart";
import "package:ibiti_guardian/services/erc20_abi.dart";
import "package:ibiti_guardian/services/localization_service.dart";
import "package:ibiti_guardian/services/vault/ibiti_vault_service.dart";
import "package:ibiti_guardian/services/vault/ibiti_vault_signer.dart";
import "package:ibiti_guardian/services/vault/epk_contract_resolver.dart";
import "package:ibiti_guardian/config/chains.dart";
import "package:ibiti_guardian/config/privy_chain_registry.dart";
import "package:ibiti_guardian/services/adapters/wallet_adapter.dart";
import "package:ibiti_guardian/utils/guardian_logger.dart";
import "package:ibiti_guardian/services/execution/native_transaction_builder.dart";
import "package:web3dart/web3dart.dart";
import "dart:convert";
import "package:http/http.dart" as http;

// ──────────────────────────────────────────────────────────────────────────────
// RevokeService — IBITI/EPK Architecture
//
// Revokes ERC-20 approvals by routing the approve(spender, 0) call through
// the IBITIVaultSigner.executeEPKTransaction(). This ensures the revocation
// goes through the EPK policy layer and is signed by the embedded Privy wallet.
//
// NOTE: WalletConnect / Reown modal has been removed from this service.
// The only execution path is EPKernel.execute() via IBITIVaultSigner.
// ──────────────────────────────────────────────────────────────────────────────
class RevokeService {
  static final BigInt _zero = BigInt.zero;
  static const _log = GuardianLogger('RevokeService');

  /// Conservative fallback values when RPC estimation fails.
  static const int _fallbackGasUnits = 100000;
  static const int _fallbackGasPriceGwei = 5;

  /// Revokes an ERC-20 approval by calling approve(spender, 0) through EPK.
  /// Returns txHash on success.
  static Future<String> revokeApproval({required ApprovalData a}) async {
    final t = LocalizationService.instance;
    final vault = IBITIVaultService.instance;

    if (a.chainId == 0) {
      throw t.t('errorRevokeUnsupported');
    }
    if (!vault.isVaultCreated) {
      throw StateError("IBITI Vault not created. Complete onboarding first.");
    }
    if (!vault.isUnlocked) {
      throw StateError("Vault is locked. Please unlock first.");
    }
    final int currentChainId;
    try {
      currentChainId = WalletAdapter.instance.chainId;
    } on StateError {
      throw StateError('Revoke is only available on EVM networks.');
    }
    if (currentChainId != a.chainId) {
      throw t.t('errorRevokeWrongNetwork');
    }

    // Encode: approve(spender, 0) — revokes the allowance
    final calldata = Erc20Abi.encodeApprove(
      spender: a.spenderAddress,
      value: _zero,
    );

    final epkAddress =
        EpkContractResolver.instance.kernelAddressForChain(a.chainId);
    final policyId = EpkContractResolver.instance.parsePolicyId(vault.policyId);
    if (epkAddress == null || policyId == null) {
      throw StateError(
        "On-chain EPK is not configured for this wallet on chain ${a.chainId}.",
      );
    }

    try {
      final txContext = TransactionRequest(
        type: TransactionType.revoke,
        fromAddress: vault.activeAddress,
        toAddress: a.token,
        spenderAddress: a.spenderAddress,
        rawAmount: BigInt.zero,
        chainId: a.chainId,
        chainKey: PrivyChainRegistry.getEvmChain(a.chainId)?.chainKey ??
            vault.chainKey,
        sourceIntent: IntentData.empty(),
      );

      final txHash = await IBITIVaultSigner.instance.executeEPKTransaction(
        txContext: txContext,
        epkAddress: epkAddress,
        policyId: policyId,
        target: a.token, // The token contract to call approve() on
        value: BigInt.zero, // No ETH value for approve call
        data: hexToBytes(calldata),
      );

      if (txHash == null || txHash.isEmpty) {
        throw t.t('errorNetworkError');
      }
      return txHash;
    } on EPKValidationException {
      // EPK policy block — re-throw with original message (e.g. "EPK not configured").
      rethrow;
    } on StateError {
      // Vault/chain state errors — re-throw with original message.
      rethrow;
    } catch (e) {
      final err = e.toString().toLowerCase();
      final symbol = ChainConfig.getNativeSymbol(a.chainId);
      if (err.contains("insufficient funds")) {
        throw t.t('errorInsufficientGas', {'symbol': symbol});
      }
      if (err.contains("user denied") || err.contains("rejected")) {
        throw t.t('errorUserRejected');
      }
      _log.e('Revoke failed', e);
      throw t.t('errorNetworkError');
    }
  }

  /// Gas estimation for revoke transaction — **conservative UI estimate**.
  ///
  /// Actual revoke execution goes through EPKernel.execute() which wraps the
  /// inner approve(spender, 0) call with signature verification, nonce checks,
  /// and delegatecall dispatch. Building full EPK calldata for eth_estimateGas
  /// would require ABI loading, a live nonce fetch, and a real EIP-712
  /// signature — effectively the entire executeEPKTransaction flow.
  ///
  /// Instead, we:
  /// 1. Call eth_estimateGas on the **inner** approve(spender, 0) payload.
  /// 2. Call eth_gasPrice for real gas pricing.
  /// 3. Apply a 50% buffer on gas units to account for EPK kernel overhead.
  /// 4. Fall back to conservative 100k / 5 Gwei on any RPC error.
  ///
  /// This gives an honest upper-bound for UI display, not an exact execution cost.
  static Future<GasEstimationResult> estimateGas({
    required ApprovalData a,
  }) async {
    final chain = PrivyChainRegistry.getEvmChain(a.chainId);
    final rpcUrl = chain?.rpcUrl;
    final symbol = ChainConfig.getNativeSymbol(a.chainId);

    // No RPC URL → use conservative fallback
    if (rpcUrl == null || rpcUrl.isEmpty) {
      _log.w('No RPC URL for chain ${a.chainId}, using fallback estimate');
      return _fallbackEstimate(symbol);
    }

    final vault = IBITIVaultService.instance;
    final from = vault.activeAddress;
    if (from.isEmpty) {
      return _fallbackEstimate(symbol);
    }

    // Build approve(spender, 0) calldata — the inner call inside EPK execute()
    final calldata = Erc20Abi.encodeApprove(
      spender: a.spenderAddress,
      value: BigInt.zero,
    );

    final txParams = <String, String>{
      'from': from,
      'to': a.token,
      'data': calldata,
      'value': '0x0',
    };

    try {
      // Parallel RPC calls for speed
      final results = await Future.wait([
        _postEvmRpc(
            rpcUrl: rpcUrl, method: 'eth_estimateGas', params: [txParams]),
        _postEvmRpc(rpcUrl: rpcUrl, method: 'eth_gasPrice', params: []),
      ]).timeout(const Duration(seconds: 8));

      final gasHex = results[0] as String;
      final priceHex = results[1] as String;

      final innerGas = _parseHexBigInt(gasHex);
      final gasPrice = _parseHexBigInt(priceHex);

      // Sanity: if RPC returned 0 or absurdly low values, use fallback
      if (innerGas <= BigInt.zero || gasPrice <= BigInt.zero) {
        _log.w('RPC returned zero gas/price, using fallback');
        return _fallbackEstimate(symbol);
      }

      // Apply 50% EPK overhead buffer: EPKernel.execute() adds ~15-20k gas
      // for signature verification + nonce update + delegatecall dispatch.
      // 50% buffer is conservative — typical approve is ~46k, so buffered
      // estimate is ~69k, which covers the ~60-65k actual EPK cost.
      final bufferedGas = innerGas + (innerGas >> 1); // innerGas * 1.5

      return GasEstimationResult(
        estimatedGas: bufferedGas,
        estimatedGasPrice: gasPrice,
        symbol: symbol,
      );
    } catch (e) {
      _log.w('RPC gas estimation failed, using fallback: $e');
      return _fallbackEstimate(symbol);
    }
  }

  /// Conservative fallback — always succeeds, never blocks UI.
  static GasEstimationResult _fallbackEstimate(String symbol) {
    return GasEstimationResult(
      estimatedGas: BigInt.from(_fallbackGasUnits),
      estimatedGasPrice: BigInt.from(_fallbackGasPriceGwei * 1000000000),
      symbol: symbol,
    );
  }

  static BigInt _parseHexBigInt(String hex) {
    final clean = hex.startsWith('0x') ? hex.substring(2) : hex;
    return BigInt.tryParse(clean, radix: 16) ?? BigInt.zero;
  }

  static Future<dynamic> _postEvmRpc({
    required String rpcUrl,
    required String method,
    required List<dynamic> params,
  }) async {
    final response = await http.post(
      Uri.parse(rpcUrl),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': method,
        'params': params,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('RPC HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    if (decoded['error'] != null) {
      throw Exception(decoded['error'].toString());
    }
    return decoded['result'];
  }
}
