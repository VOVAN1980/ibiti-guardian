import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/models/approval.dart';
import 'package:ibiti_guardian/services/security/approval_scan_service.dart';
import 'package:ibiti_guardian/services/transaction_queue.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';

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
    if (state.index < GuardianFlowState.readyNoAction.index) return null;

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
  GuardianFlowModel model = const GuardianFlowModel(
    mode: GuardianMode.safe,
    state: GuardianFlowState.idle,
  );

  StreamSubscription<RevokeProgress>? _progressSub;

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

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  Future<void> open(GuardianMode mode) async {
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

      // Delay for UX to show the "Scanning" screen (matches UI 800ms step)
      await Future.delayed(const Duration(milliseconds: 800));

      model = model.copyWith(
        state: GuardianFlowState.analyzing,
        all: approvals,
        scannedCount: approvals.length,
      );
      notifyListeners();

      // Delay for analysis UX (matches UI 800ms step)
      await Future.delayed(const Duration(milliseconds: 800));

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

  void confirmAction() {
    if (model.state != GuardianFlowState.readyReview) return;
    if (model.mode == GuardianMode.safe && model.selected.isEmpty) return;
    if (model.mode == GuardianMode.panic && model.critical.isEmpty) return;

    model = model.copyWith(state: GuardianFlowState.queuePrepared);
    notifyListeners();

    _startQueue();
  }

  void _startQueue() {
    if (model.state != GuardianFlowState.queuePrepared) return;

    // Transition directly to waitingWallet/executing pattern
    model = model.copyWith(state: GuardianFlowState.executing);
    notifyListeners();

    final queue =
        model.mode == GuardianMode.safe ? model.selected : model.critical;

    TransactionQueue().clear();
    TransactionQueue().addJobs(queue);

    _progressSub?.cancel();
    _progressSub = TransactionQueue().progressStream.listen((p) {
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

      if (p.completed == p.total && p.total > 0) {
        Future.delayed(const Duration(milliseconds: 600), () {
          model = model.copyWith(state: GuardianFlowState.completed);
          notifyListeners();
        });
      }
    });

    try {
      TransactionQueue().run();
    } catch (e) {
      model = model.copyWith(
          state: GuardianFlowState.failed,
          error: 'Failed to start transaction queue: $e');
      notifyListeners();
    }
  }
}
