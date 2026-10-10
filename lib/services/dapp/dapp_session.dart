import 'dart:convert';
import 'dapp_permissions.dart';
import 'dapp_protocol.dart';

abstract class DappWalletBackend {
  String get account;
  bool get available;
  Set<int> get supportedChains;
  Future<void> checkSigningAllowed(int chainId);
  Future<DappApproval> prepareTransaction(String origin, DappTransaction tx);
  void confirmTransaction(DappTransaction tx, DappApproval shown);
  void discardTransaction(DappTransaction tx);
  Future<void> checkTypedData(Map<String, dynamic> data, int chainId);
  Future<String> sendTransaction(DappTransaction tx,
      {required bool Function() isCurrent});
  Future<String> signMessage(String hex, String expectedAccount,
      {required bool Function() isCurrent});
  Future<String> signTypedData(
      Map<String, dynamic> data, String expectedAccount,
      {required int chainId, required bool Function() isCurrent});
  Future<dynamic> readRpc(int chainId, String method, List<dynamic> params);
}

/// A browser document owns a session. Every navigation cancels pending consent.
class DappSession {
  final DappWalletBackend wallet;
  final DappPermissions permissions;
  final Future<bool> Function(DappApproval) approve;
  final Future<bool> Function() authenticate;
  String? _origin;
  int chainId;
  int _generation = 0;
  bool _busy = false;
  bool _closed = false;
  int _reads = 0;
  DappSession(
      {required this.wallet,
      required this.permissions,
      required this.approve,
      required this.authenticate,
      this.chainId = 56});

  void navigate(String? url) {
    _generation++;
    _origin = url == null ? null : DappOrigin.canonical(url);
  }

  void close() {
    _closed = true;
    _generation++;
    _origin = null;
  }

  void invalidate() {
    _generation++;
  }

  Future<dynamic> handle(DappRpcRequest request,
      {required String sourceOrigin, required bool isMainFrame}) async {
    if (_closed ||
        !isMainFrame ||
        _origin == null ||
        DappOrigin.canonical(sourceOrigin) != _origin) {
      throw const DappError(4100, 'This document is not authorized.');
    }
    final generation = _generation;
    final origin = _origin!;
    final account = wallet.account;
    bool stillCurrent() =>
        !_closed &&
        generation == _generation &&
        _origin == origin &&
        wallet.available &&
        wallet.account.toLowerCase() == account.toLowerCase();
    void checkCurrent() {
      if (_closed ||
          generation != _generation ||
          _origin != origin ||
          wallet.account.toLowerCase() != account.toLowerCase()) {
        throw const DappError(4001, 'The wallet request is no longer active.');
      }
    }

    Future<bool> authorized() async {
      final result = wallet.available && await permissions.has(origin, account);
      checkCurrent();
      return result;
    }

    final params = request.params;
    switch (request.method) {
      case 'eth_chainId':
        return hexQuantity(BigInt.from(chainId));
      case 'net_version':
        return '$chainId';
      case 'web3_clientVersion':
        return 'IBITI Guardian';
      case 'eth_accounts':
        return await authorized() ? [account] : <String>[];
      case 'wallet_getPermissions':
        return await authorized()
            ? [
                {'parentCapability': 'eth_accounts'}
              ]
            : <dynamic>[];
      case 'wallet_revokePermissions':
        if (params.length != 1 ||
            params.first is! Map ||
            (params.first as Map).keys.any((k) => k != 'eth_accounts')) {
          throw const DappError(-32602, 'Invalid permission request.');
        }
        await permissions.revoke(origin);
        checkCurrent();
        // Also cancel an approval that is awaiting the Privy SDK. Its final
        // synchronous guard must fail even after the last permission read.
        invalidate();
        return null;
    }
    const reads = {
      'eth_call',
      'eth_estimateGas',
      'eth_getBalance',
      'eth_getCode',
      'eth_blockNumber',
      'eth_gasPrice',
      'eth_getTransactionReceipt',
      'eth_getTransactionByHash',
      'eth_getTransactionCount',
      'eth_getBlockByNumber',
      'eth_getLogs',
      'eth_feeHistory',
      'eth_maxPriorityFeePerGas'
    };
    if (reads.contains(request.method)) {
      if (_reads >= 8) {
        throw const DappError(-32005, 'Too many pending RPC reads.');
      }
      _reads++;
      try {
        final result = await wallet.readRpc(chainId, request.method, params);
        checkCurrent();
        return result;
      } finally {
        _reads--;
      }
    }
    const interactive = {
      'eth_requestAccounts',
      'wallet_requestPermissions',
      'wallet_switchEthereumChain',
      'wallet_addEthereumChain',
      'personal_sign',
      'eth_signTypedData_v4',
      'eth_sendTransaction'
    };
    if (!interactive.contains(request.method)) {
      throw const DappError(4200, 'Wallet method is not supported.');
    }
    if (_busy) {
      throw const DappError(-32002, 'A wallet approval is already pending.');
    }
    _busy = true;
    DappTransaction? tx;
    try {
      if (!wallet.available || !isEvmAddress(account)) {
        throw const DappError(4900, 'Unlock your Guardian EVM wallet first.');
      }
      if (request.method == 'eth_requestAccounts' ||
          request.method == 'wallet_requestPermissions') {
        if (request.method == 'eth_requestAccounts' && params.isNotEmpty ||
            request.method == 'wallet_requestPermissions' &&
                (params.length != 1 ||
                    params.first is! Map ||
                    (params.first as Map).keys.length != 1 ||
                    !(params.first as Map).containsKey('eth_accounts'))) {
          throw const DappError(-32602, 'Invalid account permission request.');
        }
        if (!await authorized()) {
          final accepted = await approve(DappApproval(
              origin: origin,
              method: 'connect',
              account: account,
              chainId: chainId,
              content: account));
          checkCurrent();
          if (!accepted) throw const DappError(4001, 'Connection rejected.');
          await permissions.grant(origin, account);
          checkCurrent();
        }
        return request.method == 'eth_requestAccounts'
            ? [account]
            : [
                {'parentCapability': 'eth_accounts'}
              ];
      }
      if (!await authorized()) {
        throw const DappError(4100, 'Connect this website first.');
      }
      if (request.method == 'wallet_switchEthereumChain' ||
          request.method == 'wallet_addEthereumChain') {
        if (params.length != 1 || params.first is! Map) {
          throw const DappError(-32602, 'Invalid network request.');
        }
        final desired = rpcQuantity((params.first as Map)['chainId']);
        if (!wallet.supportedChains.contains(desired.toInt())) {
          throw const DappError(
              4902, 'This network is not supported by Guardian.');
        }
        final nextChain = desired.toInt();
        if (request.method == 'wallet_addEthereumChain') return null;
        if (nextChain != chainId) {
          final accepted = await approve(DappApproval(
              origin: origin,
              method: 'switchChain',
              account: account,
              chainId: nextChain,
              content: '$nextChain'));
          checkCurrent();
          if (!accepted) {
            throw const DappError(4001, 'Network change rejected.');
          }
          chainId = nextChain;
        }
        return null;
      }
      await wallet.checkSigningAllowed(chainId);
      checkCurrent();
      DappApproval preview;
      Map<String, dynamic>? typed;
      String? messageHex;
      if (request.method == 'eth_sendTransaction') {
        if (params.length != 1) {
          throw const DappError(-32602, 'Expected one transaction.');
        }
        tx = DappTransaction.parse(params.first, account, chainId);
        preview = await wallet.prepareTransaction(origin, tx);
        checkCurrent();
      } else if (request.method == 'personal_sign') {
        if (params.length != 2 ||
            params[1] is! String ||
            (params[1] as String).toLowerCase() != account.toLowerCase()) {
          throw const DappError(4100, 'Signature account is not authorized.');
        }
        messageHex = rpcBytes(params.first, maxBytes: 16384);
        final bytes = [
          for (var i = 2; i < messageHex.length; i += 2)
            int.parse(messageHex.substring(i, i + 2), radix: 16)
        ];
        String message;
        try {
          message = utf8.decode(bytes);
        } catch (_) {
          throw const DappError(
              4200, 'Opaque binary messages cannot be signed.');
        }
        if (message.trim().isEmpty ||
            RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\u202a-\u202e\u2066-\u2069]')
                .hasMatch(message)) {
          throw const DappError(
              -32602, 'Message contains hidden control characters.');
        }
        // SIWE origin binding: a login request cannot impersonate another site.
        const siwe = ' wants you to sign in with your Ethereum account:';
        if (message.contains(siwe)) {
          final lines = message.split('\n');
          final domain = lines.first.split(siwe).first;
          final messageAccount = lines.length > 2 ? lines[2].trim() : '';
          final uriLine =
              lines.where((line) => line.startsWith('URI: ')).firstOrNull;
          final chainLine =
              lines.where((line) => line.startsWith('Chain ID: ')).firstOrNull;
          if (!lines.first.endsWith(siwe) ||
              domain != Uri.parse(origin).authority ||
              messageAccount.toLowerCase() != account.toLowerCase() ||
              uriLine == null ||
              DappOrigin.canonical(uriLine.substring(5)) != origin ||
              chainLine != 'Chain ID: $chainId') {
            throw const DappError(
                4100, 'Sign-in message does not match this website/account.');
          }
        }
        preview = DappApproval(
            origin: origin,
            method: request.method,
            account: account,
            chainId: chainId,
            content: message,
            warnings: const ['messageAuthorization']);
      } else {
        if (params.length != 2 ||
            params.first is! String ||
            (params.first as String).toLowerCase() != account.toLowerCase()) {
          throw const DappError(4100, 'Signature account is not authorized.');
        }
        typed = validateTypedData(params[1], account, chainId);
        await wallet.checkTypedData(typed, chainId);
        checkCurrent();
        preview = DappApproval(
            origin: origin,
            method: request.method,
            account: account,
            chainId: chainId,
            content: const JsonEncoder.withIndent('  ').convert(typed),
            warnings: const ['typedAuthorization']);
      }
      final accepted = await approve(preview);
      checkCurrent();
      if (!accepted) throw const DappError(4001, 'Signature rejected.');
      final authenticated = await authenticate();
      checkCurrent();
      if (!authenticated) {
        throw const DappError(4001, 'Authentication cancelled.');
      }
      // Policy is checked again after the approval/authentication awaits.
      await wallet.checkSigningAllowed(chainId);
      checkCurrent();
      if (!await authorized()) {
        throw const DappError(4100, 'Website permission was revoked.');
      }
      if (tx != null) {
        await wallet.prepareTransaction(origin, tx);
        checkCurrent();
        wallet.confirmTransaction(tx, preview);
        return await wallet.sendTransaction(tx, isCurrent: stillCurrent);
      }
      if (typed != null) {
        await wallet.checkTypedData(typed, chainId);
        checkCurrent();
        return await wallet.signTypedData(typed, account,
            chainId: chainId, isCurrent: stillCurrent);
      }
      return await wallet.signMessage(messageHex!, account,
          isCurrent: stillCurrent);
    } finally {
      if (tx != null) wallet.discardTransaction(tx);
      _busy = false;
    }
  }
}
