import 'dart:async';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web3dart/web3dart.dart';
import 'package:ibiti_guardian/models/tx_status.dart';
import 'package:ibiti_guardian/services/execution/tx_registry.dart';

/// Polls [eth_getTransactionReceipt] until a transaction is confirmed,
/// failed, or the timeout is reached.
///
/// One singleton instance manages the active polling session.
/// Starting a new session automatically cancels the previous one.
///
/// Usage:
/// ```dart
/// TxStatusPoller.instance.start(
///   txHash: hash,
///   chainId: 56,
///   onStatus: (event) { /* update UI */ },
/// );
/// ```
class TxStatusPoller {
  TxStatusPoller._();
  static final instance = TxStatusPoller._();

  static const _log = GuardianLogger('TxPoller');

  static const _pollInterval = Duration(seconds: 1);
  static const _maxAttempts = 60; // 60 × 1 s = 60 s max

  // SharedPreferences keys for restart recovery.
  static const _kPendingHash = 'txpoller_pending_hash';
  static const _kPendingChainId = 'txpoller_pending_chain_id';

  Timer? _timer;
  Web3Client? _client;
  int _attempts = 0;
  TxStatus? _lastEmittedStatus; // guard against duplicate pending spam

  /// Start polling for [txHash] on [chainId].
  ///
  /// [onStatus] is called on every state change, including the initial
  /// [TxStatus.submitted] event which fires immediately.
  ///
  /// Start polling for [txHash] on [chainId].
  ///
  /// [operationLabel] is shown in the status card and recent history,
  /// e.g. "Swapping USDT → ETH" or "Sending BNB".
  ///
  /// [assetLabel] is passed to [TxStatusEvent.voicePhrase] for the
  /// voice readout on confirmation (e.g. "0.45 ETH").
  void start({
    required String txHash,
    required int chainId,
    required void Function(TxStatusEvent) onStatus,
    String? assetLabel,
    String? operationLabel,
    String? walletAddress,
  }) {
    // Cancel any in-flight session
    _cancel();

    _attempts = 0;
    _lastEmittedStatus = null;

    // Spin up a fresh Web3Client for this chain
    _client = Web3Client(_rpcUrl(chainId), http.Client());

    final submittedEvent = TxStatusEvent(
      status: TxStatus.submitted,
      txHash: txHash,
      walletAddress: walletAddress,
      timestamp: DateTime.now(),
      operationLabel: operationLabel,
      assetLabel: assetLabel,
    );
    TxRegistry.instance.push(submittedEvent);
    onStatus(submittedEvent);

    // Persist for restart recovery.
    _persistPending(txHash, chainId);

    _timer = Timer.periodic(_pollInterval, (_) async {
      try {
        await _poll(
          txHash: txHash,
          onStatus: onStatus,
          assetLabel: assetLabel,
          operationLabel: operationLabel,
          walletAddress: walletAddress,
        );
      } catch (e) {
        // Catch-all: if _poll somehow throws past its own catch,
        // dispose client to prevent socket/fd leak.
        _log.e('poll callback unexpected error — disposing client', e);
        _cancel();
      }
    });
  }

  /// Stop any active polling session.
  void stop() => _cancel();

  /// Resume polling for a tx that was in-flight when the app was killed.
  /// Call once during app startup. If no pending tx exists, this is a no-op.
  Future<void> resumeIfPending({
    required void Function(TxStatusEvent) onStatus,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final hash = prefs.getString(_kPendingHash);
    final chainId = prefs.getInt(_kPendingChainId);
    if (hash == null || chainId == null) return;

    _log.d('Resuming pending tx: $hash on chain $chainId');
    start(
      txHash: hash,
      chainId: chainId,
      onStatus: onStatus,
      operationLabel: 'Resumed transaction',
    );
  }

  // ── Private ──────────────────────────────────────────────────────────────────

  Future<void> _poll({
    required String txHash,
    required void Function(TxStatusEvent) onStatus,
    String? assetLabel,
    String? operationLabel,
    String? walletAddress,
  }) async {
    _attempts++;

    if (_attempts > _maxAttempts) {
      _cancel();
      _clearPending();
      final e = TxStatusEvent(
        status: TxStatus.timeout,
        txHash: txHash,
        walletAddress: walletAddress,
        errorReason: 'No confirmation after 60 seconds.',
        timestamp: DateTime.now(),
        operationLabel: operationLabel,
        assetLabel: assetLabel,
      );
      TxRegistry.instance.push(e);
      onStatus(e);
      return;
    }

    try {
      final receipt = await _client!.getTransactionReceipt(txHash);

      if (receipt == null) {
        // Still pending — emit only once to avoid UI spam on every tick
        if (_lastEmittedStatus != TxStatus.pending) {
          _lastEmittedStatus = TxStatus.pending;
          final e = TxStatusEvent(
            status: TxStatus.pending,
            txHash: txHash,
            walletAddress: walletAddress,
            timestamp: DateTime.now(),
            operationLabel: operationLabel,
            assetLabel: assetLabel,
          );
          TxRegistry.instance.push(e);
          onStatus(e);
        }
        return;
      }

      // Terminal — stop polling
      _cancel();
      _clearPending();

      final success = receipt.status ?? false;
      if (success) {
        final e = TxStatusEvent(
          status: TxStatus.confirmed,
          txHash: txHash,
          walletAddress: walletAddress,
          blockNumber: receipt.blockNumber.blockNum,
          timestamp: DateTime.now(),
          operationLabel: operationLabel,
          assetLabel: assetLabel,
        );
        TxRegistry.instance.push(e);
        onStatus(e);
      } else {
        final e = TxStatusEvent(
          status: TxStatus.failed,
          txHash: txHash,
          walletAddress: walletAddress,
          blockNumber: receipt.blockNumber.blockNum,
          errorReason: 'Transaction reverted on-chain.',
          timestamp: DateTime.now(),
          operationLabel: operationLabel,
          assetLabel: assetLabel,
        );
        TxRegistry.instance.push(e);
        onStatus(e);
      }
    } catch (e) {
      // Network hiccup — keep polling, don't surface to user
      _log.w('poll error (attempt $_attempts): $e');
    }
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    try {
      _client?.dispose();
    } catch (e) {
      _log.d('client dispose: $e');
    }
    _client = null;
  }

  void _persistPending(String txHash, int chainId) {
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString(_kPendingHash, txHash);
      prefs.setInt(_kPendingChainId, chainId);
    });
  }

  void _clearPending() {
    SharedPreferences.getInstance().then((prefs) {
      prefs.remove(_kPendingHash);
      prefs.remove(_kPendingChainId);
    });
  }

  String _rpcUrl(int chainId) {
    switch (chainId) {
      case 1:
        return 'https://eth.llamarpc.com';
      case 137:
        return 'https://polygon-rpc.com';
      case 42161:
        return 'https://arb1.arbitrum.io/rpc';
      case 10:
        return 'https://mainnet.optimism.io';
      case 8453:
        return 'https://mainnet.base.org';
      case 56:
      default:
        return 'https://bsc-dataseed.binance.org/';
    }
  }
}
