import 'package:flutter/foundation.dart';
import 'dart:typed_data';

import 'package:ibiti_guardian/services/execution/clients/tron_rpc_client.dart';
import 'package:ibiti_guardian/services/swap/swap_provider.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

// ─── SunSwap V2 Constants ────────────────────────────────────────────────────

/// SunSwap V2 Router on Tron mainnet.
/// Source: github.com/sunswapteam/sunswap2.0-contracts
const String sunswapV2Router = 'TNJVzGqKBWkJxJB5XYSqGAwUTV15U24pPq';

/// WTRX (Wrapped TRX) TRC20 address on mainnet.
const String wtrxAddress = 'TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR';

/// USDT TRC20 contract on mainnet.
const String usdtTrc20 = 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t';

// ─── SunSwap V2 Swap Provider ─────────────────────────────────────────────────

/// SunSwap V2 provider for Tron token swaps.
///
/// Standard DEX flow:
///   1. `getAmountsOut` → quote preview (read-only)
///   2. Caller checks `allowance` → `approve` if needed (handled by execution layer)
///   3. `swapExactTRXForTokens` / `swapExactTokensForTRX` /
///      `swapExactTokensForTokens` → execute
///
/// Supports: TRX ↔ any TRC20, TRC20 ↔ TRC20 via WTRX intermediary.
class SunSwapProvider implements SwapProvider {
  SunSwapProvider._();
  static final SunSwapProvider instance = SunSwapProvider._();

  static const _log = GuardianLogger('SunSwapV2');
  static const int _deadlineOffsetSeconds = 600; // 10 minutes

  /// The TronGrid RPC URL used for on-chain quote calls.
  String _rpcUrl = 'https://api.trongrid.io';

  /// Allow overriding RPC URL for testing.
  // ignore: use_setters_to_change_properties
  void setRpcUrl(String url) => _rpcUrl = url;

  @override
  Future<QuoteResponse> getQuote(QuoteRequest request) async {
    final client = TronHttpRpcClient(baseUrl: _rpcUrl);

    // ── Resolve swap type and path ────────────────────────────────────
    final swapType = _resolveSwapType(
      request.sourceTokenAddress,
      request.targetTokenAddress,
    );

    final path = _buildPath(
      swapType,
      request.sourceTokenAddress,
      request.targetTokenAddress,
    );
    final amountIn = request.amount;

    // ── Call getAmountsOut on SunSwap V2 Router ────────────────────────
    final amountsOut =
        await _getAmountsOut(client, amountIn, path, request.userAddress);
    if (amountsOut.isEmpty) {
      throw RouteNotFoundException(
        'No SunSwap V2 route: ${_pathLabel(path)}',
      );
    }

    final expectedOut = amountsOut.last;
    if (expectedOut <= BigInt.zero) {
      throw IlliquidTokenException(
        'SunSwap V2: zero output for ${_pathLabel(path)}. '
        'Pool may be empty or no liquidity.',
      );
    }

    // ── Slippage ───────────────────────────────────────────────────────
    final clampedSlippageBps =
        request.slippageBps.clamp(0, SwapSlippagePolicy.maxBps);
    final minOutput = expectedOut *
        BigInt.from(10000 - clampedSlippageBps) ~/
        BigInt.from(10000);

    // ── Build calldata for execution ──────────────────────────────────
    final deadline = (DateTime.now().millisecondsSinceEpoch ~/ 1000) +
        _deadlineOffsetSeconds;

    // Only TRX→token doesn't need approval (native TRX is sent as callValue)
    final approvalNeeded = swapType != _SunSwapType.trxToToken;
    final sourceTokenForApprove =
        approvalNeeded ? request.sourceTokenAddress : '';

    // Build the ABI parameter for the swap function
    final swapParam = _buildSwapParameter(
      swapType: swapType,
      amountIn: amountIn,
      amountOutMin: minOutput,
      path: path,
      to: request.userAddress,
      deadline: BigInt.from(deadline),
    );

    final funcSelector = _swapFunctionSelector(swapType);
    final routeLabel =
        '${_tokenLabel(request.sourceTokenAddress, swapType == _SunSwapType.trxToToken)} → '
        '${_tokenLabel(request.targetTokenAddress, swapType == _SunSwapType.tokenToTrx)} '
        'via SunSwap V2';

    _log.d(
      'Quote: $routeLabel, '
      'in=$amountIn, out=$expectedOut, min=$minOutput, '
      'slippage=${clampedSlippageBps}bps, path=${path.length} hops',
    );

    return QuoteResponse(
      expectedOutputAmount: expectedOut,
      minOutputAmount: minOutput,
      routerAddress: sunswapV2Router,
      allowanceTarget: approvalNeeded ? sunswapV2Router : '',
      calldata:
          Uint8List.fromList(swapParam.codeUnits), // Store hex string as bytes
      nativeValue: swapType == _SunSwapType.trxToToken ? amountIn : BigInt.zero,
      priceImpactPct: 0.0, // SunSwap V2 doesn't return this directly
      gasEstimate: BigInt.from(TronHttpRpcClient.defaultSwapFeeLimit), // in sun
      approvalNeeded: approvalNeeded,
      providerName: 'SunSwap V2',
      quoteTimestamp: DateTime.now().toUtc(),
      routeSummary: routeLabel,
      extraSummary: {
        'swapType': swapType.name,
        'functionSelector': funcSelector,
        'parameter': swapParam,
        'path': path,
        'deadline': deadline,
        'sourceTokenForApprove': sourceTokenForApprove,
        'feeLimit': TronHttpRpcClient.defaultSwapFeeLimit,
      },
    );
  }

  // ── On-chain getAmountsOut ─────────────────────────────────────────────────

  /// Calls `getAmountsOut(uint256,address[])` on SunSwap V2 Router.
  /// Returns the output amounts for each step in the path.
  Future<List<BigInt>> _getAmountsOut(
    TronHttpRpcClient client,
    BigInt amountIn,
    List<String> path,
    String callerAddress,
  ) async {
    // ABI encode: getAmountsOut(uint256, address[])
    final amountHex = TronHttpRpcClient.abiEncodeUint256(amountIn);

    // Dynamic array: offset (0x40 = 64 bytes from start), then length + elements
    const offsetHex =
        '0000000000000000000000000000000000000000000000000000000000000040';
    final lengthHex =
        TronHttpRpcClient.abiEncodeUint256(BigInt.from(path.length));
    final addressesHex =
        path.map((addr) => TronHttpRpcClient.abiEncodeAddress(addr)).join();

    final parameter = '$amountHex$offsetHex$lengthHex$addressesHex';

    // Use caller address (or WTRX as fallback for read-only calls)
    final ownerAddr = callerAddress.isNotEmpty ? callerAddress : wtrxAddress;

    try {
      final results = await client.triggerConstantContractRaw(
        ownerAddress: ownerAddr,
        contractAddress: sunswapV2Router,
        functionSelector: 'getAmountsOut(uint256,address[])',
        parameter: parameter,
      );

      if (results.isEmpty) return [];

      // Parse the ABI-encoded uint256[] response
      return _decodeUint256Array(results.first);
    } catch (e) {
      _log.e('getAmountsOut failed for path ${_pathLabel(path)}', e);
      return [];
    }
  }

  /// Decodes an ABI-encoded `uint256[]` from a hex string.
  static List<BigInt> _decodeUint256Array(String hex) {
    // Response format: offset(32) + length(32) + N * uint256(32)
    if (hex.length < 128) return []; // At minimum: offset + length + 1 element

    // Skip the first 32 bytes (offset to array data)
    final lengthHex = hex.substring(64, 128);
    final length = BigInt.parse(lengthHex, radix: 16).toInt();

    final amounts = <BigInt>[];
    for (int i = 0; i < length; i++) {
      final start = 128 + i * 64;
      if (start + 64 > hex.length) break;
      final valueHex = hex.substring(start, start + 64);
      amounts.add(BigInt.parse(valueHex, radix: 16));
    }
    return amounts;
  }

  // ── Swap Type Resolution ──────────────────────────────────────────────────

  static _SunSwapType _resolveSwapType(String sourceAddr, String targetAddr) {
    final srcLower = sourceAddr.trim().toLowerCase();
    final dstLower = targetAddr.trim().toLowerCase();
    final srcIsNative =
        srcLower.isEmpty || srcLower == 'trx' || srcLower == 'native';
    final dstIsNative =
        dstLower.isEmpty || dstLower == 'trx' || dstLower == 'native';

    if (srcIsNative) return _SunSwapType.trxToToken;
    if (dstIsNative) return _SunSwapType.tokenToTrx;
    return _SunSwapType.tokenToToken;
  }

  /// Builds the swap path based on swap type and actual token addresses.
  ///
  /// - TRX→token: `[WTRX, targetToken]`
  /// - token→TRX: `[sourceToken, WTRX]`
  /// - token→token: `[sourceToken, WTRX, targetToken]` (via WTRX intermediary)
  static List<String> _buildPath(
    _SunSwapType type,
    String sourceAddr,
    String targetAddr,
  ) {
    switch (type) {
      case _SunSwapType.trxToToken:
        return [wtrxAddress, targetAddr];
      case _SunSwapType.tokenToTrx:
        return [sourceAddr, wtrxAddress];
      case _SunSwapType.tokenToToken:
        // Route via WTRX as intermediary (standard Uniswap V2 pattern)
        return [sourceAddr, wtrxAddress, targetAddr];
    }
  }

  static String _swapFunctionSelector(_SunSwapType type) {
    switch (type) {
      case _SunSwapType.trxToToken:
        return 'swapExactTRXForTokens(uint256,address[],address,uint256)';
      case _SunSwapType.tokenToTrx:
        return 'swapExactTokensForTRX(uint256,uint256,address[],address,uint256)';
      case _SunSwapType.tokenToToken:
        return 'swapExactTokensForTokens(uint256,uint256,address[],address,uint256)';
    }
  }

  static String _tokenLabel(String addr, bool isNative) {
    if (isNative) return 'TRX';
    if (addr == usdtTrc20) return 'USDT';
    if (addr == wtrxAddress) return 'WTRX';
    if (addr.length > 8)
      return '${addr.substring(0, 4)}...${addr.substring(addr.length - 4)}';
    return addr;
  }

  static String _pathLabel(List<String> path) {
    return path.map((a) {
      if (a == wtrxAddress) return 'WTRX';
      if (a == usdtTrc20) return 'USDT';
      if (a.length > 8)
        return '${a.substring(0, 4)}..${a.substring(a.length - 4)}';
      return a;
    }).join(' → ');
  }

  // ── ABI Parameter Building ────────────────────────────────────────────────

  /// Builds the ABI parameter hex string for the swap call.
  static String _buildSwapParameter({
    required _SunSwapType swapType,
    required BigInt amountIn,
    required BigInt amountOutMin,
    required List<String> path,
    required String to,
    required BigInt deadline,
  }) {
    final toHex = TronHttpRpcClient.abiEncodeAddress(to);
    final deadlineHex = TronHttpRpcClient.abiEncodeUint256(deadline);
    final amountOutMinHex = TronHttpRpcClient.abiEncodeUint256(amountOutMin);

    final lengthHex =
        TronHttpRpcClient.abiEncodeUint256(BigInt.from(path.length));
    final addressesHex =
        path.map((a) => TronHttpRpcClient.abiEncodeAddress(a)).join();

    switch (swapType) {
      case _SunSwapType.trxToToken:
        // swapExactTRXForTokens(uint256 amountOutMin, address[] path, address to, uint256 deadline)
        // 4 fixed-size params before the dynamic array data:
        //   amountOutMin (slot 0), path_offset (slot 1), to (slot 2), deadline (slot 3)
        //   path_offset = 4 * 32 bytes = 128 = 0x80
        const pathOffset =
            '0000000000000000000000000000000000000000000000000000000000000080';
        return '$amountOutMinHex$pathOffset$toHex$deadlineHex$lengthHex$addressesHex';

      case _SunSwapType.tokenToTrx:
      case _SunSwapType.tokenToToken:
        // swapExactTokensFor{TRX|Tokens}(uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline)
        // 5 fixed-size params:
        //   amountIn (slot 0), amountOutMin (slot 1), path_offset (slot 2), to (slot 3), deadline (slot 4)
        //   path_offset = 5 * 32 bytes = 160 = 0xA0
        final amountInHex = TronHttpRpcClient.abiEncodeUint256(amountIn);
        const pathOffset =
            '00000000000000000000000000000000000000000000000000000000000000a0';
        return '$amountInHex$amountOutMinHex$pathOffset$toHex$deadlineHex$lengthHex$addressesHex';
    }
  }
}

// ── Internal enum ────────────────────────────────────────────────────────────

enum _SunSwapType {
  trxToToken,
  tokenToTrx,
  tokenToToken,
}
