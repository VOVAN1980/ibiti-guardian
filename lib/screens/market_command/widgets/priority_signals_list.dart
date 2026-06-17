import 'package:flutter/material.dart';
import 'package:ibiti_guardian/models/automation_trigger.dart';
import 'package:ibiti_guardian/models/autonomy_mandate.dart';
import 'package:ibiti_guardian/screens/security/ai_control_screen.dart'
    show AIControlScreen;
import 'package:ibiti_guardian/screens/security/policy_limits_screen.dart';
import 'package:ibiti_guardian/screens/wallet/components/wallet_swap_modal.dart';
import 'package:ibiti_guardian/services/adapters/vault_portfolio_listener.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/market/automation_dispatch_service.dart';
import 'package:ibiti_guardian/services/market/market_policy_gate.dart';
import 'package:ibiti_guardian/services/market/market_scout_service.dart';
import 'package:ibiti_guardian/services/market/wallet_exposure_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/models/wallet_asset.dart';
import 'package:ibiti_guardian/utils/price_formatter.dart';

// ─── Public entry point (shared by SecondaryMarketList) ───────────────────────

/// Opens the focused [_AssetActionSheet] for [signal].
void openAssetActionSheet(BuildContext context, MarketOpportunity signal) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _AssetActionSheet(signal: signal),
  );
}

// ─── Block classification ──────────────────────────────────────────────────────

/// Semantic category of an execution restriction.
/// Determines color, label, and icon — NOT just "Blocked" for everything.
enum _BlockType {
  /// User CHOSE this. AI is following rules. Not an error.
  modeRestricted,

  /// Asset or network is outside the user's mandate. Fixable in AI Control.
  outsideMandate,

  /// Per-trade cap or gas floor makes trade unviable. Fixable in AI Control.
  limitTooLow,

  /// No stable balance to trade with. Fixable by adding funds.
  noBalance,
}

/// Derives the semantic block type from a raw [blockReason] string.
_BlockType _classifyBlockReason(String? reason) {
  if (reason == null) return _BlockType.modeRestricted;
  final r = reason.toLowerCase();
  if (r.contains('manual mode')) return _BlockType.modeRestricted;
  if (r.contains('allowed-assets') || r.contains('allowed-networks')) {
    return _BlockType.outsideMandate;
  }
  if (r.contains('gas') ||
      r.contains('cap') ||
      r.contains('size') ||
      r.contains('viable') ||
      r.contains('per-tx') ||
      r.contains('limit')) {
    return _BlockType.limitTooLow;
  }
  if (r.contains('balance') || r.contains('stable'))
    return _BlockType.noBalance;
  return _BlockType.outsideMandate;
}

Color _blockColor(_BlockType t) => switch (t) {
      _BlockType.modeRestricted => Colors.amber.shade600,
      _BlockType.outsideMandate => Colors.orange.shade400,
      _BlockType.limitTooLow => Colors.deepOrangeAccent,
      _BlockType.noBalance => Colors.redAccent,
    };

String _blockLabel(_BlockType t) {
  final l = LocalizationService.instance;
  return switch (t) {
    _BlockType.modeRestricted => l.t('blockModeRestricted'),
    _BlockType.outsideMandate => l.t('blockOutsideMandate'),
    _BlockType.limitTooLow => l.t('blockLimitTooLow'),
    _BlockType.noBalance => l.t('blockNoBalance'),
  };
}

IconData _blockIcon(_BlockType t) => switch (t) {
      _BlockType.modeRestricted => Icons.shield_outlined,
      _BlockType.outsideMandate => Icons.do_not_disturb_alt_outlined,
      _BlockType.limitTooLow => Icons.tune_outlined,
      _BlockType.noBalance => Icons.account_balance_wallet_outlined,
    };

// ─── Priority Signals List ─────────────────────────────────────────────────────

/// Block 2: What does the AI recommend right now?
///
/// Shows exactly 1–3 signal cards.
/// If ALL signals are fully blocked by REAL execution blockers,
/// shows a [_BlockedStatePanel] instead of a list of identical red cards.
class PrioritySignalsList extends StatelessWidget {
  final List<MarketOpportunity> signals;
  final bool isLoading;

  const PrioritySignalsList({
    super.key,
    required this.signals,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mode = AiControlService.instance.settings.mode;

    // In Guarded mode, executableByAi=true still means "user must approve" —
    // that is NOT a blocked state, it's the correct protected state.
    final nonExecutable = signals.where((s) => !s.executableByAi).toList();
    final allBlocked =
        signals.isNotEmpty && nonExecutable.length == signals.length;
    final allModeOnly = allBlocked &&
        nonExecutable.every((s) =>
            _classifyBlockReason(s.blockReason) == _BlockType.modeRestricted);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  LocalizationService.instance.t('signalsTopNow'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Mode badge — makes clear this is protected, not broken.
              if (mode == AiMode.guarded) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    LocalizationService.instance.t('marketCmdYouApprove'),
                    style: TextStyle(
                      color: Colors.amber.shade600,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          if (isLoading)
            const _LoadingCard()
          else if (signals.isEmpty)
            const _EmptySignalsCard()
          // All blocked by mode only → single calm panel, not red cards.
          else if (allBlocked && allModeOnly)
            _ModeRestrictedPanel(mode: mode)
          // All blocked by real blockers → unified blocked state panel.
          else if (allBlocked)
            _BlockedStatePanel(signals: nonExecutable)
          else
            ...signals.map((s) => _SignalCard(signal: s)),
        ],
      ),
    );
  }
}

// ─── Mode-Restricted Panel ─────────────────────────────────────────────────────

/// Shown when AI is in Manual mode — all signals are restricted by user choice.
/// Not an error. The tone must be calm and informative, never alarming.
class _ModeRestrictedPanel extends StatelessWidget {
  final AiMode mode;
  const _ModeRestrictedPanel({required this.mode});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.amber.withOpacity(0.25),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined,
                  size: 16, color: Colors.amber.shade600),
              const SizedBox(width: 8),
              Text(
                mode == AiMode.manual
                    ? LocalizationService.instance.t('modeRestrictedTitle')
                    : LocalizationService.instance
                        .t('modeRestrictedTitleGuarded'),
                style: TextStyle(
                  color: Colors.amber.shade600,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            mode == AiMode.manual
                ? LocalizationService.instance.t('modeRestrictedManualBody')
                : LocalizationService.instance.t('modeRestrictedGuardedBody'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withOpacity(0.65),
              height: 1.45,
            ),
          ),
          if (mode == AiMode.manual) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _openAiControl(context),
                icon: const Icon(Icons.settings_outlined, size: 14),
                label: Text(
                    LocalizationService.instance.t('modeRestrictedSwitchBtn')),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.amber.shade600,
                  side: BorderSide(color: Colors.amber.withOpacity(0.4)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static void _openAiControl(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AIControlScreen()),
    );
  }
}

// ─── Blocked State Panel ───────────────────────────────────────────────────────

/// Shown when ALL signals are blocked by REAL execution blockers
/// (mandate, limit, balance) — not just by mode choice.
///
/// Instead of N identical red cards, shows one unified panel with:
///  - Primary block reason (most prominent constraint)
///  - Secondary constraints (others)
///  - What AI can still do
///  - Quick CTA actions to resolve
class _BlockedStatePanel extends StatelessWidget {
  final List<MarketOpportunity> signals;
  const _BlockedStatePanel({required this.signals});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Analyse the reason distribution across all blocked signals.
    final reasons =
        signals.map((s) => _classifyBlockReason(s.blockReason)).toList();
    final counts = <_BlockType, int>{};
    for (final r in reasons) {
      counts[r] = (counts[r] ?? 0) + 1;
    }

    // Primary: most common real blocker.
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final primaryType = sorted.first.key;
    final secondaryTypes = sorted.skip(1).map((e) => e.key).toList();

    final primaryColor = _blockColor(primaryType);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: primaryColor.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Primary block reason ───────────────────────────────────────────
          Row(
            children: [
              Icon(_blockIcon(primaryType), size: 15, color: primaryColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _primaryHeadline(primaryType),
                  style: TextStyle(
                    color: primaryColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _primaryExplanation(primaryType),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withOpacity(0.65),
              height: 1.45,
            ),
          ),

          // ── Secondary constraints ──────────────────────────────────────────
          if (secondaryTypes.isNotEmpty) ...[
            const SizedBox(height: 10),
            ...secondaryTypes.map((t) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.circle,
                          size: 5, color: _blockColor(t).withOpacity(0.7)),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          '${_blockLabel(t)}: ${_secondaryNote(t)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withOpacity(0.5),
                            fontSize: 11.5,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                )),
          ],

          // ── What AI can still do ───────────────────────────────────────────
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withOpacity(0.04),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.visibility_outlined,
                    size: 13,
                    color: theme.colorScheme.onSurface.withOpacity(0.5)),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    LocalizationService.instance.t('blockStillMonitoring'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withOpacity(0.55),
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Quick CTA actions ──────────────────────────────────────────────
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Text(
            LocalizationService.instance.t('marketCmdResolve'),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withOpacity(0.4),
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (primaryType == _BlockType.noBalance ||
                  secondaryTypes.contains(_BlockType.noBalance))
                _CtaChip(
                  label: LocalizationService.instance.t('ctaAddStablecoins'),
                  icon: Icons.add_outlined,
                  onTap: () => WalletSwapModal.show(context),
                ),
              if (primaryType == _BlockType.outsideMandate ||
                  secondaryTypes.contains(_BlockType.outsideMandate))
                _CtaChip(
                  label: LocalizationService.instance.t('ctaAmendMandate'),
                  icon: Icons.edit_outlined,
                  onTap: () => _openPolicyLimits(context),
                ),
              if (primaryType == _BlockType.limitTooLow ||
                  secondaryTypes.contains(_BlockType.limitTooLow))
                _CtaChip(
                  label: LocalizationService.instance.t('ctaRaisePerTrade'),
                  icon: Icons.tune_outlined,
                  onTap: () => _openPolicyLimits(context),
                ),
              if (primaryType != _BlockType.outsideMandate &&
                  !secondaryTypes.contains(_BlockType.outsideMandate) &&
                  primaryType != _BlockType.limitTooLow &&
                  !secondaryTypes.contains(_BlockType.limitTooLow))
                _CtaChip(
                  label: LocalizationService.instance.t('ctaAiControl'),
                  icon: Icons.settings_outlined,
                  onTap: () => _openAiControl(context),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static void _openAiControl(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AIControlScreen()),
    );
  }

  static void _openPolicyLimits(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PolicyLimitsScreen()),
    );
  }

  static String _primaryHeadline(_BlockType t) {
    final l = LocalizationService.instance;
    return switch (t) {
      _BlockType.modeRestricted => l.t('blockHeadlineModeRestricted'),
      _BlockType.outsideMandate => l.t('blockHeadlineOutsideMandate'),
      _BlockType.limitTooLow => l.t('blockHeadlineLimitTooLow'),
      _BlockType.noBalance => l.t('blockHeadlineNoBalance'),
    };
  }

  static String _primaryExplanation(_BlockType t) {
    final l = LocalizationService.instance;
    return switch (t) {
      _BlockType.modeRestricted => l.t('blockExplainModeRestricted'),
      _BlockType.outsideMandate => l.t('blockExplainOutsideMandate'),
      _BlockType.limitTooLow => l.t('blockExplainLimitTooLow'),
      _BlockType.noBalance => l.t('blockExplainNoBalance'),
    };
  }

  static String _secondaryNote(_BlockType t) {
    final l = LocalizationService.instance;
    return switch (t) {
      _BlockType.modeRestricted => l.t('blockNoteMode'),
      _BlockType.outsideMandate => l.t('blockNoteMandate'),
      _BlockType.limitTooLow => l.t('blockNoteLimit'),
      _BlockType.noBalance => l.t('blockNoteBalance'),
    };
  }
}

// ─── CTA Chip ──────────────────────────────────────────────────────────────────

class _CtaChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _CtaChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: theme.colorScheme.primary.withOpacity(0.25),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: theme.colorScheme.primary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Signal Card ───────────────────────────────────────────────────────────────

class _SignalCard extends StatelessWidget {
  final MarketOpportunity signal;
  const _SignalCard({required this.signal});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mode = AiControlService.instance.settings.mode;
    final isBlocked = !signal.executableByAi;

    // Semantic classification — different types get different treatment.
    final blockType =
        isBlocked ? _classifyBlockReason(signal.blockReason) : null;

    // "Can Act" vs "Approval required" vs real-blocker types.
    final String statusLabel;
    final Color statusColor;
    final IconData statusIcon;

    if (!isBlocked && mode == AiMode.guarded) {
      // Guarded + can act = user must approve. NOT "blocked". NOT "can act" freely.
      statusLabel = LocalizationService.instance.t('signalApprovalRequired');
      statusColor = Colors.amber.shade600;
      statusIcon = Icons.shield_outlined;
    } else if (!isBlocked) {
      // Full autonomy + can act.
      statusLabel = LocalizationService.instance.t('signalCanAct');
      statusColor = Colors.greenAccent.shade400;
      statusIcon = Icons.flash_on_outlined;
    } else {
      statusLabel = _blockLabel(blockType!);
      statusColor = _blockColor(blockType);
      statusIcon = _blockIcon(blockType);
    }

    final price = signal.asset.price;
    final change = signal.asset.change24h;
    final changeColor =
        change >= 0 ? Colors.greenAccent.shade400 : Colors.redAccent;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => openAssetActionSheet(context, signal),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: statusColor.withOpacity(isBlocked ? 0.18 : 0.35),
                width: 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Header ───────────────────────────────────────────────────
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: statusColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(statusIcon, size: 10, color: statusColor),
                          const SizedBox(width: 3),
                          Text(
                            statusLabel,
                            style: TextStyle(
                              color: statusColor,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      signal.asset.symbol,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '\$${_formatPrice(price)}',
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            PriceFormatter.percent(change),
                            style: TextStyle(
                              color: changeColor,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // ── AI verdict ────────────────────────────────────────────────
                Text(
                  signal.action,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),

                // ── Why this signal ───────────────────────────────────────────
                Text(
                  signal.thesis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.6),
                    height: 1.4,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),

                // ── What AI can do now ────────────────────────────────────────
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        statusIcon,
                        size: 13,
                        color: statusColor,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _whatAiCanDoNow(signal, mode),
                          style: TextStyle(
                            color: statusColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Block reason — only for REAL blockers, not mode ───────────
                if (isBlocked &&
                    blockType != _BlockType.modeRestricted &&
                    signal.blockReason != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    signal.blockReason!,
                    style: TextStyle(
                      color: _blockColor(blockType!).withOpacity(0.6),
                      fontSize: 11,
                      height: 1.3,
                    ),
                  ),
                ],

                // ── Action buttons ─────────────────────────────────────────
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _SignalActionButton(
                        icon: Icons.auto_awesome,
                        label: LocalizationService.instance
                            .t('marketPrepareTrade'),
                        color: statusColor,
                        onTap: () => openAssetActionSheet(context, signal),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SignalActionButton(
                        icon: Icons.swap_horiz_rounded,
                        label:
                            LocalizationService.instance.t('marketActionSwap'),
                        color: mode == AiMode.manual
                            ? theme.colorScheme.onSurface.withOpacity(0.25)
                            : Colors.cyan,
                        onTap: mode == AiMode.manual
                            ? null
                            : () => _openSwapForSignal(context, signal),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _whatAiCanDoNow(MarketOpportunity opp, AiMode mode) {
    final l = LocalizationService.instance;
    if (!opp.executableByAi) {
      final block = _classifyBlockReason(opp.blockReason);
      return switch (block) {
        _BlockType.modeRestricted => l.t('signalAiMonitorOnly'),
        _BlockType.outsideMandate => l.t('signalAiBlockedMandate'),
        _BlockType.limitTooLow => l.t('signalAiBlockedLimit'),
        _BlockType.noBalance => l.t('signalAiBlockedBalance'),
      };
    }
    if (mode == AiMode.guarded) return l.t('signalAiGuarded');
    final action = opp.action.toLowerCase();
    if (action.contains('buy') || action.contains('pullback')) {
      return l.t('signalAiCanBuy');
    }
    return l.t('signalAiCanTrade');
  }

  static void _openSwapForSignal(
      BuildContext context, MarketOpportunity signal) {
    final portfolio = VaultPortfolioListener.instance.summary;
    final match = portfolio?.allAssets
        .where(
            (a) => a.symbol.toLowerCase() == signal.asset.symbol.toLowerCase())
        .firstOrNull;

    final targetAsset = match ??
        WalletAsset(
          name: signal.asset.name,
          symbol: signal.asset.symbol,
          address: '',
          balance: 0,
          priceUsd: signal.asset.price,
          valueUsd: 0,
          decimals: 18,
          chainId: 1,
        );

    WalletSwapModal.show(context,
        initialToAsset: targetAsset, additionalAssets: [targetAsset]);
  }

  static String _formatPrice(double p) => PriceFormatter.price(p);
}

// ─── Signal Action Button ──────────────────────────────────────────────────────

class _SignalActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _SignalActionButton({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Material(
      color: color.withOpacity(disabled ? 0.04 : 0.08),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Asset Action Sheet ────────────────────────────────────────────────────────

class _AssetActionSheet extends StatelessWidget {
  final MarketOpportunity signal;
  const _AssetActionSheet({required this.signal});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = AiControlService.instance.settings;
    final mode = settings.mode;
    final isBlocked = !signal.executableByAi;
    final blockType =
        isBlocked ? _classifyBlockReason(signal.blockReason) : null;

    final exposure = WalletExposureService.instance
        .snapshotFor(signal.asset.symbol, settings.mandate);
    final hasPosition = exposure.currentPositionUsd > 0;

    return DraggableScrollableSheet(
      initialChildSize: 0.62,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (_, controller) => Container(
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(bottom: 14),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // ── Asset name + price ──────────────────────────────────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(signal.asset.name,
                          style: theme.textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      Text(signal.asset.symbol,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface
                                  .withOpacity(0.45))),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '\$${_fmt(signal.asset.price)}',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${PriceFormatter.percent(signal.asset.change24h)} 24h',
                      style: TextStyle(
                        color: signal.asset.change24h >= 0
                            ? Colors.greenAccent.shade400
                            : Colors.redAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 14),

            // ── AI Verdict ──────────────────────────────────────────────────
            _SheetSection(
              title: LocalizationService.instance.t('sheetAiVerdict'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(signal.action,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(signal.thesis,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withOpacity(0.65),
                          height: 1.5)),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // ── My Exposure ─────────────────────────────────────────────────
            _SheetSection(
              title: LocalizationService.instance.t('sheetMyExposure'),
              child: hasPosition
                  ? _ExposureDetail(
                      exposure: exposure, mandate: settings.mandate)
                  : Text(
                      LocalizationService.instance
                          .t('sheetNoPosition', {'asset': signal.asset.symbol}),
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withOpacity(0.55),
                          height: 1.4),
                    ),
            ),
            const SizedBox(height: 14),

            // ── What AI Can Do ──────────────────────────────────────────────
            _SheetSection(
              title: LocalizationService.instance.t('sheetWhatAiCanDo'),
              child: _CanActBlock(
                  signal: signal, mode: mode, blockType: blockType),
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 14),

            // ── Action buttons ──────────────────────────────────────────────
            _actionButtons(context, mode, blockType),
          ],
        ),
      ),
    );
  }

  Widget _actionButtons(
      BuildContext context, AiMode mode, _BlockType? blockType) {
    final isBlocked = !signal.executableByAi;

    // Real blocker — offer resolve actions.
    if (isBlocked && blockType != _BlockType.modeRestricted) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (blockType == _BlockType.noBalance)
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                WalletSwapModal.show(context);
              },
              icon: const Icon(Icons.add_outlined, size: 14),
              label:
                  Text(LocalizationService.instance.t('sheetAddStablecoins')),
            ),
          if (blockType == _BlockType.outsideMandate ||
              blockType == _BlockType.limitTooLow) ...[
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AIControlScreen()),
                );
              },
              icon: const Icon(Icons.edit_outlined, size: 14),
              label: Text(blockType == _BlockType.limitTooLow
                  ? LocalizationService.instance.t('sheetRaisePerTrade')
                  : LocalizationService.instance.t('sheetAmendMandate')),
            ),
          ],
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => Navigator.pop(context),
            child: Text(LocalizationService.instance.t('sheetDismiss')),
          ),
        ],
      );
    }

    // Mode-restricted (Manual) — calm, no alarm.
    if (isBlocked && blockType == _BlockType.modeRestricted) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AIControlScreen()),
              );
            },
            icon: const Icon(Icons.settings_outlined, size: 14),
            label: Text(LocalizationService.instance.t('sheetSwitchGuarded')),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => Navigator.pop(context),
            child: Text(LocalizationService.instance.t('sheetDismiss')),
          ),
        ],
      );
    }

    return switch (mode) {
      AiMode.manual => SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () => Navigator.pop(context),
            child: Text(LocalizationService.instance.t('sheetAnalysisOnly')),
          ),
        ),
      AiMode.guarded => Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: Text(LocalizationService.instance.t('sheetDismiss')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: () => _prepareBuy(context),
                child: Text(LocalizationService.instance.t('sheetPrepareBuy')),
              ),
            ),
          ],
        ),
      AiMode.fullAutonomy => Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: Text(LocalizationService.instance.t('sheetDismiss')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: () => _delegateToAi(context),
                child:
                    Text(LocalizationService.instance.t('sheetDelegateToAi')),
              ),
            ),
          ],
        ),
    };
  }

  void _prepareBuy(BuildContext context) {
    final gate = MarketPolicyGate.instance.checkSwap(signal.asset);
    if (!gate.isAllowed) return;
    Navigator.pop(context);

    final portfolio = VaultPortfolioListener.instance.summary;
    final holdingsMatch = portfolio?.allAssets
        .where(
          (a) => a.symbol.toLowerCase() == signal.asset.symbol.toLowerCase(),
        )
        .firstOrNull;

    if (context.mounted) {
      if (holdingsMatch == null) {
        final targetAsset = WalletAsset(
          name: signal.asset.name,
          symbol: signal.asset.symbol,
          address: '',
          balance: 0,
          priceUsd: signal.asset.price,
          valueUsd: 0,
          decimals: 18,
          chainId: 1,
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LocalizationService.instance
                .t('sheetSearchToken', {'asset': signal.asset.symbol})),
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
          ),
        );
        WalletSwapModal.show(context,
            initialToAsset: targetAsset, additionalAssets: [targetAsset]);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LocalizationService.instance
                .t('sheetOpeningPreview', {'asset': signal.asset.symbol})),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        WalletSwapModal.show(context,
            initialToAsset: holdingsMatch, additionalAssets: [holdingsMatch]);
      }
    }
  }

  void _delegateToAi(BuildContext context) {
    Navigator.pop(context);
    final trigger = AutomationTrigger(
      id: 'manual_${signal.asset.symbol}_${DateTime.now().millisecondsSinceEpoch}',
      assetSymbol: signal.asset.symbol,
      type: TriggerType.manualDelegate,
      requestedAction: TriggerAction.execute,
      createdAt: DateTime.now(),
      label: 'Manual: ${signal.asset.symbol} — ${signal.action}',
    );
    AutomationDispatchService.instance.enqueue(
      trigger: trigger,
      reason: 'User delegated from Market Command Center: ${signal.thesis}',
      currentPrice: signal.asset.price,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(LocalizationService.instance
              .t('sheetQueuedOk', {'asset': signal.asset.symbol})),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  static String _fmt(double p) => PriceFormatter.price(p);
}

// ─── Sheet sub-widgets ─────────────────────────────────────────────────────────

class _SheetSection extends StatelessWidget {
  final String title;
  final Widget child;
  const _SheetSection({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.3)),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _ExposureDetail extends StatelessWidget {
  final ExposureSnapshot exposure;
  final AutonomyMandate mandate;
  const _ExposureDetail({required this.exposure, required this.mandate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actionColor = switch (exposure.action) {
      ExposureAction.add => Colors.greenAccent.shade400,
      ExposureAction.addCaution => Colors.amber.shade600,
      ExposureAction.hold => Colors.orange,
      ExposureAction.blockedByExposure => Colors.redAccent,
    };
    final l = LocalizationService.instance;
    final actionLabel = switch (exposure.action) {
      ExposureAction.add => l.t('exposureRoomToAdd'),
      ExposureAction.addCaution => l.t('exposureApproaching'),
      ExposureAction.hold => l.t('exposureNearLimit'),
      ExposureAction.blockedByExposure => l.t('exposureOverLimit'),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              l.t('exposureCurrent', {
                'amount': '\$${exposure.currentPositionUsd.toStringAsFixed(2)}'
              }),
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 12),
            if (mandate.maxPositionUsd > 0)
              Text(
                l.t('exposureCap', {
                  'amount': '\$${mandate.maxPositionUsd.toStringAsFixed(0)}'
                }),
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.45)),
              ),
          ],
        ),
        const SizedBox(height: 4),
        if (mandate.maxPositionUsd > 0) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (exposure.usedPct / 100).clamp(0.0, 1.0),
              backgroundColor: theme.colorScheme.onSurface.withOpacity(0.1),
              valueColor: AlwaysStoppedAnimation(actionColor),
              minHeight: 5,
            ),
          ),
          const SizedBox(height: 4),
        ],
        Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration:
                  BoxDecoration(shape: BoxShape.circle, color: actionColor),
            ),
            const SizedBox(width: 6),
            Text(actionLabel,
                style: TextStyle(
                    color: actionColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
            if (!exposure.isOverLimit && mandate.maxPositionUsd > 0) ...[
              const SizedBox(width: 8),
              Text(
                l.t('exposureRoomValue', {
                  'amount':
                      '\$${exposure.remainingCapacityUsd.toStringAsFixed(0)}'
                }),
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.45)),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _CanActBlock extends StatelessWidget {
  final MarketOpportunity signal;
  final AiMode mode;
  final _BlockType? blockType;

  const _CanActBlock({
    required this.signal,
    required this.mode,
    required this.blockType,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isBlocked = !signal.executableByAi;

    final String canDoLine;
    final String nextLine;
    final Color color;

    final l = LocalizationService.instance;

    if (mode == AiMode.manual) {
      canDoLine = l.t('canActManualLine');
      nextLine = l.t('canActManualNext');
      color = Colors.amber.shade600;
    } else if (isBlocked && blockType == _BlockType.outsideMandate) {
      canDoLine = l.t('canActOutsideMandate');
      nextLine = l.t('canActOutsideMandateNext');
      color = Colors.orange.shade400;
    } else if (isBlocked && blockType == _BlockType.limitTooLow) {
      canDoLine = l.t('canActLimitTooLow');
      nextLine = l.t('canActLimitTooLowNext');
      color = Colors.deepOrangeAccent;
    } else if (isBlocked && blockType == _BlockType.noBalance) {
      canDoLine = l.t('canActNoBalance');
      nextLine = l.t('canActNoBalanceNext');
      color = Colors.redAccent;
    } else if (isBlocked) {
      canDoLine = signal.blockReason ?? l.t('canActBlocked');
      nextLine = l.t('canActBlockedNext');
      color = Colors.redAccent;
    } else if (mode == AiMode.guarded) {
      canDoLine = l.t('canActGuarded');
      nextLine = l.t('canActGuardedNext');
      color = Colors.amber.shade600;
    } else {
      canDoLine = l.t('canActFull');
      nextLine = l.t('canActFullNext');
      color = Colors.greenAccent.shade400;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(canDoLine,
            style: TextStyle(
                color: color, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(nextLine,
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
                height: 1.4)),
      ],
    );
  }
}

// ─── Empty / loading states ────────────────────────────────────────────────────

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 90,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Center(child: CircularProgressIndicator()),
    );
  }
}

class _EmptySignalsCard extends StatelessWidget {
  const _EmptySignalsCard();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        LocalizationService.instance.t('signalsNoData'),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
            ),
      ),
    );
  }
}
