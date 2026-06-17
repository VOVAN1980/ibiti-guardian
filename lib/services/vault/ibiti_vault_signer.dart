import 'dart:convert';

import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/execution/native_transaction_builder.dart';
import 'package:ibiti_guardian/services/policy/validators/composite_validator.dart';
import 'package:ibiti_guardian/services/vault/epk_contract_resolver.dart';
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:privy_flutter/privy_flutter.dart';
import 'package:web3dart/web3dart.dart';
// ignore: depend_on_referenced_packages
import 'package:wallet/wallet.dart';

class IBITIVaultSigner {
  static final IBITIVaultSigner instance = IBITIVaultSigner._internal();
  IBITIVaultSigner._internal();

  static const _log = GuardianLogger('VaultSigner');

  static const Duration _epkDeadlineWindow = Duration(minutes: 10);

  Future<String?> signTypedData(Map<String, dynamic> typedData) async {
    final user = await IBITIVaultService.instance.getPrivyUser();
    if (user == null || user.embeddedEthereumWallets.isEmpty) {
      _log.w('No embedded ethereum wallet available');
      return null;
    }

    final wallet =
        IBITIVaultService.instance.resolveEmbeddedEthereumWallet(user);
    if (wallet == null) return null;

    try {
      final request = EthereumRpcRequest(
        method: 'eth_signTypedData_v4',
        params: [wallet.address, jsonEncode(typedData)],
      );

      final result = await wallet.provider.request(request);

      String? signature;
      result.fold(
        onSuccess: (response) {
          signature = response.data;
          _log.d('TypedData signed');
        },
        onFailure: (error) {
          _log.e('signTypedData failed', error.message);
        },
      );

      return signature;
    } catch (e) {
      _log.e('Error signing typed data', e);
      return null;
    }
  }

  Future<String?> signMessage(String message) async {
    final user = await IBITIVaultService.instance.getPrivyUser();
    if (user == null || user.embeddedEthereumWallets.isEmpty) {
      _log.w('No embedded ethereum wallet available');
      return null;
    }

    final wallet =
        IBITIVaultService.instance.resolveEmbeddedEthereumWallet(user);
    if (wallet == null) return null;

    try {
      final hexMsg =
          '0x${message.codeUnits.map((e) => e.toRadixString(16).padLeft(2, '0')).join()}';

      final request = EthereumRpcRequest(
        method: 'personal_sign',
        params: [hexMsg, wallet.address],
      );

      final result = await wallet.provider.request(request);

      String? signature;
      result.fold(
        onSuccess: (response) {
          signature = response.data;
        },
        onFailure: (error) {
          _log.e('personal_sign failed', error.message);
        },
      );

      return signature;
    } catch (e) {
      _log.e('Error signing message', e);
      return null;
    }
  }

  Future<String?> sendTransaction({
    required Map<String, dynamic> txParams,
    TransactionRequest? txContext,
  }) async {
    if (txContext != null) {
      final state = EPKPolicyManager.instance.state;
      if (state.isActive) {
        final composite = CompositeValidator();
        final epkResult = await composite.validate(txContext, state);
        if (!epkResult.isValid) {
          final reason = epkResult.userMessage ??
              epkResult.rejectionReason ??
              'EPK policy blocked this transaction.';
          _log.w('EPK block: $reason');
          throw EPKValidationException(reason);
        }
      }
    }

    final hash = await _sendRawTransaction(txParams, txContext: txContext);

    if (hash != null && txContext != null) {
      await EPKPolicyManager.instance.recordSuccessfulExecution(
        txContext.typeLabel,
        txContext.amount ?? 0.0,
      );
      _log.d('Tx sent. action=${txContext.typeLabel}');
    }

    return hash;
  }

  Future<String?> executeEPKTransaction({
    required TransactionRequest txContext,
    required String epkAddress,
    required BigInt policyId,
    required String target,
    required BigInt value,
    required Uint8List data,
  }) async {
    try {
      final configuredKernel =
          EpkContractResolver.instance.kernelAddressForChain(txContext.chainId);
      if (configuredKernel == null ||
          configuredKernel.toLowerCase() != epkAddress.toLowerCase()) {
        throw const EPKValidationException(
          'On-chain EPK kernel is not configured for this network.',
        );
      }

      final state = EPKPolicyManager.instance.state;
      if (state.isActive) {
        final composite = CompositeValidator();
        final validationResult = await composite.validate(txContext, state);
        if (!validationResult.isValid) {
          final reason = validationResult.userMessage ??
              validationResult.rejectionReason ??
              'EPK policy blocked this transaction.';
          throw EPKValidationException(reason);
        }
      }

      final abiString =
          await rootBundle.loadString('assets/abi/EPKernel.abi.json');
      final contractAbi = ContractAbi.fromJson(abiString, 'EPKernel');
      final contract =
          DeployedContract(contractAbi, EthereumAddress.fromHex(epkAddress));
      final executeFunction = contract.function('execute');

      final nonce = await _loadPolicyNonce(
        contract: contract,
        policyId: policyId,
        chainId: txContext.chainId,
      );
      if (nonce == null) {
        throw const EPKValidationException(
          'Could not load the current EPK policy nonce.',
        );
      }

      final deadline = BigInt.from(
        DateTime.now().add(_epkDeadlineWindow).millisecondsSinceEpoch ~/ 1000,
      );

      final typedData = _buildExecuteTypedData(
        chainId: txContext.chainId,
        epkAddress: epkAddress,
        policyId: policyId,
        target: target,
        value: value,
        data: data,
        nonce: nonce,
        deadline: deadline,
      );

      final signatureHex = await signTypedData(typedData);
      if (signatureHex == null || signatureHex.isEmpty) {
        throw const EPKValidationException(
          'EPK authorization signature was rejected.',
        );
      }

      final transactionData = executeFunction.encodeCall([
        policyId,
        EthereumAddress.fromHex(target),
        value,
        data,
        deadline,
        hexToBytes(signatureHex),
      ]);

      final hash = await _sendRawTransaction(
        {
          'from': IBITIVaultService.instance.activeAddress,
          'to': epkAddress,
          'data': bytesToHex(transactionData,
              include0x: true, padToEvenLength: true),
          'value': _toHex(value),
        },
        txContext: txContext,
      );

      if (hash != null) {
        await EPKPolicyManager.instance.recordSuccessfulExecution(
          txContext.typeLabel,
          txContext.amount ?? 0.0,
        );
      }

      return hash;
    } on EPKValidationException {
      rethrow;
    } catch (e) {
      _log.e('executeEPKTransaction failed', e);
      return null;
    }
  }

  Future<String?> _sendRawTransaction(
    Map<String, dynamic> txParams, {
    TransactionRequest? txContext,
  }) async {
    final user = await IBITIVaultService.instance.getPrivyUser();
    if (user == null) {
      _log.e('sendRawTransaction aborted: Privy user is null.');
      return null;
    }
    if (user.embeddedEthereumWallets.isEmpty) {
      _log.e('sendRawTransaction aborted: Privy user has no embedded Ethereum wallets.');
      return null;
    }

    final wallet =
        IBITIVaultService.instance.resolveEmbeddedEthereumWallet(user);
    if (wallet == null) {
      _log.e('sendRawTransaction aborted: resolveEmbeddedEthereumWallet returned null.');
      return null;
    }

    try {
      // Privy SDK expects tx params as a JSON-encoded String, not a raw Map.
      // See: privy_flutter example — EthereumRpcRequest.ethSendTransaction(jsonEncode(txPayload))
      // Privy also requires 'chainId' in the payload (hex string).
      // Prefer txContext.chainId (swap/approve knows its own chain) over
      // the global WalletAdapter which may lag behind or differ.
      if (!txParams.containsKey('chainId')) {
        final int cid;
        final String source;
        if (txContext != null) {
          cid = txContext.chainId;
          source = 'txContext';
        } else {
          try {
            cid = WalletAdapter.instance.chainId;
            source = 'walletAdapter(fallback)';
          } on StateError {
            throw const EPKValidationException(
              'Cannot execute EVM transaction on a non-EVM network. '
              'Switch to an EVM chain (BSC, Ethereum, Polygon, etc.).',
            );
          }
        }
        txParams['chainId'] = '0x${cid.toRadixString(16)}';
        _log.d(
            'chainId injected: $cid (0x${cid.toRadixString(16)}) via $source');
      }
      final txJson = jsonEncode(txParams);
      _log.d('eth_sendTransaction → to=${txParams['to']} '
          'chain=${txParams['chainId']} '
          'dataLen=${(txParams['data']?.toString() ?? '').length}');
      final request = EthereumRpcRequest.ethSendTransaction(txJson);

      final result = await wallet.provider.request(request);

      String? hash;
      result.fold(
        onSuccess: (response) {
          hash = response.data;
          _log.d('eth_sendTransaction success');
        },
        onFailure: (error) {
          _log.e('sendTransaction failed', error.message);
        },
      );

      return hash;
    } catch (e) {
      _log.e('Error sending tx', e);
      return null;
    }
  }

  Future<BigInt?> _loadPolicyNonce({
    required DeployedContract contract,
    required BigInt policyId,
    required int chainId,
  }) async {
    final rpcUrl = PrivyChainRegistry.getEvmChain(chainId)?.rpcUrl;
    if (rpcUrl == null || rpcUrl.isEmpty) return null;

    final client = Web3Client(rpcUrl, http.Client());
    try {
      final result = await client.call(
        contract: contract,
        function: contract.function('nonces'),
        params: [policyId],
      );
      if (result.isEmpty) return null;
      final nonce = result.first;
      if (nonce is BigInt) return nonce;
      if (nonce is int) return BigInt.from(nonce);
      return null;
    } finally {
      client.dispose();
    }
  }

  Map<String, dynamic> _buildExecuteTypedData({
    required int chainId,
    required String epkAddress,
    required BigInt policyId,
    required String target,
    required BigInt value,
    required Uint8List data,
    required BigInt nonce,
    required BigInt deadline,
  }) {
    final dataHash =
        bytesToHex(keccak256(data), include0x: true, padToEvenLength: true);

    return {
      'types': {
        'EIP712Domain': [
          {'name': 'name', 'type': 'string'},
          {'name': 'version', 'type': 'string'},
          {'name': 'chainId', 'type': 'uint256'},
          {'name': 'verifyingContract', 'type': 'address'},
        ],
        'Execute': [
          {'name': 'policyId', 'type': 'uint256'},
          {'name': 'target', 'type': 'address'},
          {'name': 'value', 'type': 'uint256'},
          {'name': 'dataHash', 'type': 'bytes32'},
          {'name': 'nonce', 'type': 'uint256'},
          {'name': 'deadline', 'type': 'uint256'},
        ],
      },
      'primaryType': 'Execute',
      'domain': {
        'name': 'Eternal Permission Kernel',
        'version': '1',
        'chainId': chainId,
        'verifyingContract': epkAddress,
      },
      'message': {
        'policyId': policyId.toString(),
        'target': target,
        'value': value.toString(),
        'dataHash': dataHash,
        'nonce': nonce.toString(),
        'deadline': deadline.toString(),
      },
    };
  }

  String _toHex(BigInt value) =>
      value == BigInt.zero ? '0x0' : '0x${value.toRadixString(16)}';
}
