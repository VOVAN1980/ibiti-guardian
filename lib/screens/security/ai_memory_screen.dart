import 'package:flutter/material.dart';
import 'package:ibiti_guardian/models/user_memory.dart';
import 'package:ibiti_guardian/services/assistant/user_memory_service.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AI Memory Screen — "Что AI помнит обо мне"
//
// Shows and manages personal vocabulary, voice macros, and preferences.
// Accessible from the AI Control Center.
// ─────────────────────────────────────────────────────────────────────────────

class AiMemoryScreen extends StatefulWidget {
  const AiMemoryScreen({super.key});

  @override
  State<AiMemoryScreen> createState() => _AiMemoryScreenState();
}

class _AiMemoryScreenState extends State<AiMemoryScreen> {
  final _memory = UserMemoryService.instance;

  @override
  void initState() {
    super.initState();
    _memory.revision.addListener(_onMemoryChanged);
  }

  @override
  void dispose() {
    _memory.revision.removeListener(_onMemoryChanged);
    super.dispose();
  }

  void _onMemoryChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l = LocalizationService.instance;
    final vocab = _memory.allVocab;
    final macros = _memory.allMacros;
    final prefs = _memory.preferences;

    return Scaffold(
      backgroundColor: GuardianColors.background,
      appBar: AppBar(
        title: Text(
          l.t('memoryTitle'),
          style: GuardianTextStyles.headline.copyWith(fontSize: 20),
        ),
        backgroundColor: GuardianColors.background,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              color: GuardianColors.textPrimary, size: 24),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert,
                color: GuardianColors.textSecondary),
            color: GuardianColors.surface,
            onSelected: (val) async {
              switch (val) {
                case 'clear_vocab':
                  final ok = await _showSectionClearConfirm(
                      context, l.t('memoryVocabTitle'));
                  if (ok == true) {
                    for (final v in List.of(_memory.allVocab)) {
                      await _memory.removeVocab(v.phrase);
                    }
                  }
                case 'clear_macros':
                  final ok = await _showSectionClearConfirm(
                      context, l.t('memoryMacrosTitle'));
                  if (ok == true) {
                    // Only remove user-created macros; defaults survive.
                    for (final m in List.of(_memory.allMacros)) {
                      if (!_memory.isDefaultMacro(m)) {
                        await _memory.removeMacro(m.triggerPhrase);
                      }
                    }
                  }
                case 'clear_prefs':
                  final ok = await _showSectionClearConfirm(
                      context, l.t('memoryPrefsTitle'));
                  if (ok == true) {
                    await _memory.updatePreference('preferredStablecoin', null);
                    await _memory.updatePreference('preferredVenue', null);
                    await _memory.updatePreference('preferredNetwork', null);
                    await _memory.updatePreference('reviewStyle', 'concise');
                    await _memory.updatePreference(
                        'showPlanBeforeExecute', true);
                  }
                case 'clear_all':
                  final confirmed = await _showClearConfirm(context);
                  if (confirmed == true) await _memory.clearAll();
              }
            },
            itemBuilder: (_) => [
              _menuItem('clear_vocab', Icons.menu_book_outlined,
                  l.t('memoryClearVocab')),
              _menuItem('clear_macros', Icons.bolt_outlined,
                  l.t('memoryClearMacros')),
              _menuItem(
                  'clear_prefs', Icons.tune_outlined, l.t('memoryClearPrefs')),
              const PopupMenuDivider(),
              _menuItem(
                  'clear_all', Icons.delete_forever, l.t('memoryClearAll'),
                  color: GuardianColors.danger),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Summary card ──────────────────────────────────────────────
            _SummaryCard(vocabCount: vocab.length, macroCount: macros.length),
            const SizedBox(height: 24),

            // ── Personal Vocabulary ──────────────────────────────────────
            _sectionHeader(l.t('memoryVocabTitle'), Icons.menu_book_outlined),
            if (vocab.isEmpty)
              _emptyHint(l.t('memoryVocabEmpty'))
            else
              ...vocab.map((v) => _VocabTile(
                    entry: v,
                    onDelete: () => _memory.removeVocab(v.phrase),
                  )),
            const SizedBox(height: 8),
            _addButton(
                l.t('memoryVocabAdd'), () => _showAddVocabDialog(context)),
            const SizedBox(height: 24),

            // ── Voice Macros ─────────────────────────────────────────────
            _sectionHeader(l.t('memoryMacrosTitle'), Icons.bolt_outlined),
            if (macros.isEmpty)
              _emptyHint(l.t('memoryMacrosEmpty'))
            else
              ...macros.map((m) => _MacroTile(
                    macro: m,
                    isDefault: _memory.isDefaultMacro(m),
                    onDelete: _memory.isDefaultMacro(m)
                        ? null
                        : () => _memory.removeMacro(m.triggerPhrase),
                    onDuplicate: _memory.isDefaultMacro(m)
                        ? () => _duplicateBuiltInMacro(m)
                        : null,
                  )),
            const SizedBox(height: 8),
            _addButton(
                l.t('memoryMacroAdd'), () => _showAddMacroDialog(context)),
            const SizedBox(height: 24),

            // ── Preferences ──────────────────────────────────────────────
            _sectionHeader(l.t('memoryPrefsTitle'), Icons.tune_outlined),
            _card([
              _chipPrefRow(
                l.t('memoryPrefStablecoin'),
                prefs.preferredStablecoin,
                _stablecoinOptions,
                (val) => _memory.updatePreference('preferredStablecoin', val),
              ),
              _divider(),
              _chipPrefRow(
                l.t('memoryPrefVenue'),
                prefs.preferredVenue,
                _venueOptions,
                (val) => _memory.updatePreference('preferredVenue', val),
              ),
              _divider(),
              _chipPrefRow(
                l.t('memoryPrefNetwork'),
                prefs.preferredNetwork,
                _networkOptions,
                (val) => _memory.updatePreference('preferredNetwork', val),
              ),
              _divider(),
              _chipPrefRow(
                l.t('memoryPrefReviewStyle'),
                prefs.reviewStyle,
                _reviewStyleOptions,
                (val) =>
                    _memory.updatePreference('reviewStyle', val ?? 'concise'),
                labels: _reviewStyleLabels,
              ),
              _divider(),
              _switchRow(
                l.t('memoryPrefShowPlan'),
                prefs.showPlanBeforeExecute,
                onChanged: (val) =>
                    _memory.updatePreference('showPlanBeforeExecute', val),
              ),
            ]),
            const SizedBox(height: 24),

            // ── How to teach ─────────────────────────────────────────────
            const _HowToTeachCard(),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }

  // ── Option lists for chip pickers ─────────────────────────────────────────
  static const _stablecoinOptions = [
    'USDT',
    'USDC',
    'BUSD',
    'DAI',
    'TUSD',
    'FDUSD'
  ];
  static const _venueOptions = [
    // CEX
    'Binance', 'MEXC', 'OKX', 'Kucoin', 'Gate.io', 'HTX',
    // DEX
    'PancakeSwap', 'Uniswap', 'Jupiter', '1inch', 'SunSwap',
    'SushiSwap', 'Raydium', 'Orca',
  ];
  static const _networkOptions = [
    'BSC',
    'Ethereum',
    'Tron',
    'Solana',
    'Polygon',
    'Arbitrum',
    'Base',
    'Optimism',
    'Avalanche',
    'TON',
  ];
  static const _reviewStyleOptions = ['concise', 'detailed'];
  Map<String, String> get _reviewStyleLabels {
    final l = LocalizationService.instance;
    return {
      'concise': l.t('memoryPrefConcise'),
      'detailed': l.t('memoryPrefDetailed')
    };
  }

  // ── Menu helper ───────────────────────────────────────────────────────────
  PopupMenuItem<String> _menuItem(String value, IconData icon, String label,
          {Color color = GuardianColors.textPrimary}) =>
      PopupMenuItem(
        value: value,
        child: Row(
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(color: color, fontSize: 14)),
          ],
        ),
      );

  // ── Section header ──────────────────────────────────────────────────────

  Widget _sectionHeader(String title, IconData icon) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            Icon(icon, color: GuardianColors.accent, size: 16),
            const SizedBox(width: 8),
            Text(title.toUpperCase(),
                style: GuardianTextStyles.caption.copyWith(
                    color: GuardianColors.textSecondary,
                    letterSpacing: 1.3,
                    fontWeight: FontWeight.w700,
                    fontSize: 11)),
          ],
        ),
      );

  Widget _emptyHint(String text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        decoration: BoxDecoration(
          color: GuardianColors.surface.withOpacity(0.3),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: GuardianColors.border.withOpacity(0.2),
              style: BorderStyle.solid),
        ),
        child: Text(text,
            textAlign: TextAlign.center,
            style: GuardianTextStyles.bodySecondary.copyWith(
                fontSize: 13,
                color: GuardianColors.textSecondary.withOpacity(0.6))),
      );

  Widget _addButton(String text, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: GuardianColors.accent.withOpacity(0.3)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.add_circle_outline,
                  color: GuardianColors.accent, size: 18),
              const SizedBox(width: 8),
              Text(text,
                  style: GuardianTextStyles.bodyPrimary.copyWith(
                      color: GuardianColors.accent,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      );

  // ── Card helpers ────────────────────────────────────────────────────────

  Widget _card(List<Widget> items) => Container(
        decoration: BoxDecoration(
          color: GuardianColors.surface.withOpacity(0.5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: GuardianColors.border.withOpacity(0.4)),
        ),
        child: Column(children: items),
      );

  Widget _divider() => Divider(
      height: 1,
      indent: 16,
      endIndent: 16,
      color: GuardianColors.border.withOpacity(0.3));

  Widget _prefRow(String label, String value, {VoidCallback? onTap}) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Expanded(
                  child: Text(label,
                      style: GuardianTextStyles.bodyPrimary
                          .copyWith(fontSize: 14))),
              Text(value,
                  style: GuardianTextStyles.bodySecondary
                      .copyWith(fontSize: 14, color: GuardianColors.accent)),
              if (onTap != null) ...[
                const SizedBox(width: 6),
                const Icon(Icons.swap_horiz,
                    size: 14, color: GuardianColors.textSecondary),
              ],
            ],
          ),
        ),
      );

  /// Collapsible chip-based preference selector.
  /// Shows current value in a compact row. Tap to expand the picker.
  Widget _chipPrefRow(String label, String? current, List<String> options,
          ValueChanged<String?> onSelected,
          {Map<String, String>? labels}) =>
      _CollapsibleChipPref(
        label: label,
        current: current,
        options: options,
        labels: labels,
        onSelected: onSelected,
      );

  Widget _chip(String label, bool selected, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? GuardianColors.accent.withOpacity(0.15)
                : GuardianColors.surface.withOpacity(0.3),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? GuardianColors.accent.withOpacity(0.5)
                  : GuardianColors.border.withOpacity(0.3),
            ),
          ),
          child: Text(label,
              style: TextStyle(
                  color: selected
                      ? GuardianColors.accent
                      : GuardianColors.textSecondary,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
        ),
      );

  Widget _switchRow(String label, bool value,
          {required ValueChanged<bool> onChanged}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
                child: Text(label,
                    style:
                        GuardianTextStyles.bodyPrimary.copyWith(fontSize: 14))),
            Switch.adaptive(
              value: value,
              onChanged: onChanged,
              activeColor: GuardianColors.accent,
            ),
          ],
        ),
      );

  // ── Dialogs ─────────────────────────────────────────────────────────────

  Future<bool?> _showClearConfirm(BuildContext context) {
    final l = LocalizationService.instance;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GuardianColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l.t('memoryClearConfirmTitle'),
            style: const TextStyle(color: GuardianColors.textPrimary)),
        content: Text(l.t('memoryClearConfirmBody'),
            style: const TextStyle(color: GuardianColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.t('memoryCancel'),
                style: const TextStyle(color: GuardianColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.t('memoryClearAll'),
                style: const TextStyle(color: GuardianColors.danger)),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showSectionClearConfirm(BuildContext context, String section) {
    final l = LocalizationService.instance;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GuardianColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l.t('memoryClearSectionTitle', {'section': section}),
            style: const TextStyle(color: GuardianColors.textPrimary)),
        content: Text(l.t('memoryClearSectionBody', {'section': section}),
            style: const TextStyle(color: GuardianColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.t('memoryCancel'),
                style: const TextStyle(color: GuardianColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.t('memoryClearSection'),
                style: const TextStyle(color: GuardianColors.danger)),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddVocabDialog(BuildContext context) async {
    final l = LocalizationService.instance;
    final phraseController = TextEditingController();
    final meaningController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GuardianColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l.t('memoryVocabAdd'),
            style: const TextStyle(color: GuardianColors.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: phraseController,
              style: const TextStyle(color: GuardianColors.textPrimary),
              decoration: InputDecoration(
                labelText: l.t('memoryVocabPhrase'),
                labelStyle:
                    const TextStyle(color: GuardianColors.textSecondary),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(
                        color: GuardianColors.border.withOpacity(0.5))),
                focusedBorder: const UnderlineInputBorder(
                    borderSide: BorderSide(color: GuardianColors.accent)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: meaningController,
              style: const TextStyle(color: GuardianColors.textPrimary),
              decoration: InputDecoration(
                labelText: l.t('memoryVocabMeaning'),
                labelStyle:
                    const TextStyle(color: GuardianColors.textSecondary),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(
                        color: GuardianColors.border.withOpacity(0.5))),
                focusedBorder: const UnderlineInputBorder(
                    borderSide: BorderSide(color: GuardianColors.accent)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.t('memoryCancel'),
                style: const TextStyle(color: GuardianColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.t('memorySave'),
                style: const TextStyle(color: GuardianColors.accent)),
          ),
        ],
      ),
    );

    if (result == true) {
      final phrase = phraseController.text.trim();
      final meaning = meaningController.text.trim();
      if (phrase.isNotEmpty && meaning.isNotEmpty) {
        await _memory.addVocab(phrase: phrase, normalizedMeaning: meaning);
      }
    }
  }

  /// Full macro creation dialog.
  Future<void> _showAddMacroDialog(BuildContext context) async {
    final l = LocalizationService.instance;
    final triggerCtl = TextEditingController();
    final descCtl = TextEditingController();
    bool requireConfirm = true;
    bool risky = false;
    final selectedModes = <AiMode>{...AiMode.values};

    // Available action templates — user picks from these.
    final actionTemplates = <_MacroActionTemplate>[
      _MacroActionTemplate('panic', l.t('memoryMacroActPanic'),
          const MacroAction(type: MacroActionType.openModal, target: 'panic')),
      _MacroActionTemplate('safe', l.t('memoryMacroActSafe'),
          const MacroAction(type: MacroActionType.openModal, target: 'safe')),
      _MacroActionTemplate(
          'revoke',
          l.t('memoryMacroActRevoke'),
          const MacroAction(
              type: MacroActionType.executeAction, target: 'revoke_all')),
      _MacroActionTemplate(
          'manual',
          l.t('memoryMacroActManual'),
          const MacroAction(
              type: MacroActionType.switchMode, target: 'manual')),
      _MacroActionTemplate(
          'guarded',
          l.t('memoryMacroActGuarded'),
          const MacroAction(
              type: MacroActionType.switchMode, target: 'guarded')),
      _MacroActionTemplate(
          'full_auto',
          l.t('memoryMacroActFullAuto'),
          const MacroAction(
              type: MacroActionType.switchMode, target: 'fullAutonomy')),
      _MacroActionTemplate('market', l.t('memoryMacroActMarket'),
          const MacroAction(type: MacroActionType.navigate, target: 'market')),
      _MacroActionTemplate('wallet', l.t('memoryMacroActWallet'),
          const MacroAction(type: MacroActionType.navigate, target: 'wallet')),
      _MacroActionTemplate(
          'swap',
          l.t('memoryMacroActSwap'),
          const MacroAction(
              type: MacroActionType.openModal, target: 'wallet_swap')),
      _MacroActionTemplate(
          'send',
          l.t('memoryMacroActSend'),
          const MacroAction(
              type: MacroActionType.openModal, target: 'wallet_send')),
      _MacroActionTemplate(
          'plan',
          l.t('memoryMacroActPlan'),
          const MacroAction(
              type: MacroActionType.navigate, target: 'showTradingPlan')),
    ];
    final selected = <String>{};

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocalState) => AlertDialog(
          backgroundColor: GuardianColors.surface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(l.t('memoryMacroAdd'),
              style: const TextStyle(color: GuardianColors.textPrimary)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: triggerCtl,
                  style: const TextStyle(color: GuardianColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: l.t('memoryMacroTrigger'),
                    labelStyle:
                        const TextStyle(color: GuardianColors.textSecondary),
                    enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(
                            color: GuardianColors.border.withOpacity(0.5))),
                    focusedBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: GuardianColors.accent)),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: descCtl,
                  style: const TextStyle(color: GuardianColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: l.t('memoryMacroDesc'),
                    labelStyle:
                        const TextStyle(color: GuardianColors.textSecondary),
                    enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(
                            color: GuardianColors.border.withOpacity(0.5))),
                    focusedBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: GuardianColors.accent)),
                  ),
                ),
                const SizedBox(height: 16),
                Text(l.t('memoryMacroActions'),
                    style: GuardianTextStyles.caption.copyWith(
                        color: GuardianColors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: actionTemplates.map((t) {
                    final isOn = selected.contains(t.id);
                    return FilterChip(
                      label: Text(t.label,
                          style: TextStyle(
                              color: isOn
                                  ? GuardianColors.accent
                                  : GuardianColors.textSecondary,
                              fontSize: 12)),
                      selected: isOn,
                      onSelected: (val) => setLocalState(() {
                        val ? selected.add(t.id) : selected.remove(t.id);
                      }),
                      selectedColor: GuardianColors.accent.withOpacity(0.15),
                      backgroundColor: GuardianColors.surface.withOpacity(0.5),
                      checkmarkColor: GuardianColors.accent,
                      side: BorderSide(
                          color: isOn
                              ? GuardianColors.accent.withOpacity(0.5)
                              : GuardianColors.border.withOpacity(0.3)),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 14),
                Text(l.t('memoryMacroModesLabel'),
                    style: GuardianTextStyles.caption.copyWith(
                        color: GuardianColors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: AiMode.values.map((mode) {
                    final isOn = selectedModes.contains(mode);
                    final mLabel = switch (mode) {
                      AiMode.manual => 'Manual',
                      AiMode.guarded => 'Guarded',
                      AiMode.fullAutonomy => 'Full Auto',
                    };
                    return FilterChip(
                      label: Text(mLabel,
                          style: TextStyle(
                              color: isOn
                                  ? GuardianColors.primary
                                  : GuardianColors.textSecondary,
                              fontSize: 12)),
                      selected: isOn,
                      onSelected: (val) => setLocalState(() {
                        val
                            ? selectedModes.add(mode)
                            : selectedModes.remove(mode);
                        // At least one mode must be selected.
                        if (selectedModes.isEmpty) selectedModes.add(mode);
                      }),
                      selectedColor: GuardianColors.primary.withOpacity(0.15),
                      backgroundColor: GuardianColors.surface.withOpacity(0.5),
                      checkmarkColor: GuardianColors.primary,
                      side: BorderSide(
                          color: isOn
                              ? GuardianColors.primary.withOpacity(0.5)
                              : GuardianColors.border.withOpacity(0.3)),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(l.t('memoryMacroConfirmToggle'),
                          style: GuardianTextStyles.bodyPrimary
                              .copyWith(fontSize: 13)),
                    ),
                    Switch.adaptive(
                      value: requireConfirm,
                      onChanged: (v) => setLocalState(() => requireConfirm = v),
                      activeColor: GuardianColors.accent,
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(l.t('memoryMacroRiskyToggle'),
                          style: GuardianTextStyles.bodyPrimary
                              .copyWith(fontSize: 13)),
                    ),
                    Switch.adaptive(
                      value: risky,
                      onChanged: (v) => setLocalState(() => risky = v),
                      activeColor: GuardianColors.danger,
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.t('memoryCancel'),
                  style: const TextStyle(color: GuardianColors.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.t('memorySave'),
                  style: const TextStyle(color: GuardianColors.accent)),
            ),
          ],
        ),
      ),
    );

    if (result == true) {
      final trigger = triggerCtl.text.trim();
      final desc = descCtl.text.trim();
      if (trigger.isNotEmpty && selected.isNotEmpty) {
        final actions = actionTemplates
            .where((t) => selected.contains(t.id))
            .map((t) => t.action)
            .toList();
        await _memory.addMacro(VoiceMacro(
          triggerPhrase: trigger,
          description:
              desc.isNotEmpty ? desc : actions.map((a) => a.target).join(' → '),
          actions: actions,
          requiresConfirmation: requireConfirm,
          allowedModes: selectedModes,
          isRisky: risky,
          createdAt: DateTime.now(),
        ));
      }
    }
  }

  /// Duplicate a built-in macro as a custom one with a new trigger phrase.
  Future<void> _duplicateBuiltInMacro(VoiceMacro source) async {
    final l = LocalizationService.instance;
    final triggerCtl = TextEditingController(text: '${source.triggerPhrase} 2');

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GuardianColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l.t('memoryMacroDuplicate'),
            style: const TextStyle(color: GuardianColors.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
                l.t('memoryMacroDuplicateHint',
                    {'source': source.triggerPhrase}),
                style: GuardianTextStyles.bodySecondary.copyWith(fontSize: 13)),
            const SizedBox(height: 14),
            TextField(
              controller: triggerCtl,
              autofocus: true,
              style: const TextStyle(color: GuardianColors.textPrimary),
              decoration: InputDecoration(
                labelText: l.t('memoryMacroTrigger'),
                labelStyle:
                    const TextStyle(color: GuardianColors.textSecondary),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(
                        color: GuardianColors.border.withOpacity(0.5))),
                focusedBorder: const UnderlineInputBorder(
                    borderSide: BorderSide(color: GuardianColors.accent)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.t('memoryCancel'),
                style: const TextStyle(color: GuardianColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, triggerCtl.text.trim()),
            child: Text(l.t('memoryMacroDuplicateBtn'),
                style: const TextStyle(color: GuardianColors.accent)),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      await _memory.addMacro(VoiceMacro(
        triggerPhrase: result,
        description: source.description,
        actions: source.actions,
        requiresConfirmation: source.requiresConfirmation,
        allowedModes: source.allowedModes,
        isRisky: source.isRisky,
        createdAt: DateTime.now(),
      ));
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Helper data class for macro action templates
// ═════════════════════════════════════════════════════════════════════════════

class _MacroActionTemplate {
  final String id;
  final String label;
  final MacroAction action;
  const _MacroActionTemplate(this.id, this.label, this.action);
}

// ═════════════════════════════════════════════════════════════════════════════
// Tiles
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// Collapsible chip preference selector
// ─────────────────────────────────────────────────────────────────────────────

class _CollapsibleChipPref extends StatefulWidget {
  final String label;
  final String? current;
  final List<String> options;
  final Map<String, String>? labels;
  final ValueChanged<String?> onSelected;

  const _CollapsibleChipPref({
    required this.label,
    required this.current,
    required this.options,
    required this.onSelected,
    this.labels,
  });

  @override
  State<_CollapsibleChipPref> createState() => _CollapsibleChipPrefState();
}

class _CollapsibleChipPrefState extends State<_CollapsibleChipPref>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;

  late final AnimationController _animCtrl;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      _animCtrl.forward();
    } else {
      _animCtrl.reverse();
    }
  }

  String get _displayValue {
    if (widget.current == null) return '—';
    return widget.labels?[widget.current!] ?? widget.current!;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Header row — always visible ───────────────────────────────
        InkWell(
          onTap: _toggle,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                Expanded(
                  child: Text(widget.label,
                      style: GuardianTextStyles.bodyPrimary
                          .copyWith(fontSize: 14)),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: Text(
                    _displayValue,
                    key: ValueKey(_displayValue),
                    style: GuardianTextStyles.bodySecondary.copyWith(
                        fontSize: 13,
                        color: widget.current != null
                            ? GuardianColors.accent
                            : GuardianColors.textSecondary),
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedRotation(
                  turns: _expanded ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 220),
                  child: const Icon(Icons.expand_more,
                      size: 18, color: GuardianColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
        // ── Chip panel — animates in/out ──────────────────────────────
        SizeTransition(
          sizeFactor: _fadeAnim,
          axisAlignment: -1,
          child: FadeTransition(
            opacity: _fadeAnim,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (widget.labels == null)
                    _buildChip('—', widget.current == null, () {
                      widget.onSelected(null);
                      _toggle();
                    }),
                  ...widget.options.map((opt) => _buildChip(
                        widget.labels?[opt] ?? opt,
                        widget.current == opt,
                        () {
                          widget.onSelected(opt);
                          _toggle();
                        },
                      )),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChip(String label, bool selected, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? GuardianColors.accent.withOpacity(0.15)
                : GuardianColors.surface.withOpacity(0.3),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? GuardianColors.accent.withOpacity(0.5)
                  : GuardianColors.border.withOpacity(0.3),
            ),
          ),
          child: Text(label,
              style: TextStyle(
                  color: selected
                      ? GuardianColors.accent
                      : GuardianColors.textSecondary,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
        ),
      );
}

class _SummaryCard extends StatelessWidget {
  final int vocabCount;
  final int macroCount;
  const _SummaryCard({required this.vocabCount, required this.macroCount});

  @override
  Widget build(BuildContext context) {
    final l = LocalizationService.instance;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            GuardianColors.accent.withOpacity(0.12),
            GuardianColors.primary.withOpacity(0.06),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: GuardianColors.accent.withOpacity(0.2)),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: GuardianColors.accent.withOpacity(0.15),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(Icons.psychology_outlined,
              color: GuardianColors.accent, size: 28),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.t('memorySummaryTitle'),
                  style: GuardianTextStyles.bodyPrimary
                      .copyWith(fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 4),
              Text(
                l.t('memorySummaryBody', {
                  'vocab': vocabCount.toString(),
                  'macros': macroCount.toString(),
                }),
                style: GuardianTextStyles.bodySecondary.copyWith(fontSize: 12),
              ),
            ],
          ),
        ),
      ]),
    );
  }
}

class _VocabTile extends StatelessWidget {
  final VocabEntry entry;
  final VoidCallback onDelete;
  const _VocabTile({required this.entry, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: GuardianColors.surface.withOpacity(0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: GuardianColors.border.withOpacity(0.3)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: GuardianColors.accent.withOpacity(0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.format_quote_outlined,
              color: GuardianColors.accent, size: 18),
        ),
        title: Text(
          '«${entry.phrase}»',
          style: GuardianTextStyles.bodyPrimary
              .copyWith(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '→ ${entry.normalizedMeaning}',
          style: GuardianTextStyles.bodySecondary.copyWith(
              fontSize: 12, color: GuardianColors.accent.withOpacity(0.8)),
        ),
        trailing: IconButton(
          icon: Icon(Icons.delete_outline,
              color: GuardianColors.danger.withOpacity(0.6), size: 20),
          onPressed: onDelete,
        ),
      ),
    );
  }
}

class _MacroTile extends StatelessWidget {
  final VoiceMacro macro;
  final bool isDefault;
  final VoidCallback? onDelete;
  final VoidCallback? onDuplicate;
  const _MacroTile(
      {required this.macro,
      this.isDefault = false,
      this.onDelete,
      this.onDuplicate});

  String _modeShortLabel(AiMode mode) => switch (mode) {
        AiMode.manual => 'M',
        AiMode.guarded => 'G',
        AiMode.fullAutonomy => 'A',
      };

  @override
  Widget build(BuildContext context) {
    final l = LocalizationService.instance;
    final isRisky = macro.isRisky;
    final allModes = macro.allowedModes.length == AiMode.values.length;
    final modesLabel = allModes
        ? l.t('memoryMacroModesAll')
        : macro.allowedModes.map(_modeShortLabel).join('/');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: GuardianColors.surface.withOpacity(0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isRisky
              ? GuardianColors.danger.withOpacity(0.3)
              : GuardianColors.border.withOpacity(0.3),
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: (isRisky ? GuardianColors.danger : GuardianColors.warning)
                .withOpacity(0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            isDefault
                ? Icons.lock_outline
                : isRisky
                    ? Icons.warning_amber_outlined
                    : Icons.bolt_outlined,
            color: isDefault
                ? GuardianColors.accent
                : isRisky
                    ? GuardianColors.danger
                    : GuardianColors.warning,
            size: 18,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                '«${macro.triggerPhrase}»',
                style: GuardianTextStyles.bodyPrimary
                    .copyWith(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            if (isDefault)
              _badge(l.t('memoryMacroDefault'), GuardianColors.accent),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              macro.description,
              style: GuardianTextStyles.bodySecondary.copyWith(fontSize: 12),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                if (macro.requiresConfirmation)
                  _badge(l.t('memoryMacroConfirm'), GuardianColors.warning),
                if (isRisky)
                  _badge(l.t('memoryMacroRisky'), GuardianColors.danger),
                _badge('${macro.actions.length} ${l.t('memoryMacroSteps')}',
                    GuardianColors.textSecondary),
                _badge(modesLabel, GuardianColors.primary),
              ],
            ),
          ],
        ),
        trailing: onDelete != null
            ? IconButton(
                icon: Icon(Icons.delete_outline,
                    color: GuardianColors.danger.withOpacity(0.6), size: 20),
                onPressed: onDelete,
              )
            : onDuplicate != null
                ? IconButton(
                    icon: Icon(Icons.copy_outlined,
                        color: GuardianColors.accent.withOpacity(0.7),
                        size: 20),
                    onPressed: onDuplicate,
                    tooltip: LocalizationService.instance
                        .t('memoryMacroDuplicateBtn'),
                  )
                : const Icon(Icons.lock_outline,
                    color: GuardianColors.textSecondary, size: 16),
      ),
    );
  }

  Widget _badge(String text, Color color) => Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text,
            style: TextStyle(
                color: color, fontSize: 9, fontWeight: FontWeight.w600)),
      );
}

class _HowToTeachCard extends StatelessWidget {
  const _HowToTeachCard();
  @override
  Widget build(BuildContext context) {
    final l = LocalizationService.instance;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: GuardianColors.surface.withOpacity(0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: GuardianColors.border.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lightbulb_outline,
                  color: GuardianColors.warning, size: 16),
              const SizedBox(width: 8),
              Text(l.t('memoryHowToTitle'),
                  style: GuardianTextStyles.bodyPrimary
                      .copyWith(fontSize: 13, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 10),
          _tip(l.t('memoryHowTo1')),
          _tip(l.t('memoryHowTo2')),
          _tip(l.t('memoryHowTo3')),
          _tip(l.t('memoryHowTo4')),
        ],
      ),
    );
  }

  Widget _tip(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('• ',
                style: TextStyle(
                    color: GuardianColors.textSecondary, fontSize: 12)),
            Expanded(
              child: Text(text,
                  style: GuardianTextStyles.bodySecondary.copyWith(
                      fontSize: 12,
                      color: GuardianColors.textSecondary.withOpacity(0.8))),
            ),
          ],
        ),
      );
}
