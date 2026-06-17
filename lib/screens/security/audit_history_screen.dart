import 'package:flutter/material.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';
import 'package:ibiti_guardian/services/audit_log_service.dart';
import 'package:ibiti_guardian/services/localization_service.dart';

class AuditHistoryScreen extends StatefulWidget {
  const AuditHistoryScreen({super.key});

  @override
  State<AuditHistoryScreen> createState() => _AuditHistoryScreenState();
}

class _AuditHistoryScreenState extends State<AuditHistoryScreen> {
  final _service = AuditLogService.instance;

  @override
  Widget build(BuildContext context) {
    final entries = _service.entries;

    return Scaffold(
      backgroundColor: GuardianColors.background,
      appBar: AppBar(
        title: Text(LocalizationService.instance.t('auditHistoryTitle'),
            style: GuardianTextStyles.headline.copyWith(fontSize: 20)),
        backgroundColor: GuardianColors.background,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              color: GuardianColors.textPrimary, size: 24),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: entries.isEmpty
          ? const Center(
              child: Text(
                'Журнал пуст.\nВыполненных действий еще нет.',
                textAlign: TextAlign.center,
                style: GuardianTextStyles.bodySecondary,
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              itemCount: entries.length,
              separatorBuilder: (_, __) => const SizedBox(height: 16),
              itemBuilder: (context, index) {
                final e = entries[index];
                final isSuccess = e.result.success;
                final isBlock = !isSuccess;

                return Container(
                  decoration: BoxDecoration(
                    color: GuardianColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isBlock
                          ? GuardianColors.danger.withOpacity(0.5)
                          : GuardianColors.success.withOpacity(0.3),
                    ),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(
                                isBlock
                                    ? Icons.block
                                    : Icons.check_circle_outline,
                                color: isBlock
                                    ? GuardianColors.danger
                                    : GuardianColors.success,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                e.actionLabel.toUpperCase(),
                                style: GuardianTextStyles.titleMedium.copyWith(
                                  color: isBlock
                                      ? GuardianColors.danger
                                      : GuardianColors.textPrimary,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.1,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            _formatDate(e.initiatedAt),
                            style: GuardianTextStyles.caption
                                .copyWith(color: GuardianColors.textSecondary),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.info_outline,
                              color: GuardianColors.info, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              e.summary,
                              style: GuardianTextStyles.bodyPrimary
                                  .copyWith(fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                      if (isBlock && e.result.message.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: GuardianColors.danger.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.warning_amber,
                                  color: GuardianColors.danger, size: 16),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Блок: ${e.result.message}',
                                  style: GuardianTextStyles.caption
                                      .copyWith(color: GuardianColors.danger),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (isSuccess && e.result.txHash != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          'Tx: ${e.result.txHash}',
                          style: GuardianTextStyles.caption.copyWith(
                              color: GuardianColors.textSecondary,
                              fontSize: 11),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final aDate = DateTime(date.year, date.month, date.day);
    final timeStr =
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

    if (aDate == today) {
      return 'Сегодня, $timeStr';
    } else if (aDate == today.subtract(const Duration(days: 1))) {
      return 'Вчера, $timeStr';
    }
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year} $timeStr';
  }
}
