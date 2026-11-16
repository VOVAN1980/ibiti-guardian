import 'package:flutter/material.dart';
import 'package:ibiti_guardian/screens/vault/vault_unlock_screen.dart';
import 'package:ibiti_guardian/services/audit_log_service.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/utils/address_key.dart';

/// The owner's controls for the AI whitelist ("trusted addresses"): the only
/// addresses the AI may send to while the vault is in STRICT mode.
///
/// Widening what the AI may do always needs the owner's PIN; taking a
/// permission away never does. The AI itself has no way to call these.
class AiTrustActions {
  const AiTrustActions._();

  /// EVM sends are checked when signing; Solana and Tron sends just before
  /// they are sent (GuardianExecutionService.nonEvmWhitelistBlock).
  static final _evmAddress = RegExp(r'^0x[0-9a-fA-F]{40}$');
  static final _solanaAddress = RegExp(r'^[1-9A-HJ-NP-Za-km-z]{32,44}$');
  static final _tronAddress = RegExp(r'^T[1-9A-HJ-NP-Za-km-z]{33}$');

  static bool canTrust(String address) {
    final a = address.trim();
    return _evmAddress.hasMatch(a) ||
        _solanaAddress.hasMatch(a) ||
        _tronAddress.hasMatch(a);
  }

  /// Older builds could put an address in the trusted *contracts* list;
  /// the AI may send there too, so it counts as trusted here as well.
  static bool isTrusted(String address) {
    final key = AddressKey.of(address);
    final p = PolicyProfileStore.instance.current;
    return p.trustedAddresses.contains(key) ||
        p.trustedContracts.contains(key);
  }

  /// Asks for the PIN, then lets the AI send to [address].
  static Future<bool> trust(
    BuildContext context, {
    required String label,
    required String address,
  }) async {
    if (!canTrust(address)) return false;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await VaultUnlockScreen.requireAuth(context, forceSetup: true);
    if (!ok) return false;
    await PolicyProfileStore.instance.addTrustedAddress(address.trim());
    AuditLogService.instance.recordSystem(
      actionLabel: 'AI whitelist',
      summary: 'Trusted for AI: $label ($address)',
    );
    _toast(
        messenger,
        LocalizationService.instance.t('addressBookTrustedDone',
            {'default': 'AI can now send to this address'}));
    return true;
  }

  /// Stops the AI from sending to [address]. No PIN: it only narrows rights.
  static Future<void> untrust(
    BuildContext context, {
    required String label,
    required String address,
    bool silent = false,
    String reason = '',
  }) async {
    // Taken before any await: the card that asked may disappear from the
    // list as soon as the address is no longer trusted.
    final messenger = ScaffoldMessenger.maybeOf(context);
    final store = PolicyProfileStore.instance;
    final key = AddressKey.of(address);
    final wasAddress = store.current.trustedAddresses.contains(key);
    final wasContract = store.current.trustedContracts.contains(key);
    if (!wasAddress && !wasContract) return;
    if (wasAddress) await store.removeTrustedAddress(key);
    if (wasContract) await store.removeTrustedContract(key);
    AuditLogService.instance.recordSystem(
      actionLabel: 'AI whitelist',
      summary: 'Removed from AI trusted$reason: $label ($address)',
    );
    if (silent) return;
    _toast(
        messenger,
        LocalizationService.instance.t('addressBookUntrustedDone',
            {'default': 'AI can no longer send to this address'}));
  }

  static void _toast(ScaffoldMessengerState? messenger, String text) {
    if (messenger == null || !messenger.mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }
}
