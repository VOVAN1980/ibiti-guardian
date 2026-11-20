import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/models/approval.dart';
import 'package:ibiti_guardian/services/security/approval_scan_service.dart';
import 'package:ibiti_guardian/services/transaction_queue.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';
import 'package:ibiti_guardian/services/security/system_status_service.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

enum GuardianMode {
  safe,
  panic,
}

enum GuardianFlowState {
  idle,
  scanning,
  analyzing,
  readyNoAction,
  readyReview,
  queuePrepared,
  waitingWallet,
  executing,
  completed,
  failed,
}

enum GuardianScenario {
  safeNoRisk,
  safeReview,
  panicNoCritical,
  panicEmergency,
}

class GuardianFlowModel {
  final GuardianMode mode;
  final GuardianFlowState state;

  // Number of active token/spender approvals returned by the completed scan,
  // not a unique contract count or a count of RPC requests.
  final int scannedCount;
  final int criticalCount;
  final int warningCount;
  final int safeCount;

  final List<ApprovalData> all;
  final List<ApprovalData> critical;
  final List<ApprovalData> warnings;
  final List<ApprovalData> safe;
  final List<ApprovalData> selected;

  final RevokeProgress? progress;
  final String? message;
  final String? error;

  const GuardianFlowModel({
    required this.mode,
    required this.state,
    this.scannedCount = 0,
    this.criticalCount = 0,
    this.warningCount = 0,
    this.safeCount = 0,
    this.all = const [],
    this.critical = const [],
    this.warnings = const [],
    this.safe = const [],
    this.selected = const [],
    this.progress,
    this.message,
    this.error,
  });

  GuardianScenario? get scenario {
    // A failed read has no risk assessment, even if all counts default to zero.
    if (state == GuardianFlowState.failed ||
        state.index < GuardianFlowState.readyNoAction.index) {
      return null;
    }

    if (mode == GuardianMode.safe) {
      return (criticalCount + warningCount) == 0
          ? GuardianScenario.safeNoRisk
          : GuardianScenario.safeReview;
    } else {
      return criticalCount == 0
          ? GuardianScenario.panicNoCritical
          : GuardianScenario.panicEmergency;
    }
  }

  bool get hasActionableItems => selected.isNotEmpty;

  bool get isTerminal =>
      state == GuardianFlowState.completed ||
      state == GuardianFlowState.failed ||
      state == GuardianFlowState.readyNoAction;

  bool get showPrimaryCta =>
      state == GuardianFlowState.readyReview ||
      state == GuardianFlowState.readyNoAction ||
      state == GuardianFlowState.completed ||
      state == GuardianFlowState.failed;

  GuardianFlowModel copyWith({
    GuardianMode? mode,
    GuardianFlowState? state,
    int? scannedCount,
    int? criticalCount,
    int? warningCount,
    int? safeCount,
    List<ApprovalData>? all,
    List<ApprovalData>? critical,
    List<ApprovalData>? warnings,
    List<ApprovalData>? safe,
    List<ApprovalData>? selected,
    RevokeProgress? progress,
    String? message,
    String? error,
  }) {
    return GuardianFlowModel(
      mode: mode ?? this.mode,
      state: state ?? this.state,
      scannedCount: scannedCount ?? this.scannedCount,
      criticalCount: criticalCount ?? this.criticalCount,
      warningCount: warningCount ?? this.warningCount,
      safeCount: safeCount ?? this.safeCount,
      all: all ?? this.all,
      critical: critical ?? this.critical,
      warnings: warnings ?? this.warnings,
      safe: safe ?? this.safe,
      selected: selected ?? this.selected,
      progress: progress ?? this.progress,
      message: message ?? this.message,
      error: error ?? this.error,
    );
  }
}

class GuardianFlowController extends ChangeNotifier {
  static const _log = GuardianLogger('GuardianFlow');

  GuardianFlowModel model = const GuardianFlowModel(
    mode: GuardianMode.safe,
    state: GuardianFlowState.idle,
  );

  StreamSubscription<RevokeProgress>? _progressSub;
  int _scanGeneration = 0;
  bool _disposed = false;

  /// Called once when the queue started by [confirmAction] has an answer for
  /// every job (submitted or failed).
  void Function(RevokeProgress result)? _onFinished;

  /// Called on every progress event of the queue started by [confirmAction]
  /// until it finishes (an AI-gated revoke keeps the AI lock alive with it).
  void Function(RevokeProgress progress)? _onProgress;

  /// The jobs [confirmAction] put into the [TransactionQueue] singleton.
  List<RevokeJob> _startedJobs = const [];

  /// A queue started by [confirmAction] has not finished yet. The queue
  /// lives in the [TransactionQueue] singleton and keeps revoking when the
  /// window closes, so the controller keeps listening until it finishes
  /// (see [dispose]).
  bool _queueActive = false;

  /// The jobs the last [confirmAction] started (empty before).
  List<RevokeJob> get startedJobs => List.unmodifiable(_startedJobs);

  /// A queue started by [confirmAction] is still revoking.
  bool get isQueueActive => _queueActive;

  bool isCritical(ApprovalData a) {
    final isUnlimited = a.allowance > BigInt.from(1000000000);
    return a.assessment.shouldRevoke ||
        a.riskLevel == RiskLevel.danger ||
        (isUnlimited && !a.isKnownDex);
  }

  bool isWarning(ApprovalData a) {
    return !isCritical(a) &&
        (a.riskLevel == RiskLevel.warning ||
            a.reputation == SpenderReputation.unknown ||
            a.reputation == SpenderReputation.suspicious);
  }

  bool isSafe(ApprovalData a) {
    return !isCritical(a) && !isWarning(a);
  }

  String _key(ApprovalData a) => '${a.spenderAddress}-${a.token}';

  /// Tells the wallet's System status card what is left after a revoke:
  /// the risky approvals of this scan minus the ones just revoked. (A rescan
  /// right away could still list them while the indexers catch up.)
  void _recordAfterRevoke() {
    String key(ApprovalData a) =>
        '${a.chainId}|${a.token.toLowerCase()}|${a.spenderAddress.toLowerCase()}';
    final revoked = {
      for (final j in [..._startedJobs, ...TransactionQueue().currentJobs])
        if (j.status == RevokeJobStatus.submitted ||
            j.status == RevokeJobStatus.confirmed)
          key(j.approval),
    };
    final left = model.all
        .where((a) => a.assessment.shouldRevoke && !revoked.contains(key(a)))
        .length;
    // The scanned wallet and network: the window may be closed and the
    // wallet or network switched before the queue finishes.
    final scanned =
        _startedJobs.isNotEmpty ? _startedJobs.first.approval : null;
    final owner = scanned?.walletAddress;
    final String walletAddress;
    final int chainId;
    if (scanned != null && owner != null && owner.isNotEmpty) {
      walletAddress = owner;
      chainId = scanned.chainId;
    } else {
      final wallet = WalletAdapter.instance;
      walletAddress = wallet.address;
      chainId = wallet.chainId; // StateError off EVM: caught by the caller.
    }
    unawaited(
        SystemStatusService.instance.recordScan(walletAddress, chainId, left));
  }

  /// Closing the window (Back, «закрой», a route reset) does not stop a
  /// running revoke queue: it keeps revoking in the [TransactionQueue]
  /// singleton. So the controller keeps listening until that queue finishes
  /// — the System status card is updated and [confirmAction]'s
  /// `onFinished` (the AI report: audit + «ИИ выполнил», releasing the AI
  /// lock) still runs — but stops touching the model.
  @override
  void dispose() {
    _disposed = true;
    _scanGeneration++;
    if (!_queueActive) {
      _progressSub?.cancel();
      _progressSub = null;
      _onFinished = null;
      _onProgress = null;
    }
    super.dispose();
  }

  Future<void> open(GuardianMode mode) async {
    if (_disposed ||
        model.state == GuardianFlowState.scanning ||
        model.state == GuardianFlowState.analyzing) {
      return;
    }
    final generation = ++_scanGeneration;
    bool isCurrentScan() => !_disposed && generation == _scanGeneration;
    final wallet = WalletAdapter.instance;
    if (!wallet.isConnected) {
      model = GuardianFlowModel(
          mode: mode,
          state: GuardianFlowState.failed,
          error: 'Wallet not connected');
      notifyListeners();
      return;
    }

    model = GuardianFlowModel(mode: mode, state: GuardianFlowState.scanning);
    notifyListeners();

    try {
      // Simulate real-world scanning progression if desired, or just scan
      final approvals = await ApprovalScanService.scan(wallet.address,
          chainId: wallet.chainId);
      if (!isCurrentScan()) return;

      // Delay for UX to show the "Scanning" screen (matches UI 800ms step)
      await Future.delayed(const Duration(milliseconds: 800));
      if (!isCurrentScan()) return;

      model = model.copyWith(
        state: GuardianFlowState.analyzing,
        all: approvals,
        scannedCount: approvals.length,
      );
      notifyListeners();

      // Delay for analysis UX (matches UI 800ms step)
      await Future.delayed(const Duration(milliseconds: 800));
      if (!isCurrentScan()) return;

      final critical = approvals.where(isCritical).toList();
      final warnings = approvals.where(isWarning).toList();
      final safe = approvals.where(isSafe).toList();

      if (mode == GuardianMode.safe) {
        final hasRisk = critical.isNotEmpty || warnings.isNotEmpty;
        model = model.copyWith(
          state: hasRisk
              ? GuardianFlowState.readyReview
              : GuardianFlowState.readyNoAction,
          critical: critical,
          warnings: warnings,
          safe: safe,
          selected: [...critical, ...warnings],
          criticalCount: critical.length,
          warningCount: warnings.length,
          safeCount: safe.length,
        );
      } else {
        final hasCritical = critical.isNotEmpty;
        model = model.copyWith(
          state: hasCritical
              ? GuardianFlowState.readyReview
              : GuardianFlowState.readyNoAction,
          critical: critical,
          warnings: warnings,
          safe: safe,
          selected: [...critical],
          criticalCount: critical.length,
          warningCount: warnings.length,
          safeCount: safe.length,
        );
      }
      notifyListeners();
    } catch (e) {
      if (!isCurrentScan()) return;
      model =
          model.copyWith(state: GuardianFlowState.failed, error: e.toString());
      notifyListeners();
    }
  }

  void toggleSelection(ApprovalData item) {
    if (model.state != GuardianFlowState.readyReview ||
        model.mode != GuardianMode.safe) {
      return;
    }

    final k = _key(item);
    final selectedKeys = model.selected.map((a) => _key(a)).toSet();

    if (selectedKeys.contains(k)) {
      final newSelected = model.selected.where((a) => _key(a) != k).toList();
      model = model.copyWith(selected: newSelected);
    } else {
      model = model.copyWith(selected: [...model.selected, item]);
    }
    notifyListeners();
  }

  /// Starts revoking the reviewed approvals. [onProgress] runs on every
  /// progress event until the queue finishes; [onFinished] runs once, when
  /// every job of the queue has an answer (an AI-opened window reports the
  /// result to AiActionGate with it). Both still run after [dispose]: the
  /// queue does not stop when the window closes. Returns false when nothing
  /// started (not in review, or nothing to revoke).
  bool confirmAction({
    void Function(RevokeProgress result)? onFinished,
    void Function(RevokeProgress progress)? onProgress,
  }) {
    if (_disposed) return false;
    if (model.state != GuardianFlowState.readyReview) return false;
    if (model.mode == GuardianMode.safe && model.selected.isEmpty) {
      return false;
    }
    if (model.mode == GuardianMode.panic && model.critical.isEmpty) {
      return false;
    }

    _onFinished = onFinished;
    _onProgress = onProgress;
    model = model.copyWith(state: GuardianFlowState.queuePrepared);
    notifyListeners();

    _startQueue();
    return true;
  }

  void _finish(RevokeProgress result) {
    final callback = _onFinished;
    _onFinished = null;
    _onProgress = null;
    _queueActive = false;
    if (_disposed) {
      // Nobody shows this queue any more: stop listening.
      _progressSub?.cancel();
      _progressSub = null;
    }
    callback?.call(result);
  }

  /// Every job this controller started has an answer (submitted / failed).
  bool get _startedJobsAnswered => _startedJobs.every((j) =>
      j.status == RevokeJobStatus.submitted ||
      j.status == RevokeJobStatus.confirmed ||
      j.status == RevokeJobStatus.failed);

  void _startQueue() {
    if (model.state != GuardianFlowState.queuePrepared) return;

    // Transition directly to waitingWallet/executing pattern
    model = model.copyWith(state: GuardianFlowState.executing);
    notifyListeners();

    final queue =
        model.mode == GuardianMode.safe ? model.selected : model.critical;

    final transactions = TransactionQueue();
    transactions.clear();
    // clear() keeps the jobs of a queue that is still running; ours are
    // appended after them and that run picks them up.
    final before = transactions.totalJobs;
    transactions.addJobs(queue);
    _startedJobs = transactions.currentJobs.sublist(before);
    _queueActive = true;

    _progressSub?.cancel();
    _progressSub = transactions.progressStream.listen((p) {
      if (!_queueActive) return;
      if (!_disposed) {
        // Update state if waiting for wallet vs executing
        if (p.currentJob?.status == RevokeJobStatus.waitingWallet) {
          if (model.state != GuardianFlowState.waitingWallet) {
            model = model.copyWith(
                state: GuardianFlowState.waitingWallet, progress: p);
            notifyListeners();
          } else {
            model = model.copyWith(progress: p);
            notifyListeners();
          }
        } else {
          if (model.state != GuardianFlowState.executing) {
            model =
                model.copyWith(state: GuardianFlowState.executing, progress: p);
            notifyListeners();
          } else {
            model = model.copyWith(progress: p);
            notifyListeners();
          }
        }
      }

      // Done: every job of ours has an answer, or the queue stopped before
      // reaching them (the run's last event, with no current job).
      final stopped = p.currentJob == null && !transactions.isRunning;
      if (_startedJobsAnswered || stopped) {
        try {
          _recordAfterRevoke();
        } catch (e) {
          // The status card is a convenience; the report must still run.
          _log.w('System status after revoke not recorded: $e');
        }
        _finish(p);
        Future.delayed(const Duration(milliseconds: 600), () {
          if (_disposed) return;
          model = model.copyWith(state: GuardianFlowState.completed);
          notifyListeners();
        });
        return;
      }
      _onProgress?.call(p);
    });

    try {
      unawaited(transactions.run());
    } catch (e) {
      model = model.copyWith(
          state: GuardianFlowState.failed,
          error: 'Failed to start transaction queue: $e');
      notifyListeners();
      _finish(RevokeProgress(
        total: queue.length,
        completed: 0,
        successCount: 0,
        failedCount: queue.length,
      ));
    }
  }
}
