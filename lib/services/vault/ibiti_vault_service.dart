import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:privy_flutter/privy_flutter.dart';
import 'package:ibiti_guardian/services/vault/privy_config_service.dart';
import 'package:ibiti_guardian/utils/tron_utils.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/services/wallet/wallet_settings_service.dart';
import 'package:ibiti_guardian/services/execution/clients/solana_rpc_client.dart';
import 'package:ibiti_guardian/services/execution/clients/tron_rpc_client.dart';
import 'package:web3dart/web3dart.dart';
// ignore: depend_on_referenced_packages
import 'package:wallet/wallet.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'dart:math';

// ──────────────────────────────────────────────────────────────────────────────
// VaultState — полное состояние IBITI Vault в памяти
// SecureStorage хранит ТОЛЬКО метаданные, НЕ приватный ключ.
// Приватный ключ никогда не покидает enklav Privy.
// ──────────────────────────────────────────────────────────────────────────────
class VaultState {
  final String walletId;
  final bool isUnlocked;
  final String? policyId;
  final String chainKey;
  final bool biometricsEnabled;
  final bool pinEnabled;
  final bool passkeyEnabled;
  final String primaryUnlockMethod;

  const VaultState({
    required this.walletId,
    required this.isUnlocked,
    this.policyId,
    this.chainKey = 'bsc', // BSC default
    this.biometricsEnabled = false,
    this.pinEnabled = false,
    this.passkeyEnabled = false,
    this.primaryUnlockMethod = 'none',
  });

  VaultState copyWith({
    String? walletId,
    bool? isUnlocked,
    String? policyId,
    String? chainKey,
    bool? biometricsEnabled,
    bool? pinEnabled,
    bool? passkeyEnabled,
    String? primaryUnlockMethod,
  }) {
    return VaultState(
      walletId: walletId ?? this.walletId,
      isUnlocked: isUnlocked ?? this.isUnlocked,
      policyId: policyId ?? this.policyId,
      chainKey: chainKey ?? this.chainKey,
      biometricsEnabled: biometricsEnabled ?? this.biometricsEnabled,
      pinEnabled: pinEnabled ?? this.pinEnabled,
      passkeyEnabled: passkeyEnabled ?? this.passkeyEnabled,
      primaryUnlockMethod: primaryUnlockMethod ?? this.primaryUnlockMethod,
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// IBITIVaultService — главный сервис жизненного цикла IBITI Vault.
// ──────────────────────────────────────────────────────────────────────────────
String _mask(String value) {
  if (value.isEmpty) return '<empty>';
  if (value.length <= 10) return value;
  return '${value.substring(0, 8)}...${value.substring(value.length - 6)}';
}

class IBITIVaultService extends ChangeNotifier {
  static final IBITIVaultService instance = IBITIVaultService._internal();
  IBITIVaultService._internal();

  static const _log = GuardianLogger('Vault');

  // ── SecureStorage keys ──────────────────────────────────────────────────────
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _kWalletId = 'vault_wallet_id';
  static const _kPolicyId = 'vault_policy_id';
  static const _kChainId = 'vault_chain_id'; // Legacy key, mapped on load
  static const _kChainKey = 'vault_chain_key';

  static const _kEvmAddress = 'vault_evm_address';
  static const _kEvmCardAddresses = 'vault_evm_card_addresses';
  static const _kSolanaAddress = 'vault_solana_address';
  static const _kTronAddress = 'vault_tron_address';

  static const _kBiometrics = 'vault_biometrics_enabled';
  static const _kPinEnabled = 'vault_pin_enabled';
  static const _kPinHash = 'vault_pin_hash';
  static const _kPinSalt = 'vault_pin_salt';
  static const _kPinAttempts = 'vault_pin_attempts';
  static const _kPinLockedUntil = 'vault_pin_locked_until';
  static const _kPasskeyEnabled = 'vault_passkey_enabled';
  static const _kPrimaryUnlockMethod = 'vault_primary_unlock_method';

  // Privy SDK
  Privy? _privy;
  bool _privyInitialized = false;

  // ── State ───────────────────────────────────────────────────────────────────
  VaultState? _state;
  VaultState? get state => _state;

  String? _evmAddress;
  String? _solanaAddress;
  String? _tronAddress;
  List<String> _evmCardAddresses = [];

  bool _walletsBootstrapped = false;

  // Vault is considered created once the main (EVM) wallet exists.
  // Solana/Tron addresses may be provisioned lazily on first chain switch.
  bool get isVaultCreated =>
      _state != null && (_evmAddress?.isNotEmpty ?? false);
  bool get isUnlocked => _state?.isUnlocked ?? false;

  String? get evmAddress => _evmAddress;
  List<String> get evmCardAddresses => List.unmodifiable(_evmCardAddresses);
  String? get solanaAddress => _solanaAddress;
  String? get tronAddress => _tronAddress;
  int get maxEvmCards => 4;
  bool get canCreateAdditionalEvmCard => _evmCardAddresses.length < maxEvmCards;

  String get chainKey => _state?.chainKey ?? 'bsc';

  String get activeAddress {
    switch (chainKey) {
      case 'solana':
        return _solanaAddress ?? '';
      case 'tron':
        return _tronAddress ?? '';
      default:
        return _evmAddress ?? '';
    }
  }

  // Backward compatibility alias for UI
  String get address => activeAddress;

  /// Returns wallet address for a specific chain without mutating global state.
  String addressForChain(String key) {
    switch (key) {
      case 'solana':
        return _solanaAddress ?? '';
      case 'tron':
        return _tronAddress ?? '';
      default:
        return _evmAddress ?? '';
    }
  }

  String? get policyId => _state?.policyId;
  bool get pinEnabled => _state?.pinEnabled ?? false;
  String get primaryUnlockMethod => _state?.primaryUnlockMethod ?? 'none';
  DateTime? get pinLockedUntil => _pinLockedUntilCache;

  BigInt? get nativeBalanceAtomic => _nativeBalanceAtomic;
  BigInt? _nativeBalanceAtomic;

  void cacheNativeBalanceAtomic(BigInt value) {
    _nativeBalanceAtomic = value;
    notifyListeners();
  }

  void setVaultCreatedForTest({
    required String evmAddress,
    String? solanaAddress,
    String? tronAddress,
    List<String>? evmCardAddresses,
  }) {
    _evmAddress = evmAddress;
    _solanaAddress = solanaAddress;
    _tronAddress = tronAddress;
    _evmCardAddresses = evmCardAddresses ?? [];
    _state = VaultState(
      walletId: 'test_wallet_id',
      isUnlocked: true,
      chainKey: 'bsc',
    );
  }

  // ── Web3 RPC client (read-only, for EVM checks) ─────────────────────────
  Web3Client? _web3;

  // ────────────────────────────────────────────────────────────────────────────
  // INIT
  // ────────────────────────────────────────────────────────────────────────────

  Future<void> init() async {
    try {
      _initPrivy();
      await _loadFromStorage();
      await _syncWithPrivySession();
      await _loadPinLockState(); // Восстанавливаем persistent ban при старте
    } catch (e) {
      _log.e('init error', e);
    }
  }

  void _initPrivy() {
    if (_privyInitialized) return;

    final configSvc = PrivyConfigService.instance;
    if (!configSvc.isValid) {
      _log.w('Privy SDK config missing or invalid in secrets/privy.json');
    }

    final config = PrivyConfig(
      appId: configSvc.appId.isEmpty ? 'invalid_app_id' : configSvc.appId,
      appClientId:
          configSvc.clientId.isEmpty ? 'invalid_client_id' : configSvc.clientId,
    );

    try {
      _privy = Privy.init(config: config);
      _privyInitialized = true;
    } on PlatformException catch (e) {
      _log.e('PlatformException code=${e.code}', e.message);
      rethrow;
    } catch (e) {
      _log.e('init error', e);
      rethrow;
    }
  }

  Future<void> _loadFromStorage() async {
    final walletId = await _storage.read(key: _kWalletId);
    final policyId = await _storage.read(key: _kPolicyId);
    final biometricsStr = await _storage.read(key: _kBiometrics);
    final pinStr = await _storage.read(key: _kPinEnabled);
    final passkeyStr = await _storage.read(key: _kPasskeyEnabled);
    final primaryUnlockMethod = await _storage.read(key: _kPrimaryUnlockMethod);

    _evmAddress = await _storage.read(key: _kEvmAddress);
    final evmCardAddressesRaw = await _storage.read(key: _kEvmCardAddresses);
    _solanaAddress = await _storage.read(key: _kSolanaAddress);
    _tronAddress = await _storage.read(key: _kTronAddress);
    _evmCardAddresses = _decodeStoredAddressList(evmCardAddressesRaw);
    if (_evmAddress != null &&
        _evmAddress!.isNotEmpty &&
        !_evmCardAddresses.contains(_evmAddress)) {
      _evmCardAddresses = [_evmAddress!, ..._evmCardAddresses]
          .where((e) => e.isNotEmpty)
          .toSet()
          .take(maxEvmCards)
          .toList();
    }

    // Migrate legacy EVM-copied Tron addresses to proper Base58 format
    if (_tronAddress != null && _tronAddress!.startsWith('0x')) {
      _tronAddress = TronUtils.evmAddressToTron(_tronAddress!);
      _persistAddresses();
    }

    // Migrate from old chains
    String cacheChainKey = 'bsc';
    final oldChainIdStr = await _storage.read(key: _kChainId);
    if (oldChainIdStr != null) {
      final id = int.tryParse(oldChainIdStr);
      if (id != null) {
        final legacyChain = PrivyChainRegistry.getEvmChain(id);
        if (legacyChain != null) cacheChainKey = legacyChain.chainKey;
      }
      await _storage.delete(key: _kChainId);
      await _storage.write(key: _kChainKey, value: cacheChainKey);
    } else {
      cacheChainKey = await _storage.read(key: _kChainKey) ?? 'bsc';
    }

    if (walletId != null) {
      _log.d(
          'Storage loaded: EVM=${_mask(_evmAddress ?? '')}, SOL=${_mask(_solanaAddress ?? '')}, TRON=${_mask(_tronAddress ?? '')}');
      _state = VaultState(
        walletId: walletId,
        isUnlocked: false, // всегда locked при старте
        policyId: policyId,
        chainKey: cacheChainKey,
        biometricsEnabled: biometricsStr == 'true',
        pinEnabled: pinStr == 'true',
        passkeyEnabled: passkeyStr == 'true',
        primaryUnlockMethod: primaryUnlockMethod ?? 'none',
      );

      _walletsBootstrapped = false;
      notifyListeners();
    }
  }

  /// Returns the Privy embedded ETH wallet whose address equals [preferredAddress] (any case).
  /// Does **not** fall back to another wallet — silent mismatch caused wrong UI vs copy.
  EmbeddedEthereumWallet? _embeddedEthMatchingOnly(
    List<EmbeddedEthereumWallet> wallets,
    String? preferredAddress,
  ) {
    if (wallets.isEmpty ||
        preferredAddress == null ||
        preferredAddress.isEmpty) {
      return null;
    }
    final want = preferredAddress.toLowerCase();
    for (final w in wallets) {
      if (w.address.toLowerCase() == want) return w;
    }
    return null;
  }

  EmbeddedSolanaWallet? _embeddedSolanaMatchingOnly(
    List<EmbeddedSolanaWallet> wallets,
    String? preferredAddress,
  ) {
    if (wallets.isEmpty ||
        preferredAddress == null ||
        preferredAddress.isEmpty) {
      return null;
    }
    final want = preferredAddress.toLowerCase();
    for (final w in wallets) {
      if (w.address.toLowerCase() == want) return w;
    }
    return null;
  }

  List<String> _decodeStoredAddressList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .map((e) => e?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toSet()
          .take(maxEvmCards)
          .toList();
    } catch (e) {
      _log.d('decodeStoredAddressList: $e');
      return [];
    }
  }

  List<String> _mergeEmbeddedEvmAddresses(List<String> available) {
    final normalizedAvailable =
        available.where((e) => e.isNotEmpty).toSet().toList();
    final merged = <String>[];
    for (final existing in _evmCardAddresses) {
      if (normalizedAvailable
          .any((a) => a.toLowerCase() == existing.toLowerCase())) {
        merged.add(
          normalizedAvailable.firstWhere(
            (a) => a.toLowerCase() == existing.toLowerCase(),
          ),
        );
      }
    }
    for (final address in normalizedAvailable) {
      if (!merged.any((a) => a.toLowerCase() == address.toLowerCase())) {
        merged.add(address);
      }
      if (merged.length >= maxEvmCards) break;
    }
    return merged.take(maxEvmCards).toList();
  }

  /// Embedded ETH wallet for signing: matches the stored primary EVM address,
  /// or resolves the sole embedded wallet when there is exactly one.
  EmbeddedEthereumWallet? resolveEmbeddedEthereumWallet(PrivyUser user) {
    if (user.embeddedEthereumWallets.isEmpty) return null;
    final embedded = user.embeddedEthereumWallets;
    final m = _embeddedEthMatchingOnly(embedded, _evmAddress);
    if (m != null) return m;
    if (embedded.length == 1) {
      return embedded.single;
    }
    return null;
  }

  /// Embedded Solana wallet for signing/display sync: matches the stored
  /// primary Solana address, or resolves the sole embedded wallet when there is
  /// exactly one.
  EmbeddedSolanaWallet? resolveEmbeddedSolanaWallet(PrivyUser user) {
    if (user.embeddedSolanaWallets.isEmpty) return null;
    final embedded = user.embeddedSolanaWallets;
    final m = _embeddedSolanaMatchingOnly(embedded, _solanaAddress);
    if (m != null) return m;
    if (embedded.length == 1) {
      return embedded.single;
    }
    return null;
  }

  Future<void> _syncWithPrivySession() async {
    if (!_privyInitialized || _privy == null) return;
    try {
      final authState = await _privy!.getAuthState();
      if (authState is Authenticated) {
        final user = await _privy!.getUser();
        if (user != null) {
          String? oldAddress = _evmAddress;
          if (user.embeddedEthereumWallets.isNotEmpty) {
            final availableEvmAddresses =
                user.embeddedEthereumWallets.map((e) => e.address).toList();
            _log.d(
                'Privy embedded ETH wallets: ${availableEvmAddresses.length}, '
                'stored cards: ${_evmCardAddresses.length}');
            _evmCardAddresses =
                _mergeEmbeddedEvmAddresses(availableEvmAddresses);
            _log.d('After merge: ${_evmCardAddresses.length} card(s)');
            if (_evmAddress == null || _evmAddress!.isEmpty) {
              _evmAddress =
                  resolveEmbeddedEthereumWallet(user)?.address ?? _evmAddress;
            } else {
              final matched = _embeddedEthMatchingOnly(
                user.embeddedEthereumWallets,
                _evmAddress,
              );
              if (matched != null) {
                _evmAddress = matched.address;
              } else {
                final embedded = user.embeddedEthereumWallets;
                // One real EOA in Privy → this IS the user's wallet; adopt it (funds/signing live here).
                // Multiple without match → keep storage until explicit wallet selection exists.
                if (embedded.length == 1) {
                  final sole = embedded.single.address;
                  if (sole.toLowerCase() != (_evmAddress ?? '').toLowerCase()) {
                    _log.i(
                        'Adopting sole embedded wallet (stored not in Privy list)');
                  }
                  _evmAddress = sole;
                } else {
                  // SAFETY: multiple Privy wallets exist and none match stored.
                  // Do NOT silently adopt embedded.first — the stored address
                  // may hold funds. Keep stored address; user must re-onboard
                  // or use explicit wallet selection to resolve the mismatch.
                  _log.e('Privy has ${embedded.length} embedded ETH wallets, '
                      'none match stored $_evmAddress — keeping stored address');
                }
              }
            }
            if (_evmAddress != null &&
                _evmAddress!.isNotEmpty &&
                !_evmCardAddresses.any((address) =>
                    address.toLowerCase() == _evmAddress!.toLowerCase())) {
              if (_evmCardAddresses.length >= maxEvmCards) {
                _evmCardAddresses =
                    _evmCardAddresses.take(maxEvmCards - 1).toList();
              }
              _evmCardAddresses = [_evmAddress!, ..._evmCardAddresses];
            }
            if ((_evmAddress == null || _evmAddress!.isEmpty) &&
                _evmCardAddresses.isNotEmpty) {
              _evmAddress = _evmCardAddresses.first;
            }
          }
          if (oldAddress != _evmAddress) {
            _log.w('Address mismatch detected — updating to Privy source');
          }
          try {
            if (user.embeddedSolanaWallets.isNotEmpty) {
              _solanaAddress =
                  resolveEmbeddedSolanaWallet(user)?.address ?? _solanaAddress;
            }
          } catch (e) {
            _log.w('Solana sync in session failed', e);
          }

          await _persistAddresses();

          if (_evmAddress != null) {
            _state = (_state ??
                    VaultState(
                      walletId: _evmAddress!,
                      isUnlocked: false,
                    ))
                .copyWith(walletId: _evmAddress!);
          }
          _log.d('Session synced');
          notifyListeners();
        }
      }
    } catch (e) {
      _log.d('Session sync skipped: $e');
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
// AUTH (Email OTP) Real flow
// ────────────────────────────────────────────────────────────────────────────

  Future<bool> sendEmailCode(String email) async {
    _initPrivy();
    try {
      if (_privy == null) return false;
      final result = await _privy!.email.sendCode(email);
      bool success = false;
      result.fold(
        onSuccess: (_) => success = true,
        onFailure: (e) => _log.e('sendEmailCode failed', e.message),
      );
      return success;
    } catch (e) {
      _log.e('sendEmailCode error', e);
      return false;
    }
  }

  Future<bool> loginWithEmailCode({
    required String email,
    required String code,
  }) async {
    _initPrivy();
    try {
      if (_privy == null) return false;
      final result =
          await _privy!.email.loginWithCode(code: code, email: email);

      bool success = false;
      result.fold(
        onSuccess: (_) => success = true,
        onFailure: (e) => _log.e('loginWithEmailCode failed', e.message),
      );

      if (!success) return false;
      final ok = await ensureAllWallets();
      if (ok) unlock();
      return ok;
    } catch (e) {
      _log.e('loginWithEmailCode error', e);
      return false;
    }
  }

  Future<bool> loginWithGoogle() async {
    _initPrivy();
    try {
      if (_privy == null) return false;

      final result = await _privy!.oAuth.login(
        provider: OAuthProvider.google,
        appUrlScheme: 'ibitiguardian',
      );

      bool success = false;
      result.fold(
        onSuccess: (_) => success = true,
        onFailure: (e) => _log.e('Google OAuth failed', e.message),
      );

      if (!success) return false;
      final ok = await ensureAllWallets();
      if (ok) unlock();
      return ok;
    } catch (e) {
      _log.e('loginWithGoogle failed', e);
      return false;
    }
  }

// ────────────────────────────────────────────────────────────────────────────
// WALLET BOOTSTRAPPING
// ────────────────────────────────────────────────────────────────────────────

  Future<bool> ensureAllWallets() async {
    try {
      if (_walletsBootstrapped) return true;

      final evmOk = await _ensureEthereumWallet();
      if (!evmOk) return false;

      await _ensureSolanaWallet();
      await _ensureTronWallet();

      await _persistAddresses();

      if (_evmAddress != null) {
        _state =
            (_state ?? VaultState(walletId: _evmAddress!, isUnlocked: false))
                .copyWith(walletId: _evmAddress!);
        await _storage.write(key: _kWalletId, value: _state!.walletId);
      }

      _walletsBootstrapped = true;

      // Sync active chain with saved default network from WalletSettings.
      // After reinstall, SecureStorage may reset chainKey to 'bsc' while
      // SharedPreferences (WalletSettingsService) still has user's choice.
      try {
        final settings = WalletSettingsService.instance;
        if (settings.isLoaded) {
          final savedDisplayName = settings.defaultNetwork;
          final savedChain =
              PrivyChainRegistry.supportedChains.cast<dynamic>().firstWhere(
                    (c) => c != null && c.displayName == savedDisplayName,
                    orElse: () => null,
                  );
          if (savedChain != null &&
              _state != null &&
              _state!.chainKey != savedChain.chainKey &&
              hasAddressForChain(savedChain.chainKey)) {
            _log.i('Restoring chain from settings: ${savedChain.chainKey}');
            await setActiveChain(savedChain.chainKey);
          }
        }
      } catch (e) {
        _log.e('Chain sync from settings error', e);
      }

      notifyListeners();
      return true;
    } catch (e) {
      _log.e('ensureAllWallets error', e);
      return false;
    }
  }

  Future<bool> _ensureEthereumWallet() async {
    try {
      final user = await _privy?.getUser();
      if (user == null) return false;

      EmbeddedEthereumWallet wallet;
      if (user.embeddedEthereumWallets.isNotEmpty) {
        final embedded = user.embeddedEthereumWallets;

        // 1. Try to match stored primary address
        EmbeddedEthereumWallet? resolved = resolveEmbeddedEthereumWallet(user);

        // 2. No stored match, sole embedded → adopt it
        if (resolved == null && embedded.length == 1) {
          resolved = embedded.single;
          _log.i('No stored EVM match. Adopting sole embedded wallet.');
        }

        // 3. No stored match, multiple embedded → take first as primary
        //    (storage wiped, no other source of truth for primary)
        if (resolved == null && embedded.length > 1) {
          resolved = embedded.first;
          _log.i(
              'Storage wiped, adopting first of ${embedded.length} embedded wallets as primary.');
        }

        if (resolved == null) return false;
        wallet = resolved;
      } else {
        final createResult =
            await user.createEthereumWallet(allowAdditional: false);
        bool created = false;
        EmbeddedEthereumWallet? newWallet;
        createResult.fold(
          onSuccess: (w) {
            newWallet = w;
            created = true;
          },
          onFailure: (e) => _log.e('createEthWallet failed', e.message),
        );
        if (!created || newWallet == null) return false;
        wallet = newWallet!;
      }

      _evmAddress = wallet.address;

      // Merge ALL embedded ETH wallets from Privy, not just the resolved primary.
      // This ensures additional cards are recovered after reinstall or storage reset.
      final allEmbedded =
          user.embeddedEthereumWallets.map((e) => e.address).toList();
      _evmCardAddresses = _mergeEmbeddedEvmAddresses(allEmbedded);

      // Guarantee primary is first in the card list for UI consistency.
      _evmCardAddresses = [
        _evmAddress!,
        ..._evmCardAddresses
            .where((a) => a.toLowerCase() != _evmAddress!.toLowerCase()),
      ].take(maxEvmCards).toList();

      _log.d('ensureEthWallet: embedded=${allEmbedded.length}, '
          'mergedCards=${_evmCardAddresses.length}, '
          'primary=${_mask(_evmAddress!)}');

      await _persistAddresses();
      return true;
    } catch (e) {
      _log.e('_ensureEthereumWallet error', e);
      return false;
    }
  }

  Future<void> _ensureSolanaWallet() async {
    try {
      final user = await _privy?.getUser();
      if (user == null) return;

      try {
        if (user.embeddedSolanaWallets.isNotEmpty) {
          final resolved = resolveEmbeddedSolanaWallet(user);
          if (resolved == null) {
            _log.w(
                'Multiple embedded Solana wallets found and none match stored — refusing to guess');
            return;
          }
          _solanaAddress = resolved.address;
          return;
        }
      } catch (e) {
        _log.w('Solana embedded wallet check failed', e);
      }

      final result = await user.createSolanaWallet(allowAdditional: false);
      result.fold(
        onSuccess: (wallet) => _solanaAddress = wallet.address,
        onFailure: (e) => _log.e('createSolWallet failed', e.message),
      );
    } catch (e) {
      _log.e('_ensureSolanaWallet error', e);
    }
  }

  Future<void> _ensureTronWallet() async {
    try {
      if (_tronAddress != null && _tronAddress!.isNotEmpty) return;
      if (_evmAddress != null) {
        _tronAddress = TronUtils.evmAddressToTron(_evmAddress!);
      }
    } catch (e) {
      _log.e('_ensureTronWallet error', e);
    }
  }

  Future<void> _persistAddresses() async {
    _log.d('Persisting addresses');

    if (_evmAddress != null) {
      await _storage.write(key: _kEvmAddress, value: _evmAddress);
    } else {
      await _storage.delete(key: _kEvmAddress);
    }

    if (_evmCardAddresses.isNotEmpty) {
      await _storage.write(
        key: _kEvmCardAddresses,
        value: jsonEncode(_evmCardAddresses.take(maxEvmCards).toList()),
      );
    } else {
      await _storage.delete(key: _kEvmCardAddresses);
    }

    if (_solanaAddress != null) {
      await _storage.write(key: _kSolanaAddress, value: _solanaAddress);
    } else {
      await _storage.delete(key: _kSolanaAddress);
    }

    if (_tronAddress != null) {
      await _storage.write(key: _kTronAddress, value: _tronAddress);
    } else {
      await _storage.delete(key: _kTronAddress);
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // LOCK / UNLOCK
  // ────────────────────────────────────────────────────────────────────────────

  void unlock() {
    if (_state == null) return;
    _state = _state!.copyWith(isUnlocked: true);
    notifyListeners();
  }

  void lock() {
    if (_state == null) return;
    _state = _state!.copyWith(isUnlocked: false);
    notifyListeners();
  }

  Future<void> logout() async {
    try {
      if (_privy != null) {
        await _privy!.logout();
      }
    } catch (e) {
      _log.e('logout privy error', e);
    }

    await _storage.delete(key: _kWalletId);
    await _storage.delete(key: _kPolicyId);
    await _storage.delete(key: _kChainId);
    await _storage.delete(key: _kChainKey);
    await _storage.delete(key: _kEvmAddress);
    await _storage.delete(key: _kEvmCardAddresses);
    await _storage.delete(key: _kSolanaAddress);
    await _storage.delete(key: _kTronAddress);

    await _storage.delete(key: _kBiometrics);
    await _storage.delete(key: _kPinEnabled);
    await _storage.delete(key: _kPinHash);
    await _storage.delete(key: _kPinSalt);
    await _storage.delete(key: _kPinAttempts);
    await _storage.delete(key: _kPinLockedUntil);
    await _storage.delete(key: _kPasskeyEnabled);

    _pinLockedUntilCache = null;
    _state = null;
    _evmAddress = null;
    _evmCardAddresses = [];
    _solanaAddress = null;
    _tronAddress = null;
    _walletsBootstrapped = false;
    _nativeBalanceAtomic = null;
    _web3?.dispose();
    _web3 = null;
    notifyListeners();
  }

  // ── BALANCE (Multi-chain support) ───────────────────────────────────────────

  /// Fetch active atomic balance based on chain key and rpc config.
  Future<BigInt> getActiveNativeBalanceAtomic() async {
    final addr = activeAddress;
    if (addr.isEmpty) return BigInt.zero;

    switch (chainKey) {
      case 'solana':
        try {
          final rpcUrl = PrivyChainRegistry.getChain(chainKey).rpcUrl ??
              'https://api.mainnet-beta.solana.com';
          final client = SolanaHttpRpcClient(rpcUrl: rpcUrl);
          return await client.getBalanceLamports(addr);
        } catch (e) {
          _log.w('Solana balance fetch failed', e);
          return BigInt.zero;
        }

      case 'tron':
        try {
          final rpcUrl = PrivyChainRegistry.getChain(chainKey).rpcUrl ??
              'https://api.trongrid.io';
          const tronApiKey = String.fromEnvironment('TRONGRID_API_KEY');
          final client = TronHttpRpcClient(
              baseUrl: rpcUrl, apiKey: tronApiKey.isEmpty ? null : tronApiKey);
          return await client.getBalanceSun(addr);
        } catch (e) {
          _log.w('Tron balance fetch failed', e);
          return BigInt.zero;
        }

      default:
        return _getEvmBalanceWei(addr);
    }
  }

  Future<BigInt> _getEvmBalanceWei(String addr) async {
    try {
      final rpcUrl = PrivyChainRegistry.getChain(chainKey).rpcUrl ??
          'https://bsc-dataseed.binance.org/';
      _web3?.dispose();
      _web3 = Web3Client(rpcUrl, http.Client());
      final etherAddr = EthereumAddress.fromHex(addr);
      final etherAmount = await _web3!.getBalance(etherAddr);
      return etherAmount.getInWei;
    } catch (e) {
      return BigInt.zero;
    }
  }

  Future<double> getNativeBalance() async {
    final atomic = await getActiveNativeBalanceAtomic();
    final decimals = switch (chainKey) {
      'solana' => 9,
      'tron' => 6,
      _ => 18,
    };

    final divisor = BigInt.from(10).pow(decimals);
    final whole = (atomic ~/ divisor).toDouble();
    final frac = (atomic % divisor).toDouble() / divisor.toDouble();
    return double.parse((whole + frac).toStringAsFixed(4));
  }

  Future<PrivyUser?> getPrivyUser() async {
    if (_privy == null) {
      _log.e('getPrivyUser: _privy is null (Privy is not initialized).');
      return null;
    }
    try {
      final user = await _privy!.getUser();
      if (user == null) {
        _log.w('getPrivyUser: getUser returned null (no active session).');
      }
      return user;
    } catch (e) {
      _log.e('getPrivyUser: getUser threw an exception', e);
      return null;
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // POLICY & CHAIN MANAGEMENT
  // ────────────────────────────────────────────────────────────────────────────

  Future<void> setActiveChain(String key) async {
    if (_state == null || chainKey == key) return;
    // Caller is responsible for ensuring the wallet exists (via createNetworkProfile)
    // before calling this. UI should gate with hasAddressForChain.
    final newChain = PrivyChainRegistry.getChain(key);
    await _storage.write(key: _kChainKey, value: newChain.chainKey);
    _state = _state!.copyWith(chainKey: newChain.chainKey);

    _nativeBalanceAtomic = null;
    notifyListeners();

    await refreshActiveBalance();
  }

  /// Returns true if this vault already has an address for [chainKey].
  bool hasAddressForChain(String key) {
    switch (key) {
      case 'solana':
        return _solanaAddress != null && _solanaAddress!.isNotEmpty;
      case 'tron':
        return _tronAddress != null && _tronAddress!.isNotEmpty;
      default:
        return _evmAddress != null && _evmAddress!.isNotEmpty;
    }
  }

  /// Creates a network-specific address (Solana or Tron) and persists it.
  /// Returns [true] on success, [false] if provisioning failed.
  Future<bool> createNetworkProfile(String key) async {
    if (_state == null) return false;
    try {
      if (key == 'solana') {
        await _ensureSolanaWallet();
      } else if (key == 'tron') {
        await _ensureTronWallet();
      } else {
        return false; // EVM is created during onboarding
      }
      await _persistAddresses();
      return hasAddressForChain(key);
    } catch (e) {
      _log.e('createNetworkProfile($key) failed', e);
      return false;
    }
  }

  Future<bool> setActiveEvmCard(String address) async {
    if (address.isEmpty) return false;
    final match = _evmCardAddresses
        .where((e) => e.toLowerCase() == address.toLowerCase());
    if (match.isEmpty) return false;
    final nextAddress = match.first;
    if (_evmAddress?.toLowerCase() == nextAddress.toLowerCase()) return true;

    _evmAddress = nextAddress;
    _state = _state?.copyWith(walletId: nextAddress);
    await _storage.write(key: _kEvmAddress, value: nextAddress);
    if (_state != null) {
      await _storage.write(key: _kWalletId, value: _state!.walletId);
    }
    _nativeBalanceAtomic = null;
    notifyListeners();
    await refreshActiveBalance();
    return true;
  }

  Future<String?> createAdditionalEvmCard() async {
    if (!isVaultCreated || !canCreateAdditionalEvmCard) return null;
    try {
      final user = await _privy?.getUser();
      if (user == null) return null;

      final createResult =
          await user.createEthereumWallet(allowAdditional: true);
      EmbeddedEthereumWallet? newWallet;
      createResult.fold(
        onSuccess: (wallet) => newWallet = wallet,
        onFailure: (e) => _log.e('createAdditionalEvmCard failed', e.message),
      );
      if (newWallet == null) return null;

      final newAddress = newWallet!.address;
      if (!_evmCardAddresses
          .any((e) => e.toLowerCase() == newAddress.toLowerCase())) {
        _evmCardAddresses =
            [..._evmCardAddresses, newAddress].take(maxEvmCards).toList();
      }

      _evmAddress = newAddress;
      _state = _state?.copyWith(walletId: newAddress);
      await _persistAddresses();
      if (_state != null) {
        await _storage.write(key: _kWalletId, value: _state!.walletId);
      }
      _nativeBalanceAtomic = null;
      notifyListeners();
      await refreshActiveBalance();
      return newAddress;
    } catch (e) {
      _log.e('createAdditionalEvmCard error', e);
      return null;
    }
  }

  Future<void> refreshActiveBalance() async {
    try {
      final atomic = await getActiveNativeBalanceAtomic();
      cacheNativeBalanceAtomic(atomic);
    } catch (e) {
      _log.w('refreshActiveBalance failed', e);
    }
  }

  Future<void> savePolicyId(String policyId) async {
    await _storage.write(key: _kPolicyId, value: policyId);
    _state = _state?.copyWith(policyId: policyId);
    notifyListeners();
  }

  Future<void> setBiometricsEnabled(bool enabled) async {
    await _storage.write(key: _kBiometrics, value: enabled.toString());
    _state = _state?.copyWith(biometricsEnabled: enabled);
    notifyListeners();
  }

  Future<void> setPinEnabled(bool enabled) async {
    await _storage.write(key: _kPinEnabled, value: enabled.toString());
    _state = _state?.copyWith(pinEnabled: enabled);
    notifyListeners();
  }

  Future<void> setPasskeyEnabled(bool enabled) async {
    await _storage.write(key: _kPasskeyEnabled, value: enabled.toString());
    _state = _state?.copyWith(passkeyEnabled: enabled);
    notifyListeners();
  }

  Future<void> setPrimaryUnlockMethod(String method) async {
    await _storage.write(key: _kPrimaryUnlockMethod, value: method);
    _state = _state?.copyWith(primaryUnlockMethod: method);
    notifyListeners();
  }

  // ────────────────────────────────────────────────────────────────────────────
  // PIN CODE MANAGEMENT
  // ────────────────────────────────────────────────────────────────────────────

  static const int _maxPinAttempts = 5;
  static const Duration _lockoutDuration = Duration(minutes: 5);

  bool get isPinLocked {
    if (_pinLockedUntilCache == null) return false;
    if (DateTime.now().isAfter(_pinLockedUntilCache!)) return false;
    return true;
  }

  DateTime? _pinLockedUntilCache;

  Future<void> _loadPinLockState() async {
    final lockedUntilStr = await _storage.read(key: _kPinLockedUntil);
    if (lockedUntilStr != null) {
      final lockedUntil = DateTime.tryParse(lockedUntilStr);
      if (lockedUntil != null && DateTime.now().isBefore(lockedUntil)) {
        _pinLockedUntilCache = lockedUntil;
      } else {
        await _storage.delete(key: _kPinLockedUntil);
        await _storage.delete(key: _kPinAttempts);
        _pinLockedUntilCache = null;
      }
    }
  }

  String _generateSalt() {
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    return base64UrlEncode(values);
  }

  String _hashPin(String pin, String salt) {
    final bytes = utf8.encode(pin + salt);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  Future<void> savePin(String pin, {bool makePrimary = false}) async {
    final salt = _generateSalt();
    final hash = _hashPin(pin, salt);

    await _storage.write(key: _kPinSalt, value: salt);
    await _storage.write(key: _kPinHash, value: hash);
    await setPinEnabled(true);
    if (makePrimary) {
      await setPrimaryUnlockMethod('pin');
    }
  }

  Future<bool> verifyPin(String pin) async {
    if (!pinEnabled) return false;
    if (isPinLocked) return false;

    final storedHash = await _storage.read(key: _kPinHash);
    final storedSalt = await _storage.read(key: _kPinSalt);
    if (storedHash == null || storedSalt == null) return false;

    final computedHash = _hashPin(pin, storedSalt);
    if (computedHash == storedHash) {
      await _storage.delete(key: _kPinAttempts);
      await _storage.delete(key: _kPinLockedUntil);
      _pinLockedUntilCache = null;
      return true;
    } else {
      final attemptsStr = await _storage.read(key: _kPinAttempts);
      int attempts = int.tryParse(attemptsStr ?? '0') ?? 0;
      attempts++;
      await _storage.write(key: _kPinAttempts, value: attempts.toString());

      if (attempts >= _maxPinAttempts) {
        final lockedUntil = DateTime.now().add(_lockoutDuration);
        await _storage.write(
            key: _kPinLockedUntil, value: lockedUntil.toIso8601String());
        _pinLockedUntilCache = lockedUntil;
      }
      return false;
    }
  }

  Future<void> clearPin() async {
    await _storage.delete(key: _kPinHash);
    await _storage.delete(key: _kPinSalt);
    await _storage.delete(key: _kPinAttempts);
    await _storage.delete(key: _kPinLockedUntil);
    _pinLockedUntilCache = null;
    await setPinEnabled(false);
    if (primaryUnlockMethod == 'pin') {
      await setPrimaryUnlockMethod('none');
    }
  }

  Future<bool> isPinEnabled() async {
    final val = await _storage.read(key: _kPinEnabled);
    return val == 'true';
  }

  @override
  void dispose() {
    _web3?.dispose();
    super.dispose();
  }
}
