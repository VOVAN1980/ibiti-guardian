import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';
import 'package:ibiti_guardian/widgets/ai_core_widget.dart';
import 'package:ibiti_guardian/widgets/transaction_preview_card.dart';
import 'package:ibiti_guardian/widgets/swap_preview_card.dart';
import 'package:ibiti_guardian/widgets/tx_status_card.dart';
import 'package:ibiti_guardian/services/audio_manager.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/models/tx_status.dart';
import 'package:ibiti_guardian/services/intents/intent_parser.dart';
import 'package:ibiti_guardian/services/assistant/guardian_assistant_service.dart';
import 'package:ibiti_guardian/models/assistant_response.dart';
import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/models/execution_path.dart';
import 'package:ibiti_guardian/models/rpc_simulation_result.dart';
import 'package:ibiti_guardian/services/execution/guardian_execution_controller.dart';
import 'package:ibiti_guardian/services/execution/tx_status_poller.dart';
import 'package:ibiti_guardian/screens/vault/vault_unlock_screen.dart';
import 'package:ibiti_guardian/services/policy/guardian_policy_engine.dart';
import 'package:ibiti_guardian/services/automation/automation_engine.dart'; // AutomationTelemetryBus
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/assistant/language_detector.dart';
import 'package:ibiti_guardian/screens/security/guardian_control_screen.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/models/app_intent.dart';
import 'package:ibiti_guardian/services/intents/intent_prompt_mapper.dart';
import 'dart:async';

enum _MessageRole { user, assistant }

class _ChatMessage {
  final String text;
  final _MessageRole role;
  final ResponseType? responseType;
  final String? detail;
  final AssistantResponse? fullResponse;

  // Phase 10: tx status feedback
  final String? txHash;
  final int? txChainId;
  final Stream<TxStatusEvent>? txStatusStream;
  final TxStatusEvent? txInitialEvent;

  _ChatMessage({
    required this.text,
    required this.role,
    this.responseType,
    this.detail,
    this.fullResponse,
    this.txHash,
    this.txChainId,
    this.txStatusStream,
    this.txInitialEvent,
  });

  bool get isPreview =>
      responseType == ResponseType.preview &&
      fullResponse?.pendingTransaction != null;

  bool get isSwapPreview => isPreview && (fullResponse?.isSwapPreview ?? false);

  /// True when this message carries a live tx status card.
  bool get isTxStatus => txHash != null && txStatusStream != null;
}

enum _AssistantLoadType { instant, light, heavy }

class AssistantChatScreen extends StatefulWidget {
  final VoidCallback onOpenVoice;

  /// Optional pre-filled plain-text prompt — sent automatically after welcome.
  final String? initialPrompt;

  /// Optional structured intent — converted to a human prompt via
  /// [IntentPromptMapper] before sending. Takes priority over [initialPrompt].
  final AppIntent? initialIntent;

  const AssistantChatScreen({
    super.key,
    required this.onOpenVoice,
    this.initialPrompt,
    this.initialIntent,
  });

  @override
  State<AssistantChatScreen> createState() => _AssistantChatScreenState();
}

class _AssistantChatScreenState extends State<AssistantChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _assistant = GuardianAssistantService.instance;
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  final List<_ChatMessage> _messages = [];
  // Voice output is handled by the Voice Screen via VoiceTurnController.

  bool _isThinking = false;
  String _thinkingText = "Thinking...";
  AICoreState _coreState = AICoreState.idle;

  /// Last detected user language — kept across messages for voice consistency.
  /// Updated on every user message. Falls back to 'en'.
  String _currentLang = 'en';

  static const _quickCommandKeys = [
    'cmdAnyRisks',
    'cmdScan',
    'cmdShowBalance',
    'cmdMyAddress',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _messages.isEmpty) {
        _addMessage(_ChatMessage(
          text: LocalizationService.instance.t('assistantWelcome'),
          role: _MessageRole.assistant,
        ));
        // Resolve launch intent → prompt, then auto-send
        final String? launchPrompt = _resolveLaunchPrompt();
        if (launchPrompt != null && launchPrompt.isNotEmpty) {
          Future.delayed(const Duration(milliseconds: 600), () {
            if (mounted) _sendMessageText(launchPrompt);
          });
        }
      }
    });
    AutomationTelemetryBus.instance.addListener(_automationListener);
  }

  /// Returns the first applicable launch prompt, or null.
  String? _resolveLaunchPrompt() {
    // initialIntent takes priority — produces a structured sentence
    if (widget.initialIntent != null) {
      return IntentPromptMapper.toPrompt(widget.initialIntent!,
          lang: _currentLang);
    }
    // Fall back to plain text (legacy / simple callers)
    if (widget.initialPrompt != null && widget.initialPrompt!.isNotEmpty) {
      return widget.initialPrompt;
    }
    return null;
  }

  @override
  void dispose() {
    AutomationTelemetryBus.instance.removeListener(_automationListener);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _automationListener(String msg) {
    if (mounted) {
      _addMessage(_ChatMessage(
        text: msg,
        role: _MessageRole.assistant,
        responseType: ResponseType.info,
      ));
    }
  }

  void _addMessage(_ChatMessage msg) {
    if (!mounted) return;

    // Ensure we are not in build phase when inserting items
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.idle) {
      Future.microtask(() => _addMessage(msg));
      return;
    }

    setState(() {
      _messages.add(msg);
      _listKey.currentState?.insertItem(
        _messages.length - 1,
        duration: const Duration(milliseconds: 300),
      );
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent + 100,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  _AssistantLoadType _determineLoadType(IntentType type) {
    switch (type) {
      case IntentType.showBalances:
      case IntentType.showWalletCards:
      case IntentType.showAddress:
      case IntentType.receiveAsset:
      case IntentType.showHistory:
      case IntentType.openAddressBook:
      case IntentType.openWalletSettings:
      case IntentType.openMarket:
        return _AssistantLoadType.instant;
      case IntentType.showRisks:
      case IntentType.scanApprovals:
      case IntentType.openSecurityCenter:
      case IntentType.unknown:
        return _AssistantLoadType.light;
      case IntentType.sendAsset:
      case IntentType.revokeApproval:
      case IntentType.swapAsset:
      case IntentType.buyAsset:
      case IntentType.sellAsset:
        return _AssistantLoadType.heavy;
    }
  }

  /// Programmatic send (e.g. from initialPrompt or quick-action deeplink).
  void _sendMessageText(String text) {
    _controller.text = text;
    _sendMessage(text);
  }

  Future<void> _sendMessage(String input) async {
    // No-op: realtime interrupt is handled by VAD barge-in.

    final t = LocalizationProvider.of(context);
    final trimmed = input.trim();
    if (trimmed.isEmpty) return;
    _controller.clear();
    HapticFeedback.lightImpact();

    _addMessage(_ChatMessage(text: trimmed, role: _MessageRole.user));

    final tentativeIntent = IntentParser.parse(trimmed);
    final loadType = _determineLoadType(tentativeIntent.type);

    setState(() {
      _isThinking = true;
      _thinkingText = t.t('assistantThinking');
      _coreState = AICoreState.thinking;
    });
    _scrollToBottom();

    if (loadType == _AssistantLoadType.instant) {
      _thinkingText = t.t('assistantFetching');
      await Future.delayed(const Duration(milliseconds: 100));
    } else if (loadType == _AssistantLoadType.light) {
      _thinkingText = t.t('assistantAnalyzingDetails');
      await Future.delayed(const Duration(milliseconds: 300));
    } else {
      _thinkingText = t.t('assistantAnalyzingVector');
      await Future.delayed(const Duration(milliseconds: 400));
      if (mounted) setState(() => _thinkingText = t.t('assistantPreflight'));
      await Future.delayed(const Duration(milliseconds: 400));
    }

    final lang = LanguageDetector.detect(trimmed);
    _currentLang = lang; // persist for voice consistency
    final response = await _assistant.process(trimmed, languageCode: lang, source: AssistantInputSource.generalChat);

    if (mounted) {
      // ── Handle Guardian Modal trigger from AI ──────────────────────────────
      if (response.type == ResponseType.guardianRevoke) {
        final mode = response.detail ?? 'safe'; // 'panic' or 'safe'
        setState(() {
          _isThinking = false;
          _coreState = mode == 'panic' ? AICoreState.danger : AICoreState.safe;
        });
        // Show the AI's spoken response in chat first
        _addMessage(_ChatMessage(
          text: response.message,
          role: _MessageRole.assistant,
          responseType: response.type,
          detail: response.detail,
          fullResponse: response,
        ));
        HapticFeedback.heavyImpact();
        // Then open the guardian modal — it handles its own scan lifecycle.
        await GuardianControlScreen.showAiModal(context, mode: mode);
        if (mounted) {
          setState(() => _coreState = AICoreState.idle);
        }
        return;
      }

      setState(() {
        _isThinking = false;
        if (response.type == ResponseType.error) {
          _coreState = AICoreState.danger;
        } else if (response.type == ResponseType.warning) {
          _coreState = AICoreState.warning;
        } else if (response.type == ResponseType.action) {
          _coreState = AICoreState.safe;
        } else {
          _coreState = AICoreState.idle;
        }
      });

      _addMessage(_ChatMessage(
        text: response.message,
        role: _MessageRole.assistant,
        responseType: response.type,
        detail: response.detail,
        fullResponse: response,
      ));
      HapticFeedback.mediumImpact();
      // Voice output is handled exclusively by the Voice Screen.
      // Text chat does not speak responses.
      if (_shouldAutoExecuteResponse(response)) {
        Future.microtask(() => _autoExecuteResponse(response));
      }
    }
  }

  bool get _isFullAutonomyMode =>
      AiControlService.instance.settings.mode == AiMode.fullAutonomy;

  bool _shouldAutoExecuteResponse(AssistantResponse response) {
    if (!_isFullAutonomyMode) return false;
    if (response.type != ResponseType.preview) return false;
    return response.pendingTransaction != null || response.swapPlan != null;
  }

  bool get _isGuardedMode =>
      AiControlService.instance.settings.mode == AiMode.guarded;

  Future<void> _autoExecuteResponse(AssistantResponse response) async {
    if (!mounted || !_isFullAutonomyMode) return;

    if (response.swapPlan != null && response.executionPath != null) {
      final plan = response.swapPlan!;
      final path = response.executionPath!;
      _addMessage(_ChatMessage(
        text: 'AI autonomy is active. Executing approved swap flow.',
        role: _MessageRole.assistant,
        responseType: ResponseType.info,
      ));
      if (plan.approveStep != null) {
        final approveOk = await _confirmSwapStep(
          plan.approveStep!,
          path,
          policy: response.policy,
          autoApproved: true,
        );
        if (!approveOk) return;
      }
      await _confirmSwapStep(
        plan.swapStep,
        path,
        policy: response.policy,
        rpc: response.rpcSimulation,
        autoApproved: true,
      );
      return;
    }

    if (response.pendingTransaction != null && response.executionPath != null) {
      _addMessage(_ChatMessage(
        text: 'AI autonomy is active. Executing approved action.',
        role: _MessageRole.assistant,
        responseType: ResponseType.info,
      ));
      await _confirmTransaction(
        response.pendingTransaction!,
        response.executionPath!,
        policy: response.policy,
        rpc: response.rpcSimulation,
        autoApproved: true,
      );
    }
  }

  Future<bool> _confirmTransaction(
    TransactionRequest tx,
    ExecutionPath path, {
    PolicyResult? policy,
    RpcSimulationResult? rpc,
    bool autoApproved = false,
  }) async {
    if (!autoApproved && _isGuardedMode) {
      _addMessage(_ChatMessage(
        text:
            'Guarded mode active. I prepared everything, but final confirmation and signature stay with you.',
        role: _MessageRole.assistant,
        responseType: ResponseType.info,
      ));
    }
    final proceed = autoApproved
        ? true
        : await _showExecutionGateDialog(
            tx,
            path,
            policy: policy,
            rpc: rpc,
          );
    if (!proceed) {
      if (!mounted) return false;
      _addMessage(_ChatMessage(
        text: 'Execution cancelled before signing.',
        role: _MessageRole.assistant,
        responseType: ResponseType.info,
      ));
      return false;
    }

    final t = LocalizationProvider.of(context);
    setState(() {
      _isThinking = true;
      _thinkingText =
          t.t('assistantExecuting', {'path': path.toString().split('.').last});
      _coreState = AICoreState.thinking;
    });
    _scrollToBottom();

    final authorized =
        autoApproved ? true : await VaultUnlockScreen.requireAuth(context, forceSetup: true);
    if (!authorized) {
      setState(() {
        _isThinking = false;
        _coreState = AICoreState.danger;
      });
      _addMessage(_ChatMessage(
        text: 'Transaction cancelled: vault authentication failed.',
        role: _MessageRole.assistant,
        responseType: ResponseType.error,
      ));
      return false;
    }

    try {
      final response =
          await GuardianExecutionController.instance.orchestrateConfirmation(
        tx,
        path,
      );

      if (!mounted) return false;
      setState(() {
        _isThinking = false;
        _coreState = response.type == ResponseType.error
            ? AICoreState.danger
            : AICoreState.safe;
      });

      // Show brief status message
      _addMessage(_ChatMessage(
        text: response.type == ResponseType.error
            ? response.message
            : 'Transaction sent.',
        role: _MessageRole.assistant,
        responseType: response.type,
      ));

      // If we got a hash, start polling
      final hash = response.detail;
      if (hash != null &&
          hash.startsWith('0x') &&
          response.type != ResponseType.error) {
        final amountLabel = tx.amount == null
            ? null
            : '${tx.amount} ${tx.tokenSymbol ?? ''}'.trim();
        _showTxStatus(
          txHash: hash,
          chainId: tx.chainId,
          walletAddress: tx.fromAddress,
          operationLabel: tx.displaySummary,
          assetLabel: amountLabel,
        );
        return true;
      }
      return response.type != ResponseType.error;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        _isThinking = false;
        _coreState = AICoreState.danger;
      });
      _addMessage(_ChatMessage(
        text: 'Execution aborted: $e',
        role: _MessageRole.assistant,
        responseType: ResponseType.error,
      ));
      return false;
    }
  }

  /// Handles a single step (approve or swap) from a SwapPreviewCard.
  Future<bool> _confirmSwapStep(
    TransactionRequest step,
    ExecutionPath path, {
    PolicyResult? policy,
    RpcSimulationResult? rpc,
    bool autoApproved = false,
  }) async {
    final isApprove = step.type == TransactionType.approve;
    if (!autoApproved && _isGuardedMode) {
      _addMessage(_ChatMessage(
        text: isApprove
            ? 'Guarded mode active. Approval is prepared, but only you can sign it.'
            : 'Guarded mode active. Swap is prepared, but only you can sign it.',
        role: _MessageRole.assistant,
        responseType: ResponseType.info,
      ));
    }
    final proceed = autoApproved
        ? true
        : await _showExecutionGateDialog(
            step,
            path,
            policy: policy,
            rpc: rpc,
          );
    if (!proceed) {
      if (!mounted) return false;
      _addMessage(_ChatMessage(
        text: isApprove
            ? 'Approval cancelled before signing.'
            : 'Swap cancelled before signing.',
        role: _MessageRole.assistant,
        responseType: ResponseType.info,
      ));
      return false;
    }

    setState(() {
      _isThinking = true;
      _thinkingText = isApprove ? 'Approving token…' : 'Executing swap…';
      _coreState = AICoreState.thinking;
    });
    _scrollToBottom();

    final authorized =
        autoApproved ? true : await VaultUnlockScreen.requireAuth(context, forceSetup: true);
    if (!authorized) {
      setState(() {
        _isThinking = false;
        _coreState = AICoreState.danger;
      });
      _addMessage(_ChatMessage(
        text: isApprove
            ? 'Approval cancelled: vault authentication failed.'
            : 'Swap cancelled: vault authentication failed.',
        role: _MessageRole.assistant,
        responseType: ResponseType.error,
      ));
      return false;
    }

    try {
      final response =
          await GuardianExecutionController.instance.orchestrateSwapStep(
        step,
        path,
      );

      if (!mounted) return false;
      setState(() {
        _isThinking = false;
        _coreState = response.type == ResponseType.error
            ? AICoreState.danger
            : AICoreState.safe;
      });

      final label = isApprove ? 'Approval sent.' : 'Swap sent.';
      _addMessage(_ChatMessage(
        text: response.type == ResponseType.error ? response.message : label,
        role: _MessageRole.assistant,
        responseType: response.type,
      ));

      // Start tx status polling if we have a hash
      final hash = response.detail;
      if (hash != null &&
          hash.startsWith('0x') &&
          response.type != ResponseType.error) {
        _showTxStatus(
          txHash: hash,
          chainId: step.chainId,
          walletAddress: step.fromAddress,
          operationLabel: step.displaySummary,
          assetLabel: isApprove ? null : (step.targetTokenSymbol ?? '').trim(),
        );
        return true;
      }
      return response.type != ResponseType.error;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        _isThinking = false;
        _coreState = AICoreState.danger;
      });
      _addMessage(_ChatMessage(
        text: 'Step aborted: $e',
        role: _MessageRole.assistant,
        responseType: ResponseType.error,
      ));
      return false;
    }
  }

  Future<bool> _showExecutionGateDialog(
    TransactionRequest tx,
    ExecutionPath path, {
    PolicyResult? policy,
    RpcSimulationResult? rpc,
  }) async {
    if (!mounted) return false;
    final severity = policy?.severity ?? PolicySeverity.info;
    final isRisky =
        severity == PolicySeverity.warning || severity == PolicySeverity.danger;
    final loc = LocalizationService.instance;
    final title =
        isRisky ? loc.t('execConfirmHighRisk') : loc.t('execConfirmFinal');
    final accent = severity == PolicySeverity.danger
        ? GuardianColors.danger
        : severity == PolicySeverity.warning
            ? GuardianColors.warning
            : GuardianColors.accent;
    final gas = _formatEstimatedGas(rpc?.estimatedGas);
    final warnings = <String>[
      if (policy?.reason != null && policy!.reason!.isNotEmpty) policy.reason!,
      ...(rpc?.warnings ?? const []),
    ];

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: GuardianColors.surface,
        title: Row(
          children: [
            Icon(Icons.shield_rounded, color: accent, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: GuardianTextStyles.titleMedium.copyWith(color: accent),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _confirmLine(loc.t('execConfirmAction'), tx.typeLabel),
              _confirmLine(loc.t('execConfirmFrom'), tx.fromAddress),
              _confirmLine(loc.t('execConfirmTo'), tx.toAddress),
              _confirmLine(loc.t('execConfirmNetwork'), tx.networkLabel),
              _confirmLine(loc.t('execConfirmPath'), path.label),
              if (tx.tokenSymbol != null && tx.amount != null)
                _confirmLine(loc.t('execConfirmAmount'),
                    '${tx.amount} ${tx.tokenSymbol}'),
              if (gas != null) _confirmLine(loc.t('execConfirmGas'), gas),
              if (warnings.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  warnings.first,
                  style: GuardianTextStyles.caption.copyWith(color: accent),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: accent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(isRisky
                ? loc.t('execConfirmUnderstand')
                : loc.t('execConfirmExecute')),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Widget _confirmLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: GuardianTextStyles.caption),
          const SizedBox(height: 2),
          Text(
            value,
            style: GuardianTextStyles.bodyPrimary.copyWith(
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  String? _formatEstimatedGas(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final normalized = raw.startsWith('0x') ? raw.substring(2) : raw;
    final gasUnits = BigInt.tryParse(
      normalized,
      radix: raw.startsWith('0x') ? 16 : 10,
    );
    if (gasUnits == null) return raw;
    return '$gasUnits units';
  }

  // ── Phase 10: Tx Status Feedback ─────────────────────────────────────────────

  /// Injects a [TxStatusCard] into the chat and starts polling.
  void _showTxStatus({
    required String txHash,
    required int chainId,
    String? assetLabel,
    String? operationLabel,
    String? walletAddress,
  }) {
    // Create a broadcast stream controller so the widget can subscribe
    final controller = StreamController<TxStatusEvent>.broadcast();

    final initialEvent = TxStatusEvent(
      status: TxStatus.submitted,
      txHash: txHash,
      walletAddress: walletAddress,
      timestamp: DateTime.now(),
      operationLabel: operationLabel,
      assetLabel: assetLabel,
    );

    _addMessage(_ChatMessage(
      text: 'Transaction sent.',
      role: _MessageRole.assistant,
      responseType: ResponseType.info,
      txHash: txHash,
      txChainId: chainId,
      txStatusStream: controller.stream,
      txInitialEvent: initialEvent,
    ));

    // No _speak() here — execution service already spoke via speechText.
    // Voice fires only on terminal states (confirmed / failed / timeout).
    TxStatusPoller.instance.start(
      txHash: txHash,
      chainId: chainId,
      walletAddress: walletAddress,
      operationLabel: operationLabel,
      assetLabel: assetLabel,
      onStatus: (event) {
        if (!controller.isClosed) controller.add(event);
        if (event.isTerminal) {
          controller.close();
          // Voice announce on terminal status
          final phrase = event.voicePhrase(assetLabel: assetLabel);
          if (phrase.isNotEmpty) {
            _speak(phrase);
          }
        }
      },
    );
  }

  Future<void> _speak(String text) async {
    if (text.isEmpty) return;
    // Routes through AudioManager → SpeechNormalizer → TtsService.
    // Language-aware normalization ensures natural spoken output.
    await AudioManager.instance.speakTts(text, lang: _currentLang);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GuardianColors.background,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          Expanded(child: _buildChatList()),
          _buildInputArea(),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final t = LocalizationProvider.of(context);
    return AppBar(
      backgroundColor: GuardianColors.background,
      elevation: 0,
      centerTitle: true,
      title: Text(t.t('shellChat'), style: GuardianTextStyles.headline),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: AICoreWidget(size: 32, state: _coreState),
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(color: GuardianColors.glassBorder, height: 1),
      ),
    );
  }

  Widget _buildChatList() {
    return AnimatedList(
      key: _listKey,
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      initialItemCount: _messages.length,
      itemBuilder: (context, index, animation) {
        final message = _messages[index];
        return SlideTransition(
          position: animation.drive(
              Tween(begin: const Offset(0, 0.2), end: Offset.zero)
                  .chain(CurveTween(curve: Curves.easeOutCubic))),
          child: FadeTransition(
            opacity: animation,
            child: _buildChatBubble(message),
          ),
        );
      },
    );
  }

  Widget _buildChatBubble(_ChatMessage msg) {
    final isUser = msg.role == _MessageRole.user;
    Color bg = isUser ? GuardianColors.surfaceElevated : GuardianColors.surface;
    Color border = isUser ? Colors.transparent : GuardianColors.glassBorder;

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment:
                isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isUser) ...[
                AICoreWidget(size: 20, state: _coreState),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: bg,
                    border: Border.all(color: border),
                    borderRadius: BorderRadius.circular(16).copyWith(
                      bottomRight: isUser
                          ? const Radius.circular(2)
                          : const Radius.circular(16),
                      bottomLeft: !isUser
                          ? const Radius.circular(2)
                          : const Radius.circular(16),
                    ),
                  ),
                  child: Text(
                    msg.text,
                    style: GuardianTextStyles.bodyPrimary.copyWith(height: 1.4),
                  ),
                ),
              ),
            ],
          ),
          // ── Tx Status Card (Phase 10) ──────────────────────────────────
          if (msg.isTxStatus) ...[
            const SizedBox(height: 8),
            TxStatusCard(
              txHash: msg.txHash!,
              chainId: msg.txChainId ?? 56,
              initialEvent: msg.txInitialEvent!,
              statusStream: msg.txStatusStream!,
            ),
          ] else if (msg.isSwapPreview) ...[
            const SizedBox(height: 12),
            SwapPreviewCard(
              plan: msg.fullResponse!.swapPlan!,
              executionPath: msg.fullResponse!.executionPath!,
              severity:
                  msg.fullResponse!.policy?.severity ?? PolicySeverity.info,
              onConfirmStep: (stepIndex) async {
                final plan = msg.fullResponse!.swapPlan!;
                final path = msg.fullResponse!.executionPath!;
                final step = stepIndex == 0 ? plan.approveStep! : plan.swapStep;
                return _confirmSwapStep(
                  step,
                  path,
                  policy: msg.fullResponse!.policy,
                  rpc: stepIndex == 0 ? null : msg.fullResponse!.rpcSimulation,
                );
              },
              onCancel: () => setState(() => _coreState = AICoreState.idle),
            ),
          ] else if (msg.isPreview) ...[
            const SizedBox(height: 12),
            TransactionPreviewCard(
              transaction: msg.fullResponse!.pendingTransaction!,
              explanation: msg.fullResponse!.explanation!,
              policyResult: msg.fullResponse!.policy!,
              rpcResult: msg.fullResponse!.rpcSimulation!,
              executionPath: msg.fullResponse!.executionPath!,
              onConfirm: () => _confirmTransaction(
                msg.fullResponse!.pendingTransaction!,
                msg.fullResponse!.executionPath!,
                policy: msg.fullResponse!.policy,
                rpc: msg.fullResponse!.rpcSimulation,
              ),
              onCancel: () => setState(() => _coreState = AICoreState.idle),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    final t = LocalizationProvider.of(context);
    return SafeArea(
        bottom: true,
        top: false,
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: const BoxDecoration(
            color: GuardianColors.surface,
            border: Border(top: BorderSide(color: GuardianColors.glassBorder)),
          ),
          child: Column(
            children: [
              if (_isThinking)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 10),
                      Text(_thinkingText,
                          style: GuardianTextStyles.caption
                              .copyWith(color: GuardianColors.accent)),
                    ],
                  ),
                ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _quickCommandKeys.map((key) {
                    final label = t.t(key);
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        label: Text(label, style: GuardianTextStyles.caption),
                        backgroundColor: GuardianColors.surfaceElevated,
                        onPressed: () => _sendMessage(label),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      style: GuardianTextStyles.bodyPrimary,
                      decoration: InputDecoration(
                        hintText: t.t('assistantTypePrompt'),
                        filled: true,
                        fillColor: GuardianColors.surfaceElevated,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none),
                      ),
                      onSubmitted: _sendMessage,
                    ),
                  ),
                  const SizedBox(width: 12),
                  CircleAvatar(
                    backgroundColor: GuardianColors.accent,
                    child: IconButton(
                      icon: const Icon(Icons.arrow_upward, color: Colors.white),
                      onPressed: () => _sendMessage(_controller.text),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ));
  }
}
