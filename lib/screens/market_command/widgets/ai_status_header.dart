import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ibiti_guardian/screens/security/policy_limits_screen.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/assistant/guardian_assistant_service.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_account_store.dart';
import 'package:ibiti_guardian/services/exchanges/exchange_order_service.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

// ── Stubs for archived JarvisAutonomousOperator ──
enum JarvisMessageType { report }

class JarvisMessage {
  final String text;
  final DateTime timestamp;
  final JarvisMessageType type;
  const JarvisMessage({required this.text, required this.timestamp, required this.type});
}

// ─── AiStatusHeader ────────────────────────────────────────────────────────────

/// Block 1: What does the AI see and what can it do right now?
///
/// Answers FOUR things in plain human language:
///  1. Mode — what the AI is allowed to do in general.
///  2. What it CANNOT do now (if relevant).
///  3. Available budget for AI to work with.
///  4. Best next step for the user.
class AiStatusHeader extends StatefulWidget {
  final AiControlSettings settings;
  final int pendingQueueCount;
  final VoidCallback? onScanRequested;

  const AiStatusHeader({
    super.key,
    required this.settings,
    required this.pendingQueueCount,
    this.onScanRequested,
  });

  @override
  State<AiStatusHeader> createState() => _AiStatusHeaderState();
}

class _AiStatusHeaderState extends State<AiStatusHeader> {
  bool _isChatOpen = false;
  Timer? _chatPollTimer;
  final List<JarvisMessage> _chatHistory = [];
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // Auto-trading operator archived — no messages to consume
    // ALWAYS poll for new messages so we can auto-open the chat
    _startPolling();
  }

  final TextEditingController _chatInputController = TextEditingController();
  bool _isSending = false;

  void _sendMessage() async {
    final text = _chatInputController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _chatHistory.add(JarvisMessage(
        text: 'Вы: $text',
        timestamp: DateTime.now(),
        type: JarvisMessageType.report,
      ));
      _chatInputController.clear();
      _isSending = true;
    });
    _scrollToBottom();

    try {
      // Wire text input to the main Voice/Intent Pipeline
      final response = await GuardianAssistantService.instance.process(text, source: AssistantInputSource.marketChat);

      if (mounted) {
        setState(() {
          _chatHistory.add(JarvisMessage(
            text: response.message,
            timestamp: DateTime.now(),
            type: JarvisMessageType.report,
          ));
        });
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _chatHistory.add(JarvisMessage(
            text: 'Ошибка: $e',
            timestamp: DateTime.now(),
            type: JarvisMessageType.report,
          ));
        });
        _scrollToBottom();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _chatPollTimer?.cancel();
    _scrollController.dispose();
    _chatInputController.dispose();
    super.dispose();
  }

  void _toggleChat() {
    setState(() {
      _isChatOpen = !_isChatOpen;
      if (_isChatOpen) {
        _scrollToBottom();
      }
    });
  }

  void _startPolling() {
    _chatPollTimer?.cancel();
    // Auto-trading operator archived — no message polling needed
    _chatPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      // No-op: JarvisAutonomousOperator has been archived
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  bool _getJarvisEnabled() {
    return DateTime.now().millisecondsSinceEpoch < 0;
  }

  void _toggleJarvis() {
    // Auto-trading operator archived — toggle is no-op
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mode = widget.settings.mode;
    final isExecuting = widget.pendingQueueCount > 0;
    // Auto-trading operator archived — Jarvis always shows as disabled
    final isJarvisEnabled = _getJarvisEnabled();

    // ── Live data from policy + dispatch ──────────────────────────────
    final double limitUsd = widget.settings.dailyLimit;
    double totalPnl = 0; // TODO: wire to PnL tracker when available
    int todayTrades = 0; // TODO: wire to daily trade counter
    // "В работе" — open allocated USD + open positions
    double inWorkUsd = 0; // TODO: wire to dispatch open positions
    int inWorkPositions = 0; // TODO: wire to daily position counter (originally int)
    // Funding source label
    final fundingLabel = widget.settings.fundingSourceLabel;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _modeColor(mode).withOpacity(0.4),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header Row (Mode + Close Button if chat open) ──
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _modeColor(mode),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _modeLabel(mode),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: _modeColor(mode),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              if (isExecuting && !_isChatOpen) ...[
                const SizedBox(width: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    LocalizationService.instance.t('aiStatusQueuedCount',
                        {'count': widget.pendingQueueCount}),
                    style: TextStyle(
                      color: Colors.amber.shade600,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
              if (_isChatOpen)
                GestureDetector(
                  onTap: _toggleChat,
                  child: Icon(
                    Icons.close_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),

          // ── Chat View OR Standard View ──
          if (_isChatOpen) ...[
            // ── Chat Area ──
            Container(
              height: MediaQuery.of(context).size.height * 0.45,
              margin: const EdgeInsets.only(top: 8, bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.05)),
              ),
              child: Column(
                children: [
                  Expanded(
                    child: _chatHistory.isEmpty
                        ? Center(
                            child: Text(
                              'JARVIS пока молчит...',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.3),
                                fontSize: 13,
                              ),
                            ),
                          )
                        : ListView.separated(
                            controller: _scrollController,
                            itemCount: _chatHistory.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 12),
                            itemBuilder: (context, index) {
                              final msg = _chatHistory[index];
                              final isUser = msg.text.startsWith('Вы: ');
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (!isUser)
                                    Text(
                                      '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}',
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.3),
                                        fontSize: 10,
                                        fontFamily: 'Courier',
                                      ),
                                    ),
                                  if (!isUser) const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      msg.text,
                                      textAlign: isUser
                                          ? TextAlign.right
                                          : TextAlign.left,
                                      style: TextStyle(
                                        color: isUser
                                            ? Colors.blueAccent.shade100
                                            : Colors.white,
                                        fontSize: 13,
                                        height: 1.4,
                                        fontWeight: isUser
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 8),
                  // Chat Input Field
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 36,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: Colors.white.withOpacity(0.1)),
                          ),
                          child: TextField(
                            controller: _chatInputController,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13),
                            decoration: InputDecoration(
                              hintText: 'Спросить JARVIS...',
                              hintStyle: TextStyle(
                                  color: Colors.white.withOpacity(0.3),
                                  fontSize: 13),
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              isDense: true,
                            ),
                            onSubmitted: (_) => _sendMessage(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: _isSending ? null : _sendMessage,
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: _isSending
                                ? Colors.grey.withOpacity(0.2)
                                : theme.colorScheme.primary.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: _isSending
                                    ? Colors.transparent
                                    : theme.colorScheme.primary
                                        .withOpacity(0.5)),
                          ),
                          child: _isSending
                              ? Padding(
                                  padding: const EdgeInsets.all(10.0),
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: theme.colorScheme.primary),
                                )
                              : Icon(Icons.send_rounded,
                                  size: 16, color: theme.colorScheme.primary),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ] else ...[
            // ── Standard Status Info ──
            Text(
              _whatAiDoing(mode, isExecuting),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.85),
                height: 1.4,
              ),
            ),

            if (_cannotDoNote(mode, widget.settings) != null) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.block_outlined,
                      size: 13,
                      color: theme.colorScheme.onSurface.withOpacity(0.45)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _cannotDoNote(mode, widget.settings)!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withOpacity(0.5),
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (_) => DailyLimitBalancesDialog(
                          settings: widget.settings,
                        ),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.onSurface.withOpacity(0.04),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: theme.colorScheme.onSurface.withOpacity(0.08),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'ЛИМИТ ДНЯ',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                              color: theme.colorScheme.onSurface.withOpacity(0.5),
                            ),
                          ),
                          const SizedBox(height: 4),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '\$${limitUsd.toStringAsFixed(0)}',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(height: 2),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              fundingLabel,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.onSurface.withOpacity(0.7),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onSurface.withOpacity(0.04),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: theme.colorScheme.onSurface.withOpacity(0.08),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'PnL',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                            color: theme.colorScheme.onSurface.withOpacity(0.5),
                          ),
                        ),
                        const SizedBox(height: 4),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '${totalPnl >= 0 ? '+' : ''}\$${totalPnl.toStringAsFixed(2)}',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: totalPnl >= 0 ? Colors.greenAccent : Colors.redAccent,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '$todayTrades сделок',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: totalPnl >= 0 ? Colors.greenAccent.withOpacity(0.8) : Colors.redAccent.withOpacity(0.8),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onSurface.withOpacity(0.04),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: theme.colorScheme.onSurface.withOpacity(0.08),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'В РАБОТЕ',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                            color: theme.colorScheme.onSurface.withOpacity(0.5),
                          ),
                        ),
                        const SizedBox(height: 4),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '\$${inWorkUsd.toStringAsFixed(2)}',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: inWorkUsd > 0 ? Colors.cyanAccent : theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '$inWorkPositions позиций',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurface.withOpacity(0.7),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            if (widget.settings.mandate.allowedAssets.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                LocalizationService.instance.t('aiStatusMandate', {
                  'assets': widget.settings.mandate.allowedAssets.join(' · ')
                }),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.45),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],

            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 10),

            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.arrow_right_alt_rounded,
                    size: 16, color: _modeColor(mode)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _bestNextStep(mode, isExecuting, widget.settings),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface.withOpacity(0.75),
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ], // End of non-chat standard view

          // ── Quick Actions ─────────────────────────────────────────────
          const SizedBox(height: 14),
          Row(
            children: [
              _actionButton(
                context,
                icon: Icons.chat_bubble_outline_rounded,
                label: _isChatOpen ? 'Скрыть' : 'Чат',
                color: _isChatOpen ? Colors.white54 : GuardianColors.accent,
                onTap: _toggleChat,
              ),
              const SizedBox(width: 10),
              _actionButton(
                context,
                icon: isJarvisEnabled
                    ? Icons.stop_rounded
                    : Icons.play_arrow_rounded,
                label: isJarvisEnabled ? 'Стоп' : 'Пуск',
                color: isJarvisEnabled ? Colors.redAccent : Colors.greenAccent,
                onTap: _toggleJarvis,
              ),
              const SizedBox(width: 10),
              _actionButton(
                context,
                icon: Icons.tune_rounded,
                label: LocalizationService.instance
                    .t('marketQuickLimits', {'default': 'Лимиты'}),
                color: Colors.orange.shade400,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PolicyLimitsScreen()),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Material(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Copy strings — plain human language, zero enum names ─────────────────

  static String _modeLabel(AiMode mode) {
    final l = LocalizationService.instance;
    return switch (mode) {
      AiMode.manual => l.t('aiModeAnalysisOnly'),
      AiMode.guarded => l.t('aiModeGuarded'),
      AiMode.fullAutonomy => l.t('aiModeFullAutonomy'),
    };
  }

  static String _whatAiDoing(AiMode mode, bool isExecuting) {
    final l = LocalizationService.instance;
    return switch (mode) {
      AiMode.manual => l.t('aiDoingManual'),
      AiMode.guarded => l.t('aiDoingGuarded'),
      AiMode.fullAutonomy =>
        isExecuting ? l.t('aiDoingFullExecuting') : l.t('aiDoingFullReady'),
    };
  }

  static String? _cannotDoNote(AiMode mode, AiControlSettings settings) {
    final l = LocalizationService.instance;
    if (mode == AiMode.manual) return l.t('aiCannotManual');
    if (settings.mandate.allowedAssets.isNotEmpty &&
        settings.mandate.allowedAssets.length == 1) {
      return l.t('aiCannotNarrowMandate',
          {'asset': settings.mandate.allowedAssets.first});
    }
    return null;
  }

  static String _bestNextStep(
      AiMode mode, bool isExecuting, AiControlSettings settings) {
    final l = LocalizationService.instance;
    if (mode == AiMode.manual) return l.t('aiNextManual');
    if (mode == AiMode.guarded) return l.t('aiNextGuarded');
    if (isExecuting) return l.t('aiNextExecuting');
    return l.t('aiNextReady');
  }

  static Color _modeColor(AiMode mode) => switch (mode) {
        AiMode.manual => Colors.grey,
        AiMode.guarded => Colors.amber.shade600,
        AiMode.fullAutonomy => Colors.greenAccent.shade400,
      };

  Widget _chip(
    BuildContext context, {
    required IconData icon,
    required String label,
    bool faded = false,
  }) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon,
            size: 13,
            color: theme.colorScheme.onSurface.withOpacity(faded ? 0.3 : 0.5)),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface.withOpacity(faded ? 0.35 : 0.85),
          ),
        ),
      ],
    );
  }
}

class DailyLimitBalancesDialog extends StatefulWidget {
  final AiControlSettings settings;

  const DailyLimitBalancesDialog({super.key, required this.settings});

  @override
  State<DailyLimitBalancesDialog> createState() => _DailyLimitBalancesDialogState();
}

class _DailyLimitBalancesDialogState extends State<DailyLimitBalancesDialog> {
  final Map<String, double> _balances = {};
  final Map<String, bool> _isLoading = {};
  final Map<String, bool> _isConnected = {};

  @override
  void initState() {
    super.initState();
    _loadBalances();
  }

  String? _okxRegion;

  Future<void> _loadBalances() async {
    final okxReg = await ExchangeAccountStore.instance.getOkxRegion();
    if (mounted) {
      setState(() {
        _okxRegion = okxReg;
      });
    }
    // 1. Wallet Balance
    final portfolio = VaultPortfolioListener.instance.summary;
    final walletKey = portfolio?.chainKey ?? widget.settings.activeSources.firstWhere(
      (s) => s == 'bsc' || s == 'ethereum' || s == 'eth',
      orElse: () => 'bsc',
    );

    double walletBal = 0.0;
    if (portfolio != null) {
      walletBal = _sumUsdStables(portfolio.allAssets);
    }

    if (mounted) {
      setState(() {
        _balances[walletKey] = walletBal;
        _isConnected[walletKey] = true;
      });
    }

    // 2. Exchanges
    for (final ex in ['binance', 'mexc', 'gateio', 'okx']) {
      if (!mounted) return;
      final connected = await ExchangeAccountStore.instance.isConnected(ex);
      if (mounted) {
        setState(() {
          _isConnected[ex] = connected;
        });
      }

      if (connected) {
        if (mounted) {
          setState(() {
            _isLoading[ex] = true;
          });
        }
        try {
          double? bal;
          if (ex == 'okx') {
            final region = _okxRegion ?? await ExchangeAccountStore.instance.getOkxRegion();
            final targetAsset = region == 'eea' ? 'USDC' : 'USDT';
            final adapter = ExchangeOrderService.instance.adapterFor('okx');
            if (adapter != null) {
              bal = await adapter.fetchAssetBalance(targetAsset);
            } else {
              bal = await ExchangeAccountStore.instance.fetchUsdtBalance(ex);
            }
          } else {
            bal = await ExchangeAccountStore.instance.fetchUsdtBalance(ex);
          }

          if (mounted) {
            setState(() {
              _balances[ex] = bal ?? 0.0;
              _isLoading[ex] = false;
            });
          }
        } catch (_) {
          if (mounted) {
            setState(() {
              _isLoading[ex] = false;
            });
          }
        }
      }
    }

    final okxConnected = _isConnected['okx'] == true;
    if (okxConnected && _okxRegion != null) {
      final creds = await ExchangeAccountStore.instance.getCredentials('okx');
      if (creds != null) {
        final apiKey = creds['apiKey'] ?? '';
        final hasAlerted = await ExchangeAccountStore.instance.hasShownOkxRegionAlert(apiKey, _okxRegion!);
        if (!hasAlerted) {
          await ExchangeAccountStore.instance.setOkxRegionAlertShown(apiKey, _okxRegion!, true);
          Future.delayed(const Duration(milliseconds: 1500), () {
            if (mounted) {
              _showOkxRegionAlert(context, _okxRegion!);
            }
          });
        }
      }
    }
  }

  void _showOkxRegionAlert(BuildContext context, String region) {
    final isEea = region == 'eea';
    final locale = Localizations.localeOf(context).languageCode;
    final isRu = locale == 'ru' || locale == 'uk';

    final title = isRu
        ? (isEea ? 'Ограничение региона OKX' : 'Регион OKX: Global')
        : (isEea ? 'OKX Region Restriction' : 'OKX Region: Global');

    final message = isRu
        ? (isEea
            ? 'Ваш аккаунт OKX находится в регионе EEA (Европейская экономическая зона). В связи с правилами MiCA, торговля будет автоматически переведена на USDC вместо USDT. Баланс OKX отображается в USDC.'
            : 'Ваш аккаунт OKX определен как Global. Все операции и балансы будут осуществляться в парах к USDT.')
        : (isEea
            ? 'Your OKX account is located in the EEA (European Economic Area) region. Due to MiCA regulations, trading will automatically route to USDC instead of USDT. OKX balance is displayed in USDC.'
            : 'Your OKX account is detected as Global. All operations and balances will be processed in USDT pairs.');

    final buttonText = isRu ? 'Понятно' : 'Understood';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF0C0F17),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: GuardianColors.glassBorder,
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: GuardianColors.accentGlow.withOpacity(0.06),
                  blurRadius: 40,
                  spreadRadius: 2,
                ),
                const BoxShadow(color: Colors.black54, blurRadius: 30),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      isEea ? Icons.warning_amber_rounded : Icons.check_circle_outline_rounded,
                      color: isEea ? Colors.orangeAccent : Colors.greenAccent,
                      size: 28,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: GuardianTextStyles.titleMedium.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  message,
                  style: GuardianTextStyles.bodySecondary.copyWith(
                    color: Colors.white70,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isEea ? Colors.orangeAccent.withOpacity(0.15) : Colors.greenAccent.withOpacity(0.15),
                    foregroundColor: isEea ? Colors.orangeAccent : Colors.greenAccent,
                    side: BorderSide(
                      color: isEea ? Colors.orangeAccent.withOpacity(0.3) : Colors.greenAccent.withOpacity(0.3),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    buttonText,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  double _sumUsdStables(List assets) {
    const usdSymbols = {'USDT', 'USDC', 'DAI', 'BUSD', 'FDUSD'};
    double sum = 0;
    for (final a in assets) {
      if (usdSymbols.contains(a.symbol.toUpperCase())) {
        sum += a.valueUsd;
      }
    }
    return sum;
  }

  @override
  Widget build(BuildContext context) {
    final activeSources = widget.settings.activeSources;
    final locale = Localizations.localeOf(context).languageCode;
    final isRu = locale == 'ru' || locale == 'uk';

    // Build the list of sources
    final items = <_DailyLimitBalanceItem>[];

    // Wallet Chain
    final portfolio = VaultPortfolioListener.instance.summary;
    if (portfolio != null) {
      items.add(_DailyLimitBalanceItem(
        id: portfolio.chainKey,
        name: portfolio.networkName,
        isWallet: true,
      ));
    } else {
      final walletKey = widget.settings.activeSources.firstWhere(
        (s) => s == 'bsc' || s == 'ethereum' || s == 'eth',
        orElse: () => 'bsc',
      );
      items.add(_DailyLimitBalanceItem(
        id: walletKey,
        name: walletKey == 'bsc' ? 'BNB Chain' : 'Ethereum',
        isWallet: true,
      ));
    }

    // Exchanges
    items.addAll([
      const _DailyLimitBalanceItem(id: 'mexc', name: 'MEXC Spot', isWallet: false),
      const _DailyLimitBalanceItem(id: 'gateio', name: 'Gate.io Spot', isWallet: false),
      _DailyLimitBalanceItem(
        id: 'okx',
        name: _okxRegion != null ? 'OKX (${_okxRegion!.toUpperCase()}) Spot' : 'OKX Spot',
        isWallet: false,
      ),
      const _DailyLimitBalanceItem(id: 'binance', name: 'Binance Spot', isWallet: false),
    ]);

    return Dialog(
      backgroundColor: const Color(0xFF0C0F17),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    isRu ? 'Daily Trading Sources' : 'Daily Trading Sources',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white60, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: items.length,
                separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 12),
                itemBuilder: (context, index) {
                  final item = items[index];
                  final isConnected = _isConnected[item.id] ?? (item.isWallet ? true : false);
                  final isLoading = _isLoading[item.id] ?? false;
                  final balance = _balances[item.id] ?? 0.0;
                  final isSelected = activeSources.contains(item.id);
                  final settings = AiControlService.instance.settings;
                  final minTradeBal = settings.minTradeBalance;
                  final hasMinBalance = balance >= minTradeBal;
                  final isGrayedOut = !isConnected;

                  // Text lines to display
                  String line1 = '';
                   String line2 = '';
                   Color line2Color = Colors.white54;
                   String quoteAsset = 'USDT';
                   if (item.id == 'okx') {
                     quoteAsset = _okxRegion == 'eea' ? 'USDC' : 'USDT';
                   }

                   if (isLoading) {
                     line1 = isRu ? 'Загрузка баланса...' : 'Loading balance...';
                   } else if (!isConnected) {
                     line1 = isRu ? 'Не подключено' : 'Not connected';
                   } else {
                     line1 = isRu ? 'Баланс: \$${balance.toStringAsFixed(2)} $quoteAsset' : 'Balance: \$${balance.toStringAsFixed(2)} $quoteAsset';
                     if (!hasMinBalance) {
                       line2 = isRu 
                           ? 'Buy недоступен: минимум ${minTradeBal.toStringAsFixed(0)} $quoteAsset' 
                           : 'Buy unavailable: minimum ${minTradeBal.toStringAsFixed(0)} $quoteAsset';
                       line2Color = Colors.orangeAccent;
                     } else {
                       line2 = isSelected
                           ? (isRu ? 'Активно: ON' : 'Active: ON')
                           : (isRu ? 'Активно: OFF' : 'Active: OFF');
                       line2Color = isSelected ? const Color(0xFF00E676) : Colors.white54;
                     }
                   }

                  return Opacity(
                    opacity: isGrayedOut ? 0.35 : 1.0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                      decoration: BoxDecoration(
                        color: isSelected && !isGrayedOut ? const Color(0x1F00E676) : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isSelected && !isGrayedOut ? const Color(0x4D00E676) : Colors.transparent,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            item.isWallet ? Icons.account_balance_wallet : Icons.swap_horiz,
                            color: isSelected && !isGrayedOut ? const Color(0xFF00E676) : Colors.white70,
                            size: 18,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.name,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: isSelected && !isGrayedOut ? const Color(0xFF00E676) : Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  line1,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.white54,
                                  ),
                                ),
                                if (line2.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    line2,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: line2Color,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (isConnected && hasMinBalance && !isLoading)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? const Color(0x1F00E676)
                                    : Colors.white12,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: isSelected
                                      ? const Color(0x4D00E676)
                                      : Colors.transparent,
                                ),
                              ),
                              child: Text(
                                isSelected ? 'ON' : 'OFF',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: isSelected ? const Color(0xFF00E676) : Colors.white60,
                                ),
                              ),
                            )
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DailyLimitBalanceItem {
  final String id;
  final String name;
  final bool isWallet;

  const _DailyLimitBalanceItem({required this.id, required this.name, required this.isWallet});
}
