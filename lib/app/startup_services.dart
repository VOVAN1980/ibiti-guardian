import 'package:ibiti_guardian/utils/guardian_logger.dart';

/// Services main() starts before runApp but does not wait for, so the boot
/// animation appears sooner. BootScreen awaits [ready] before Privy/Vault
/// init, so every screen after it sees them initialized, as before.
class StartupServices {
  StartupServices._();

  static Future<void> _ready = Future<void>.value();
  static bool _done = true;

  static Future<void> get ready => _ready;
  static bool get isDone => _done;

  static void begin(Future<void> work) {
    _done = false;
    _ready = work.then<void>((_) {}, onError: (Object e) {
      const GuardianLogger('Startup').e('Core services init failed', e);
    }).whenComplete(() => _done = true);
  }
}
