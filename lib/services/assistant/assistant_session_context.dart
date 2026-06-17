import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/services/adapters/wallet_adapter.dart';

class AssistantSessionContext {
  AssistantSessionContext._();
  static final instance = AssistantSessionContext._();

  String get currentVaultAddress => IBITIVaultService.instance.address;

  /// Returns EVM chain ID or 0 for non-EVM chains (Solana/Tron).
  /// Used only for informational AI context, NOT for signing.
  int get currentVaultChainId {
    try {
      return WalletAdapter.instance.chainId;
    } on StateError {
      return 0;
    }
  }

  String? lastTopic;
  String? lastSymbol;
  String? lastScreen;
  String? lastIntentType;
  DateTime? lastUpdatedAt;

  // ── Voice session context ─────────────────────────────────────────────────
  // Tracks which modal is open and how many voice turns have occurred,
  // so follow-up commands ("change amount", "use different token") know
  // the current UI context.

  /// Currently open modal name (e.g. 'wallet_send', 'wallet_swap'), or null.
  String? currentOpenModal;

  /// Number of voice turns in the current session.
  int voiceTurnCount = 0;

  /// Called by guardian_app_shell when a modal opens or closes.
  void setOpenModal(String? modal) {
    currentOpenModal = modal;
    lastUpdatedAt = DateTime.now();
  }

  /// Increment turn count for each voice interaction.
  void incrementTurn() {
    voiceTurnCount++;
    lastUpdatedAt = DateTime.now();
  }

  /// Reset session-specific state when voice session ends.
  void resetSession() {
    currentOpenModal = null;
    voiceTurnCount = 0;
  }

  void update({
    String? topic,
    String? symbol,
    String? screen,
    String? intentType,
  }) {
    if (topic != null && topic.isNotEmpty) lastTopic = topic;
    if (symbol != null && symbol.isNotEmpty) lastSymbol = symbol;
    if (screen != null && screen.isNotEmpty) lastScreen = screen;
    if (intentType != null && intentType.isNotEmpty) {
      lastIntentType = intentType;
    }
    lastUpdatedAt = DateTime.now();
  }
}
