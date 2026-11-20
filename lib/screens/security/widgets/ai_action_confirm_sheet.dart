import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ibiti_guardian/config/privy_chain_registry.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/security/ai_action_gate.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

/// The card the AI shows before it carries out a money action in
/// «Автономный» mode: what, amount, where to, network or venue, fee — with
/// «Отмена» / «Подтвердить». After «Подтвердить» AiActionGate asks for the
/// PIN (or biometrics).
///
/// It cannot be swiped or tapped away; the system back button counts as
/// «Отмена». The gate can close it with an answer (voice «да» / «нет», the
/// card timeout, a mode change).
class AiActionConfirmSheet extends StatefulWidget {
  const AiActionConfirmSheet({
    super.key,
    required this.summary,
    this.note,
    this.answer,
  });

  final AiActionSummary summary;

  /// Why the card appears although the PIN setting is off (a new address,
  /// an unknown price, …).
  final String? note;

  /// Set by the gate: the card closes with that answer.
  final ValueListenable<bool?>? answer;

  /// True only for «Подтвердить»; Cancel, back and anything else are false.
  static Future<bool> show(
    BuildContext context,
    AiActionSummary summary, {
    String? note,
    ValueListenable<bool?>? answer,
  }) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AiActionConfirmSheet(
        summary: summary,
        note: note,
        answer: answer,
      ),
    );
    return result == true;
  }

  @override
  State<AiActionConfirmSheet> createState() => _AiActionConfirmSheetState();
}

class _AiActionConfirmSheetState extends State<AiActionConfirmSheet> {
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    widget.answer?.addListener(_onAnswer);
    // The gate may have answered before the card was built.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onAnswer());
  }

  @override
  void dispose() {
    widget.answer?.removeListener(_onAnswer);
    super.dispose();
  }

  void _onAnswer() {
    final value = widget.answer?.value;
    if (value != null) _close(value);
  }

  void _close(bool confirmed) {
    if (_closed || !mounted) return;
    _closed = true;
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    if (route == null || route.isCurrent) {
      navigator.pop(confirmed);
    } else if (route.isActive) {
      // Something was opened above the card: remove just the card.
      navigator.removeRoute(route, confirmed);
    }
  }

  static String _shortAddress(String address) {
    final a = address.trim();
    if (a.length <= 14) return a;
    return '${a.substring(0, 6)}…${a.substring(a.length - 4)}';
  }

  static String _networkLabel(String chainKey) {
    try {
      final name = PrivyChainRegistry.getChain(chainKey).displayName;
      if (name.trim().isNotEmpty) return name;
    } catch (_) {}
    return chainKey.toUpperCase();
  }

  static String _venueLabel(String venue) {
    switch (venue.trim().toLowerCase()) {
      case 'mexc':
        return 'MEXC';
      case 'okx':
        return 'OKX';
      case 'binance':
        return 'Binance';
      case 'gateio':
      case 'gate.io':
        return 'Gate.io';
      default:
        return venue.trim();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = LocalizationService.instance;
    final s = widget.summary;
    final value = s.valueUsd;
    final rows = <(String, String)>[
      (t.t('aiActionCardWhat', {'default': 'Action'}), s.title),
      (t.t('aiActionCardAmount', {'default': 'Amount'}), s.amountLabel),
      (
        t.t('aiActionCardValue', {'default': 'Value'}),
        value == null
            ? t.t('aiActionCardValueUnknown', {'default': 'unknown'})
            : '≈ \$${value.toStringAsFixed(2)}',
      ),
      if (s.toAddress?.trim().isNotEmpty ?? false)
        (t.t('aiActionCardTo', {'default': 'To'}), _shortAddress(s.toAddress!)),
      if (s.network?.trim().isNotEmpty ?? false)
        (
          t.t('aiActionCardNetwork', {'default': 'Network'}),
          _networkLabel(s.network!.trim()),
        ),
      if (s.venue?.trim().isNotEmpty ?? false)
        (t.t('aiActionCardVenue', {'default': 'Venue'}), _venueLabel(s.venue!)),
      if (s.feeLabel?.trim().isNotEmpty ?? false)
        (t.t('aiActionCardFee', {'default': 'Fee'}), s.feeLabel!),
    ];
    final note = widget.note?.trim();
    final pinHint = t.t('aiActionCardPinHint',
        {'default': 'After «Confirm» you will enter your PIN.'});
    final voiceHint = t.t('aiActionCardVoiceHint',
        {'default': 'You can also say «yes» or «no».'});

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          decoration: BoxDecoration(
            color: GuardianColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: GuardianColors.accent.withValues(alpha: 0.35)),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  const Icon(Icons.smart_toy_outlined,
                      color: GuardianColors.accent, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      t.t('aiActionCardTitle',
                          {'default': 'Confirm the AI action'}),
                      style: GuardianTextStyles.headline.copyWith(fontSize: 18),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                for (final row in rows) _infoRow(row.$1, row.$2),
                if (note != null && note.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: GuardianColors.warning.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color:
                              GuardianColors.warning.withValues(alpha: 0.35)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.info_outline,
                            color: GuardianColors.warning, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            note,
                            style: GuardianTextStyles.bodySecondary
                                .copyWith(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  '$pinHint $voiceHint',
                  style: GuardianTextStyles.caption.copyWith(
                      color: GuardianColors.textSecondary, fontSize: 12),
                ),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('aiActionCardCancel'),
                      onPressed: () => _close(false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: GuardianColors.textPrimary,
                        side: BorderSide(
                            color:
                                GuardianColors.border.withValues(alpha: 0.8)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(
                          t.t('policyEditCancel', {'default': 'Cancel'})),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey('aiActionCardConfirm'),
                      onPressed: () => _close(true),
                      style: FilledButton.styleFrom(
                        backgroundColor: GuardianColors.accent,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(
                          t.t('aiControlConfirm', {'default': 'Confirm'})),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: Text(
                label,
                style: GuardianTextStyles.bodySecondary.copyWith(
                    fontSize: 13, color: GuardianColors.textSecondary),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                value,
                style: GuardianTextStyles.bodyPrimary.copyWith(
                    fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
}
