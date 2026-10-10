import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/policy_profile.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/models/tx_status.dart';
import 'package:ibiti_guardian/services/execution/tx_registry.dart';
import 'package:ibiti_guardian/services/market/market_data_service.dart';
import 'package:ibiti_guardian/services/market/token_registry_service.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/services/policy/validators/composite_validator.dart';
import 'package:ibiti_guardian/services/threat_intelligence_service.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_signer.dart';
import 'dapp_protocol.dart';
import 'dapp_session.dart';
import 'dapp_policy.dart';
import 'dapp_simulation.dart';
import 'dapp_verified_receive.dart';
import 'dapp_transaction_consent.dart';

class DappRpc {
  final http.Client Function() createClient;
  DappRpc({http.Client Function()? createClient})
      : createClient = createClient ?? http.Client.new;

  Future<dynamic> call(int chainId, String method, List<dynamic> params) async {
    final chain = PrivyChainRegistry.getEvmChain(chainId);
    if (chain?.rpcUrl == null) {
      throw const DappError(4901, 'Unsupported network.');
    }
    final client = createClient();
    try {
      final response = await client
          .post(Uri.parse(chain!.rpcUrl!),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'jsonrpc': '2.0',
                'id': 1,
                'method': method,
                'params': params
              }))
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200 || response.body.length > 2000000) {
        throw const DappError(-32000, 'Network RPC is unavailable.');
      }
      final result = jsonDecode(response.body);
      if (result is! Map ||
          result['error'] != null ||
          !result.containsKey('result')) {
        throw const DappError(
            -32000, 'RPC rejected the request or simulation reverted.');
      }
      return result['result'];
    } on DappError {
      rethrow;
    } catch (_) {
      throw const DappError(-32000, 'Network RPC is unavailable.');
    } finally {
      client.close();
    }
  }
}

class GuardianDappWallet implements DappWalletBackend {
  final DappRpc rpc;
  GuardianDappWallet({DappRpc? rpc}) : rpc = rpc ?? DappRpc();
  final _prepared = <DappTransaction, _PreparedDappTransaction>{};
  Future<DappReceiverRegistry>? _receivers;
  Future<DappReceiverRegistry> get _receiverRegistry =>
      _receivers ??= rootBundle
          .loadString('assets/dapp/verified_receivers.json')
          .then(DappReceiverRegistry.fromJson);
  IBITIVaultService get _vault => IBITIVaultService.instance;
  EpkState get policyState => EPKPolicyManager.instance.state;
  @override
  String get account => _vault.evmAddress ?? '';
  @override
  bool get available =>
      _vault.isVaultCreated && _vault.isUnlocked && !_vault.privySessionExpired;
  @override
  Set<int> get supportedChains => PrivyChainRegistry.supportedChains
      .where((c) => c.isEvm)
      .map((c) => c.evmChainId!)
      .toSet();

  @override
  Future<void> checkSigningAllowed(int chainId) async {
    if (!available || !supportedChains.contains(chainId)) {
      throw const DappError(
          4900, 'Unlock and sign in to your Guardian wallet.');
    }
    if (!policyState.isActive) {
      throw const DappError(4100, 'Guardian protection is paused.');
    }
    if (!await _vault.hasPrivySession()) {
      throw const DappError(
          4900, 'The Privy session has expired. Sign in again.');
    }
  }

  double? _usd(BigInt raw, int decimals, String symbol) {
    if (raw == BigInt.zero) return 0;
    final amount = raw.toDouble() / BigInt.from(10).pow(decimals).toDouble();
    if (['USDT', 'USDC', 'DAI', 'BUSD'].contains(symbol)) return amount;
    final markets = MarketDataService.instance;
    if (markets.isStale) return null;
    final values = markets.cachedMarkets
        .where((a) => a.symbol.toUpperCase() == symbol.toUpperCase());
    if (values.isEmpty ||
        values.first.price <= 0 ||
        !values.first.price.isFinite) {
      return null;
    }
    final priceTime = values.first.sourceUpdatedAt;
    // A global market refresh does not prove this particular price is fresh.
    if (priceTime == null ||
        DateTime.now().difference(priceTime) > MarketDataService.maxStaleness ||
        priceTime.isAfter(DateTime.now())) {
      return null;
    }
    return amount * values.first.price;
  }

  _TxFacts _facts(DappTransaction tx, {DappReceiveEvidence? receive}) {
    final chain = PrivyChainRegistry.getEvmChain(tx.chainId)!;
    final token = TokenRegistryService.instance
        .resolveBuiltInAddress(tx.to, chain.chainKey);
    final knownToken = (tx.isApproval || tx.isTokenTransfer) && token.found;
    if ((tx.isApproval || tx.isTokenTransfer) && !knownToken) {
      throw const DappError(
          4100, 'This token is not in Guardian’s verified token registry.');
    }
    final nativeUsd = _usd(tx.value, 18, chain.nativeSymbol!);
    final tokenUsd =
        knownToken ? _usd(tx.tokenAmount!, token.decimals, token.symbol) : 0.0;
    final outgoing =
        nativeUsd != null && tokenUsd != null ? nativeUsd + tokenUsd : null;
    if (receive != null && !receive.matches(tx)) {
      throw const DappError(4100, 'Withdrawal simulation is no longer fresh.');
    }
    final unknown = tx.data != '0x' && !knownToken && receive == null;
    final projection = TransactionRequest(
        type: TransactionType.unknown,
        fromAddress: tx.from,
        toAddress: tx.to,
        chainId: tx.chainId,
        chainKey: chain.chainKey,
        sourceIntent: IntentData.empty(),
        amount: outgoing,
        tokenSymbol: knownToken ? token.symbol : chain.nativeSymbol,
        rawAmount: tx.value,
        spenderAddress: tx.tokenRecipient,
        isUnlimitedApproval: tx.isUnlimitedApproval,
        calldata: Uint8List.fromList([
          for (var i = 2; i < tx.data.length; i += 2)
            int.parse(tx.data.substring(i, i + 2), radix: 16)
        ]));
    return _TxFacts(projection, outgoing, unknown);
  }

  Future<void> _checkPolicy(DappTransaction tx, _TxFacts facts,
      {DappReceiveEvidence? receive}) async {
    final profile = PolicyProfileStore.instance.current;
    final epk = policyState;
    DappPolicy.check(
        tx: tx,
        profile: profile,
        epk: epk,
        spendUsd: facts.spendUsd,
        unknownSpend: facts.unknownSpend,
        verifiedReceive: receive,
        contractCall: tx.data != '0x' && !tx.isApproval && !tx.isTokenTransfer);
    // Same production EPK target and threat validators used by VaultSigner.
    final result = await CompositeValidator(verifiedReceive: receive)
        .validate(facts.projection, epk);
    if (!result.isValid) {
      throw const DappError(4100, 'Your EPK rules blocked this request.');
    }
    final intel = ThreatIntelligenceService.instance;
    if (intel.lookup(tx.chainId, tx.to) != null ||
        tx.tokenRecipient != null &&
            intel.lookup(tx.chainId, tx.tokenRecipient!) != null) {
      throw const DappError(
          4100, 'Guardian detected a dangerous contract or recipient.');
    }
  }

  @override
  Future<DappApproval> prepareTransaction(
      String origin, DappTransaction tx) async {
    if (tx.from.toLowerCase() != account.toLowerCase()) {
      throw const DappError(4100, 'Wallet account changed.');
    }
    final previous = _prepared[tx];
    late final DappGasPlan plan;
    DappReceiveEvidence? receive;
    late final _TxFacts facts;
    try {
      if (DappReceiveCall.recognizes(tx)) {
        // Prove the exact receive before offering one-time native consent.
        // A selector or an HTTPS origin is never enough to authorize a target.
        await checkSigningAllowed(tx.chainId);
        if (ThreatIntelligenceService.instance.lookup(tx.chainId, tx.to) != null) {
          throw const DappError(4100, 'Guardian detected a dangerous contract or recipient.');
        }
        DappReceiveCall.parse(tx);
        plan = await simulateDappTransaction(tx, rpc.call,
            approved: previous?.gas);
        final chain = PrivyChainRegistry.getEvmChain(tx.chainId)!;
        receive = await simulateVerifiedReceive(
            tx, plan, await _receiverRegistry, rpc.call,
            isVerifiedToken: (address) => TokenRegistryService.instance
                .resolveBuiltInAddress(address, chain.chainKey)
                .found);
        facts = _facts(tx, receive: receive);
        await _checkPolicy(tx, facts, receive: receive);
      } else {
        facts = _facts(tx);
        await _checkPolicy(tx, facts);
        plan = await simulateDappTransaction(tx, rpc.call,
            approved: previous?.gas);
      }
    } catch (_) {
      _prepared.remove(tx);
      rethrow;
    }
    if (previous == null) {
      _prepared.clear();
    }
    final chain = PrivyChainRegistry.getEvmChain(tx.chainId)!;
    final preview = DappApproval(
        origin: origin,
        method: 'eth_sendTransaction',
        account: tx.from,
        chainId: tx.chainId,
        content: const JsonEncoder.withIndent('  ').convert(plan.payload),
        fee: '${_formatAtomic(plan.maxFee)} ${chain.nativeSymbol}',
        transactionDetails: Map.unmodifiable({
          if (receive != null) 'operation': 'verifiedReceive',
          'target': tx.to,
          'nativeValue': '${_formatAtomic(tx.value)} ${chain.nativeSymbol}',
          if (tx.tokenRecipient != null) 'tokenRecipient': tx.tokenRecipient!,
          if (tx.tokenAmount != null)
            'tokenAmount':
                '${_formatAtomic(tx.tokenAmount!, decimals: TokenRegistryService.instance.resolveBuiltInAddress(tx.to, chain.chainKey).decimals)} ${facts.projection.tokenSymbol}',
          if (receive != null)
            'receiveAmount':
                '${_formatAtomic(receive.call.amount, decimals: TokenRegistryService.instance.resolveBuiltInAddress(receive.call.token, chain.chainKey).decimals)} ${TokenRegistryService.instance.resolveBuiltInAddress(receive.call.token, chain.chainKey).symbol}',
          if (receive != null) 'receiveToken': receive.call.token,
          if (receive != null) 'recipient': receive.call.recipient,
          if (receive != null) 'outgoingAssets': '0',
        }),
        warnings: [
          if (tx.isApproval) 'tokenApproval',
          if (tx.isUnlimitedApproval) 'unlimitedApproval',
          if (facts.unknownSpend) 'unverifiedTokenChanges',
          if (receive != null) 'verifiedReceive',
          if (receive != null) 'oneTimeReceive',
          'simulationLimits'
        ]);
    if (previous != null && previous.consent.preview.origin != origin) {
      _prepared.remove(tx);
      throw const DappError(4100, 'Website origin changed.');
    }
    _prepared[tx] = _PreparedDappTransaction(plan, receive,
        previous?.consent ?? DappTransactionConsent(tx, preview));
    return preview;
  }

  @override
  void confirmTransaction(DappTransaction tx, DappApproval shown) {
    final prepared = _prepared[tx];
    if (prepared == null) {
      throw const DappError(4100, 'A confirmed simulation is required.');
    }
    prepared.consent.confirm(tx, shown);
  }

  @override
  void discardTransaction(DappTransaction tx) => _prepared.remove(tx);

  @override
  Future<void> checkTypedData(Map<String, dynamic> data, int chainId) async {
    _checkTypedDataNow(data, chainId);
  }

  void _checkTypedDataNow(Map<String, dynamic> data, int chainId) {
    if (!policyState.isActive) {
      throw const DappError(4100, 'Guardian protection is paused.');
    }
    final domain = data['domain'] as Map;
    final contract = domain['verifyingContract'] as String?;
    final profile = PolicyProfileStore.instance.current;
    if (contract != null) {
      if (ThreatIntelligenceService.instance.lookup(chainId, contract) !=
          null) {
        throw const DappError(
            4100, 'The verifying contract is flagged as dangerous.');
      }
      if ((profile.mode == PolicyMode.safe || !profile.allowUnknownContracts) &&
          !profile.trustedContracts
              .any((a) => a.toLowerCase() == contract.toLowerCase())) {
        throw const DappError(
            4100, 'The verifying contract is not allowed by your policy.');
      }
    }
    // Permit/Permit2/orders may spend off-chain. The existing EPK transaction
    // validators cannot enforce them; do not release an unbounded authorization.
    final lower = jsonEncode(data).toLowerCase();
    if (RegExp(
            r'permit|spender|allowance|order|approval|approve|transfer|token|amount|value|delegat|authoriz')
        .hasMatch(lower)) {
      throw const DappError(4100,
          'Spending authorizations require a dedicated EPK permit validator.');
    }
  }

  @override
  Future<String> sendTransaction(DappTransaction tx,
      {required bool Function() isCurrent}) async {
    final prepared = _prepared.remove(tx);
    if (prepared == null) {
      throw const DappError(4100, 'A confirmed simulation is required.');
    }
    prepared.consent.consume(tx);
    await checkSigningAllowed(tx.chainId);
    final currentFacts = _facts(tx, receive: prepared.receive);
    await _checkPolicy(tx, currentFacts, receive: prepared.receive);
    if (!isCurrent()) {
      throw const DappError(4001, 'Request cancelled before signing.');
    }
    final hash = await IBITIVaultSigner.instance.sendTransaction(
        txParams: Map.of(prepared.gas.payload),
        txContext: currentFacts.projection,
        verifiedReceive: prepared.receive,
        canProceed: () {
          if (!isCurrent()) return false;
          // Recheck synchronous rules after Privy's getUser() await as well.
          try {
            final fresh = _facts(tx, receive: prepared.receive);
            DappPolicy.check(
                tx: tx,
                profile: PolicyProfileStore.instance.current,
                epk: policyState,
                spendUsd: fresh.spendUsd,
                unknownSpend: fresh.unknownSpend,
                verifiedReceive: prepared.receive,
                contractCall:
                    tx.data != '0x' && !tx.isApproval && !tx.isTokenTransfer);
            final intel = ThreatIntelligenceService.instance;
            return intel.lookup(tx.chainId, tx.to) == null &&
                (tx.tokenRecipient == null ||
                    intel.lookup(tx.chainId, tx.tokenRecipient!) == null);
          } on DappError {
            return false;
          }
        });
    if (hash == null || !RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(hash)) {
      throw const DappError(
          -32000, 'The wallet did not return a transaction hash.');
    }
    // Receipt tracking is independent: the existing singleton poller cancels
    // previous wallet operations, so do not take over its active session.
    unawaited(_trackReceipt(hash, tx, receive: prepared.receive));
    return hash;
  }

  Future<void> _trackReceipt(String hash, DappTransaction tx,
      {DappReceiveEvidence? receive}) async {
    void publish(TxStatus status) => TxRegistry.instance.push(TxStatusEvent(
        status: status,
        txHash: hash,
        walletAddress: tx.from,
        timestamp: DateTime.now(),
        operationLabel: 'dApp · ${tx.chainId}'));
    publish(TxStatus.submitted);
    for (var attempt = 0; attempt < 30; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      try {
        final receipt =
            await rpc.call(tx.chainId, 'eth_getTransactionReceipt', [hash]);
        if (receipt is Map &&
            receipt['transactionHash']?.toString().toLowerCase() ==
                hash.toLowerCase()) {
          final success = rpcQuantity(receipt['status']) == BigInt.one;
          if (!success) {
            publish(TxStatus.failed);
          } else if (receive == null || receive.confirmsReceipt(receipt, tx)) {
            publish(TxStatus.confirmed);
          } else {
            // Success of the EVM call alone does not prove the promised payout.
            publish(TxStatus.timeout);
          }
          return;
        }
      } catch (_) {/* Bounded retry of receipt reads only, never the write. */}
    }
    publish(TxStatus.timeout);
  }

  @override
  Future<String> signMessage(String hex, String expectedAccount,
      {required bool Function() isCurrent}) async {
    final signature = await IBITIVaultSigner.instance.signDappMessageHex(hex,
        expectedAddress: expectedAccount,
        canProceed: () =>
            isCurrent() && policyState.isActive);
    if (signature == null) {
      throw const DappError(-32000, 'Message signing failed.');
    }
    return signature;
  }

  @override
  Future<String> signTypedData(
      Map<String, dynamic> data, String expectedAccount,
      {required int chainId, required bool Function() isCurrent}) async {
    _checkTypedDataNow(data, chainId);
    final signature = await IBITIVaultSigner.instance
        .signTypedData(data, expectedAddress: expectedAccount, canProceed: () {
      if (!isCurrent()) return false;
      // Policy and threat data may change during Privy's getUser() await.
      try {
        _checkTypedDataNow(data, chainId);
        return true;
      } on DappError {
        return false;
      }
    });
    if (signature == null) {
      throw const DappError(-32000, 'Typed data signing failed.');
    }
    return signature;
  }

  @override
  Future<dynamic> readRpc(int chainId, String method, List<dynamic> params) =>
      rpc.call(chainId, method, params);
}

class _TxFacts {
  final TransactionRequest projection;
  final double? spendUsd;
  final bool unknownSpend;
  const _TxFacts(this.projection, this.spendUsd, this.unknownSpend);
}

class _PreparedDappTransaction {
  final DappGasPlan gas;
  final DappReceiveEvidence? receive;
  final DappTransactionConsent consent;
  const _PreparedDappTransaction(this.gas, this.receive, this.consent);
}

String _formatAtomic(BigInt amount, {int decimals = 18}) {
  if (decimals == 0) return amount.toString();
  final digits = amount.toString().padLeft(decimals + 1, '0');
  final fraction = digits
      .substring(digits.length - decimals)
      .replaceFirst(RegExp(r'0+$'), '');
  return '${digits.substring(0, digits.length - decimals)}${fraction.isEmpty ? '' : '.$fraction'}';
}
