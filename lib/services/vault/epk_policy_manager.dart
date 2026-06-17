import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/services/policy/epk_capability_resolver.dart';
import 'package:ibiti_guardian/services/vault/epk_contract_resolver.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';

enum EPKExecutionMode { local, guarded, onChainEpk, fallback }

class EpkState {
  final bool isActive;
  final bool isDeployed;
  final String chain;
  final String? policyId;
  final EPKExecutionMode executionMode;

  // Validators
  final bool hasSpendLimitValidator;
  final bool hasTargetSelectorGuard;
  final bool hasThreatFeedBlocklistValidator;
  final bool hasCompositeValidator;

  // Policies
  final double perTxLimit;
  final double dailyLimit;

  // Agent
  final String? agentAddress;
  final String agentScope;
  final DateTime? agentExpiry;

  // Meta
  final String lastAction;
  final String lastBlock;
  final int panicEventsCount;

  // Local Enforcement Tracking
  final double spentTodayUsd;
  final String? lastSpendResetDate;

  const EpkState({
    this.isActive = true,
    this.isDeployed = false,
    this.chain = 'BSC Mainnet',
    this.policyId,
    this.executionMode = EPKExecutionMode.local,
    this.hasSpendLimitValidator = true,
    this.hasTargetSelectorGuard = true,
    this.hasThreatFeedBlocklistValidator = true,
    this.hasCompositeValidator = false,
    this.perTxLimit = 100.0,
    this.dailyLimit = 500.0,
    this.agentAddress,
    this.agentScope = 'Level 2 Guarded',
    this.agentExpiry,
    this.lastAction = 'None',
    this.lastBlock = 'Loading...',
    this.panicEventsCount = 0,
    this.spentTodayUsd = 0.0,
    this.lastSpendResetDate,
  });

  EpkState copyWith({
    bool? isActive,
    bool? isDeployed,
    String? chain,
    String? policyId,
    EPKExecutionMode? executionMode,
    bool? hasSpendLimitValidator,
    bool? hasTargetSelectorGuard,
    bool? hasThreatFeedBlocklistValidator,
    bool? hasCompositeValidator,
    double? perTxLimit,
    double? dailyLimit,
    String? agentAddress,
    String? agentScope,
    DateTime? agentExpiry,
    String? lastAction,
    String? lastBlock,
    int? panicEventsCount,
    double? spentTodayUsd,
    String? lastSpendResetDate,
  }) {
    return EpkState(
      isActive: isActive ?? this.isActive,
      isDeployed: isDeployed ?? this.isDeployed,
      chain: chain ?? this.chain,
      policyId: policyId ?? this.policyId,
      executionMode: executionMode ?? this.executionMode,
      hasSpendLimitValidator:
          hasSpendLimitValidator ?? this.hasSpendLimitValidator,
      hasTargetSelectorGuard:
          hasTargetSelectorGuard ?? this.hasTargetSelectorGuard,
      hasThreatFeedBlocklistValidator: hasThreatFeedBlocklistValidator ??
          this.hasThreatFeedBlocklistValidator,
      hasCompositeValidator:
          hasCompositeValidator ?? this.hasCompositeValidator,
      perTxLimit: perTxLimit ?? this.perTxLimit,
      dailyLimit: dailyLimit ?? this.dailyLimit,
      agentAddress: agentAddress ?? this.agentAddress,
      agentScope: agentScope ?? this.agentScope,
      agentExpiry: agentExpiry ?? this.agentExpiry,
      lastAction: lastAction ?? this.lastAction,
      lastBlock: lastBlock ?? this.lastBlock,
      panicEventsCount: panicEventsCount ?? this.panicEventsCount,
      spentTodayUsd: spentTodayUsd ?? this.spentTodayUsd,
      lastSpendResetDate: lastSpendResetDate ?? this.lastSpendResetDate,
    );
  }
}

class EPKPolicyManager extends ChangeNotifier {
  static final EPKPolicyManager instance = EPKPolicyManager._internal();
  EPKPolicyManager._internal() {
    IBITIVaultService.instance.addListener(_handleVaultChanged);
  }

  static const _log = GuardianLogger('EPKPolicy');

  EpkState _state = const EpkState();
  EpkState get state => _state;
  String _lastVaultFingerprint = '';

  Future<void> init() async {
    _lastVaultFingerprint = _vaultFingerprint();
    await refreshPolicy();
  }

  void _handleVaultChanged() {
    final nextFingerprint = _vaultFingerprint();
    if (nextFingerprint == _lastVaultFingerprint) return;

    _lastVaultFingerprint = nextFingerprint;
    EpkCapabilityResolver.instance.invalidateCache();
    unawaited(refreshPolicy());
  }

  String _vaultFingerprint() {
    final vault = IBITIVaultService.instance;
    return '${vault.activeAddress}|${vault.chainKey}|${vault.policyId ?? ''}';
  }

  /// Creates a new policy and associates it with the current vault address.
  Future<bool> createPolicy({double dailyLimitUsd = 1000.0}) async {
    final vaultAddress = IBITIVaultService.instance.activeAddress;
    if (vaultAddress.isEmpty) return false;

    final chainId =
        PrivyChainRegistry.getChain(IBITIVaultService.instance.chainKey)
            .evmChainId;
    final reason = chainId == null
        ? 'Current chain is not EVM.'
        : EpkContractResolver.instance.missingReason(
            chainId: chainId,
            rawPolicyId: IBITIVaultService.instance.policyId,
          );

    if (reason != null) {
      _log.w('createPolicy refused: $reason');
      return false;
    }

    _state = _state.copyWith(
      policyId: IBITIVaultService.instance.policyId,
      dailyLimit: dailyLimitUsd,
      isDeployed: true,
      executionMode: EPKExecutionMode.onChainEpk,
    );
    notifyListeners();
    return true;
  }

  /// Refreshes policy details from the EPKernel contract.
  Future<void> refreshPolicy() async {
    final vault = IBITIVaultService.instance;
    final policyId = IBITIVaultService.instance.policyId;
    final chain = PrivyChainRegistry.getChain(vault.chainKey);
    final chainId = chain.evmChainId;
    final isReady = chainId != null &&
        EpkContractResolver.instance.isReady(
          chainId: chainId,
          rawPolicyId: policyId,
        );
    final kernel = chainId == null
        ? null
        : EpkContractResolver.instance.kernelAddressForChain(chainId);

    _state = _state.copyWith(
      policyId: policyId,
      isActive: vault.isVaultCreated && _state.isActive,
      isDeployed: isReady,
      executionMode:
          isReady ? EPKExecutionMode.onChainEpk : EPKExecutionMode.local,
      chain: chain.displayName,
      agentExpiry: DateTime.now().add(const Duration(hours: 18)),
      lastBlock: kernel == null
          ? 'Kernel not configured'
          : 'Kernel ${kernel.substring(0, 8)}...',
    );
    notifyListeners();
  }

  Future<void> emergencyPause() async {
    // Send tx to pause EPK
    _state = _state.copyWith(isActive: false, lastAction: 'EMERGENCY_PAUSE');
    notifyListeners();
  }

  Future<void> resumeProtection() async {
    _state = _state.copyWith(
      isActive: true,
      lastAction: 'EPK_RESUMED',
      executionMode: _state.isDeployed
          ? EPKExecutionMode.onChainEpk
          : EPKExecutionMode.local,
    );
    notifyListeners();
  }

  Future<void> revokeAgent() async {
    // Send tx to clear agent permissions map
    _state = _state.copyWith(
        agentAddress: null, agentScope: 'Revoked', lastAction: 'AGENT_REVOKED');
    notifyListeners();
  }

  void updateLimits({double? perTx, double? daily}) {
    final nextPerTx = perTx ?? _state.perTxLimit;
    final nextDaily = daily ?? _state.dailyLimit;
    if (nextPerTx == _state.perTxLimit && nextDaily == _state.dailyLimit) {
      return;
    }

    _state = _state.copyWith(
      perTxLimit: nextPerTx,
      dailyLimit: nextDaily,
    );
    notifyListeners();
  }

  Future<void> recordSuccessfulExecution(
      String action, double amountUsdSpent) async {
    final now = DateTime.now();
    final dateStr = '${now.year}-${now.month}-${now.day}';

    double newSpent = _state.spentTodayUsd;
    if (_state.lastSpendResetDate != dateStr) {
      newSpent = amountUsdSpent;
    } else {
      newSpent += amountUsdSpent;
    }

    _state = _state.copyWith(
      lastAction: action,
      spentTodayUsd: newSpent,
      lastSpendResetDate: dateStr,
      lastBlock: 'Pending/Local',
    );
    notifyListeners();
  }
}
