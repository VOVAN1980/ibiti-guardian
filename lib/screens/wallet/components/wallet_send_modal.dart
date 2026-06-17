import 'dart:async';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';
import 'package:ibiti_guardian/utils/token_symbol_normalizer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/screens/vault/vault_unlock_screen.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_bus.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/utils/amount_parser.dart';
import 'package:ibiti_guardian/services/execution/guardian_execution_controller.dart';
import 'package:ibiti_guardian/services/execution/tx_status_poller.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/wallet/address_book_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/voice/tts_service.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/widgets/transaction_preview_card.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

class WalletSendModal extends StatefulWidget {
  /// Optional pre-selected asset (e.g. from an asset row tap).
  final WalletAsset? initialAsset;

  /// When true, the tutorial voice guide is silenced on modal open.
  /// Persisted to SharedPreferences.
  static bool voiceGuideMuted = false;
  static const _muteKey = 'send_guide_muted';

  /// Load persisted mute state (call once at app start or before first show).
  static Future<void> loadMuteState() async {
    final prefs = await SharedPreferences.getInstance();
    voiceGuideMuted = prefs.getBool(_muteKey) ?? false;
  }

  const WalletSendModal({super.key, this.initialAsset});

  static void show(BuildContext context, {WalletAsset? initialAsset}) {
    showDialog(
      context: context,
      barrierColor: const Color(0xFF07090D)
          .withOpacity(0.85), // Very dark premium overlay
      barrierDismissible:
          false, // Don't close on tap outside, instead we will unfocus keyboard
      builder: (_) => WalletSendModal(initialAsset: initialAsset),
    );
  }

  @override
  State<WalletSendModal> createState() => _WalletSendModalState();
}

class _WalletSendModalState extends State<WalletSendModal>
    with TickerProviderStateMixin {
  final _addressController = TextEditingController();
  final _amountController = TextEditingController();
  StreamSubscription<UICommand>? _cmdSub;
  bool _isExecuting = false;

  /// Index of currently highlighted field during the guide animation.
  /// 0 = token selector, 1 = recipient, 2 = amount, 3 = send button, -1 = none
  int _highlightIndex = -1;
  Timer? _highlightTimer;

  /// Single-shot guard — prevents double guide execution on race/reopen.
  bool _guideStarted = false;

  /// Currently selected asset for send. null = use native.
  WalletAsset? _selectedAsset;

  @override
  void initState() {
    super.initState();
    _selectedAsset = widget.initialAsset;
    ScreenContextService.instance.setModal('wallet_send');

    final bus = UICommandBus.instance;
    final cachedAddress = bus.latestFieldValue('send_address');
    final cachedAmount = bus.latestFieldValue('send_amount');
    if (cachedAddress != null && cachedAddress.isNotEmpty) {
      _addressController.text = cachedAddress;
    }
    if (cachedAmount != null && cachedAmount.isNotEmpty) {
      _amountController.text = cachedAmount;
    }
    _applySelectedTokenPayload(bus.latestPayload('send_token'));
    _cmdSub = UICommandBus.instance.commands.listen(_handleCommand);
    final shouldPreview = bus.consumePendingAction('wallet_send_preview') ||
        bus.consumePendingAction('send_preview');
    if (shouldPreview) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _previewSend();
        }
      });
    }

    // Single entry point for guide — runs once after first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _startGuideOnce());
  }

  /// Unified guide startup: load mute → wait for AI TTS → animation + narration.
  Future<void> _startGuideOnce() async {
    if (_guideStarted || !mounted) return;
    _guideStarted = true;

    await WalletSendModal.loadMuteState();
    if (!mounted || WalletSendModal.voiceGuideMuted) return;

    // Wait for any in-flight TTS (e.g. "Открываю окно отправки...") to finish.
    int waited = 0;
    while (TtsService.instance.isCurrentlySpeaking && waited < 15000) {
      await Future.delayed(const Duration(milliseconds: 300));
      waited += 300;
      if (!mounted || WalletSendModal.voiceGuideMuted) return;
    }
    if (!mounted || WalletSendModal.voiceGuideMuted) return;

    // Start animation and narration together — after AI speech ended.
    _startGuideAnimation();
    final lang =
        SettingsService.instance.settings.languageCode.trim().toLowerCase();
    final text = lang.startsWith('ru')
        ? 'Выберите токен для отправки, введите адрес получателя и сумму, затем нажмите отправить.'
        : 'Select the token to send, enter the recipient address and amount, then tap send.';
    TtsService.instance.speak(text);
  }

  /// Sequentially highlights fields in sync with the TTS guide narration.
  void _startGuideAnimation() {
    int step = 0;
    setState(() => _highlightIndex = 0);
    _highlightTimer =
        Timer.periodic(const Duration(milliseconds: 3000), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      step++;
      if (step > 3) {
        timer.cancel();
        if (mounted) setState(() => _highlightIndex = -1);
        return;
      }
      setState(() => _highlightIndex = step);
    });
  }

  void _applySelectedTokenPayload(Map<String, dynamic>? payload) {
    final rawSymbol = payload?['symbol']?.toString();
    if (rawSymbol == null || rawSymbol.isEmpty) return;
    final symbol = TokenSymbolNormalizer.normalize(rawSymbol);
    final assets = VaultPortfolioListener.instance.summary?.allAssets ??
        const <WalletAsset>[];
    final match = assets.cast<WalletAsset?>().firstWhere(
          (asset) => asset?.symbol.toUpperCase() == symbol,
          orElse: () => null,
        );
    if (match != null) {
      _selectedAsset = match;
    }
  }

  void _handleCommand(UICommand cmd) {
    if (!mounted) return;
    if (cmd.type == UICommandType.fillField) {
      final target = cmd.target;
      final val = cmd.payload?['value']?.toString();
      if (val == null) return;
      if (target == 'send_address') {
        setState(() => _addressController.text = val);
      } else if (target == 'send_amount') {
        setState(() => _amountController.text = val);
      }
    } else if (cmd.type == UICommandType.selectToken &&
        cmd.target == 'send_token') {
      setState(() {
        _applySelectedTokenPayload(cmd.payload);
      });
    } else if (cmd.type == UICommandType.executeAction &&
        (cmd.target == 'wallet_send_preview' || cmd.target == 'send_preview')) {
      // Only Full Autonomy can auto-submit; Guard mode requires manual press
      if (AiControlService.instance.settings.mode == AiMode.fullAutonomy) {
        _previewSend();
      }
    }
  }

  @override
  void dispose() {
    ScreenContextService.instance.clearModal();
    TtsService.instance.stop();
    _highlightTimer?.cancel();
    _cmdSub?.cancel();
    _addressController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  String get _activeChainKey => IBITIVaultService.instance.chainKey;

  String get _tokenSymbol {
    if (_selectedAsset != null) return _selectedAsset!.symbol;
    return PrivyChainRegistry.getChain(_activeChainKey).nativeSymbol ?? 'TOKEN';
  }

  int get _tokenDecimals {
    if (_selectedAsset != null) return _selectedAsset!.decimals;
    switch (_activeChainKey) {
      case 'solana':
        return 9;
      case 'tron':
        return 6;
      default:
        return 18;
    }
  }

  bool get _isErc20 => _selectedAsset != null && !_selectedAsset!.isNative;

  List<AddressEntry> get _recipientSuggestions {
    final query = _addressController.text.trim().toLowerCase();
    final entries = AddressBookService.instance.entries;
    if (query.isEmpty) {
      return entries.take(4).toList();
    }
    return entries
        .where((entry) =>
            entry.label.toLowerCase().contains(query) ||
            entry.address.toLowerCase().contains(query))
        .take(4)
        .toList();
  }

  Future<void> _previewSend() async {
    final t = LocalizationProvider.of(context);
    final vault = IBITIVaultService.instance;
    final toAddress = _addressController.text.trim();
    final amountStr = _amountController.text.trim();

    if (toAddress.isEmpty || amountStr.isEmpty) return;

    // EVM/BSC Address check
    final chain = PrivyChainRegistry.getChain(_activeChainKey);
    if (chain.isEvm) {
      if (!toAddress.startsWith('0x') || toAddress.length != 42) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            t.t('walletSendInvalidEvmAddress', {
              'default': 'Invalid EVM/BSC address. Must start with 0x and be 42 characters long.',
              'ru': 'Неверный адрес EVM/BSC. Должен начинаться с 0x и иметь длину 42 символа.',
            }),
          ),
          backgroundColor: GuardianColors.danger,
        ));
        return;
      }
    }

    // ── Policy limit check ───────────────────────────────────────────────────
    final aiSettings = AiControlService.instance.settings;
    final numericAmount = double.tryParse(amountStr.replaceAll(',', '.')) ?? 0;
    if (numericAmount > 0 &&
        _selectedAsset != null &&
        _selectedAsset!.priceUsd > 0) {
      final usdValue = numericAmount * _selectedAsset!.priceUsd;
      if (aiSettings.perTxLimit > 0 && usdValue > aiSettings.perTxLimit) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            t.t('walletSendExceedsLimit', {
              'default':
                  '\$${usdValue.toStringAsFixed(2)} exceeds the per-transaction limit of \$${aiSettings.perTxLimit.toStringAsFixed(0)}',
              'ru':
                  'Сумма \$${usdValue.toStringAsFixed(2)} превышает лимит \$${aiSettings.perTxLimit.toStringAsFixed(0)} на транзакцию',
            }),
          ),
          backgroundColor: GuardianColors.warning,
        ));
        return;
      }
    }

    final atomicAmount = parseDecimalToAtomic(amountStr, _tokenDecimals);
    if (atomicAmount <= BigInt.zero) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(t.t('walletSendInvalidAmount', {'default': 'Invalid amount'})),
      ));
      return;
    }

    try {
      final tx = _buildPreviewTransaction(
        vault: vault,
        toAddress: toAddress,
        amountStr: amountStr,
        atomicAmount: atomicAmount,
      );
      if (tx == null) throw StateError('Active wallet address is not ready.');

      if (!mounted) return;
      setState(() => _isExecuting = true);

      final preview =
          await GuardianExecutionController.instance.previewTransaction(tx);
      if (!mounted) return;

      if (preview.type == ResponseType.error ||
          preview.pendingTransaction == null ||
          preview.explanation == null ||
          preview.policy == null ||
          preview.rpcSimulation == null ||
          preview.executionPath == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(preview.message),
          backgroundColor: GuardianColors.danger,
        ));
        return;
      }

      await _showPreviewSheet(preview);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e is StateError
            ? e.toString()
            : t.t('walletSendError', {'default': 'Transaction failed'})),
        backgroundColor: GuardianColors.danger,
      ));
    } finally {
      if (mounted) setState(() => _isExecuting = false);
    }
  }

  TransactionRequest? _buildPreviewTransaction({
    required IBITIVaultService vault,
    required String toAddress,
    required String amountStr,
    required BigInt atomicAmount,
  }) {
    final fromAddress = vault.activeAddress;
    if (fromAddress.isEmpty) return null;

    return TransactionRequest(
      type: TransactionType.send,
      fromAddress: fromAddress,
      toAddress: toAddress,
      tokenSymbol: _tokenSymbol,
      tokenContract: _isErc20 ? _selectedAsset!.address : null,
      amount: double.tryParse(amountStr.replaceAll(',', '.')),
      rawAmount: atomicAmount,
      tokenDecimals: _tokenDecimals,
      chainId: PrivyChainRegistry.getChain(vault.chainKey).evmChainId ?? 0,
      chainKey: vault.chainKey,
      sourceIntent: IntentData(
        type: IntentType.sendAsset,
        rawInput: 'wallet_send',
        toAddress: toAddress,
        amount: double.tryParse(amountStr.replaceAll(',', '.')),
        rawAmount: atomicAmount,
        tokenSymbol: _tokenSymbol,
        sourceTokenDecimals: _tokenDecimals,
      ),
    );
  }

  Future<void> _showPreviewSheet(AssistantResponse preview) async {
    final tx = preview.pendingTransaction!;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: TransactionPreviewCard(
              transaction: tx,
              explanation: preview.explanation!,
              policyResult: preview.policy!,
              rpcResult: preview.rpcSimulation!,
              executionPath: preview.executionPath!,
              onConfirm: () async {
                Navigator.of(sheetContext).pop();
                await _confirmPreview(tx, preview.executionPath!);
              },
              onCancel: () => Navigator.of(sheetContext).pop(),
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmPreview(
    TransactionRequest tx,
    ExecutionPath path,
  ) async {
    final t = LocalizationProvider.of(context);
    final authorized = await VaultUnlockScreen.requireAuth(context, forceSetup: true);
    if (!authorized) {
      return;
    }

    if (!mounted) return;
    setState(() => _isExecuting = true);

    try {
      final result =
          await GuardianExecutionController.instance.orchestrateConfirmation(
        tx,
        path,
      );

      if (!mounted) return;

      if (result.type == ResponseType.error || result.detail == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result.message),
          backgroundColor: GuardianColors.danger,
        ));
        return;
      }

      if (tx.chainId > 0 && result.detail!.startsWith('0x')) {
        TxStatusPoller.instance.start(
          txHash: result.detail!,
          chainId: tx.chainId,
          walletAddress: tx.fromAddress,
          operationLabel: tx.displaySummary,
          assetLabel: '${tx.amount ?? ''} ${tx.tokenSymbol ?? ''}'.trim(),
          onStatus: (_) {},
        );
      }

      final shortHash = result.detail!.length > 12
          ? '${result.detail!.substring(0, 12)}...'
          : result.detail!;

      final recipient = _addressController.text.trim();
      if (recipient.isNotEmpty &&
          !AddressBookService.instance.entries.any(
            (entry) => entry.address.toLowerCase() == recipient.toLowerCase(),
          )) {
        final label =
            'Recent ${recipient.substring(0, recipient.length > 6 ? 6 : recipient.length)}';
        AddressBookService.instance.add(label, recipient);
      }

      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '${t.t('walletSendSuccess', {'default': 'Sent!'})} $shortHash'),
        backgroundColor: GuardianColors.success,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.toString()),
        backgroundColor: GuardianColors.danger,
      ));
    } finally {
      if (mounted) setState(() => _isExecuting = false);
    }
  }

  // Known token logo URLs for quick visual identification
  static const _tokenLogos = <String, String>{
    'BNB': 'https://cryptologos.cc/logos/bnb-bnb-logo.png',
    'ETH': 'https://cryptologos.cc/logos/ethereum-eth-logo.png',
    'SOL': 'https://cryptologos.cc/logos/solana-sol-logo.png',
    'TRX': 'https://cryptologos.cc/logos/tron-trx-logo.png',
    'POL': 'https://cryptologos.cc/logos/polygon-matic-logo.png',
    'USDT': 'https://cryptologos.cc/logos/tether-usdt-logo.png',
    'USDC': 'https://cryptologos.cc/logos/usd-coin-usdc-logo.png',
    'BTC': 'https://cryptologos.cc/logos/bitcoin-btc-logo.png',
    // IBITI uses fallback letter icon — no remote logo
    'DOGE': 'https://cryptologos.cc/logos/dogecoin-doge-logo.png',
    'ADA': 'https://cryptologos.cc/logos/cardano-ada-logo.png',
    'DOT': 'https://cryptologos.cc/logos/polkadot-new-dot-logo.png',
    'LINK': 'https://cryptologos.cc/logos/chainlink-link-logo.png',
    'UNI': 'https://cryptologos.cc/logos/uniswap-uni-logo.png',
    'AAVE': 'https://cryptologos.cc/logos/aave-aave-logo.png',
    'ARB': 'https://cryptologos.cc/logos/arbitrum-arb-logo.png',
    'CAKE': 'https://cryptologos.cc/logos/pancakeswap-cake-logo.png',
    'DAI': 'https://cryptologos.cc/logos/multi-collateral-dai-dai-logo.png',
    'SHIB': 'https://cryptologos.cc/logos/shiba-inu-shib-logo.png',
    'PEPE': 'https://cryptologos.cc/logos/pepe-pepe-logo.png',
  };

  Widget _tokenIcon(String symbol, {double size = 20}) {
    // Check wallet assets for logo first
    final assets = VaultPortfolioListener.instance.summary?.allAssets ?? [];
    final walletAsset = assets.cast<WalletAsset?>().firstWhere(
        (a) =>
            a?.symbol.toUpperCase() == symbol.toUpperCase() &&
            a?.logoUrl != null,
        orElse: () => null);
    final url = walletAsset?.logoUrl ?? _tokenLogos[symbol.toUpperCase()];
    if (url != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size),
        child: Image.network(url,
            width: size,
            height: size,
            errorBuilder: (_, __, ___) => Icon(Icons.token_rounded,
                size: size, color: GuardianColors.textSecondary)),
      );
    }
    return Icon(Icons.token_rounded,
        size: size, color: GuardianColors.textSecondary);
  }

  void _openTokenMenu(BuildContext context) async {
    final chainKey = IBITIVaultService.instance.chainKey;
    final RenderBox button = context.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context);
    final RenderBox overlayBox =
        overlay.context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset(0, button.size.height),
            ancestor: overlayBox),
        button.localToGlobal(button.size.bottomRight(Offset.zero),
            ancestor: overlayBox),
      ),
      Offset.zero & overlayBox.size,
    );

    final assets = VaultPortfolioListener.instance.summary?.allAssets ?? [];
    final currentNative =
        PrivyChainRegistry.getChain(chainKey).nativeSymbol ?? 'ETH';

    // Collect all wallet asset symbols
    final walletSymbols = <String>{};
    for (final a in assets) {
      walletSymbols.add(a.symbol.toUpperCase());
    }

    // Add native tokens from ALL supported chains
    for (final chain in PrivyChainRegistry.supportedChains) {
      if (chain.nativeSymbol != null) {
        walletSymbols.add(chain.nativeSymbol!.toUpperCase());
      }
    }

    // IBITI is added only if it's actually in wallet holdings

    // Build menu items — current chain native first, then others sorted
    final sorted = walletSymbols.toList()..remove(currentNative.toUpperCase());
    sorted.sort();

    final items = <PopupMenuEntry<String>>[
      PopupMenuItem(
        value: currentNative,
        child: Row(children: [
          _tokenIcon(currentNative),
          const SizedBox(width: 10),
          Text(currentNative,
              style: GuardianTextStyles.bodyPrimary
                  .copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(width: 6),
          Text('(native)',
              style: GuardianTextStyles.caption
                  .copyWith(fontSize: 10, color: Colors.greenAccent)),
        ]),
      ),
      const PopupMenuDivider(height: 1),
    ];
    for (final sym in sorted) {
      items.add(PopupMenuItem(
        value: sym,
        child: Row(children: [
          _tokenIcon(sym),
          const SizedBox(width: 10),
          Text(sym, style: GuardianTextStyles.bodyPrimary),
        ]),
      ));
    }

    final selected = await showMenu<String>(
      context: context,
      position: position,
      items: items,
      color: const Color(0xFF141820),
      elevation: 12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    );

    if (selected != null) {
      if (selected == currentNative) {
        setState(() {
          _selectedAsset = null;
          _amountController.clear();
        });
      } else {
        final match = assets.cast<WalletAsset?>().firstWhere(
            (a) => a?.symbol.toUpperCase() == selected,
            orElse: () => null);
        if (match != null) {
          setState(() {
            _selectedAsset = match;
            _amountController.clear();
          });
        } else {
          setState(() {
            _selectedAsset = WalletAsset(
              name: selected,
              symbol: selected,
              address: 'registry',
              balance: 0,
              decimals: 18,
              priceUsd: 0,
              valueUsd: 0,
              chainId: 0,
            );
            _amountController.clear();
          });
        }
      }
    }
  }

  void _pasteFromClipboard() {
    Clipboard.getData('text/plain').then((data) {
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text(LocalizationService.instance
              .t('walletClipboardEmpty', {'default': 'Clipboard is empty'})),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF1A1D27),
        ));
        return;
      }
      // Parse EIP-681 / plain address
      String address = text;
      if (text.startsWith('ethereum:')) {
        address = text.replaceFirst('ethereum:', '').split('?').first;
      }
      if (mounted) {
        setState(() => _addressController.text = address);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text(LocalizationService.instance
              .t('walletAddressPasted', {'default': 'Address pasted'})),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF1A1D27),
          duration: const Duration(seconds: 1),
        ));
      }
    });
  }

  /// Opens a full-screen QR code scanner to capture an address.
  /// Requests camera permission at runtime before launching.
  Future<void> _openQrScanner(BuildContext ctx) async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
          content: Text('Camera permission is required for QR scanning'),
          behavior: SnackBarBehavior.floating,
        ));
      }
      return;
    }
    if (!ctx.mounted) return;
    bool hasPopped = false;
    Navigator.of(ctx, rootNavigator: true).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (scanCtx) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            title: const Text('Scan QR Code',
                style: TextStyle(color: Colors.white)),
            leading: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.of(scanCtx).pop(),
            ),
          ),
          body: MobileScanner(
            onDetect: (capture) {
              if (hasPopped) return;
              final barcodes = capture.barcodes;
              if (barcodes.isNotEmpty) {
                final raw = barcodes.first.rawValue ?? '';
                if (raw.isNotEmpty) {
                  hasPopped = true;
                  String address = raw;
                  if (raw.startsWith('ethereum:')) {
                    address =
                        raw.replaceFirst('ethereum:', '').split('?').first;
                  }
                  Navigator.of(scanCtx).pop();
                  if (mounted) {
                    setState(() => _addressController.text = address);
                  }
                }
              }
            },
          ),
        ),
      ),
    );
  }

  /// Returns an animated border decoration for the field at [fieldIndex].
  /// Glows bright accent when it's the currently highlighted field.
  BoxDecoration _fieldDecoration(int fieldIndex, {double radius = 14}) {
    final isActive = _highlightIndex == fieldIndex;
    return BoxDecoration(
      color: isActive
          ? GuardianColors.accent.withOpacity(0.07)
          : GuardianColors.surfaceElevated,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: isActive ? GuardianColors.accent : GuardianColors.glassBorder,
        width: isActive ? 2.5 : 1.0,
      ),
      boxShadow: isActive
          ? [
              BoxShadow(
                color: GuardianColors.accent.withOpacity(0.6),
                blurRadius: 20,
                spreadRadius: 2,
              )
            ]
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final vault = IBITIVaultService.instance;

    return ListenableBuilder(
      listenable: vault,
      builder: (context, _) {
        final chainKey = vault.chainKey;
        return GestureDetector(
          onTap: () {
            // Unfocus keyboard if tapped outside inputs
            FocusScope.of(context).unfocus();
          },
          child: Center(
            child: Padding(
              padding: EdgeInsets.only(
                  left: 12, right: 12, top: 40, bottom: 24 + bottomInset),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: double.infinity, // Almost full screen
                  constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height *
                          0.9), // Expand vertically
                  // Gradient border wrapper
                  padding: const EdgeInsets.all(2.0),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(26),
                    gradient: const LinearGradient(
                      colors: [
                        Color(0xFFE53935), // Red
                        Color(0xFFFF6F00), // Deep orange
                        Color(0xFFFFD600), // Gold
                        Color(0xFFFF6F00), // Deep orange
                        Color(0xFFE53935), // Red
                      ],
                      stops: [0.0, 0.25, 0.5, 0.75, 1.0],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                          color: const Color(0xFFE53935).withOpacity(0.3),
                          blurRadius: 40,
                          spreadRadius: 4),
                      BoxShadow(
                          color: const Color(0xFFFFD600).withOpacity(0.15),
                          blurRadius: 60,
                          spreadRadius: 8),
                      const BoxShadow(color: Colors.black87, blurRadius: 30),
                    ],
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF0C0F17),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // — Gradient Header —
                          Container(
                            padding: const EdgeInsets.fromLTRB(20, 16, 12, 14),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  GuardianColors.accent.withOpacity(0.12),
                                  Colors.transparent
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(24)),
                            ),
                            child: Row(
                              children: [
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    setState(() =>
                                        WalletSendModal.voiceGuideMuted =
                                            !WalletSendModal.voiceGuideMuted);
                                    SharedPreferences.getInstance().then((p) =>
                                        p.setBool(WalletSendModal._muteKey,
                                            WalletSendModal.voiceGuideMuted));
                                    if (WalletSendModal.voiceGuideMuted) {
                                      TtsService.instance.stop();
                                      _highlightTimer?.cancel();
                                      setState(() => _highlightIndex = -1);
                                    }
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: GuardianColors.accent
                                          .withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(
                                      WalletSendModal.voiceGuideMuted
                                          ? Icons.volume_off_rounded
                                          : Icons.volume_up_rounded,
                                      color: WalletSendModal.voiceGuideMuted
                                          ? Colors.white.withOpacity(0.3)
                                          : GuardianColors.accent,
                                      size: 22,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    t.t('walletSendViaVault',
                                        {'default': 'Send via Vault'}),
                                    style: GuardianTextStyles.headline.copyWith(
                                        fontSize: 20, letterSpacing: 0.3),
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () => Navigator.of(context).pop(),
                                  child: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.06),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: const Icon(Icons.close_rounded,
                                        color: GuardianColors.textSecondary,
                                        size: 18),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // — Body —
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // Token selector
                                Builder(
                                  builder: (ctx) => GestureDetector(
                                    onTap: () => _openTokenMenu(ctx),
                                    child: AnimatedContainer(
                                      duration:
                                          const Duration(milliseconds: 300),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 14, vertical: 12),
                                      decoration: _fieldDecoration(0),
                                      child: Row(
                                        children: [
                                          if (_selectedAsset?.logoUrl != null)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                  right: 8),
                                              child: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                child: Image.network(
                                                    _selectedAsset!.logoUrl!,
                                                    width: 22,
                                                    height: 22,
                                                    errorBuilder:
                                                        (_, __, ___) =>
                                                            const SizedBox()),
                                              ),
                                            ),
                                          Text(_tokenSymbol,
                                              style: GuardianTextStyles.caption
                                                  .copyWith(
                                                      color:
                                                          GuardianColors.accent,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      fontSize: 14)),
                                          const SizedBox(width: 6),
                                          Text('· ${chainKey.toUpperCase()}',
                                              style:
                                                  GuardianTextStyles.caption),
                                          const Spacer(),
                                          const Icon(
                                              Icons.keyboard_arrow_down_rounded,
                                              size: 18,
                                              color:
                                                  GuardianColors.textSecondary),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 18),
                                // Recipient
                                Text(
                                    t.t('walletSendRecipient',
                                        {'default': 'Recipient Address'}),
                                    style: GuardianTextStyles.caption
                                        .copyWith(fontSize: 12)),
                                const SizedBox(height: 6),
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 300),
                                  decoration: _fieldDecoration(1),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: _addressController,
                                          maxLines: null,
                                          minLines: 1,
                                          keyboardType: TextInputType.multiline,
                                          style: GuardianTextStyles.bodyPrimary
                                              .copyWith(
                                                  fontFamily: 'monospace',
                                                  fontSize: 12),
                                          decoration: InputDecoration(
                                            hintText: chainKey == 'tron'
                                                ? 'T...'
                                                : chainKey == 'solana'
                                                    ? '...(base58)'
                                                    : '0x...',
                                            filled: true,
                                            fillColor: Colors.transparent,
                                            border: InputBorder.none,
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                    horizontal: 14,
                                                    vertical: 12),
                                          ),
                                        ),
                                      ),
                                      // Contacts icon
                                      Material(
                                        color: Colors.transparent,
                                        child: InkWell(
                                          borderRadius:
                                              BorderRadius.circular(20),
                                          onTap: () {
                                            final entries = AddressBookService
                                                .instance.entries;
                                            showModalBottomSheet(
                                              context: context,
                                              useRootNavigator: true,
                                              backgroundColor:
                                                  const Color(0xFF141820),
                                              shape:
                                                  const RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.vertical(
                                                        top: Radius.circular(
                                                            20)),
                                              ),
                                              builder: (sheetCtx) => SafeArea(
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    const SizedBox(height: 12),
                                                    Container(
                                                        width: 40,
                                                        height: 4,
                                                        decoration: BoxDecoration(
                                                            color:
                                                                Colors.white24,
                                                            borderRadius:
                                                                BorderRadius
                                                                    .circular(
                                                                        2))),
                                                    const SizedBox(height: 16),
                                                    Padding(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                          horizontal: 20),
                                                      child: Row(
                                                        children: [
                                                          const Icon(
                                                              Icons
                                                                  .contacts_rounded,
                                                              color:
                                                                  GuardianColors
                                                                      .accent,
                                                              size: 22),
                                                          const SizedBox(
                                                              width: 10),
                                                          Text(
                                                              LocalizationService
                                                                  .instance
                                                                  .t(
                                                                      'walletAddressBook',
                                                                      {
                                                                    'default':
                                                                        'Address Book'
                                                                  }),
                                                              style: GuardianTextStyles
                                                                  .headline
                                                                  .copyWith(
                                                                      fontSize:
                                                                          18)),
                                                        ],
                                                      ),
                                                    ),
                                                    const SizedBox(height: 12),
                                                    if (entries.isEmpty)
                                                      Padding(
                                                        padding:
                                                            const EdgeInsets
                                                                .symmetric(
                                                                vertical: 32,
                                                                horizontal: 20),
                                                        child: Column(
                                                          children: [
                                                            Icon(
                                                                Icons
                                                                    .person_add_disabled_rounded,
                                                                size: 48,
                                                                color: Colors
                                                                    .white
                                                                    .withOpacity(
                                                                        0.15)),
                                                            const SizedBox(
                                                                height: 12),
                                                            Text(
                                                                LocalizationService
                                                                    .instance
                                                                    .t(
                                                                        'walletAddressBookEmpty',
                                                                        {
                                                                      'default':
                                                                          'No saved contacts yet'
                                                                    }),
                                                                style: GuardianTextStyles
                                                                    .caption
                                                                    .copyWith(
                                                                        fontSize:
                                                                            14,
                                                                        color: GuardianColors
                                                                            .textSecondary)),
                                                          ],
                                                        ),
                                                      )
                                                    else
                                                      ...entries
                                                          .map((e) => ListTile(
                                                                leading:
                                                                    const CircleAvatar(
                                                                  backgroundColor:
                                                                      Color(
                                                                          0xFF1E2230),
                                                                  child: Icon(
                                                                      Icons
                                                                          .person_outline_rounded,
                                                                      color: GuardianColors
                                                                          .accent,
                                                                      size: 20),
                                                                ),
                                                                title: Text(
                                                                    e.label,
                                                                    style: GuardianTextStyles
                                                                        .bodyPrimary),
                                                                subtitle: Text(
                                                                  e.address.length >
                                                                          16
                                                                      ? '${e.address.substring(0, 8)}...${e.address.substring(e.address.length - 6)}'
                                                                      : e.address,
                                                                  style: GuardianTextStyles
                                                                      .caption
                                                                      .copyWith(
                                                                          fontSize:
                                                                              11),
                                                                ),
                                                                onTap: () {
                                                                  Navigator.of(
                                                                          sheetCtx)
                                                                      .pop();
                                                                  setState(() =>
                                                                      _addressController
                                                                              .text =
                                                                          e.address);
                                                                },
                                                              )),
                                                    const SizedBox(height: 16),
                                                  ],
                                                ),
                                              ),
                                            );
                                          },
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 8, vertical: 10),
                                            child: Icon(Icons.contacts_rounded,
                                                color: GuardianColors.accent
                                                    .withOpacity(0.8),
                                                size: 20),
                                          ),
                                        ),
                                      ),
                                      // QR Scanner
                                      Material(
                                        color: Colors.transparent,
                                        child: InkWell(
                                          borderRadius:
                                              BorderRadius.circular(20),
                                          onTap: () => _openQrScanner(context),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 4, vertical: 10),
                                            child: Icon(
                                                Icons.qr_code_scanner_rounded,
                                                color: GuardianColors.accent
                                                    .withOpacity(0.7),
                                                size: 20),
                                          ),
                                        ),
                                      ),
                                      // Paste from clipboard
                                      Material(
                                        color: Colors.transparent,
                                        child: InkWell(
                                          borderRadius:
                                              BorderRadius.circular(20),
                                          onTap: _pasteFromClipboard,
                                          child: Padding(
                                            padding: const EdgeInsets.only(
                                                right: 8,
                                                left: 4,
                                                top: 10,
                                                bottom: 10),
                                            child: Icon(
                                                Icons.content_paste_rounded,
                                                color: GuardianColors.accent
                                                    .withOpacity(0.5),
                                                size: 18),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                const SizedBox(height: 8),
                                // Amount
                                Row(children: [
                                  Text(
                                      t.t('walletSendAmount',
                                          {'default': 'Amount'}),
                                      style: GuardianTextStyles.caption
                                          .copyWith(fontSize: 12)),
                                  const Spacer(),
                                  if (_selectedAsset != null)
                                    Text(
                                        'Balance: ${_selectedAsset!.balance.toStringAsFixed(4)} $_tokenSymbol',
                                        style: GuardianTextStyles.caption
                                            .copyWith(fontSize: 11)),
                                ]),
                                const SizedBox(height: 6),
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 300),
                                  decoration: _fieldDecoration(2),
                                  child: TextField(
                                    controller: _amountController,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                            decimal: true),
                                    style: GuardianTextStyles.headline
                                        .copyWith(fontSize: 22),
                                    decoration: InputDecoration(
                                      hintText: '0.00',
                                      filled: true,
                                      fillColor: Colors.transparent,
                                      border: InputBorder.none,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 14, vertical: 12),
                                      suffixText: _tokenSymbol,
                                      suffixStyle: GuardianTextStyles.caption,
                                      suffixIcon: _selectedAsset != null
                                          ? TextButton(
                                              onPressed: () => setState(() =>
                                                  _amountController.text =
                                                      _selectedAsset!.balance
                                                          .toStringAsFixed(6)),
                                              child: Text(
                                                  LocalizationService.instance
                                                      .t('btnMax'),
                                                  style: GuardianTextStyles
                                                      .caption
                                                      .copyWith(
                                                          color: GuardianColors
                                                              .accent,
                                                          fontWeight:
                                                              FontWeight.w800)),
                                            )
                                          : null,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 20),
                                // Send button — centered
                                Center(
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 300),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(100),
                                      gradient: LinearGradient(
                                        colors: _highlightIndex == 3
                                            ? [
                                                const Color(0xFF60A5FA),
                                                const Color(0xFF2563EB)
                                              ]
                                            : [
                                                const Color(0xFF3B82F6),
                                                const Color(0xFF1D4ED8)
                                              ],
                                      ),
                                      boxShadow: _highlightIndex == 3
                                          ? [
                                              BoxShadow(
                                                  color: GuardianColors.accent
                                                      .withOpacity(0.7),
                                                  blurRadius: 18,
                                                  spreadRadius: 2)
                                            ]
                                          : [
                                              const BoxShadow(
                                                  color: Colors.black38,
                                                  blurRadius: 6,
                                                  offset: Offset(0, 3))
                                            ],
                                    ),
                                    child: ElevatedButton.icon(
                                      onPressed:
                                          _isExecuting ? null : _previewSend,
                                      icon: _isExecuting
                                          ? const SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: Colors.white))
                                          : const Icon(Icons.send_rounded,
                                              size: 15, color: Colors.white),
                                      label: Text(
                                          t.t('walletSendExecuteTarget',
                                              {'default': 'SEND'}),
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w800,
                                              fontSize: 13,
                                              letterSpacing: 1.1)),
                                      style: ElevatedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 22, vertical: 11),
                                        backgroundColor: Colors.transparent,
                                        shadowColor: Colors.transparent,
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(100)),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ), // inner Container (dark bg)
                ), // outer Container (gradient border)
              ),
            ),
          ),
        );
      },
    );
  }
}

// в”Ђв”Ђ Token picker sheet в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ

class _TokenPickerSheet extends StatelessWidget {
  final String nativeSymbol;
  final List<WalletAsset> assets;
  final String? selectedAddress;
  final ValueChanged<WalletAsset> onSelected;
  final VoidCallback onNativeSelected;

  const _TokenPickerSheet({
    required this.nativeSymbol,
    required this.assets,
    required this.selectedAddress,
    required this.onSelected,
    required this.onNativeSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: GuardianColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            const Center(
              child: Padding(
                padding: EdgeInsets.only(top: 12, bottom: 8),
                child: SizedBox(
                  width: 40,
                  height: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: GuardianColors.glassBorder,
                      borderRadius: BorderRadius.all(Radius.circular(2)),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Text(
                  LocalizationService.instance.t('walletSelectTokenLabel'),
                  style: GuardianTextStyles.headline.copyWith(fontSize: 18)),
            ),
            const Divider(color: GuardianColors.glassBorder, height: 1),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.5,
              ),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  // Native token row
                  _TokenRow(
                    symbol: nativeSymbol,
                    name: 'Native Token',
                    logoUrl: null,
                    balance: null,
                    isSelected: selectedAddress == null,
                    onTap: () {
                      onNativeSelected();
                      Navigator.pop(context);
                    },
                  ),
                  if (assets.isNotEmpty)
                    const Divider(
                        color: GuardianColors.glassBorder,
                        height: 1,
                        indent: 20),
                  ...assets.where((a) => !a.isNative).map((a) => _TokenRow(
                        symbol: a.symbol,
                        name: a.name,
                        logoUrl: a.logoUrl,
                        balance: a.balance,
                        isSelected: selectedAddress == a.address,
                        onTap: () {
                          onSelected(a);
                          Navigator.pop(context);
                        },
                      )),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TokenRow extends StatelessWidget {
  final String symbol;
  final String name;
  final String? logoUrl;
  final double? balance;
  final bool isSelected;
  final VoidCallback onTap;

  const _TokenRow({
    required this.symbol,
    required this.name,
    required this.logoUrl,
    required this.balance,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        color: isSelected
            ? GuardianColors.accent.withOpacity(0.08)
            : Colors.transparent,
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: GuardianColors.surfaceElevated,
                borderRadius: BorderRadius.circular(18),
              ),
              child: logoUrl != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Image.network(
                        logoUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(
                            Icons.token_rounded,
                            color: GuardianColors.textTertiary,
                            size: 20),
                      ),
                    )
                  : const Icon(Icons.monetization_on_outlined,
                      color: GuardianColors.accent, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(symbol,
                      style: GuardianTextStyles.bodyPrimary
                          .copyWith(fontWeight: FontWeight.w700)),
                  Text(name, style: GuardianTextStyles.caption),
                ],
              ),
            ),
            if (balance != null)
              Text(
                balance!.toStringAsFixed(balance! < 1 ? 4 : 2),
                style: GuardianTextStyles.bodyPrimary,
              ),
            if (isSelected) ...[
              const SizedBox(width: 8),
              const Icon(Icons.check_rounded,
                  color: GuardianColors.accent, size: 18),
            ],
          ],
        ),
      ),
    );
  }
}
