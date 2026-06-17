import 'dart:io' show Platform;
import "package:flutter/material.dart";
import "package:flutter/foundation.dart";
import "package:ibiti_guardian/utils/guardian_logger.dart";
import "package:sqflite_common_ffi/sqflite_ffi.dart";
import "package:flutter_localizations/flutter_localizations.dart";
import "package:workmanager/workmanager.dart";
import "package:ibiti_guardian/services/localization_service.dart";
import "package:ibiti_guardian/services/spender_intelligence_service.dart";
import "package:ibiti_guardian/services/update_service.dart";
import "package:ibiti_guardian/services/execution/execution_router.dart";
import "package:ibiti_guardian/services/settings/settings_service.dart";
import "package:ibiti_guardian/services/security/ai_control_service.dart";
import "package:ibiti_guardian/services/policy/policy_profile_store.dart";
import "package:ibiti_guardian/services/vault/epk_policy_manager.dart";
import "package:ibiti_guardian/services/assistant/user_memory_service.dart";
import "package:ibiti_guardian/screens/wallet/components/wallet_send_modal.dart";
import "package:ibiti_guardian/services/voice/voice_turn_controller.dart";
import "package:ibiti_guardian/services/assistant/screen_context_service.dart";
import "package:ibiti_guardian/theme/guardian_theme.dart";
import "package:ibiti_guardian/screens/boot_screen.dart";

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      await UpdateService.instance.initBackground();
      return Future.value(true);
    } catch (e) {
      const log = GuardianLogger('Workmanager');
      log.e('Task failed', e);
      return Future.value(false);
    }
  });
}

/// Whether we're running on a desktop OS (Windows/macOS/Linux).
bool get isDesktop =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Desktop: use FFI-based SQLite instead of Android/iOS native plugin.
  if (isDesktop) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  // Workmanager is only supported on Android/iOS.
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: kDebugMode,
    );
    await Workmanager().registerPeriodicTask(
      "1",
      "app_update_check",
      frequency: const Duration(hours: 24),
      initialDelay: const Duration(minutes: 5),
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
    );
  }
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    const log = GuardianLogger('Guardian');
    log.e('Framework error: ${details.exception}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    const log = GuardianLogger('Guardian');
    log.e('Async error: $error');
    return true;
  };
  // ── Phase 1: SettingsService must be first (others read settings at runtime)
  await SettingsService.instance.init();

  // ── Phase 2: Independent services in parallel
  // AiControlService, EPKPolicyManager, SpenderIntelligence, UserMemory,
  // WalletSendModal — verified: no cross-dependencies between them.
  await Future.wait([
    AiControlService.instance.init(),
    EPKPolicyManager.instance.init(),
    SpenderIntelligenceService.instance.init(),
    UserMemoryService.instance.init(),
    WalletSendModal.loadMuteState(),
  ]);

  // ── Phase 3: PolicyProfileStore depends on AiControlService + EPKPolicyManager
  // (its _syncDependents reads/writes their limits) — must run AFTER phase 2.
  await PolicyProfileStore.instance.load();

  // ExecutionRouter.init() is synchronous
  ExecutionRouter.instance.init();

  runApp(const GuardianApp());
}

class GuardianApp extends StatefulWidget {
  const GuardianApp({super.key});
  static void setLocale(BuildContext context, Locale newLocale) async {
    await LocalizationService.instance.load(newLocale);
    context.findAncestorStateOfType<_GuardianAppState>()?.updateLocale(
          newLocale,
        );
  }

  @override
  State<GuardianApp> createState() => _GuardianAppState();
}

class _GuardianAppState extends State<GuardianApp> {
  Locale? _locale;
  @override
  void initState() {
    super.initState();
    _fetchLocale();
    _checkForUpdates();
  }

  Future<void> _checkForUpdates() async {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final result =
          await UpdateService.instance.checkForUpdates(isAutoCheck: true);
      if (result.status == UpdateStatus.updateAvailable && mounted) {
        _showUpdateDialog(result);
      }
    });
  }

  void _showUpdateDialog(UpdateCheckResult result) {
    final t = LocalizationService.instance;
    final context = navigatorKey.currentContext;
    if (context == null) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0D1117),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.blue.withOpacity(0.3), width: 1),
        ),
        title: Row(
          children: [
            const Icon(Icons.system_update, color: Colors.blue),
            const SizedBox(width: 12),
            Text(
              t.t('settingsUpdateTitle').toUpperCase(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.t('settingsUpdateNewMsg', {'version': result.latestDisplay}),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              t.t('settingsAboutVersion', {'version': result.currentDisplay}),
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 14,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              t.t('settingsUpdateActionLater').toUpperCase(),
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              UpdateService.instance.launchStore(customUrl: result.updateUrl);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue.withOpacity(0.2),
              foregroundColor: Colors.blue,
              side: BorderSide(color: Colors.blue.withOpacity(0.5)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              t.t('settingsUpdateActionUpdate').toUpperCase(),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _fetchLocale() async {
    final settings = SettingsService.instance.settings;
    final code = settings.languageCode.trim();
    Locale activeLocale;
    if (code.isNotEmpty) {
      activeLocale = Locale(code);
    } else {
      final deviceCode = PlatformDispatcher.instance.locale.languageCode;
      const supported = [
        'en',
        'ru',
        'de',
        'fr',
        'es',
        'pt',
        'tr',
        'ar',
        'zh',
        'hi',
        'ja',
        'ko',
        'it',
        'pl',
        'uk',
        'id',
        'vi',
      ];
      activeLocale = Locale(supported.contains(deviceCode) ? deviceCode : 'en');
    }
    await LocalizationService.instance.load(activeLocale);
    if (mounted) {
      setState(() => _locale = activeLocale);
    }
  }

  void updateLocale(Locale newLocale) {
    LocalizationService.instance.load(newLocale).then((_) {
      if (mounted) {
        setState(() => _locale = newLocale);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_locale == null) {
      return const SizedBox.shrink();
    }
    return LocalizationProvider(
      service: LocalizationService.instance,
      locale: _locale!,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        title: "IBITI Guardian",
        theme: GuardianTheme.darkTheme,
        locale: _locale,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en'),
          Locale('ru'),
          Locale('de'),
          Locale('fr'),
          Locale('es'),
          Locale('pt'),
          Locale('tr'),
          Locale('ar'),
          Locale('zh'),
          Locale('hi'),
          Locale('ja'),
          Locale('ko'),
          Locale('it'),
          Locale('pl'),
          Locale('uk'),
          Locale('id'),
          Locale('vi'),
        ],
        builder: (context, child) {
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onLongPressStart: (details) {
              final voice = VoiceTurnController.instance;
              // Don't summon if already in a voice session.
              if (voice.isSessionActive) return;
              // Start session with 60s timeout for context bubbles.
              voice.startSession(timeout: const Duration(seconds: 60));
              // Notify AppShell about the bubble position.
              ScreenContextService.instance.bubblePosition.value = Offset(
                details.globalPosition.dx - 28,
                details.globalPosition.dy - 76,
              );
            },
            child: child,
          );
        },
        home: const BootScreen(),
      ),
    );
  }
}
