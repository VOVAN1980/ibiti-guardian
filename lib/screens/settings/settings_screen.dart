import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:ibiti_guardian/main.dart';
import 'package:ibiti_guardian/services/assistant/voice_greeting_service.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';
import 'package:ibiti_guardian/services/settings/settings_service.dart';
import 'package:ibiti_guardian/services/audio_manager.dart';
import 'package:ibiti_guardian/models/notification_settings.dart';
import 'package:ibiti_guardian/models/sound_settings.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/screens/vault/vault_unlock_screen.dart';
import 'package:ibiti_guardian/widgets/ai_form_widget.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/screens/settings/pin_setup_screen.dart';
import 'package:local_auth/local_auth.dart';
import 'package:ibiti_guardian/models/jarvis_personality.dart';

class _Lang {
  final String code;
  final String name;
  final String nativeName;
  final String flag;
  const _Lang(this.code, this.name, this.nativeName, this.flag);
}

const _kLanguages = [
  _Lang('en', 'English', 'English', '🇺🇸'),
  _Lang('ru', 'Russian', 'Русский', '🇷🇺'),
  _Lang('de', 'German', 'Deutsch', '🇩🇪'),
  _Lang('fr', 'French', 'Français', '🇫🇷'),
  _Lang('es', 'Spanish', 'Español', '🇪🇸'),
  _Lang('pt', 'Portuguese', 'Português', '🇵🇹'),
  _Lang('tr', 'Turkish', 'Türkçe', '🇹🇷'),
  _Lang('ar', 'Arabic', 'العربية', '🇸🇦'),
  _Lang('zh', 'Chinese', '中文', '🇨🇳'),
  _Lang('hi', 'Hindi', 'हिन्दी', '🇮🇳'),
  _Lang('ja', 'Japanese', '日本語', '🇯🇵'),
  _Lang('ko', 'Korean', '한국어', '🇰🇷'),
  _Lang('it', 'Italian', 'Italiano', '🇮🇹'),
  _Lang('pl', 'Polish', 'Polski', '🇵🇱'),
  _Lang('uk', 'Ukrainian', 'Українська', '🇺🇦'),
  _Lang('id', 'Indonesian', 'Bahasa Indonesia', '🇮🇩'),
  _Lang('vi', 'Vietnamese', 'Tiếng Việt', '🇻🇳'),
];

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GuardianColors.background,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: GuardianColors.background,
            surfaceTintColor: Colors.transparent,
            title: Text(LocalizationProvider.of(context).t('settingsTitle'),
                style: GuardianTextStyles.headline),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(1),
              child: Container(height: 1, color: GuardianColors.glassBorder),
            ),
          ),
          const SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            sliver: _SettingsBody(),
          ),
        ],
      ),
    );
  }
}

class _SettingsBody extends StatelessWidget {
  const _SettingsBody();

  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    return SliverList(
      delegate: SliverChildListDelegate([
        // AI & Assistant section
        _SectionHeader(label: t.t('settingsSectionAi')),
        _NavTile(
          icon: Icons.psychology_outlined,
          title: t.t('settingsNeuralOperator'),
          subtitle: t.t('settingsNeuralOperatorSub'),
          destination: const _AiSettingsScreen(),
        ),
        _NavTile(
          icon: Icons.translate_outlined,
          title: t.t('settingsLanguage'),
          subtitle: t.t('settingsLangSub'),
          destination: const _LanguageScreen(),
        ),
        _NavTile(
          icon: Icons.notifications_active_outlined,
          title: t.t('settingsNotifications'),
          subtitle: t.t('settingsNotificationsSub'),
          destination: const _NotificationsScreen(),
        ),
        _NavTile(
          icon: Icons.volume_up_outlined,
          title: t.t('settingsSound'),
          subtitle: t.t('settingsSoundSub'),
          destination: const _SoundsScreen(),
        ),
        const SizedBox(height: 28),

        // App section
        _SectionHeader(label: t.t('settingsSectionApp')),
        _NavTile(
          icon: Icons.lock_outline,
          title: t.t('settingsSecurity'),
          subtitle:
              'Управление доступом к Vault', // Fallback string, we'll localize later
          destination: const _SecurityVaultScreen(),
        ),
        _NavTile(
          icon: Icons.security_outlined,
          title: t.t('settingsMonitoring'),
          subtitle: t.t('settingsMonitoringSub'),
          destination: const _MonitoringScreen(),
        ),
        _NavTile(
          icon: Icons.update_outlined,
          title: t.t('settingsUpdateTitle'),
          subtitle: t.t('settingsUpdateSub'),
          destination: const _UpdatesScreen(),
        ),
        const SizedBox(height: 28),

        // About section
        _SectionHeader(label: t.t('settingsSectionAbout')),
        _NavTile(
          icon: Icons.info_outline,
          title: t.t('settingsAboutTitle'),
          subtitle: t.t('settingsAboutSub'),
          destination: const _AboutScreen(),
        ),
        const SizedBox(height: 48),

        // Footer brand
        Center(
          child: Column(
            children: [
              ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  colors: [Color(0xFF007AFF), Color(0xFF5856D6)],
                ).createShader(bounds),
                child: Text(
                  t.t('settingsAboutBrand'),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 4.0,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                t.t('settingsAboutSecuredBy'),
                style: GuardianTextStyles.caption
                    .copyWith(color: GuardianColors.textTertiary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),
      ]),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 4),
      child: Text(
        label,
        style: GuardianTextStyles.caption.copyWith(
          color: GuardianColors.accent,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget destination;
  const _NavTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.destination,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => destination),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: GuardianColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: GuardianColors.glassBorder),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: GuardianColors.accentGlow,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 20, color: GuardianColors.accent),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: GuardianTextStyles.bodyPrimary),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: GuardianTextStyles.caption
                          .copyWith(color: GuardianColors.textTertiary)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                size: 20, color: GuardianColors.textTertiary),
          ],
        ),
      ),
    );
  }
}

class _SettingsScaffold extends StatelessWidget {
  final String title;
  final Widget body;
  const _SettingsScaffold({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GuardianColors.background,
      appBar: AppBar(
        backgroundColor: GuardianColors.background,
        surfaceTintColor: Colors.transparent,
        title: Text(title, style: GuardianTextStyles.headline),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: GuardianColors.glassBorder),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              size: 18, color: GuardianColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: body,
    );
  }
}

// Helper toggle row
class _ToggleRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleRow({
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: GuardianColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: GuardianColors.glassBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: GuardianTextStyles.bodyPrimary),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(subtitle!,
                      style: GuardianTextStyles.caption
                          .copyWith(color: GuardianColors.textTertiary)),
                ],
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: GuardianColors.accent,
            activeTrackColor: GuardianColors.accentGlow,
            inactiveThumbColor: GuardianColors.textTertiary,
          ),
        ],
      ),
    );
  }
}

class _LanguageScreen extends StatefulWidget {
  const _LanguageScreen();

  @override
  State<_LanguageScreen> createState() => _LanguageScreenState();
}

class _LanguageScreenState extends State<_LanguageScreen> {
  String _selectedCode = 'en';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selectedCode = SettingsService.instance.settings.languageCode;
  }

  Future<void> _apply(_Lang lang) async {
    setState(() {
      _selectedCode = lang.code;
      _saving = true;
    });
    HapticFeedback.selectionClick();
    await SettingsService.instance.updateLanguage(lang.code);
    if (mounted) {
      GuardianApp.setLocale(context, Locale(lang.code));
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsScaffold(
      title: LocalizationProvider.of(context).t('settingsLanguage'),
      body: ListView.builder(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: MediaQuery.of(context).padding.bottom + 12,
        ),
        itemCount: _kLanguages.length,
        itemBuilder: (_, i) {
          final lang = _kLanguages[i];
          final selected = lang.code == _selectedCode;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            margin: const EdgeInsets.only(bottom: 10),
            child: GestureDetector(
              onTap: _saving ? null : () => _apply(lang),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: selected
                      ? GuardianColors.accentGlow
                      : GuardianColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: selected
                        ? GuardianColors.accent
                        : GuardianColors.glassBorder,
                    width: selected ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Text(lang.flag, style: const TextStyle(fontSize: 24)),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(lang.nativeName,
                              style: GuardianTextStyles.bodyPrimary),
                          Text(lang.name,
                              style: GuardianTextStyles.caption.copyWith(
                                  color: GuardianColors.textTertiary)),
                        ],
                      ),
                    ),
                    if (selected)
                      const Icon(Icons.check_circle,
                          color: GuardianColors.accent, size: 20),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _NotificationsScreen extends StatefulWidget {
  const _NotificationsScreen();

  @override
  State<_NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<_NotificationsScreen> {
  late NotificationSettings _ns;

  @override
  void initState() {
    super.initState();
    _ns = SettingsService.instance.settings.notificationSettings;
  }

  Future<void> _update(NotificationSettings updated) async {
    setState(() => _ns = updated);
    await SettingsService.instance.updateNotificationSettings(updated);
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsScaffold(
      title: LocalizationProvider.of(context).t('settingsNotifications'),
      body: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).padding.bottom + 16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(
                label: LocalizationProvider.of(context)
                    .t('settingsSectionSecurityAlerts')),
            _ToggleRow(
              title: LocalizationProvider.of(context)
                  .t('settingsNotificationsCritical'),
              subtitle: LocalizationProvider.of(context)
                  .t('settingsNotificationsCriticalSub'),
              value: _ns.criticalThreatAlerts,
              onChanged: (v) => _update(_ns.copyWith(criticalThreatAlerts: v)),
            ),
            _ToggleRow(
              title: LocalizationProvider.of(context)
                  .t('settingsNotificationsHighRisk'),
              subtitle: LocalizationProvider.of(context)
                  .t('settingsNotificationsHighRiskSub'),
              value: _ns.highRiskApprovalAlerts,
              onChanged: (v) =>
                  _update(_ns.copyWith(highRiskApprovalAlerts: v)),
            ),
            _ToggleRow(
              title: LocalizationProvider.of(context)
                  .t('settingsNotificationsUnlimited'),
              subtitle: LocalizationProvider.of(context)
                  .t('settingsNotificationsUnlimitedSub'),
              value: _ns.unlimitedApprovalAlerts,
              onChanged: (v) =>
                  _update(_ns.copyWith(unlimitedApprovalAlerts: v)),
            ),
            _ToggleRow(
              title: LocalizationProvider.of(context)
                  .t('settingsNotificationsThreatDb'),
              subtitle: LocalizationProvider.of(context)
                  .t('settingsNotificationsThreatDbSub'),
              value: _ns.threatDatabaseAlerts,
              onChanged: (v) => _update(_ns.copyWith(threatDatabaseAlerts: v)),
            ),
            const SizedBox(height: 20),
            _SectionHeader(
                label: LocalizationProvider.of(context)
                    .t('settingsSectionMonitoring')),
            _ToggleRow(
              title: LocalizationProvider.of(context)
                  .t('settingsNotificationsMonitoring'),
              subtitle: LocalizationProvider.of(context)
                  .t('settingsNotificationsMonitoringHealthSub'),
              value: _ns.monitoringHealthAlerts,
              onChanged: (v) =>
                  _update(_ns.copyWith(monitoringHealthAlerts: v)),
            ),
            _ToggleRow(
              title: LocalizationProvider.of(context)
                  .t('settingsNotificationsRevoke'),
              subtitle: LocalizationProvider.of(context)
                  .t('settingsNotificationsRevokeSub'),
              value: _ns.revokeResultAlerts,
              onChanged: (v) => _update(_ns.copyWith(revokeResultAlerts: v)),
            ),
            const SizedBox(height: 20),
            _SectionHeader(
                label: LocalizationProvider.of(context)
                    .t('settingsSectionAccount')),
            _ToggleRow(
              title: LocalizationProvider.of(context).t('settingsSubscription'),
              subtitle: LocalizationProvider.of(context)
                  .t('settingsNotificationsSubscriptionSub'),
              value: _ns.subscriptionReminders,
              onChanged: (v) => _update(_ns.copyWith(subscriptionReminders: v)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SoundsScreen extends StatefulWidget {
  const _SoundsScreen();

  @override
  State<_SoundsScreen> createState() => _SoundsScreenState();
}

class _SoundsScreenState extends State<_SoundsScreen> {
  late SoundSettings _ss;

  @override
  void initState() {
    super.initState();
    _ss = SettingsService.instance.settings.soundSettings;
  }

  @override
  void dispose() {
    AudioManager.instance.stopAll();
    super.dispose();
  }

  Future<void> _update(SoundSettings updated) async {
    setState(() => _ss = updated);
    await SettingsService.instance.updateSoundSettings(updated);
  }

  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    return _SettingsScaffold(
      title: t.t('settingsSound'),
      body: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).padding.bottom + 16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(label: t.t('settingsSoundSectionMain')),
            _ToggleRow(
              title: t.t('settingsSoundEffects'),
              subtitle: t.t('settingsSoundEffectsSub'),
              value: _ss.soundEnabled,
              onChanged: (v) {
                AudioManager.instance.stopAll();
                _update(_ss.copyWith(soundEnabled: v));
              },
            ),
            _ToggleRow(
              title: t.t('settingsVibration'),
              subtitle: t.t('settingsVibrationSub'),
              value: _ss.vibrationEnabled,
              onChanged: (v) {
                AudioManager.instance.stopAll();
                _update(_ss.copyWith(vibrationEnabled: v));
              },
            ),
            const SizedBox(height: 20),
            _SectionHeader(label: t.t('settingsSoundSectionNotifications')),
            _ToggleRow(
              title: t.t('settingsSoundCriticalAlarm'),
              subtitle: t.t('settingsSoundCriticalAlarmSub'),
              value: _ss.criticalAlarmEnabled,
              onChanged: (v) {
                AudioManager.instance.stopAll();
                _update(_ss.copyWith(criticalAlarmEnabled: v));
              },
            ),
            _ToggleRow(
              title: t.t('settingsSoundPanicAlarm'),
              subtitle: t.t('settingsSoundPanicAlarmSub'),
              value: _ss.panicAlarmEnabled,
              onChanged: (v) {
                AudioManager.instance.stopAll();
                _update(_ss.copyWith(panicAlarmEnabled: v));
              },
            ),
            const SizedBox(height: 20),
            _SectionHeader(label: t.t('settingsSectionSoundSelection')),
            _SoundPicker(
              label: t.t('settingsSoundAlertSelect'),
              options: SoundSettings.alertSounds,
              selected: _ss.selectedAlertSoundId,
              onSelect: (id) async {
                await AudioManager.instance.previewAlertSound(id);
                _update(_ss.copyWith(selectedAlertSoundId: id));
              },
            ),
            const SizedBox(height: 12),
            _SoundPicker(
              label: t.t('settingsSoundCriticalSelect'),
              options: SoundSettings.criticalSounds,
              selected: _ss.selectedCriticalSoundId,
              onSelect: (id) async {
                await AudioManager.instance.previewCriticalSound(id);
                _update(_ss.copyWith(selectedCriticalSoundId: id));
              },
            ),
            const SizedBox(height: 12),
            _SoundPicker(
              label: t.t('settingsSoundPanicSelect'),
              options: SoundSettings.panicSounds,
              selected: _ss.selectedPanicSoundId,
              onSelect: (id) async {
                await AudioManager.instance.previewPanicSound(id);
                _update(_ss.copyWith(selectedPanicSoundId: id));
              },
            ),
            const SizedBox(height: 20),
            _SectionHeader(label: 'Пополнение кошелька'),
            _ToggleRow(
              title: 'Звук пополнения',
              subtitle: 'Приятный звук монет при получении денег',
              value: _ss.topUpSoundEnabled,
              onChanged: (v) {
                AudioManager.instance.stopAll();
                _update(_ss.copyWith(topUpSoundEnabled: v));
              },
            ),
            if (_ss.topUpSoundEnabled) ...[
              const SizedBox(height: 12),
              _SoundPicker(
                label: 'Звук пополнения',
                options: SoundSettings.topUpSounds,
                selected: _ss.selectedTopUpSoundId,
                onSelect: (id) async {
                  await AudioManager.instance.previewTopUpSound(id);
                  _update(_ss.copyWith(selectedTopUpSoundId: id));
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SoundPicker extends StatelessWidget {
  final String label;
  final List<String> options;
  final String selected;
  final ValueChanged<String> onSelect;
  const _SoundPicker({
    required this.label,
    required this.options,
    required this.selected,
    required this.onSelect,
  });

  String _prettyName(String id) {
    return id
        .replaceAll('_', ' ')
        .split(' ')
        .map((w) => w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : w)
        .join(' ');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: GuardianColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: GuardianColors.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: GuardianTextStyles.caption.copyWith(
                  color: GuardianColors.accent, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: options.map((id) {
              final isSelected = id == selected;
              return GestureDetector(
                onTap: () => onSelect(id),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? GuardianColors.accent
                        : GuardianColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isSelected
                          ? GuardianColors.accent
                          : GuardianColors.glassBorder,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _prettyName(id),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: isSelected
                              ? Colors.white
                              : GuardianColors.textSecondary,
                        ),
                      ),
                      if (isSelected) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.play_circle_outline,
                            size: 14, color: Colors.white),
                      ],
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _MonitoringScreen extends StatefulWidget {
  const _MonitoringScreen();

  @override
  State<_MonitoringScreen> createState() => _MonitoringScreenState();
}

class _MonitoringScreenState extends State<_MonitoringScreen> {
  late bool _autoMonitoring;
  late int _interval;
  late bool _multiWallet;

  @override
  void initState() {
    super.initState();
    final s = SettingsService.instance.settings;
    _autoMonitoring = s.autoMonitoringEnabled;
    _interval = s.monitoringIntervalMinutes;
    _multiWallet = s.multiWalletMonitoringEnabled;
  }

  Future<void> _save() async {
    await SettingsService.instance.updateMonitoringSettings(
      autoMonitoringEnabled: _autoMonitoring,
      monitoringIntervalMinutes: _interval,
      multiWalletMonitoringEnabled: _multiWallet,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    return _SettingsScaffold(
      title: t.t('settingsMonitoring'),
      body: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).padding.bottom + 16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(label: t.t('settingsMonitoringHeader')),
            _ToggleRow(
              title: t.t('settingsSecurityAutoMonitoring'),
              subtitle: t.t('settingsMonitoringAutoSub'),
              value: _autoMonitoring,
              onChanged: (v) {
                setState(() => _autoMonitoring = v);
                _save();
              },
            ),
            _ToggleRow(
              title: t.t('settingsSecurityMultiWallet'),
              subtitle: t.t('settingsMonitoringMultiSub'),
              value: _multiWallet,
              onChanged: (v) {
                setState(() => _multiWallet = v);
                _save();
              },
            ),
            const SizedBox(height: 20),
            _SectionHeader(label: t.t('settingsMonitoringIntervalHeader')),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: GuardianColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: GuardianColors.glassBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _interval == 1
                        ? t.t('settingsMonitoringEverySingular',
                            {'minutes': _interval})
                        : t.t(
                            'settingsMonitoringEvery', {'minutes': _interval}),
                    style: GuardianTextStyles.bodyPrimary
                        .copyWith(color: GuardianColors.accent),
                  ),
                  const SizedBox(height: 8),
                  Slider(
                    value: _interval.toDouble(),
                    min: 5,
                    max: 60,
                    divisions: 11,
                    activeColor: GuardianColors.accent,
                    inactiveColor: GuardianColors.glassBorder,
                    onChanged: (v) => setState(() => _interval = v.round()),
                    onChangeEnd: (_) => _save(),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('5 min',
                          style: GuardianTextStyles.caption
                              .copyWith(color: GuardianColors.textTertiary)),
                      Text('60 min',
                          style: GuardianTextStyles.caption
                              .copyWith(color: GuardianColors.textTertiary)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SecurityVaultScreen extends StatefulWidget {
  const _SecurityVaultScreen();

  @override
  State<_SecurityVaultScreen> createState() => _SecurityVaultScreenState();
}

class _SecurityVaultScreenState extends State<_SecurityVaultScreen> {
  @override
  void initState() {
    super.initState();
    // IBITIVaultService is a singleton ChangeNotifier
    IBITIVaultService.instance.addListener(_updateState);
    _updateState();
  }

  void _updateState() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    IBITIVaultService.instance.removeListener(_updateState);
    super.dispose();
  }

  Future<void> _toggleBiometrics(bool enable) async {
    if (!enable) {
      await IBITIVaultService.instance.setBiometricsEnabled(false);
      if (IBITIVaultService.instance.primaryUnlockMethod == 'biometric') {
        if (IBITIVaultService.instance.pinEnabled) {
          await IBITIVaultService.instance.setPrimaryUnlockMethod('pin');
        } else {
          await IBITIVaultService.instance.setPrimaryUnlockMethod('none');
        }
      }
      return;
    }
    if (!mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: GuardianColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Основной способ входа',
                  style: GuardianTextStyles.titleMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Выберите, что использовать в верхнем блоке быстрого входа.',
                  style: GuardianTextStyles.bodySecondary,
                ),
                const SizedBox(height: 18),
                ListTile(
                  leading: const Icon(Icons.fingerprint,
                      color: GuardianColors.accent),
                  title: Text(LocalizationService.instance
                      .t('settingsSecBiometricTitle')),
                  subtitle: Text(LocalizationService.instance
                      .t('settingsSecBiometricSub')),
                  onTap: () => Navigator.pop(context, 'biometric'),
                ),
                ListTile(
                  leading: const Icon(Icons.pin, color: GuardianColors.accent),
                  title: Text(
                      LocalizationService.instance.t('settingsSecPinTitle')),
                  subtitle: Text(LocalizationService.instance
                      .t('settingsSecPinAsPrimary')),
                  onTap: () => Navigator.pop(context, 'pin'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (selected == null) return;
    if (selected == 'biometric') {
      final LocalAuthentication auth = LocalAuthentication();
      final bool canAuthenticateWithBiometrics = await auth.canCheckBiometrics;
      final bool canAuthenticate =
          canAuthenticateWithBiometrics || await auth.isDeviceSupported();
      if (!canAuthenticate) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Биометрия недоступна на этом устройстве')),
        );
        return;
      }
      try {
        final bool didAuthenticate = await auth.authenticate(
          localizedReason:
              LocalizationService.instance.t('settingsSecBiometricConfirm'),
          biometricOnly: false,
        );
        if (!didAuthenticate) return;
        await IBITIVaultService.instance.setBiometricsEnabled(true);
        await IBITIVaultService.instance.setPrimaryUnlockMethod('biometric');
      } catch (e) {
        const log = GuardianLogger('SecuritySettings');
        log.e('Biometrics error', e);
      }
      return;
    }
    await IBITIVaultService.instance.setBiometricsEnabled(true);
    if (!IBITIVaultService.instance.pinEnabled) {
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const PinSetupScreen()),
      );
    }
    if (IBITIVaultService.instance.pinEnabled) {
      await IBITIVaultService.instance.setPrimaryUnlockMethod('pin');
    }
  }

  Future<void> _togglePin(bool enable) async {
    if (enable) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const PinSetupScreen()),
      );
      if (IBITIVaultService.instance.pinEnabled &&
          IBITIVaultService.instance.primaryUnlockMethod == 'none') {
        await IBITIVaultService.instance.setPrimaryUnlockMethod('pin');
      }
    } else {
      final authenticated = await VaultUnlockScreen.requireAuth(context);
      if (authenticated) {
        await IBITIVaultService.instance.clearPin();
      }
    }
  }

  void _showComingSoon(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(LocalizationService.instance
              .t('settingsSecComingSoon', {'feature': feature}))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vaultState = IBITIVaultService.instance.state;
    final bool bioEnabled = vaultState?.biometricsEnabled ?? false;
    final bool pinEnabled = vaultState?.pinEnabled ?? false;
    final bool isProtected = bioEnabled || pinEnabled;
    // NOTE: primaryUnlockMethod available via IBITIVaultService.instance.primaryUnlockMethod when needed

    return _SettingsScaffold(
      title: LocalizationService.instance.t('settingsSecVaultTitle'),
      body: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).padding.bottom + 16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Статус-баннер ─────────────────────────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              margin: const EdgeInsets.only(bottom: 24),
              decoration: BoxDecoration(
                color: isProtected
                    ? const Color(0xFF0A3D1F)
                    : const Color(0xFF3D1A0A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isProtected
                      ? const Color(0xFF22C55E)
                      : const Color(0xFFF97316),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isProtected
                        ? Icons.verified_user
                        : Icons.warning_amber_rounded,
                    color: isProtected
                        ? const Color(0xFF22C55E)
                        : const Color(0xFFF97316),
                    size: 26,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isProtected
                              ? LocalizationService.instance
                                  .t('settingsSecVaultProtected')
                              : LocalizationService.instance
                                  .t('settingsSecVaultUnprotected'),
                          style: GuardianTextStyles.bodyPrimary.copyWith(
                            color: isProtected
                                ? const Color(0xFF22C55E)
                                : const Color(0xFFF97316),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          isProtected
                              ? LocalizationService.instance
                                  .t('settingsSecVaultProtectedSub')
                              : LocalizationService.instance
                                  .t('settingsSecVaultUnprotectedSub'),
                          style: GuardianTextStyles.caption.copyWith(
                            color: isProtected
                                ? const Color(0xFF86EFAC)
                                : const Color(0xFFFED7AA),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ── Быстрый вход ─────────────────────────────────────────────
            _SectionHeader(
                label: LocalizationService.instance.t('settingsSecQuickLogin')),
            _ToggleRow(
              title: LocalizationService.instance.t('settingsSecBiometricSub'),
              subtitle: LocalizationService.instance
                  .t('settingsSecBiometricForLogin'),
              value: bioEnabled,
              onChanged: _toggleBiometrics,
            ),

            const SizedBox(height: 16),

            // ── Резервный доступ ─────────────────────────────────────────
            _SectionHeader(
                label:
                    LocalizationService.instance.t('settingsSecBackupAccess')),
            _ToggleRow(
              title: LocalizationService.instance.t('settingsSecPinDigits'),
              subtitle: pinEnabled
                  ? LocalizationService.instance.t('settingsSecPinActiveSub')
                  : LocalizationService.instance.t('settingsSecPinInactiveSub'),
              value: pinEnabled,
              onChanged: _togglePin,
            ),

            const SizedBox(height: 16),

            // ── Дополнительно (Coming Soon) ───────────────────────────────
            _SectionHeader(
                label: LocalizationService.instance.t('settingsSecAdditional')),
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: GuardianColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: GuardianColors.glassBorder),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                                LocalizationService.instance
                                    .t('settingsPasskey'),
                                style: GuardianTextStyles.bodyPrimary),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: GuardianColors.accent.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                    color:
                                        GuardianColors.accent.withOpacity(0.4)),
                              ),
                              child: Text(
                                LocalizationService.instance
                                    .t('settingsSecPasskeySoon'),
                                style: GuardianTextStyles.caption.copyWith(
                                  color: GuardianColors.accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          LocalizationService.instance
                              .t('settingsSecPasskeyDesc'),
                          style: GuardianTextStyles.caption.copyWith(
                            color: GuardianColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.lock_clock_outlined,
                      color: GuardianColors.textTertiary, size: 22),
                ],
              ),
            ),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

// Updates Screen
class _UpdatesScreen extends StatefulWidget {
  const _UpdatesScreen();
  @override
  State<_UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends State<_UpdatesScreen> {
  bool _checking = false;
  String _status = 'Tap below to check for updates.';

  Future<void> _checkNow() async {
    setState(() {
      _checking = true;
      _status = 'Checking...';
    });
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) {
      setState(() {
        _checking = false;
        _status = 'You are running the latest version.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    return _SettingsScaffold(
      title: t.t('settingsUpdateTitle'),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 40),
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: GuardianColors.accentGlow,
                border: Border.all(color: GuardianColors.accent, width: 1),
              ),
              child: const Icon(Icons.system_update_outlined,
                  size: 40, color: GuardianColors.accent),
            ),
            const SizedBox(height: 20),
            Text(
              _status == 'Tap below to check for updates.'
                  ? t.t('settingsUpdateCheckSub')
                  : (_status == 'Checking...'
                      ? t.t('dashboardStatusInitializing')
                      : (_status == 'You are running the latest version.'
                          ? t.t('settingsUpdateLatestMsg')
                          : _status)),
              textAlign: TextAlign.center,
              style: GuardianTextStyles.bodyPrimary,
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _checking ? null : _checkNow,
                style: ElevatedButton.styleFrom(
                  backgroundColor: GuardianColors.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: _checking
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(t.t('settingsUpdateCheckBtn'),
                        style: GuardianTextStyles.button),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutScreen extends StatefulWidget {
  const _AboutScreen();

  @override
  State<_AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<_AboutScreen> {
  String _version = '—';
  String _buildNumber = '—';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _version = info.version;
        _buildNumber = info.buildNumber;
      });
    }
  }

  Future<void> _launch(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    return _SettingsScaffold(
      title: t.t('settingsAboutTitle'),
      body: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 24,
          bottom: MediaQuery.of(context).padding.bottom + 24,
        ),
        child: Column(
          children: [
            const SizedBox(height: 20),
            // App Icon / Brand
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: GuardianColors.accent.withOpacity(0.25),
                    blurRadius: 30,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.asset('assets/logo/icon.png',
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                          decoration: BoxDecoration(
                            color: GuardianColors.accentGlow,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: const Icon(Icons.psychology,
                              size: 56, color: GuardianColors.accent),
                        )),
              ),
            ),
            const SizedBox(height: 20),
            ShaderMask(
              shaderCallback: (b) => const LinearGradient(
                colors: [Color(0xFF007AFF), Color(0xFF5856D6)],
              ).createShader(b),
              child: Text(
                t.t('settingsAboutBrand'),
                style: GuardianTextStyles.titleMedium
                    .copyWith(color: Colors.white),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              t.t('settingsAboutVersion',
                  {'version': '$_version ($_buildNumber)'}),
              style: GuardianTextStyles.caption
                  .copyWith(color: GuardianColors.textTertiary),
            ),
            const SizedBox(height: 8),
            Text(
              t.t('settingsAboutContent'),
              textAlign: TextAlign.center,
              style: GuardianTextStyles.bodySecondary.copyWith(
                color: GuardianColors.textTertiary,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 36),
            // Info tiles
            Container(
              decoration: BoxDecoration(
                color: GuardianColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: GuardianColors.glassBorder),
              ),
              child: Column(
                children: [
                  _AboutTile(
                    title: t.t('settingsAboutPrivacy'),
                    icon: Icons.privacy_tip_outlined,
                    onTap: () => _launch(
                        'https://github.com/VOVAN1980/IBITI Guardian/blob/main/privacy.html'),
                  ),
                  _Divider(),
                  _AboutTile(
                    title: LocalizationService.instance.t('settingsAboutTerms'),
                    icon: Icons.gavel_outlined,
                    onTap: () =>
                        _launch('https://github.com/VOVAN1980/IBITI Guardian'),
                  ),
                  _Divider(),
                  _AboutTile(
                    title:
                        LocalizationService.instance.t('settingsAboutSupport'),
                    icon: Icons.support_agent_outlined,
                    onTap: () => _launch('mailto:support@aimoneyguardian.app'),
                  ),
                  _Divider(),
                  _AboutTile(
                    title: LocalizationService.instance.t('settingsAboutRate'),
                    icon: Icons.star_outline_rounded,
                    onTap: () =>
                        _launch('https://github.com/VOVAN1980/IBITI Guardian'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 40),
            Text(
              '© 2025 IBITI Guardian. All rights reserved.',
              textAlign: TextAlign.center,
              style: GuardianTextStyles.caption
                  .copyWith(color: GuardianColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Divider(height: 1, color: GuardianColors.glassBorder);
  }
}

class _AboutTile extends StatelessWidget {
  final String title;
  final IconData icon;
  final VoidCallback onTap;
  const _AboutTile({
    required this.title,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(icon, color: GuardianColors.accent, size: 22),
      title: Text(title, style: GuardianTextStyles.bodyPrimary),
      trailing: const Icon(Icons.open_in_new,
          size: 16, color: GuardianColors.textTertiary),
      onTap: onTap,
    );
  }
}

class _AiSettingsScreen extends StatefulWidget {
  const _AiSettingsScreen();

  @override
  State<_AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<_AiSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final t = LocalizationProvider.of(context);
    final provider = context.dependOnInheritedWidgetOfExactType<LocalizationProvider>();
    final isRussian = provider?.locale.languageCode == 'ru';
    final settings = SettingsService.instance.settings;

    return Scaffold(
      backgroundColor: GuardianColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          t.t('settingsNeuralOperator'),
          style: GuardianTextStyles.headline.copyWith(fontSize: 20),
        ),
      ),
      body: ListView(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 24,
          bottom: MediaQuery.of(context).padding.bottom + 24,
        ),
        children: [
          _SectionHeader(label: t.t('settingsAiSectionTitle')),
          const SizedBox(height: 16),
          SwitchListTile(
            title: Text(t.t('settingsAiEnabled'),
                style: GuardianTextStyles.bodyPrimary),
            subtitle: Text(
              isRussian
                  ? 'Использует встроенный интеллект (OpenAI) для помощи.'
                  : 'Uses built-in intelligence (OpenAI) to assist.',
              style: GuardianTextStyles.caption
                  .copyWith(color: GuardianColors.accent),
            ),
            value: settings.isNeuralOperatorEnabled,
            onChanged: (val) {
              SettingsService.instance
                  .updateAiSettings(isNeuralOperatorEnabled: val);
              setState(() {});
            },
            activeColor: GuardianColors.accent,
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 32),

          // AI Form Selection
          _SectionHeader(label: isRussian ? 'Форма ИИ' : 'AI Appearance'),
          const SizedBox(height: 16),
          _AiFormSelector(
            currentForm: _aiFormFromPath(settings.selectedMascotPath),
            onSelect: (form) {
              SettingsService.instance
                  .updateAiSettings(selectedMascotPath: _pathFromAiForm(form));
              setState(() {});
            },
          ),
          const SizedBox(height: 32),

          // Personality Selection
          _SectionHeader(
              label: isRussian ? 'JARVIS Personality' : 'AI Voice Personality'),
          const SizedBox(height: 16),
          _PersonalitySelector(
            current: settings.jarvisPersonality,
            onSelect: (p) {
              SettingsService.instance.updateJarvisPersonality(p);
              setState(() {});
            },
          ),
          const SizedBox(height: 32),

          // Voice Selection
          _SectionHeader(label: t.t('settingsAiVoice')),
          const SizedBox(height: 16),
          _VoiceSelector(
            currentVoiceId: VoiceGreetingService.instance.selectedVoiceId,
            onSelect: (voiceId) async {
              await VoiceGreetingService.instance.updateVoice(voiceId);
              setState(() {});
            },
          ),
          const SizedBox(height: 32),

          // Stable voice mode toggle
          SwitchListTile(
            title: Text(
              settings.languageCode.startsWith('ru')
                  ? 'Стабильный режим голоса'
                  : 'Stable Voice Mode',
              style: GuardianTextStyles.bodyPrimary,
            ),
            subtitle: Text(
              settings.languageCode.startsWith('ru')
                  ? 'Использовать tts-1 (меньше выразительности, но тембр всегда стабилен).'
                  : 'Use tts-1 model (less expressive, but stable voice tone).',
              style: GuardianTextStyles.caption
                  .copyWith(color: GuardianColors.accent),
            ),
            value: settings.useStableVoice,
            onChanged: (val) {
              SettingsService.instance.updateAiSettings(useStableVoice: val);
              setState(() {});
            },
            activeColor: GuardianColors.accent,
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Future<void> _launchHelp() async {
    final tts = Uri.parse('https://platform.openai.com/api-keys');
    // Using simple url_launcher link
    // ignore: deprecated_member_use
    if (await canLaunch(tts.toString())) {
      // ignore: deprecated_member_use
      await launch(tts.toString());
    }
  }

  /// Maps stored mascot path → AiFormType
  static AiFormType _aiFormFromPath(String path) {
    if (path.contains('core')) return AiFormType.core;
    if (path.contains('ethereal')) return AiFormType.plasma;
    if (path.contains('stealth')) return AiFormType.fog;
    if (path.contains('command')) return AiFormType.stream;
    return AiFormType.core;
  }

  /// Maps AiFormType → path string (reusing existing keys for compatibility)
  static String _pathFromAiForm(AiFormType form) {
    switch (form) {
      case AiFormType.plasma:
        return 'assets/mascot/neural/ethereal.png';
      case AiFormType.core:
        return 'assets/mascot/neural/core.png';
      case AiFormType.fog:
        return 'assets/mascot/neural/stealth.png';
      case AiFormType.stream:
        return 'assets/mascot/neural/command.png';
    }
  }
}

// ─── Animated AI Form Selector ───────────────────────────────────────────────

class _AiFormSelector extends StatelessWidget {
  final AiFormType currentForm;
  final ValueChanged<AiFormType> onSelect;

  const _AiFormSelector({required this.currentForm, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: AiFormType.values.map((form) {
        final isSelected = form == currentForm;
        return GestureDetector(
          onTap: () => onSelect(form),
          child: Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: isSelected
                      ? _formGlowColor(form).withOpacity(0.15)
                      : GuardianColors.surface,
                  border: Border.all(
                    color: isSelected
                        ? _formGlowColor(form)
                        : GuardianColors.glassBorder,
                    width: isSelected ? 2 : 1,
                  ),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: _formGlowColor(form).withOpacity(0.4),
                            blurRadius: 14,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: AiFormWidget(
                    type: form,
                    size: 56,
                    active: isSelected,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                  color: isSelected
                      ? _formGlowColor(form)
                      : GuardianColors.textTertiary,
                ),
                child: Text(form.label),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Color _formGlowColor(AiFormType form) {
    switch (form) {
      case AiFormType.plasma:
        return const Color(0xFF00CFFF);
      case AiFormType.core:
        return const Color(0xFFFFAA00);
      case AiFormType.fog:
        return const Color(0xFF9900FF);
      case AiFormType.stream:
        return const Color(0xFF00FF88);
    }
  }
}

// ─── Personality Selector ────────────────────────────────────────────────────

class _PersonalitySelector extends StatelessWidget {
  final JarvisPersonality current;
  final ValueChanged<JarvisPersonality> onSelect;

  const _PersonalitySelector(
      {required this.current, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: GuardianColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: GuardianColors.glassBorder),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 12),
            child: Text(
              'Как JARVIS разговаривает',
              style: GuardianTextStyles.caption
                  .copyWith(color: GuardianColors.accent),
            ),
          ),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.55,
            children: JarvisPersonality.values.map((p) {
              final isSelected = p == current;
              return GestureDetector(
                onTap: () => onSelect(p),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? GuardianColors.accent.withOpacity(0.15)
                        : Colors.white.withOpacity(0.03),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isSelected
                          ? GuardianColors.accent.withOpacity(0.6)
                          : GuardianColors.glassBorder,
                      width: isSelected ? 1.5 : 1,
                    ),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Text(p.emoji,
                              style: const TextStyle(fontSize: 18)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              p.nameRu(),
                              style:
                                  GuardianTextStyles.bodyPrimary.copyWith(
                                color: isSelected
                                    ? Colors.white
                                    : GuardianColors.textSecondary,
                                fontWeight: isSelected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                fontSize: 14,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isSelected)
                            Icon(Icons.check_circle_rounded,
                                size: 16,
                                color: GuardianColors.accent),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        p.descriptionRu(),
                        style: GuardianTextStyles.caption.copyWith(
                          color: isSelected
                              ? Colors.white70
                              : GuardianColors.textSecondary.withOpacity(0.6),
                          fontSize: 11,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

// ─── Voice Selector ──────────────────────────────────────────────────────────

class _VoiceSelector extends StatefulWidget {
  final String currentVoiceId;
  final ValueChanged<String> onSelect;

  const _VoiceSelector({required this.currentVoiceId, required this.onSelect});

  @override
  State<_VoiceSelector> createState() => _VoiceSelectorState();
}

class _VoiceSelectorState extends State<_VoiceSelector> {
  String? _previewing;
  static const _voices = [
    ('verse', 'Verse — нейтральный, чистый'),
    ('cedar', 'Cedar — глубокий, уверенный'),
    ('marin', 'Marin — мягкий, дружелюбный'),
  ];

  Future<void> _preview(String voiceId) async {
    setState(() => _previewing = voiceId);
    // Apply voice & speak test phrase
    await VoiceGreetingService.instance.updateVoice(voiceId);
    await VoiceGreetingService.instance
        .speak('И\u0301бити Гардиан. Оператор на связи.');
    if (mounted) setState(() => _previewing = null);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: GuardianColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: GuardianColors.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text(
              'AI Voice (OpenAI TTS)',
              style: GuardianTextStyles.caption
                  .copyWith(color: GuardianColors.accent),
            ),
          ),
          ..._voices.map((entry) {
            final (voiceId, displayName) = entry;
            final isSelected = voiceId == widget.currentVoiceId;
            final isPreviewing = _previewing == voiceId;
            return InkWell(
              onTap: () => widget.onSelect(voiceId),
              borderRadius: BorderRadius.circular(12),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: isSelected
                      ? GuardianColors.accent.withOpacity(0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected
                        ? GuardianColors.accent.withOpacity(0.5)
                        : Colors.transparent,
                  ),
                ),
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.only(right: 12),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSelected
                            ? GuardianColors.accent
                            : GuardianColors.glassBorder,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        displayName,
                        style: GuardianTextStyles.bodyPrimary.copyWith(
                          color: isSelected
                              ? Colors.white
                              : GuardianColors.textSecondary,
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: isPreviewing ? null : () => _preview(voiceId),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: isPreviewing
                              ? GuardianColors.accent.withOpacity(0.2)
                              : Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: isPreviewing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                  color: GuardianColors.accent,
                                ),
                              )
                            : const Icon(
                                Icons.play_circle_outline_rounded,
                                size: 18,
                                color: GuardianColors.textSecondary,
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
