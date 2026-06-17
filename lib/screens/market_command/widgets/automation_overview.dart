import 'package:flutter/material.dart';
import 'package:ibiti_guardian/models/automation_trigger.dart';
import 'package:ibiti_guardian/models/dispatch_item.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/market/automation_dispatch_service.dart';

// ─── Automation Overview ───────────────────────────────────────────────────────

/// Block 4: What is the AI doing / what is queued?
///
/// Shows:
///  - Active trigger count
///  - Pending queue items (what AI is about to do)
///  - Blocked/failed items (why AI stopped)
///
/// Does NOT show full dispatch history — just what matters for current decisions.
class AutomationOverview extends StatelessWidget {
  final AutomationDispatchService dispatch;
  final List<AutomationTrigger> triggers;

  const AutomationOverview({
    super.key,
    required this.dispatch,
    required this.triggers,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = dispatch.pendingItems;
    final history = dispatch.historyItems.take(3).toList();

    // If nothing to show, return empty SizedBox — this block should not
    // appear at all when there is no automation activity.
    if (triggers.isEmpty && pending.isEmpty && history.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            LocalizationService.instance.t('marketCmdAutomation'),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 10),

          // ── Active triggers count ─────────────────────────────────────────
          if (triggers.isNotEmpty)
            _InfoRow(
              icon: Icons.radar_outlined,
              text: triggers.length == 1
                  ? LocalizationService.instance
                      .t('marketCmdTriggerCount', {'count': triggers.length})
                  : LocalizationService.instance
                      .t('marketCmdTriggersCount', {'count': triggers.length}),
              color: Colors.amber.shade600,
            ),

          // ── Pending queue items ───────────────────────────────────────────
          if (pending.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...pending.map((item) => _QueueItemRow(item: item)),
          ],

          // ── Recent history ────────────────────────────────────────────────
          if (history.isNotEmpty) ...[
            const SizedBox(height: 4),
            ...history.map((item) => _HistoryItemRow(item: item)),
          ],
        ],
      ),
    );
  }
}

// ─── Rows ──────────────────────────────────────────────────────────────────────

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _InfoRow({required this.icon, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w500,
                  )),
        ),
      ],
    );
  }
}

class _QueueItemRow extends StatelessWidget {
  final DispatchItem item;
  const _QueueItemRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isProcessing = item.status == DispatchStatus.processing;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Colors.amber.withOpacity(0.25),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          if (isProcessing)
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            )
          else
            Icon(Icons.pending_outlined,
                size: 13, color: theme.colorScheme.onSurface.withOpacity(0.5)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${isProcessing ? LocalizationService.instance.t('automationProcessing') : LocalizationService.instance.t('automationQueued')}: ${item.assetSymbol}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  item.reason,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () =>
                AutomationDispatchService.instance.cancelItem(item.id),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(40, 30),
              foregroundColor: Colors.redAccent,
            ),
            child: Text(LocalizationService.instance.t('automationCancel'),
                style: const TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }
}

class _HistoryItemRow extends StatelessWidget {
  final DispatchItem item;
  const _HistoryItemRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDone = item.status == DispatchStatus.done;
    final isFailed = item.status == DispatchStatus.failed;

    final color = isDone
        ? Colors.greenAccent.shade400
        : (isFailed ? Colors.redAccent : Colors.grey);
    final icon = isDone
        ? Icons.check_circle_outline
        : (isFailed ? Icons.error_outline : Icons.block_outlined);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${item.assetSymbol}: ${item.blockReason ?? LocalizationService.instance.t('automationExecuted')}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
                fontSize: 11,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
