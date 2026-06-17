import 'dart:async';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/models/approval.dart';
import 'package:ibiti_guardian/models/gas_estimation_result.dart';
import 'package:ibiti_guardian/services/revoke_service.dart';
import 'package:ibiti_guardian/services/security/security_event_service.dart';
import 'package:ibiti_guardian/models/security_event.dart';

enum RevokeJobStatus { pending, waitingWallet, submitted, confirmed, failed }

class RevokeJob {
  final ApprovalData approval;
  RevokeJobStatus status;
  String? error;
  String? txHash;

  RevokeJob({
    required this.approval,
    this.status = RevokeJobStatus.pending,
    this.error,
    this.txHash,
  });
}

class RevokeProgress {
  final int total;
  final int completed;
  final int successCount;
  final int failedCount;
  final RevokeJob? currentJob;

  RevokeProgress({
    required this.total,
    required this.completed,
    required this.successCount,
    required this.failedCount,
    this.currentJob,
  });

  double get percent => total == 0 ? 0 : completed / total;
}

class TransactionQueue {
  static final TransactionQueue _instance = TransactionQueue._internal();
  factory TransactionQueue() => _instance;
  TransactionQueue._internal();

  static const _log = GuardianLogger('TransactionQueue');

  final List<RevokeJob> _jobs = [];
  bool _isRunning = false;
  bool _cancelRequested = false;

  final _progressController = StreamController<RevokeProgress>.broadcast();
  Stream<RevokeProgress> get progressStream => _progressController.stream;

  bool get isRunning => _isRunning;
  int get totalJobs => _jobs.length;
  List<RevokeJob> get currentJobs => List.unmodifiable(_jobs);

  void addJobs(List<ApprovalData> approvals) {
    for (var a in approvals) {
      _jobs.add(RevokeJob(approval: a));
    }
    _notify();
  }

  void clear() {
    if (_isRunning) return;
    _jobs.clear();
    _notify();
  }

  /// Request cancellation of the running queue.
  /// The queue will stop after the current job completes.
  void requestCancel() {
    if (_isRunning) {
      _cancelRequested = true;
      _log.w('Cancel requested — will stop after current job');
    }
  }

  Future<void> run({bool emitEvents = true}) async {
    if (_isRunning || _jobs.isEmpty) return;
    _isRunning = true;
    _cancelRequested = false;

    int successCount = 0;
    int failedCount = 0;
    int completed = 0;

    // We process only pending jobs
    while (true) {
      // Check for user-requested cancellation
      if (_cancelRequested) {
        _log.d('Queue cancelled by user');
        break;
      }

      RevokeJob? job;
      try {
        job = _jobs.firstWhere((j) => j.status == RevokeJobStatus.pending);
      } catch (e) {
        break; // No more pending jobs
      }

      job.status = RevokeJobStatus.waitingWallet;
      _notifyProgress(completed, successCount, failedCount, job);

      try {
        final txHash = await RevokeService.revokeApproval(a: job.approval);
        job.txHash = txHash;
        job.status = RevokeJobStatus.submitted;
        successCount++;

        // Emit security event for timeline (FREE & PRO)
        if (emitEvents) {
          SecurityEventService.instance.emit(
            SecurityEvent(
              type: SecurityEventType.revokeCompleted,
              severity: 'low',
              timestamp: DateTime.now(),
              walletAddress: job.approval.walletAddress,
              title: 'Revoke Successful',
              message:
                  'Permission revoked for ${job.approval.tokenSymbol} on ${job.approval.spender}',
              metadata: {
                'token': job.approval.token,
                'spender': job.approval.spenderAddress,
                'chainId': job.approval.chainId,
                'txHash': txHash,
              },
            ),
          );
        }
      } catch (e) {
        job.error = e.toString();
        job.status = RevokeJobStatus.failed;
        failedCount++;
      }

      completed++;
      _notifyProgress(completed, successCount, failedCount, job);

      // Add a small delay between requests to avoid spamming the wallet or hitting rate limits
      await Future.delayed(const Duration(milliseconds: 600));
    }

    _isRunning = false;
    _cancelRequested = false;
    _notifyProgress(completed, successCount, failedCount, null);
  }

  void _notifyProgress(
    int completed,
    int success,
    int failed,
    RevokeJob? current,
  ) {
    _progressController.add(
      RevokeProgress(
        total: _jobs.length,
        completed: completed,
        successCount: success,
        failedCount: failed,
        currentJob: current,
      ),
    );
  }

  void _notify() {
    _notifyProgress(
      _jobs.where((j) => j.status != RevokeJobStatus.pending).length,
      _jobs
          .where(
            (j) =>
                j.status == RevokeJobStatus.submitted ||
                j.status == RevokeJobStatus.confirmed,
          )
          .length,
      _jobs.where((j) => j.status == RevokeJobStatus.failed).length,
      null,
    );
  }

  /// Estimates total gas for a list of approvals
  Future<GasEstimationResult?> estimateTotalGas(
    List<ApprovalData> approvals,
  ) async {
    if (approvals.isEmpty) return null;

    BigInt totalGas = BigInt.zero;
    BigInt maxGasPrice = BigInt.zero;
    int successCount = 0;

    for (var a in approvals) {
      try {
        final estimate = await RevokeService.estimateGas(a: a);
        totalGas += estimate.estimatedGas;
        if (estimate.estimatedGasPrice > maxGasPrice) {
          maxGasPrice = estimate.estimatedGasPrice;
        }
        successCount++;
      } catch (e) {
        // Ignore failures for individual estimates to not break the flow
        _log.e('Failed to estimate gas for ${a.token}', e);
      }
    }

    if (successCount == 0) return null;

    return GasEstimationResult(
      estimatedGas: totalGas,
      estimatedGasPrice: maxGasPrice,
    );
  }
}
