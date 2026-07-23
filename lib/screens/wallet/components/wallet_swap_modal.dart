import 'dart:async';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ibiti_guardian/services/assistant/screen_context_service.dart';
import 'package:ibiti_guardian/utils/token_symbol_normalizer.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/models/assistant_directive.dart';
import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/swap_execution_plan.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/assistant/ui_command_bus.dart';
import 'package:ibiti_guardian/services/execution/guardian_execution_controller.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/config/chains.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

import 'package:ibiti_guardian/services/voice/voice_turn_controller.dart';

import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/market/token_discovery_service.dart';
import 'package:ibiti_guardian/services/voice/tts_service.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';

/// Native token logo URLs — shared by swap modal and token picker.
const _nativeTokenLogos = <String, String>{
  'BNB': 'https://cryptologos.cc/logos/bnb-bnb-logo.png',
  'ETH': 'https://cryptologos.cc/logos/ethereum-eth-logo.png',
  'SOL': 'https://cryptologos.cc/logos/solana-sol-logo.png',
  'TRX': 'https://cryptologos.cc/logos/tron-trx-logo.png',
  'MATIC': 'https://cryptologos.cc/logos/polygon-matic-logo.png',
  'POL': 'https://cryptologos.cc/logos/polygon-matic-logo.png',
  'AVAX': 'https://cryptologos.cc/logos/avalanche-avax-logo.png',
};

/// Swap flow state machine for inline execution.
enum _SwapFlowState {
  idle,
  quoting,
  preview,
  approving,
  awaitingApproval, // approve submitted, waiting for user to continue
  swapping,
  success,
  error
}

/// Premium inline Swap UI. Shows token pair, slippage control, fee breakdown.
/// Falls back to AI assistant for quote execution.
class WalletSwapModal extends StatefulWidget {
  final WalletAsset? initialFromAsset;
  final WalletAsset? initialToAsset;
  final List<WalletAsset> additionalAssets;

  const WalletSwapModal({
    super.key,
    this.initialFromAsset,
    this.initialToAsset,
    this.additionalAssets = const [],
  });

  static void show(
    BuildContext context, {
    WalletAsset? initialFromAsset,
    WalletAsset? initialToAsset,
    List<WalletAsset> additionalAssets = const [],
  }) {
    showDialog(
      context: context,
      useSafeArea: true,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: WalletSwapModal(
          initialFromAsset: initialFromAsset,
          initialToAsset: initialToAsset,
          additionalAssets: additionalAssets,
        ),
      ),
    );
  }

  @override
  State<WalletSwapModal> createState() => _WalletSwapModalState();

  /// When true, the tutorial voice guide is silenced on modal open.
  static bool voiceGuideMuted = false;
  static const _muteKey = 'swap_guide_muted';

  static Future<void> loadMuteState() async {
    final prefs = await SharedPreferences.getInstance();
    voiceGuideMuted = prefs.getBool(_muteKey) ?? false;
  }
}

class _WalletSwapModalState extends State<WalletSwapModal> {
  late WalletAsset? _fromAsset;
  WalletAsset? _toAsset;
  final _amountController = TextEditingController();
  StreamSubscription<UICommand>? _cmdSub;
  double _slippage = 0.5;
  bool _showSlippageOptions = false;

  /// Local swap chain — independent from global wallet active chain.
  late String _swapChainKey;

  // ── Inline swap execution state ──────────────────────────────────────────
  _SwapFlowState _flowState = _SwapFlowState.idle;
  AssistantResponse? _quoteResponse;
  SwapExecutionPlan? _swapPlan;
  String? _swapError;
  String? _txHash;

  /// Guide highlight index (-1 = inactive)
  int _highlightIndex = -1;
  Timer? _highlightTimer;

  /// Single-shot guard — prevents double guide execution on race/reopen.
  bool _guideStarted = false;

  /// Assets for the current swap chain only.
  List<WalletAsset> get _assets {
    return VaultPortfolioListener.instance.assetsForChain(_swapChainKey);
  }

  List<WalletAsset> get _pickerAssets {
    final merged = [..._assets];
    for (final extra in widget.additionalAssets) {
      if (extra.chainKey != _swapChainKey) continue;
      final exists = merged.any(
        (asset) =>
            asset.address.toLowerCase() == extra.address.toLowerCase() &&
            asset.chainId == extra.chainId,
      );
      if (!exists) merged.add(extra);
    }
    return merged;
  }

  double get _inputAmount =>
      double.tryParse(_amountController.text.replaceAll(',', '.')) ?? 0;

  double get _nativePriceUsd {
    for (final asset in _assets) {
      if (asset.isNative) return asset.priceUsd;
    }
    return 0;
  }

  double? get _estimatedOutput {
    if (_inputAmount <= 0 || _toAsset == null) return null;
    final fromPrice = _fromAsset?.priceUsd ?? _nativePriceUsd;
    final toPrice = _toAsset?.priceUsd ?? 0;
    if (fromPrice <= 0 || toPrice <= 0) return null;
    final grossUsd = _inputAmount * fromPrice;
    final output = grossUsd / toPrice;
    return output * (1 - (_slippage / 100));
  }

  double? get _estimatedOutputUsd {
    if (_estimatedOutput == null || _toAsset == null) return null;
    return _estimatedOutput! * _toAsset!.priceUsd;
  }

  double get _estimatedNetworkFeeUsd {
    final notional = (_fromAsset?.priceUsd ?? _nativePriceUsd) * _inputAmount;
    return (notional * 0.0025).clamp(0.35, 12.0);
  }

  double get _estimatedPriceImpactPct {
    if (_inputAmount <= 0) return 0.0;
    return (_inputAmount / 2500).clamp(0.02, 1.75);
  }

  String get _nativeSymbol =>
      PrivyChainRegistry.getChain(_swapChainKey).nativeSymbol ?? 'ETH';

  /// Chain-aware native token decimals.
  int get _nativeDecimals {
    switch (_swapChainKey) {
      case 'solana':
        return 9;
      case 'tron':
        return 6;
      default:
        return 18;
    }
  }

  /// Native token logo URL per chain.
  String? get _nativeLogoUrl => _nativeTokenLogos[_nativeSymbol];

  /// Returns the real swap provider name based on the swap chain.
  String get _routeProviderLabel {
    switch (_swapChainKey) {
      case 'solana':
        return 'Jupiter V2';
      case 'tron':
        return 'SunSwap V2';
      default:
        return '0x Router';
    }
  }

  @override
  void initState() {
    super.initState();
    _swapChainKey = IBITIVaultService.instance.chainKey;
    _fromAsset = widget.initialFromAsset;
    _toAsset = widget.initialToAsset;
    ScreenContextService.instance.setModal('wallet_swap');
    _publishTokenContext();
    final bus = UICommandBus.instance;
    final cachedAmount = bus.latestFieldValue('swap_amount');
    if (cachedAmount != null && cachedAmount.isNotEmpty) {
      _amountController.text = cachedAmount;
    }
    _applyTokenPayload(bus.latestPayload('swap_from_token'), true);
    _applyTokenPayload(bus.latestPayload('swap_to_token'), false);
    _cmdSub = bus.commands.listen(_handleCommand);
    final shouldQuote = bus.consumePendingAction('wallet_swap_quote') ||
        bus.consumePendingAction('swap_quote') ||
        bus.consumePendingAction('swap_preview');
    if (shouldQuote) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _executeInlineSwap();
        }
      });
    }

    // Single entry point for guide — runs once after first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _startGuideOnce());
  }

  @override
  void dispose() {
    TtsService.instance.stop();
    _highlightTimer?.cancel();
    ScreenContextService.instance.clearModal();
    _cmdSub?.cancel();
    _amountController.dispose();
    super.dispose();
  }

  /// Unified guide startup: load mute → wait for AI TTS → animation + narration.
  Future<void> _startGuideOnce() async {
    if (_guideStarted || !mounted) return;
    _guideStarted = true;

    await WalletSwapModal.loadMuteState();
    if (!mounted || WalletSwapModal.voiceGuideMuted) return;

    // Wait for any in-flight TTS (e.g. "Открываю окно обмена...") to finish.
    int waited = 0;
    while (TtsService.instance.isCurrentlySpeaking && waited < 15000) {
      await Future.delayed(const Duration(milliseconds: 300));
      waited += 300;
      if (!mounted || WalletSwapModal.voiceGuideMuted) return;
    }
    if (!mounted || WalletSwapModal.voiceGuideMuted) return;

    // Start animation and narration together — after AI speech ended.
    _startGuideAnimation();
    final lang =
        SettingsService.instance.settings.languageCode.trim().toLowerCase();
    final text = lang.startsWith('ru')
        ? 'Выберите токен для обмена и сумму, укажите токен получения, затем нажмите обмен.'
        : 'Select the token to swap and the amount, choose the destination token, then tap swap.';
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
      if (step > 2) {
        timer.cancel();
        if (mounted) setState(() => _highlightIndex = -1);
        return;
      }
      setState(() => _highlightIndex = step);
    });
  }

  /// Wraps a field widget with an animated glow border when guide is active.
  Widget _guideGlow({required int fieldIndex, required Widget child}) {
    final isActive = _highlightIndex == fieldIndex;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        boxShadow: isActive
            ? [
                BoxShadow(
                  color: GuardianColors.accent.withOpacity(0.45),
                  blurRadius: 16,
                  spreadRadius: 2,
                ),
              ]
            : [],
      ),
      child: child,
    );
  }

  /// Push current from/to token symbols to ScreenContextService
  /// so the voice fast-path can use them when user says "поставь 5"
  /// without naming a token.
  void _publishTokenContext() {
    final ctx = ScreenContextService.instance;
    ctx.setSelectedFromSymbol(
      _fromAsset?.symbol.toUpperCase() ?? _nativeSymbol,
    );
    ctx.setSelectedToSymbol(_toAsset?.symbol.toUpperCase());
  }

  void _handleCommand(UICommand cmd) {
    if (!mounted) return;
    if (cmd.type == UICommandType.fillField &&
        cmd.target == 'swap_amount' &&
        cmd.payload?['value'] != null) {
      setState(() {
        _amountController.text = cmd.payload!['value'].toString();
      });
      return;
    }
    if (cmd.type == UICommandType.selectToken &&
        cmd.target == 'swap_from_token') {
      setState(() => _applyTokenPayload(cmd.payload, true));
      return;
    }
    if (cmd.type == UICommandType.selectToken &&
        cmd.target == 'swap_to_token') {
      setState(() => _applyTokenPayload(cmd.payload, false));
      return;
    }
    if (cmd.type == UICommandType.executeAction &&
        (cmd.target == 'wallet_swap_quote' ||
            cmd.target == 'swap_quote' ||
            cmd.target == 'swap_preview')) {
      _executeInlineSwap();
      return;
    }
    if (cmd.type == UICommandType.executeAction &&
        cmd.target == 'swap_open_search') {
      // Voice requested search tab — open To picker on Search tab
      _pickToken(false);
    }
  }

  void _applyTokenPayload(Map<String, dynamic>? payload, bool isFrom) {
    final rawSymbol = payload?['symbol']?.toString();
    if (rawSymbol == null || rawSymbol.isEmpty) return;
    final symbol = TokenSymbolNormalizer.normalize(rawSymbol);
    final match = _pickerAssets.cast<WalletAsset?>().firstWhere(
          (asset) => asset?.symbol.toUpperCase() == symbol,
          orElse: () => null,
        );
    if (match == null) {
      return;
    }
    if (isFrom) {
      _fromAsset = match;
    } else {
      _toAsset = match;
    }
    _publishTokenContext();
  }

  void _swapDirection() {
    HapticFeedback.lightImpact();
    setState(() {
      final tmp = _fromAsset;
      _fromAsset = _toAsset;
      _toAsset = tmp;
      _amountController.clear();
      _publishTokenContext();
    });
  }

  /// Inline swap: get quote → show preview → user confirms → execute.
  Future<void> _executeInlineSwap() async {
    if (_inputAmount <= 0 || _toAsset == null) return;

    final fromSymbol = _fromAsset?.symbol ?? _nativeSymbol;
    final toSymbol = _toAsset?.symbol ?? _nativeSymbol;
    final fromAddress = _fromAsset?.address ?? '';
    final toAddress = _toAsset?.address ?? '';
    final srcDecimals = _fromAsset?.decimals ?? _nativeDecimals;
    final dstDecimals = _toAsset?.decimals ?? _nativeDecimals;

    // Non-EVM chains: native token address must be normalized for DEX APIs.
    // Solana: Jupiter requires wSOL mint, not '' or 'native'.
    // Tron: SunSwap detects native via empty or 'TRX', so 'native' must be
    //        converted to empty string (SunSwap uses WTRX internally).
    const wsolMint = 'So11111111111111111111111111111111111111112';

    String resolveNativeAddr(String addr, WalletAsset? asset) {
      final lower = addr.trim().toLowerCase();
      final isNative =
          lower.isEmpty || lower == 'native' || asset?.isNative == true;

      if (_swapChainKey == 'solana' && isNative) return wsolMint;
      if (_swapChainKey == 'tron' && isNative) return ''; // SunSwap handles it
      return addr;
    }

    final resolvedFromAddr = resolveNativeAddr(fromAddress, _fromAsset);
    final resolvedToAddr = resolveNativeAddr(toAddress, _toAsset);

    // Debug: trace exact values sent to execution pipeline
    print('[SwapModal] from=$fromSymbol addr=$resolvedFromAddr '
        'decimals=${_fromAsset?.decimals} (resolved=$srcDecimals)');
    print('[SwapModal] to=$toSymbol addr=$resolvedToAddr '
        'decimals=${_toAsset?.decimals} (resolved=$dstDecimals)');
    print('[SwapModal] amount=$_inputAmount chain=$_swapChainKey');

    // Build IntentData for the swap pipeline
    final intent = IntentData(
      type: IntentType.swapAsset,
      rawInput: 'swap $_inputAmount $fromSymbol to $toSymbol',
      amount: _inputAmount,
      sourceTokenSymbol: fromSymbol,
      sourceTokenAddress:
          resolvedFromAddr.isEmpty ? fromSymbol : resolvedFromAddr,
      targetTokenSymbol: toSymbol,
      targetTokenAddress: resolvedToAddr.isEmpty ? toSymbol : resolvedToAddr,
      sourceTokenDecimals: srcDecimals,
      targetTokenDecimals: dstDecimals,
      slippageBps: (_slippage * 100).toInt(),
      origin: IntentOrigin.wallet,
    );

    setState(() {
      _flowState = _SwapFlowState.quoting;
      _swapError = null;
      _txHash = null;
    });

    try {
      final response = await GuardianExecutionController.instance
          .requestSwapPreviewForChain(intent, _swapChainKey);

      if (!mounted) return;

      if (response.type == ResponseType.error) {
        setState(() {
          _flowState = _SwapFlowState.error;
          _swapError = response.message;
        });
        return;
      }

      if (response.swapPlan == null) {
        setState(() {
          _flowState = _SwapFlowState.error;
          _swapError = response.message;
        });
        return;
      }

      setState(() {
        _flowState = _SwapFlowState.preview;
        _quoteResponse = response;
        _swapPlan = response.swapPlan;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _flowState = _SwapFlowState.error;
        _swapError = e.toString();
      });
    }
  }

  /// User confirmed — execute the swap (approve if needed, then swap).
  Future<void> _confirmSwap() async {
    final plan = _swapPlan;
    final path = _quoteResponse?.executionPath ?? ExecutionPath.localProtected;
    if (plan == null) {
      print('[SwapModal] ❌ _confirmSwap called but _swapPlan is null');
      return;
    }

    print('[SwapModal] _confirmSwap called, '
        'requiresApproval=${plan.requiresApproval}, '
        'flowState=$_flowState');

    try {
      // Step 1: Approve if needed
      if (plan.requiresApproval &&
          _flowState != _SwapFlowState.awaitingApproval) {
        setState(() => _flowState = _SwapFlowState.approving);
        print('[SwapModal] Starting approve step...');
        final approveResult = await GuardianExecutionController.instance
            .orchestrateSwapStep(plan.approveStep!, path);
        if (!mounted) return;
        print('[SwapModal] Approve result: ${approveResult.type}');
        if (approveResult.type == ResponseType.error) {
          setState(() {
            _flowState = _SwapFlowState.error;
            _swapError = approveResult.message;
          });
          return;
        }
        // Approve submitted — wait for user to press "Continue swap"
        setState(() => _flowState = _SwapFlowState.awaitingApproval);
        return;
      }

      // Step 2: Swap
      setState(() => _flowState = _SwapFlowState.swapping);
      print('[SwapModal] Starting swap step...');
      final swapResult = await GuardianExecutionController.instance
          .orchestrateSwapStep(plan.swapStep, path);
      if (!mounted) return;

      if (swapResult.type == ResponseType.error) {
        setState(() {
          _flowState = _SwapFlowState.error;
          _swapError = swapResult.message;
        });
        return;
      }

      final hash = swapResult.detail;
      setState(() {
        _flowState = _SwapFlowState.success;
        _txHash = (hash != null && hash.isNotEmpty) ? hash : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _flowState = _SwapFlowState.error;
        _swapError = e.toString();
      });
    }
  }

  /// Summon green AI orb by starting voice session.
  /// The FloatingMicBubble managed by GuardianAppShell will appear
  /// automatically over the swap modal. No navigation, no new screens.
  void _openAiHelper() {
    final voice = VoiceTurnController.instance;
    if (!voice.isSessionActive) {
      voice.startSession();
    }
  }

  void _resetSwapFlow() {
    setState(() {
      _resetSwapFlowStateOnly();
    });
  }

  /// Resets swap flow state WITHOUT calling setState — for use inside
  /// a parent setState block (e.g. onChainSelected).
  void _resetSwapFlowStateOnly() {
    _flowState = _SwapFlowState.idle;
    _quoteResponse = null;
    _swapPlan = null;
    _swapError = null;
    _txHash = null;
  }

  void _pickToken(bool isFrom) {
    ScreenContextService.instance.setSwapField(isFrom ? 'from' : 'to');
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _SwapTokenPickerSheet(
        isFromPicker: isFrom,
        initialChainKey: _swapChainKey,
        showNetworkSelector: isFrom,
        onChainSelected: (chainKey) {
          if (chainKey != _swapChainKey) {
            setState(() {
              _swapChainKey = chainKey;
              _fromAsset = null;
              _toAsset = null;
              _amountController.clear();
              _resetSwapFlowStateOnly();
              _publishTokenContext();
            });
          }
        },
        onSelected: (asset) {
          setState(() {
            if (isFrom) {
              _fromAsset = asset;
              _toAsset = null;
              _amountController.clear(); // Clear only when FROM changes
              // Auto-suggest: IBITI → USDT, USDT → IBITI
              final sym = asset.symbol.toUpperCase();
              if (sym == 'IBITI') {
                final usdt = _pickerAssets.cast<WalletAsset?>().firstWhere(
                    (a) => a?.symbol.toUpperCase() == 'USDT',
                    orElse: () => null);
                if (usdt != null) _toAsset = usdt;
              } else if (sym == 'USDT') {
                final ibiti = _pickerAssets.cast<WalletAsset?>().firstWhere(
                    (a) => a?.symbol.toUpperCase() == 'IBITI',
                    orElse: () => null);
                if (ibiti != null) _toAsset = ibiti;
              }
            } else {
              _toAsset = asset;
            }
            _publishTokenContext();
          });
        },
        onNative: () {
          final nativeAsset = _assets
              .cast<WalletAsset?>()
              .firstWhere((a) => a?.isNative == true, orElse: () => null);
          final synthNative = nativeAsset ??
              WalletAsset(
                name: _nativeSymbol,
                symbol: _nativeSymbol,
                address: '',
                balance: 0,
                logoUrl: _nativeLogoUrl,
                priceUsd: _nativePriceUsd,
                valueUsd: 0,
                decimals: _nativeDecimals,
                isNative: true,
                chainId:
                    PrivyChainRegistry.getChain(_swapChainKey).evmChainId ?? 0,
                chainKey: _swapChainKey,
              );
          setState(() {
            if (isFrom) {
              _fromAsset = synthNative;
              _toAsset = null;
              _amountController.clear();
            } else {
              _toAsset = synthNative;
            }
            _publishTokenContext();
          });
        },
      ),
    ).whenComplete(() {
      ScreenContextService.instance.clearSwapField();
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final fromSymbol = _fromAsset?.symbol ?? _nativeSymbol;
    final toSymbol = _toAsset?.symbol ?? '—';
    final fromBalance = _fromAsset?.balance;
    final estimatedOutputUsd = _estimatedOutputUsd;

    return Padding(
      padding: EdgeInsets.only(
          left: 12,
          right: 12,
          top: 40,
          bottom: MediaQuery.of(context).padding.bottom + 16 + bottomInset),
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.88),
          decoration: BoxDecoration(
            color: const Color(0xFF0C0F17),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: GuardianColors.glassBorder,
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                  color: GuardianColors.accentGlow.withOpacity(0.08),
                  blurRadius: 40,
                  spreadRadius: 2),
              const BoxShadow(color: Colors.black54, blurRadius: 30),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Title ────────────────────────────────────────────────────
                  Row(
                    children: [
                      // Voice guide mute toggle
                      GestureDetector(
                        onTap: () async {
                          setState(() => WalletSwapModal.voiceGuideMuted =
                              !WalletSwapModal.voiceGuideMuted);
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setBool(WalletSwapModal._muteKey,
                              WalletSwapModal.voiceGuideMuted);
                          if (WalletSwapModal.voiceGuideMuted) {
                            TtsService.instance.stop();
                            _highlightTimer?.cancel();
                            setState(() => _highlightIndex = -1);
                          }
                        },
                        child: Icon(
                          WalletSwapModal.voiceGuideMuted
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          size: 22,
                          color: WalletSwapModal.voiceGuideMuted
                              ? GuardianColors.textTertiary
                              : GuardianColors.accent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(LocalizationService.instance.t('swapTitle'),
                            style: GuardianTextStyles.headline
                                .copyWith(fontSize: 22),
                            overflow: TextOverflow.ellipsis),
                      ),
                      // Slippage toggle (compact)
                      GestureDetector(
                        onTap: () => setState(
                            () => _showSlippageOptions = !_showSlippageOptions),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: GuardianColors.surfaceElevated,
                            borderRadius: BorderRadius.circular(10),
                            border:
                                Border.all(color: GuardianColors.glassBorder),
                          ),
                          child: Text('${_slippage}%',
                              style: GuardianTextStyles.caption.copyWith(
                                color: GuardianColors.textSecondary,
                                fontSize: 11,
                              )),
                        ),
                      ),
                    ],
                  ),

                  // ── Slippage picker ──────────────────────────────────────────
                  if (_showSlippageOptions) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [0.1, 0.5, 1.0, 2.0].map((s) {
                        final isActive = _slippage == s;
                        return Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() {
                              _slippage = s;
                              _showSlippageOptions = false;
                            }),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 160),
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              decoration: BoxDecoration(
                                color: isActive
                                    ? GuardianColors.accent
                                    : GuardianColors.surfaceElevated,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Center(
                                child: Text('$s%',
                                    style: GuardianTextStyles.caption.copyWith(
                                      color: isActive
                                          ? GuardianColors.background
                                          : GuardianColors.textSecondary,
                                      fontWeight: FontWeight.w700,
                                    )),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],

                  const SizedBox(height: 20),

                  // ── From token ───────────────────────────────────────────────
                  _guideGlow(
                    fieldIndex: 0,
                    child: _TokenAmountBox(
                      label: LocalizationService.instance.t('swapFrom'),
                      symbol: fromSymbol,
                      balance: fromBalance,
                      controller: _amountController,
                      onChanged: (_) => setState(() {}),
                      onPickToken: () => _pickToken(true),
                      onMax: fromBalance != null && fromBalance > 0
                          ? () {
                              HapticFeedback.lightImpact();
                              setState(() {
                                _amountController.text =
                                    fromBalance.toStringAsFixed(4);
                              });
                            }
                          : null,
                    ),
                  ),

                  // ── Swap direction button ────────────────────────────────────
                  Center(
                    child: GestureDetector(
                      onTap: _swapDirection,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 8),
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: GuardianColors.surfaceElevated,
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: GuardianColors.glassBorder),
                        ),
                        child: const Icon(Icons.swap_vert_rounded,
                            color: GuardianColors.accent),
                      ),
                    ),
                  ),

                  // ── To token ─────────────────────────────────────────────────
                  _guideGlow(
                    fieldIndex: 1,
                    child: _TokenAmountBox(
                      label: LocalizationService.instance.t('swapTo'),
                      symbol: toSymbol,
                      balance: null,
                      isReadOnly: true,
                      controller: null,
                      onPickToken: () => _pickToken(false),
                      onMax: null,
                      trailingValue: estimatedOutputUsd != null
                          ? '≈ \$${estimatedOutputUsd.toStringAsFixed(2)}'
                          : null,
                      hintText: _estimatedOutput?.toStringAsFixed(6),
                    ),
                  ),

                  // ── Route Tracker ──────────────────────────────────────────────
                  if (_inputAmount > 0 && _toAsset != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: GuardianColors.surfaceElevated,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: GuardianColors.glassBorder),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.route_outlined,
                              size: 16,
                              color: GuardianColors.success.withOpacity(0.9)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _routeProviderLabel,
                                  style: GuardianTextStyles.caption.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '$fromSymbol → $toSymbol',
                                  style: GuardianTextStyles.caption.copyWith(
                                    color: GuardianColors.textTertiary,
                                    fontSize: 11,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: GuardianColors.success.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'Best route',
                              style: TextStyle(
                                color: GuardianColors.success,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // ── Fee info pill ─────────────────────────────────────────────
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: GuardianColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: GuardianColors.glassBorder),
                    ),
                    child: Column(
                      children: [
                        _FeeRow(
                            label:
                                LocalizationService.instance.t('swapNetwork'),
                            value: _swapChainKey.toUpperCase()),
                        const SizedBox(height: 6),
                        _FeeRow(
                            label: LocalizationService.instance
                                .t('swapSlippageTol'),
                            value: '$_slippage%'),
                        const SizedBox(height: 6),
                        _FeeRow(
                          label:
                              LocalizationService.instance.t('swapNetworkFee'),
                          value:
                              '\$${_estimatedNetworkFeeUsd.toStringAsFixed(2)}',
                        ),
                        const SizedBox(height: 6),
                        _FeeRow(
                          label:
                              LocalizationService.instance.t('swapPriceImpact'),
                          value:
                              '${_estimatedPriceImpactPct.toStringAsFixed(2)}%',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Inline swap flow UI ──────────────────────────────────────
                  _buildSwapFlowSection(fromSymbol, toSymbol),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Inline swap flow section ─────────────────────────────────────────────

  Widget _buildSwapFlowSection(String fromSymbol, String toSymbol) {
    switch (_flowState) {
      case _SwapFlowState.idle:
        return Column(
          children: [
            _guideGlow(
              fieldIndex: 2,
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed:
                      _toAsset != null && _amountController.text.isNotEmpty
                          ? _executeInlineSwap
                          : null,
                  icon: const Icon(Icons.swap_horiz_rounded, size: 20),
                  label: Text(
                    LocalizationService.instance
                        .t('swapCta', {'default': 'Обмен'}),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: GuardianColors.accent,
                    foregroundColor: GuardianColors.background,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: _openAiHelper,
                icon: const Icon(Icons.smart_toy_outlined, size: 16),
                label: Text(
                  LocalizationService.instance
                      .t('swapAskAi', {'default': 'Спросить AI Ассистента'}),
                  style: GuardianTextStyles.caption
                      .copyWith(color: GuardianColors.textTertiary),
                ),
              ),
            ),
          ],
        );

      case _SwapFlowState.quoting:
        return _flowStatusCard(
          icon: Icons.search_rounded,
          label: LocalizationService.instance
              .t('swapQuoting', {'default': 'Получаю маршрут...'}),
          showSpinner: true,
        );

      case _SwapFlowState.preview:
        return _buildPreviewCard(fromSymbol, toSymbol);

      case _SwapFlowState.approving:
        return _flowStatusCard(
          icon: Icons.lock_open_rounded,
          label: LocalizationService.instance
              .t('swapApproving', {'default': 'Одобряю токен...'}),
          showSpinner: true,
        );

      case _SwapFlowState.awaitingApproval:
        return Column(
          children: [
            _flowStatusCard(
              icon: Icons.check_circle_outline_rounded,
              label: LocalizationService.instance.t('swapApproveSubmitted',
                  {'default': 'Approve отправлен. Подождите подтверждение.'}),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _confirmSwap,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: GuardianColors.accent,
                  foregroundColor: GuardianColors.background,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                child: Text(
                  LocalizationService.instance
                      .t('swapContinue', {'default': 'Продолжить обмен'}),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        );

      case _SwapFlowState.swapping:
        return _flowStatusCard(
          icon: Icons.swap_horiz_rounded,
          label: LocalizationService.instance
              .t('swapExecuting', {'default': 'Выполняю обмен...'}),
          showSpinner: true,
        );

      case _SwapFlowState.success:
        return _buildSuccessCard();

      case _SwapFlowState.error:
        return _buildErrorCard();
    }
  }

  Widget _flowStatusCard({
    required IconData icon,
    required String label,
    bool showSpinner = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: GuardianColors.surfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: GuardianColors.glassBorder),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (showSpinner) ...[
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: GuardianColors.accent,
              ),
            ),
            const SizedBox(width: 12),
          ] else ...[
            Icon(icon, size: 18, color: GuardianColors.accent),
            const SizedBox(width: 12),
          ],
          Flexible(
            child: Text(
              label,
              style: GuardianTextStyles.caption.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewCard(String fromSymbol, String toSymbol) {
    final plan = _swapPlan!;
    final quote = plan.quote;
    final targetDecimals = _toAsset?.decimals ?? 18;
    final minOut = _formatBigInt(quote.minOutputAmount, targetDecimals);
    final expectedOut =
        _formatBigInt(quote.expectedOutputAmount, targetDecimals);
    final targetSym = _toAsset?.symbol ?? toSymbol;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: GuardianColors.surfaceElevated,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: GuardianColors.accent.withOpacity(0.3)),
          ),
          child: Column(
            children: [
              _FeeRow(
                label: 'Provider',
                value: quote.providerName,
              ),
              const SizedBox(height: 6),
              _FeeRow(
                label: LocalizationService.instance
                    .t('swapExpected', {'default': 'Expected'}),
                value: '$expectedOut $targetSym',
              ),
              const SizedBox(height: 6),
              _FeeRow(
                label: LocalizationService.instance
                    .t('swapMinReceived', {'default': 'Min received'}),
                value: '$minOut $targetSym',
              ),
              const SizedBox(height: 6),
              _FeeRow(
                label: LocalizationService.instance.t('swapSlippageTol'),
                value: '$_slippage%',
              ),
              if (quote.priceImpactPct > 0) ...[
                const SizedBox(height: 6),
                _FeeRow(
                  label: LocalizationService.instance.t('swapPriceImpact'),
                  value: '${quote.priceImpactPct.toStringAsFixed(2)}%',
                ),
              ],
              if (plan.requiresApproval) ...[
                const SizedBox(height: 6),
                _FeeRow(
                  label: 'Steps',
                  value: '1. Approve → 2. Swap',
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _confirmSwap,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: GuardianColors.success,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
            child: Text(
              LocalizationService.instance
                  .t('swapConfirm', {'default': 'Подтвердить обмен'}),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _resetSwapFlow,
          child: Text(
            LocalizationService.instance.t('swapCancel', {'default': 'Отмена'}),
            style: GuardianTextStyles.caption
                .copyWith(color: GuardianColors.textTertiary),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccessCard() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: GuardianColors.success.withOpacity(0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: GuardianColors.success.withOpacity(0.3)),
          ),
          child: Column(
            children: [
              const Icon(Icons.check_circle_rounded,
                  color: GuardianColors.success, size: 36),
              const SizedBox(height: 8),
              Text(
                LocalizationService.instance
                    .t('swapSuccess', {'default': 'Обмен выполнен'}),
                style: GuardianTextStyles.bodyPrimary.copyWith(
                  fontWeight: FontWeight.w700,
                  color: GuardianColors.success,
                ),
              ),
              if (_txHash != null && _txHash!.length > 10) ...[
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: () async {
                    final explorerUrl =
                        ChainConfig.getTxUrl(_swapChainKey, _txHash!);
                    if (explorerUrl != null) {
                      // Open explorer in external browser
                      final uri = Uri.tryParse(explorerUrl);
                      if (uri != null) {
                        await launchUrl(uri,
                            mode: LaunchMode.externalApplication);
                        return;
                      }
                    }
                    // Fallback: copy hash if no explorer URL
                    Clipboard.setData(ClipboardData(text: _txHash!));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('TX hash copied'),
                        duration: const Duration(seconds: 2),
                        backgroundColor: GuardianColors.surface,
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'TX: ${_txHash!.substring(0, 10)}...',
                        style: GuardianTextStyles.caption.copyWith(
                          color: GuardianColors.accent,
                          decoration: TextDecoration.underline,
                          decorationColor:
                              GuardianColors.accent.withOpacity(0.5),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.open_in_new_rounded,
                          size: 12,
                          color: GuardianColors.accent.withOpacity(0.7)),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () => Navigator.pop(context),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              side: const BorderSide(color: GuardianColors.glassBorder),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
            child: Text(
              LocalizationService.instance
                  .t('btnClose', {'default': 'Закрыть'}),
              style: GuardianTextStyles.caption
                  .copyWith(color: GuardianColors.textSecondary),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorCard() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: GuardianColors.danger.withOpacity(0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: GuardianColors.danger.withOpacity(0.3)),
          ),
          child: Row(
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: GuardianColors.danger, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _swapError ?? 'Unknown error',
                  style: GuardianTextStyles.caption
                      .copyWith(color: GuardianColors.danger, height: 1.3),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _resetSwapFlow,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: GuardianColors.glassBorder),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(
                  LocalizationService.instance
                      .t('swapRetry', {'default': 'Повторить'}),
                  style: GuardianTextStyles.caption
                      .copyWith(color: GuardianColors.textSecondary),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextButton(
                onPressed: _openAiHelper,
                child: Text(
                  LocalizationService.instance
                      .t('swapAskAi', {'default': 'Спросить AI'}),
                  style: GuardianTextStyles.caption
                      .copyWith(color: GuardianColors.accent),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Format BigInt amount to human-readable string.
  static String _formatBigInt(BigInt raw, int decimals) {
    if (raw == BigInt.zero) return '0';
    final divisor = BigInt.from(10).pow(decimals);
    final whole = raw ~/ divisor;
    final frac = (raw % divisor).toString().padLeft(decimals, '0');
    final trimmed = frac.length > 6 ? frac.substring(0, 6) : frac;
    return '$whole.${trimmed.replaceAll(RegExp(r'0+$'), '').padRight(2, '0')}';
  }
}

// ── Token Amount Box ──────────────────────────────────────────────────────────

class _TokenAmountBox extends StatelessWidget {
  final String label;
  final String symbol;
  final double? balance;
  final bool isReadOnly;
  final TextEditingController? controller;
  final VoidCallback onPickToken;
  final VoidCallback? onMax;
  final String? trailingValue;
  final String? hintText;
  final ValueChanged<String>? onChanged;

  const _TokenAmountBox({
    required this.label,
    required this.symbol,
    this.balance,
    this.isReadOnly = false,
    this.controller,
    required this.onPickToken,
    this.onMax,
    this.trailingValue,
    this.hintText,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: GuardianColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: GuardianColors.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(label,
                    style: GuardianTextStyles.caption
                        .copyWith(color: Colors.white70),
                    overflow: TextOverflow.ellipsis),
              ),
              if (balance != null) ...[
                const SizedBox(width: 8),
                Text(
                  LocalizationService.instance.t('swapBalance',
                      {'b': balance!.toStringAsFixed(4), 'sym': symbol}),
                  style: GuardianTextStyles.caption
                      .copyWith(color: GuardianColors.textSecondary),
                ),
              ],
              if (trailingValue != null) ...[
                const SizedBox(width: 8),
                Text(
                  trailingValue!,
                  style: GuardianTextStyles.caption.copyWith(
                    color: Colors.white.withOpacity(0.70),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (!isReadOnly && controller != null)
                Expanded(
                  child: TextField(
                    controller: controller,
                    onChanged: onChanged,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w900),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: hintText ?? '0.00',
                      hintStyle: TextStyle(
                          color: Colors.white.withOpacity(0.45),
                          fontSize: 28,
                          fontWeight: FontWeight.w900),
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                )
              else
                Expanded(
                  child: Text(
                    hintText ?? '—',
                    style: TextStyle(
                        color: hintText != null && hintText != '—'
                            ? Colors.white
                            : Colors.white.withOpacity(0.45),
                        fontSize: 28,
                        fontWeight: FontWeight.w900),
                  ),
                ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: onPickToken,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: GuardianColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: GuardianColors.glassBorder),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(symbol,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(width: 6),
                      const Icon(Icons.keyboard_arrow_down_rounded,
                          size: 16, color: GuardianColors.textSecondary),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (onMax != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: onMax,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: GuardianColors.accent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(LocalizationService.instance.t('btnMax'),
                      style: GuardianTextStyles.caption.copyWith(
                          color: GuardianColors.accent,
                          fontWeight: FontWeight.w800)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FeeRow extends StatelessWidget {
  final String label;
  final String value;
  const _FeeRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label,
            style: GuardianTextStyles.caption.copyWith(color: Colors.white70)),
        const Spacer(),
        Text(value,
            style: GuardianTextStyles.caption
                .copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

// ── Swap Token Picker Sheet (3 tabs: Wallet / Popular / Search) ───────────────

class _SwapTokenPickerSheet extends StatefulWidget {
  final bool isFromPicker;
  final ValueChanged<WalletAsset> onSelected;
  final VoidCallback onNative;

  /// Initial chain key — picker manages its own copy internally.
  final String initialChainKey;

  /// If true, shows network selector chips (FROM picker).
  final bool showNetworkSelector;

  /// Called with the final chain key when user selects a token/native.
  /// Only fires on actual selection, NOT on chip browsing.
  final ValueChanged<String>? onChainSelected;

  const _SwapTokenPickerSheet({
    required this.isFromPicker,
    required this.onSelected,
    required this.onNative,
    required this.initialChainKey,
    this.showNetworkSelector = false,
    this.onChainSelected,
  });

  @override
  State<_SwapTokenPickerSheet> createState() => _SwapTokenPickerSheetState();
}

class _SwapTokenPickerSheetState extends State<_SwapTokenPickerSheet> {
  final _searchController = TextEditingController();
  List<TokenDiscoveryResult> _searchResults = [];
  bool _isSearching = false;
  String? _searchError;
  Timer? _debounce;

  List<TokenDiscoveryResult>? _popularCache;

  /// Picker-local chain key — changes without touching parent state.
  late String _localChainKey;

  @override
  void initState() {
    super.initState();
    _localChainKey = widget.initialChainKey;
    // Listen for background asset fetches (Tron/Solana on-demand loading)
    VaultPortfolioListener.instance.addListener(_onPortfolioUpdate);
  }

  void _onPortfolioUpdate() {
    if (mounted) setState(() {});
  }

  /// Resolve wallet assets for the current picker chain.
  List<WalletAsset> get _walletAssets {
    return VaultPortfolioListener.instance.assetsForChain(_localChainKey);
  }

  String get _nativeSymbol =>
      PrivyChainRegistry.getChain(_localChainKey).nativeSymbol ?? 'ETH';

  int get _nativeDecimals {
    switch (_localChainKey) {
      case 'solana':
        return 9;
      case 'tron':
        return 6;
      default:
        return 18;
    }
  }

  void _onChipTap(String chainKey) {
    if (chainKey == _localChainKey) return;
    setState(() {
      _localChainKey = chainKey;
      _popularCache = null;
      _searchController.clear();
      _searchResults = [];
      _searchError = null;
    });
  }

  @override
  void dispose() {
    VaultPortfolioListener.instance.removeListener(_onPortfolioUpdate);
    _searchController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
        _searchError = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _performSearch(query.trim());
    });
  }

  Future<void> _performSearch(String query) async {
    setState(() {
      _isSearching = true;
      _searchError = null;
    });

    try {
      List<TokenDiscoveryResult> results;
      final isContractAddress = _isContractAddress(query);
      if (isContractAddress) {
        // Contract/mint address lookup
        final result =
            await TokenDiscoveryService.instance.resolveByAddress(query);
        results = result != null ? [result] : [];
        if (results.isEmpty) {
          _searchError = LocalizationService.instance.t(
            'swapTokenNotFound',
            {'default': 'Token not found or network not supported'},
          );
        }
      } else {
        results = await TokenDiscoveryService.instance.resolve(query);
      }

      if (mounted) {
        setState(() {
          _searchResults = results;
          _isSearching = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSearching = false;
          _searchError = e.toString();
        });
      }
    }
  }

  /// Chain-aware contract address detection.
  bool _isContractAddress(String query) {
    switch (_localChainKey) {
      case 'solana':
        // SPL mint: base58, 32-44 chars, no 0x prefix
        return query.length >= 32 &&
            query.length <= 44 &&
            !query.startsWith('0x') &&
            RegExp(r'^[1-9A-HJ-NP-Za-km-z]+$').hasMatch(query);
      case 'tron':
        // TRC20: T prefix, 34 chars base58check
        return query.startsWith('T') && query.length == 34;
      default:
        // EVM: 0x prefix, 42 chars hex
        return query.startsWith('0x') && query.length >= 42;
    }
  }

  String _searchHintForChain() {
    final l = LocalizationService.instance;
    switch (_localChainKey) {
      case 'solana':
        return l.t('swapSearchHintSolana',
            {'default': 'Symbol, name, or SPL mint address'});
      case 'tron':
        return l.t('swapSearchHintTron',
            {'default': 'Symbol, name, or TRC20 contract (T...)'});
      default:
        return l.t('swapSearchHintEvm',
            {'default': 'Symbol, name, or 0x contract address'});
    }
  }

  void _selectDiscoveryResult(TokenDiscoveryResult result) {
    // Convert to WalletAsset with real chain context
    final contractAddr = result.contractAddress;
    if (contractAddr == null || contractAddr.isEmpty) return;

    final chain = PrivyChainRegistry.getChain(_localChainKey);
    final asset = WalletAsset(
      name: result.name,
      symbol: result.symbol,
      address: contractAddr,
      balance: 0,
      decimals: result.decimals,
      priceUsd: result.priceUsd ?? 0,
      valueUsd: 0,
      chainId: chain.evmChainId ?? 0,
      chainKey: _localChainKey,
      logoUrl: result.logoUrl,
    );
    widget.onChainSelected?.call(_localChainKey);
    widget.onSelected(asset);
    Navigator.pop(context);
  }

  List<TokenDiscoveryResult> get _popular {
    if (_popularCache != null) return _popularCache!;
    _popularCache =
        TokenDiscoveryService.instance.getPopularTokens(_localChainKey);
    return _popularCache!;
  }

  // ── Network chip labels ───────────────────────────────────────────────────
  static const _chainLabels = <String, String>{
    'eth': 'ETH',
    'bsc': 'BNB',
    'base': 'BASE',
    'arbitrum': 'ARB',
    'polygon': 'POL',
    'solana': 'SOL',
    'tron': 'TRX',
  };

  @override
  Widget build(BuildContext context) {
    final chainInfo = PrivyChainRegistry.getChain(_localChainKey);
    final hasSearch = _searchController.text.trim().isNotEmpty;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.80,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF0C0F17),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Handle ──
            const Center(
              child: Padding(
                padding: EdgeInsets.only(top: 12, bottom: 4),
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
            // ── Title + chain badge ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Row(
                children: [
                  Text(
                    LocalizationService.instance
                        .t('swapSelectToken', {'default': 'Select token'}),
                    style: GuardianTextStyles.headline.copyWith(fontSize: 18),
                  ),
                  const Spacer(),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: GuardianColors.accent.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      chainInfo.displayName,
                      style: const TextStyle(
                        color: GuardianColors.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // ── Network selector chips (FROM picker only) ──
            if (widget.showNetworkSelector) _buildNetworkChips(),
            // ── Search ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _searchController,
                onChanged: _onSearchChanged,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: _searchHintForChain(),
                  hintStyle: const TextStyle(
                      color: GuardianColors.textSecondary, fontSize: 13),
                  prefixIcon: const Icon(Icons.search_rounded,
                      color: GuardianColors.textSecondary, size: 20),
                  filled: true,
                  fillColor: GuardianColors.surfaceElevated,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ),
            // ── Content ──
            Expanded(
              child: hasSearch ? _buildSearchResults() : _buildDefaultList(),
            ),
          ],
        ),
      ),
    );
  }

  /// Horizontal scrollable network chips.
  Widget _buildNetworkChips() {
    final chains = PrivyChainRegistry.supportedChains;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: chains.map((chain) {
            final isSelected = chain.chainKey == _localChainKey;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: GestureDetector(
                onTap: () {
                  if (!isSelected) {
                    _onChipTap(chain.chainKey);
                  }
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? GuardianColors.accent.withOpacity(0.18)
                        : GuardianColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isSelected
                          ? GuardianColors.accent
                          : Colors.transparent,
                      width: 1.2,
                    ),
                  ),
                  child: Text(
                    _chainLabels[chain.chainKey] ??
                        chain.chainKey.toUpperCase(),
                    style: TextStyle(
                      color: isSelected
                          ? GuardianColors.accent
                          : GuardianColors.textSecondary,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildDefaultList() {
    final popular = _popular;
    final assets = _walletAssets;
    // Exclude verified tokens that already appear in "Your tokens"
    final walletSymbols = assets.map((a) => a.symbol.toUpperCase()).toSet();
    final filteredPopular = popular
        .where((t) => !walletSymbols.contains(t.symbol.toUpperCase()))
        .toList();
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        // ── Section: Your tokens ──
        _sectionHeader(LocalizationService.instance
            .t('swapYourTokens', {'default': 'Your tokens'})),
        // Native token
        _TokenListTile(
          symbol: _nativeSymbol,
          name: LocalizationService.instance
              .t('swapNativeToken', {'default': 'Native token'}),
          logoUrl: _nativeTokenLogos[_nativeSymbol],
          onTap: () {
            widget.onChainSelected?.call(_localChainKey);
            widget.onNative();
            Navigator.pop(context);
          },
        ),
        // Wallet assets
        ...assets.where((a) => !a.isNative).map(
              (a) => _TokenListTile(
                symbol: a.symbol,
                name: a.name,
                subtitle:
                    '${a.balance.toStringAsFixed(4)} · \$${a.valueUsd.toStringAsFixed(2)}',
                logoUrl: a.logoUrl,
                onTap: () {
                  widget.onChainSelected?.call(_localChainKey);
                  widget.onSelected(a);
                  Navigator.pop(context);
                },
              ),
            ),
        if (assets.where((a) => !a.isNative).isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              LocalizationService.instance.t('swapNoWalletTokens',
                  {'default': 'No other tokens in wallet on this network'}),
              style: GuardianTextStyles.caption
                  .copyWith(color: GuardianColors.textTertiary),
              textAlign: TextAlign.center,
            ),
          ),
        // ── Section: Verified ──
        if (filteredPopular.isNotEmpty) ...[
          const SizedBox(height: 8),
          _sectionHeader(LocalizationService.instance
              .t('swapVerifiedTokens', {'default': 'Verified tokens'})),
          ...filteredPopular.map(
            (t) => _TokenListTile(
              symbol: t.symbol,
              name: t.name,
              subtitle: t.priceUsd != null
                  ? '\$${t.priceUsd!.toStringAsFixed(4)}'
                  : null,
              logoUrl: t.logoUrl,
              badge: LocalizationService.instance
                  .t('swapBadgeVerified', {'default': 'Verified'}),
              isVerified: true,
              onTap: () => _selectDiscoveryResult(t),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSearchResults() {
    if (_isSearching) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: GuardianColors.accent,
          ),
        ),
      );
    }
    if (_searchError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _searchError!,
            style: GuardianTextStyles.caption
                .copyWith(color: GuardianColors.danger),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_searchResults.isEmpty) {
      return Center(
        child: Text(
          LocalizationService.instance
              .t('swapNoResults', {'default': 'No tokens found'}),
          style: GuardianTextStyles.caption
              .copyWith(color: GuardianColors.textSecondary),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: _searchResults
          .map(
            (r) => _TokenListTile(
              symbol: r.symbol,
              name: r.name,
              subtitle: r.hasContract
                  ? (r.priceUsd != null
                      ? '\$${r.priceUsd!.toStringAsFixed(4)}'
                      : r.contractAddress != null
                          ? '${r.contractAddress!.substring(0, 8)}...'
                          : null)
                  : LocalizationService.instance.t(
                      'swapNoContract',
                      {'default': 'No contract address'},
                    ),
              logoUrl: r.logoUrl,
              badge: r.source == 'holdings'
                  ? LocalizationService.instance
                      .t('swapBadgeWallet', {'default': 'Wallet'})
                  : r.source == 'registry'
                      ? LocalizationService.instance
                          .t('swapBadgeVerified', {'default': 'Verified'})
                      : r.source == 'onchain'
                          ? LocalizationService.instance
                              .t('swapBadgeOnChain', {'default': 'On-chain'})
                          : null,
              isVerified: r.source == 'registry',
              enabled: r.hasContract,
              onTap: r.hasContract ? () => _selectDiscoveryResult(r) : null,
            ),
          )
          .toList(),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Text(
        title.toUpperCase(),
        style: GuardianTextStyles.caption.copyWith(
          color: GuardianColors.textTertiary,
          fontWeight: FontWeight.w700,
          fontSize: 10,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

// ── Shared token list tile ──────────────────────────────────────────────────────

class _TokenListTile extends StatelessWidget {
  final String symbol;
  final String name;
  final String? subtitle;
  final String? logoUrl;
  final String? badge;
  final Widget? iconWidget;
  final bool enabled;
  final bool isVerified;
  final VoidCallback? onTap;

  const _TokenListTile({
    required this.symbol,
    required this.name,
    this.subtitle,
    this.logoUrl,
    this.badge,
    this.iconWidget,
    this.enabled = true,
    this.isVerified = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: ListTile(
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: GuardianColors.surfaceElevated,
            borderRadius: BorderRadius.circular(18),
          ),
          child: iconWidget ??
              (logoUrl != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Image.network(
                        logoUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.token_rounded,
                          color: GuardianColors.textTertiary,
                          size: 20,
                        ),
                      ),
                    )
                  : const Icon(Icons.token_rounded,
                      color: GuardianColors.textTertiary, size: 20)),
        ),
        title: Row(
          children: [
            Text(
              symbol,
              style: GuardianTextStyles.bodyPrimary
                  .copyWith(fontWeight: FontWeight.w700),
            ),
            if (badge != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isVerified
                      ? Colors.greenAccent.withOpacity(0.15)
                      : GuardianColors.accent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  badge!,
                  style: TextStyle(
                    color:
                        isVerified ? Colors.greenAccent : GuardianColors.accent,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
        subtitle: subtitle != null
            ? Text(subtitle!,
                style: GuardianTextStyles.caption
                    .copyWith(color: GuardianColors.textSecondary))
            : Text(name,
                style: GuardianTextStyles.caption
                    .copyWith(color: GuardianColors.textSecondary)),
        onTap: enabled ? onTap : null,
      ),
    );
  }
}
