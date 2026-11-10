import 'dart:async';
import 'dart:io' show Platform;
import "package:flutter/material.dart";
import "package:flutter/scheduler.dart";
import "package:ibiti_guardian/app/background_tasks.dart";
import "package:ibiti_guardian/app/startup_services.dart";
import "package:ibiti_guardian/utils/guardian_logger.dart";
import "package:ibiti_guardian/app/guardian_app_shell.dart";
import "package:ibiti_guardian/services/pro/pro_service.dart";
import "package:ibiti_guardian/services/settings/settings_service.dart";
// Removed wallet registry
import "package:ibiti_guardian/services/pro/billing_service.dart";
import "package:ibiti_guardian/services/alerts/notification_service.dart";
import "package:ibiti_guardian/services/alerts/sound_service.dart";
import "package:ibiti_guardian/services/audio_manager.dart";
import "package:ibiti_guardian/services/alerts/alert_service.dart";
import "package:ibiti_guardian/services/security/monitoring_service.dart";
import "package:ibiti_guardian/services/threat_intelligence_service.dart";
import "package:ibiti_guardian/services/security/system_health_service.dart";
import "package:ibiti_guardian/services/wallet/wallet_topup_detector.dart";
import "package:ibiti_guardian/services/moralis/moralis_config_service.dart";
import "package:ibiti_guardian/services/security/security_event_service.dart";
import "package:ibiti_guardian/services/assistant/voice_greeting_service.dart";
import "package:ibiti_guardian/services/vault/privy_config_service.dart";
import "package:ibiti_guardian/services/vault/ibiti_vault_service.dart";
import "package:ibiti_guardian/screens/vault/vault_onboarding_screen.dart";
import "package:ibiti_guardian/widgets/energy_pulse_painter.dart";
import "package:ibiti_guardian/theme/guardian_colors.dart";
import "package:ibiti_guardian/screens/vault/vault_unlock_screen.dart";
import "package:ibiti_guardian/screens/vault/privy_reauth_screen.dart";
import "package:ibiti_guardian/screens/settings/language_selection_screen.dart";
import "package:ibiti_guardian/services/execution/tx_status_poller.dart";

class BootScreen extends StatefulWidget {
  const BootScreen({super.key});

  @override
  State<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends State<BootScreen> with TickerProviderStateMixin {
  late final AnimationController _singularityController;
  late final AnimationController _vibrationController;
  late final AnimationController _expansionController;
  late final AnimationController _revealController;

  bool _startCinematic = false;
  Widget? _destination;

  @override
  void initState() {
    super.initState();

    // Fast but cinematic durations
    _singularityController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200));

    _vibrationController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 60))
      ..repeat(reverse: true);

    _expansionController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500));

    _revealController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1000));

    _startInitialization();
  }

  Future<void> _startInitialization() async {
    // Loading runs under the intro (it used to run first, on a black
    // screen); the curtains open once both are done.
    final charged = Completer<void>();
    final ready = _runCriticalInitialization(charged.future);
    await _waitForSteadyFrames();
    await _runIntro(ready, charged);
    await ready;

    if (!mounted) return;

    // If vault/settings init failed, show error state — do NOT navigate.
    if (_criticalInitFailed) {
      setState(() {});
      return;
    }

    _determineDestination();
    await _runReveal();

    // Deferred services start after the next screen is up, so they don't
    // steal frames from the animation (that was the stutter).
    Future.delayed(
        const Duration(milliseconds: 400), _runDeferredInitialization);
  }

  void _retryInitialization() {
    setState(() {
      _criticalInitFailed = false;
      _destination = null;
    });
    _startInitialization();
  }

  bool _criticalInitFailed = false;

  /// [privyGate]: Privy's SDK init keeps the Android main thread (and the
  /// CPU) busy for ~1.5 s, which froze the intro mid-growth. It starts once
  /// the singularity is fully charged, where a pause doesn't show.
  Future<void> _runCriticalInitialization(Future<void> privyGate) async {
    const log = GuardianLogger('Boot');
    final isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;

    // Services main() started without waiting (see StartupServices) must be
    // up before anything below, as when main() awaited them.
    try {
      await StartupServices.ready.timeout(const Duration(seconds: 15));
    } catch (e) {
      log.e('Core services still starting', e);
    }

    // Phase A: Independent services in parallel
    // ProService + SoundService have no cross-deps.
    // SettingsService is already initialized in main() — not repeated here.
    try {
      await Future.wait([
        ProService.instance.init(),
        SoundService.instance.init(),
      ]).timeout(const Duration(seconds: 10));
    } catch (e) {
      log.e('Parallel critical init failed', e);
    }

    await privyGate;

    // Phase B: Privy → Vault (strict order, Vault depends on Privy config)
    final privySteps = <String, Future<void> Function()>{
      if (!isDesktop)
        'PrivyConfigService': () => PrivyConfigService.instance.init(),
      if (!isDesktop)
        'IBITIVaultService': () => IBITIVaultService.instance.init(),
    };

    for (final entry in privySteps.entries) {
      try {
        await entry.value().timeout(const Duration(seconds: 10));
      } catch (e) {
        log.e('Critical init FAILED: ${entry.key}', e);
        // Vault or Privy failure means the app cannot
        // authenticate or navigate correctly — show error + Retry.
        if (entry.key == 'IBITIVaultService' ||
            entry.key == 'PrivyConfigService') {
          _criticalInitFailed = true;
        }
      }
    }
  }

  /// Services that failed during deferred init — available for diagnostics.
  final List<String> _failedDeferredServices = [];
  List<String> get failedDeferredServices =>
      List.unmodifiable(_failedDeferredServices);

  void _runDeferredInitialization() {
    Future<void>(() async {
      const log = GuardianLogger('Boot');
      final isDesktop =
          Platform.isWindows || Platform.isMacOS || Platform.isLinux;

      final deferredSteps = <String, Future<void> Function()>{
        // First: MonitoringService registers a Workmanager task.
        'BackgroundTasks': setupBackgroundTasks,
        'ThreatIntelligence': () => ThreatIntelligenceService.instance.init(),
        if (!isDesktop) 'Billing': () => BillingService.instance.init(),
        if (!isDesktop)
          'Notification': () => NotificationService.instance.init(),
        'Alert': () => AlertService.instance.init(),
        if (!isDesktop) 'Monitoring': () => MonitoringService.instance.init(),
        'MoralisConfig': () => MoralisConfigService.instance.init(),
        if (!isDesktop)
          'SecurityEvent': () => SecurityEventService.instance.init(),
        'SystemHealth': () => SystemHealthService.instance.init(),
        'VoiceGreeting': () => VoiceGreetingService.instance.init(),
        if (!isDesktop)
          'TopUpDetector': () async {
            WalletTopUpDetector.instance.start();
          },
        if (!isDesktop)
          'TxPollerResume': () =>
              TxStatusPoller.instance.resumeIfPending(onStatus: (_) {}),
      };

      _failedDeferredServices.clear();
      for (final entry in deferredSteps.entries) {
        try {
          await entry.value().timeout(const Duration(seconds: 10));
        } catch (e) {
          log.e('Deferred init FAILED: ${entry.key}', e);
          _failedDeferredServices.add(entry.key);
        }
      }

      if (_failedDeferredServices.isNotEmpty) {
        log.w('Deferred init: ${_failedDeferredServices.length} service(s) '
            'failed: ${_failedDeferredServices.join(', ')}');
      }
    });
  }

  void _determineDestination() {
    final isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;

    // Desktop: no Privy/Vault — go straight to app shell.
    if (isDesktop) {
      _destination = const GuardianAppShell();
      return;
    }

    final vault = IBITIVaultService.instance;
    final settings = SettingsService.instance.settings;

    if (!settings.hasSelectedLanguage) {
      _destination = const LanguageSelectionScreen();
    } else if (!vault.isVaultCreated) {
      _destination = const VaultOnboardingPlaceholder();
    } else if (vault.privySessionExpired) {
      // PIN only unlocks the app; signing needs a live Privy session.
      _destination = const PrivyReauthScreen();
    } else if (((vault.state?.biometricsEnabled ?? false) ||
            vault.pinEnabled) &&
        !vault.isUnlocked) {
      _destination = const VaultUnlockScreen();
    } else {
      _destination = const GuardianAppShell();
    }
  }

  /// The first frames after launch come in bursts while the engine and
  /// surface settle; an animation started then plays mostly unseen.
  /// Waits until frames flow (or 1.5 s at most).
  Future<void> _waitForSteadyFrames() async {
    final clock = Stopwatch()..start();
    var last = 0;
    var steady = 0;
    while (mounted && steady < 3 && clock.elapsedMilliseconds < 1500) {
      await SchedulerBinding.instance.endOfFrame;
      final now = clock.elapsedMilliseconds;
      steady = now - last < 50 ? steady + 1 : 0;
      last = now;
    }
  }

  /// Singularity, then the horizontal rift once [ready] completes.
  Future<void> _runIntro(Future<void> ready, Completer<void> charged) async {
    if (!mounted) {
      if (!charged.isCompleted) charged.complete();
      return;
    }
    setState(() => _startCinematic = true);

    // 1. Singularity
    AudioManager.instance.playSound("opening_crackle.wav");
    await _singularityController.forward();
    if (!charged.isCompleted) charged.complete();
    // Still loading: the charged singularity keeps trembling until done.
    await ready;
    if (!mounted || _criticalInitFailed) return;
    await Future.delayed(const Duration(milliseconds: 200));

    // 2. Horizontal Expansion
    if (!mounted) return;
    // The jitter is invisible once the rift starts; stop repainting it.
    _vibrationController.stop();
    await _expansionController.forward();
    await Future.delayed(const Duration(milliseconds: 200));
  }

  /// Vertical reveal, then navigate.
  Future<void> _runReveal() async {
    if (!mounted) return;
    AudioManager.instance.playSound("opening_whoosh.wav");
    await _revealController.forward();

    if (!mounted) return;

    // Destination is already determined before cinematic starts
    if (_destination == null) return;

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => _destination!,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
  }

  @override
  void dispose() {
    _singularityController.dispose();
    _vibrationController.dispose();
    _expansionController.dispose();
    _revealController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    const themeCurve = Curves.easeInOutCubic;

    // ── Error state: critical init failed ────────────────────────────────
    if (_criticalInitFailed) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, color: Colors.red.shade400, size: 56),
                const SizedBox(height: 20),
                const Text(
                  'Failed to initialize Guardian.\nPlease check your connection and retry.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 16,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 28),
                ElevatedButton.icon(
                  onPressed: _retryInitialization,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: GuardianColors.accent,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 32, vertical: 14),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // MIDDLE LAYER: The Heavy Vertical Curtains
          AnimatedBuilder(
            animation: _revealController,
            builder: (context, child) {
              final reveal = themeCurve.transform(_revealController.value);
              return Stack(
                children: [
                  // Top Curtain
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: (size.height / 2) * (1 - reveal),
                    child: Container(
                      color: Colors.black,
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          height: 3,
                          decoration: BoxDecoration(
                            boxShadow: [
                              BoxShadow(
                                color: GuardianColors.accent
                                    .withOpacity(0.6 * (1 - reveal)),
                                blurRadius: 10,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Bottom Curtain
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    height: (size.height / 2) * (1 - reveal),
                    child: Container(
                      color: Colors.black,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Container(
                          height: 3,
                          decoration: BoxDecoration(
                            boxShadow: [
                              BoxShadow(
                                color: GuardianColors.accent
                                    .withOpacity(0.6 * (1 - reveal)),
                                blurRadius: 10,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),

          // TOP LAYER: Cinematic Pulse
          if (_startCinematic)
            Center(
              child: AnimatedBuilder(
                animation: Listenable.merge([
                  _singularityController,
                  _vibrationController,
                  _expansionController,
                  _revealController
                ]),
                builder: (context, child) {
                  final singularity = _singularityController.value;
                  final vibration = _vibrationController.value;
                  final expansion =
                      themeCurve.transform(_expansionController.value);
                  final reveal = themeCurve.transform(_revealController.value);

                  if (reveal >= 1.0) return const SizedBox.shrink();

                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      // Stage 1: The Heavy Singularity
                      if (expansion < 0.05)
                        Transform.translate(
                          offset: Offset(
                            (vibration - 0.5) * 5 * (1 - singularity * 0.5),
                            (vibration - 0.5) * 5 * (1 - singularity * 0.5),
                          ),
                          child: CustomPaint(
                            size: const Size(250, 250),
                            painter: EnergyPulsePainter(
                              scale: singularity,
                              intensity: singularity,
                              color: GuardianColors.accent,
                            ),
                          ),
                        ),

                      // Stage 2: The Horizontal Rift
                      if (expansion > 0)
                        Container(
                          width: size.width * expansion,
                          height: 2 * (1 - reveal),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            boxShadow: [
                              BoxShadow(
                                color: GuardianColors.accent
                                    .withOpacity(0.9 * (1 - reveal)),
                                blurRadius: 20,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
