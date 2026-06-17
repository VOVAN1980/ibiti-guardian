import 'package:flutter/material.dart';
import 'package:ibiti_guardian/services/market/rocket_alert_settings.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';

// ─── Rocket Alert Settings Card ────────────────────────────────────────────────
//
// Compact settings card for configuring rocket (price spike) notifications.
// Lives inside the Market Command screen as a collapsible section.
//
// NEVER auto-trades. NEVER buys or sells. notifyOnly always.
// ─────────────────────────────────────────────────────────────────────────────────

class RocketAlertSettingsCard extends StatelessWidget {
  const RocketAlertSettingsCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: RocketAlertSettings.instance,
      builder: (context, _) {
        final s = RocketAlertSettings.instance;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
          child: Container(
            decoration: BoxDecoration(
              color: GuardianColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: s.enabled
                    ? const Color(0xFFFF9100).withValues(alpha: 0.3)
                    : GuardianColors.border,
              ),
            ),
            child: Column(
              children: [
                // ── Header: toggle ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 8, 0),
                  child: Row(
                    children: [
                      const Text('🚀',
                          style: TextStyle(fontSize: 18)),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Rocket Alerts',
                          style: TextStyle(
                            color: GuardianColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        s.summary,
                        style: TextStyle(
                          color: s.enabled
                              ? const Color(0xFFFF9100)
                              : GuardianColors.textSecondary
                                  .withValues(alpha: 0.5),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Switch(
                        value: s.enabled,
                        onChanged: (v) => s.setEnabled(v),
                        activeColor: const Color(0xFFFF9100),
                      ),
                    ],
                  ),
                ),

                // ── Settings body (visible when enabled) ──
                if (s.enabled) ...[
                  Divider(
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.06)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                    child: Column(
                      children: [
                        // ── Threshold % ──
                        _SettingRow(
                          label: 'Threshold',
                          options: const [5, 10, 20, 50],
                          selectedValue: s.thresholdPct.round(),
                          suffix: '%',
                          onChanged: (v) => s.setThresholdPct(v.toDouble()),
                        ),
                        const SizedBox(height: 10),
                        // ── Window ──
                        _SettingRow(
                          label: 'Window',
                          options: const [1, 5, 15, 30],
                          selectedValue: s.windowMinutes,
                          suffix: 'm',
                          onChanged: (v) => s.setWindowMinutes(v),
                        ),
                        const SizedBox(height: 10),
                        // ── Scope ──
                        Row(
                          children: [
                            SizedBox(
                              width: 72,
                              child: Text(
                                'Scope',
                                style: TextStyle(
                                  color: GuardianColors.textSecondary
                                      .withValues(alpha: 0.7),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Row(
                                children: RocketAlertScope.values.map((scope) {
                                  final isSelected = s.scope == scope;
                                  final label = scope ==
                                          RocketAlertScope.favorites
                                      ? '★ Favorites'
                                      : 'All Market';
                                  return Expanded(
                                    child: Padding(
                                      padding: EdgeInsets.only(
                                          right: scope ==
                                                  RocketAlertScope.allMarket
                                              ? 0
                                              : 6),
                                      child: GestureDetector(
                                        onTap: () => s.setScope(scope),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 7),
                                          decoration: BoxDecoration(
                                            color: isSelected
                                                ? const Color(0xFFFF9100)
                                                    .withValues(alpha: 0.15)
                                                : Colors.white
                                                    .withValues(alpha: 0.04),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            border: Border.all(
                                              color: isSelected
                                                  ? const Color(0xFFFF9100)
                                                      .withValues(alpha: 0.4)
                                                  : Colors.white
                                                      .withValues(alpha: 0.08),
                                            ),
                                          ),
                                          child: Center(
                                            child: Text(
                                              label,
                                              style: TextStyle(
                                                color: isSelected
                                                    ? const Color(0xFFFF9100)
                                                    : Colors.white
                                                        .withValues(alpha: 0.5),
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        // ── Cooldown ──
                        _SettingRow(
                          label: 'Cooldown',
                          options: const [5, 15, 30, 60],
                          selectedValue: s.cooldownMinutes,
                          suffix: 'm',
                          onChanged: (v) => s.setCooldownMinutes(v),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Reusable row: label + segmented button group.
class _SettingRow extends StatelessWidget {
  final String label;
  final List<int> options;
  final int selectedValue;
  final String suffix;
  final ValueChanged<int> onChanged;

  const _SettingRow({
    required this.label,
    required this.options,
    required this.selectedValue,
    required this.suffix,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: TextStyle(
              color:
                  GuardianColors.textSecondary.withValues(alpha: 0.7),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: Row(
            children: options.asMap().entries.map((entry) {
              final v = entry.value;
              final isLast = entry.key == options.length - 1;
              final isSelected = selectedValue == v;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: isLast ? 0 : 6),
                  child: GestureDetector(
                    onTap: () => onChanged(v),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFFFF9100)
                                .withValues(alpha: 0.15)
                            : Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isSelected
                              ? const Color(0xFFFF9100)
                                  .withValues(alpha: 0.4)
                              : Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Center(
                        child: Text(
                          '$v$suffix',
                          style: TextStyle(
                            color: isSelected
                                ? const Color(0xFFFF9100)
                                : Colors.white.withValues(alpha: 0.5),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}
