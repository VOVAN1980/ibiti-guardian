import 'package:flutter/material.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';

// ────────────────────────────────────────────────────────────────────────────
// WalletAdapter — единственный источник правды о текущем кошельке.
//
// АРХИТЕКТУРА:
//   Источник адреса: IBITIVaultService (нативный IBITI Vault).
//   WcService заморожен — не используется как основной источник.
//   Все сервисы читают address/chainId только отсюда.
// ────────────────────────────────────────────────────────────────────────────
class WalletAdapter extends ChangeNotifier {
  static final WalletAdapter instance = WalletAdapter._internal();
  factory WalletAdapter() => instance;

  WalletAdapter._internal() {
    IBITIVaultService.instance.addListener(_onVaultUpdate);
  }

  void _onVaultUpdate() {
    notifyListeners();
  }

  // ── Public API (те же геттеры, что были — для обратной совместимости) ──────

  bool get isConnected => IBITIVaultService.instance.isVaultCreated;
  bool get isReady => IBITIVaultService.instance.isVaultCreated;
  String get address => IBITIVaultService.instance.address;
  String get chainKey => IBITIVaultService.instance.chainKey;

  /// Returns the EVM chain ID for the current active network.
  /// Throws [StateError] if the current network is not EVM (Solana/Tron)
  /// — callers must handle non-EVM paths before reaching this getter.
  int get chainId {
    final chain = PrivyChainRegistry.getChain(chainKey);
    final id = chain.evmChainId;
    if (id == null) {
      throw StateError(
        'WalletAdapter.chainId called on non-EVM chain "$chainKey". '
        'Use chain-specific signing for ${chain.displayName}.',
      );
    }
    return id;
  }

  String get walletName => 'IBITI Vault';

  // ── Vault-specific ─────────────────────────────────────────────────────────

  bool get isUnlocked => IBITIVaultService.instance.isUnlocked;
  String? get policyId => IBITIVaultService.instance.policyId;

  /// Native token balance in Wei for the current wallet address.
  ///
  /// Returns null if the balance has not been loaded yet (e.g. before portfolio sync).
  /// The swap gas check in [GuardianExecutionController] skips this gate when null,
  /// ensuring no false blocks during startup.
  BigInt? get nativeBalance => IBITIVaultService.instance.nativeBalanceAtomic;

  @override
  void dispose() {
    IBITIVaultService.instance.removeListener(_onVaultUpdate);
    super.dispose();
  }
}
