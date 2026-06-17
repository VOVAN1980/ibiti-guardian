import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:ibiti_guardian/models/tx_status.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

/// Chat-bubble widget that shows live tx status feedback.
///
/// Transitions automatically between states:
///   submitted → pending → confirmed ✓ / failed ✗ / timeout
///
/// Shows [txHash] as a tappable secondary detail (copies to clipboard).
/// Shows an explorer link when terminal.
class TxStatusCard extends StatefulWidget {
  final String txHash;
  final int chainId;
  final TxStatusEvent initialEvent;

  /// Stream of status updates from [TxStatusPoller].
  final Stream<TxStatusEvent> statusStream;

  const TxStatusCard({
    super.key,
    required this.txHash,
    required this.chainId,
    required this.initialEvent,
    required this.statusStream,
  });

  @override
  State<TxStatusCard> createState() => _TxStatusCardState();
}

class _TxStatusCardState extends State<TxStatusCard>
    with SingleTickerProviderStateMixin {
  late TxStatusEvent _current;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _current = widget.initialEvent;

    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    widget.statusStream.listen((event) {
      if (mounted) {
        setState(() => _current = event);
        if (event.isTerminal) _pulse.stop();
      }
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Color get _statusColor {
    switch (_current.status) {
      case TxStatus.confirmed:
        return GuardianColors.accent;
      case TxStatus.failed:
      case TxStatus.timeout:
        return GuardianColors.danger;
      default:
        return GuardianColors.warning;
    }
  }

  IconData get _statusIcon {
    switch (_current.status) {
      case TxStatus.confirmed:
        return Icons.check_circle_outline;
      case TxStatus.failed:
        return Icons.cancel_outlined;
      case TxStatus.timeout:
        return Icons.timer_off_outlined;
      default:
        return Icons.radio_button_unchecked;
    }
  }

  String get _shortHash {
    final h = widget.txHash;
    if (h.length < 12) return h;
    return '${h.substring(0, 8)}...${h.substring(h.length - 6)}';
  }

  String _explorerUrl() {
    const explorers = <int, String>{
      1: 'https://etherscan.io/tx/',
      56: 'https://bscscan.com/tx/',
      137: 'https://polygonscan.com/tx/',
      42161: 'https://arbiscan.io/tx/',
      10: 'https://optimistic.etherscan.io/tx/',
      8453: 'https://basescan.org/tx/',
      43114: 'https://snowtrace.io/tx/',
    };
    final base = explorers[widget.chainId] ?? 'https://bscscan.com/tx/';
    return '$base${widget.txHash}';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: GuardianColors.surface,
        border: Border.all(color: _statusColor.withOpacity(0.45)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Status row ─────────────────────────────────────────────────────
          Row(
            children: [
              // Pulsing icon while pending
              _current.isTerminal
                  ? Icon(_statusIcon, color: _statusColor, size: 18)
                  : AnimatedBuilder(
                      animation: _pulse,
                      builder: (_, __) => Icon(
                        _statusIcon,
                        color:
                            _statusColor.withOpacity(0.4 + _pulse.value * 0.6),
                        size: 18,
                      ),
                    ),
              const SizedBox(width: 10),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                    _current.statusLabel,
                    key: ValueKey(_current.status),
                    style: GuardianTextStyles.bodyPrimary.copyWith(
                      color: _statusColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              if (!_current.isTerminal)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(_statusColor),
                  ),
                ),
            ],
          ),

          // ── Error reason ───────────────────────────────────────────────────
          if (_current.errorReason != null) ...[
            const SizedBox(height: 6),
            Text(
              _current.errorReason!,
              style: GuardianTextStyles.caption
                  .copyWith(color: GuardianColors.danger),
            ),
          ],

          // ── Block number on confirmed ──────────────────────────────────────
          if (_current.blockNumber != null) ...[
            const SizedBox(height: 4),
            Text(
              'Block #${_current.blockNumber}',
              style: GuardianTextStyles.caption
                  .copyWith(color: GuardianColors.textSecondary),
            ),
          ],

          const SizedBox(height: 10),

          // ── Hash + copy ────────────────────────────────────────────────────
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: widget.txHash));
              HapticFeedback.lightImpact();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Hash copied'),
                  duration: Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: GuardianColors.surfaceElevated,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _shortHash,
                    style: GuardianTextStyles.caption.copyWith(
                      fontFamily: 'monospace',
                      color: GuardianColors.textSecondary,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.copy_outlined,
                      size: 12, color: GuardianColors.textSecondary),
                ],
              ),
            ),
          ),

          // ── Explorer link (terminal states only) ─────────────────────────
          if (_current.isTerminal) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () async {
                final url = Uri.parse(_explorerUrl());
                if (await canLaunchUrl(url)) {
                  await launchUrl(url, mode: LaunchMode.externalApplication);
                }
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: _statusColor.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _statusColor.withOpacity(0.2)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.open_in_new_rounded,
                        size: 12, color: _statusColor),
                    const SizedBox(width: 6),
                    Text(
                      'View on Explorer',
                      style: GuardianTextStyles.caption.copyWith(
                        color: _statusColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
