import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ibiti_guardian/main.dart' show navigatorKey;
import 'package:ibiti_guardian/models/audit_log_entry.dart';
import 'package:ibiti_guardian/models/execution_result.dart';
import 'package:ibiti_guardian/models/intent_data.dart';
import 'package:ibiti_guardian/screens/security/widgets/ai_action_confirm_sheet.dart';
import 'package:ibiti_guardian/screens/vault/vault_unlock_screen.dart';
import 'package:ibiti_guardian/services/alerts/notification_service.dart';
import 'package:ibiti_guardian/services/audit_log_service.dart';
import 'package:ibiti_guardian/services/localization_service.dart';
import 'package:ibiti_guardian/services/policy/delegation_controller.dart';
import 'package:ibiti_guardian/services/policy/policy_profile_store.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';
import 'package:ibiti_guardian/services/swap/sunswap_provider.dart'
    show sunswapV2Router;
import 'package:ibiti_guardian/services/vault/epk_policy_manager.dart';
import 'package:ibiti_guardian/services/vault/ibiti_vault_service.dart';
import 'package:ibiti_guardian/utils/address_key.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AiActionGate — the one door every AI money action goes through.
//
// Modes (code names stay; labels changed):
//   «Советник» (AiMode.manual)       → adviseOnly: the AI only advises.
//   «Ручной»   (AiMode.guarded)      → prepareOnly: the AI fills the window,
//                                      the user confirms with the PIN there.
//   «Автономный» (AiMode.fullAutonomy):
//     • PIN setting ON (default) → card (what, amount, to, fee) → «Подтвердить»
//       (tap or voice «да») → PIN → execute → «ИИ выполнил: …».
//     • PIN setting OFF → executes without the card only when ALL hold:
//       daily trading limit, «AI Мандат» (asset, network, venue, max position
//       for buys), EPK active (on-chain), trusted recipient (trusted
//       addresses/contracts, own cards, self, official swap routers), known
//       USD value, app in the foreground, vault unlocked. A new address, an
//       unknown price or a locked vault fall back to the card + PIN.
//   Over a limit / outside the mandate / EPK paused → blocked in every case,
//   with the reason and a hint to raise the limit in «Политика» (PIN).
//   Revoke only lowers allowances: never blocked by EPK pause, expired AI
//   permissions, limits or the mandate (at most it asks for the card + PIN).
//
// One AI money action at a time: a global lock is held from the card through
// execution until reportExecuted / release (or a timeout).
// ─────────────────────────────────────────────────────────────────────────────

/// What kind of money action the AI wants to run.
enum AiActionKind {
  cexOrder,
  onChainSend,
  onChainSwap,
  onChainBuy,
  onChainSell,
  approve,
  revoke,
  delegatedTrade,
}

/// What the AI wants to do: shown on the confirmation card and checked by
/// [AiActionGate]. Callers build it from the real order / transaction.
@immutable
class AiActionSummary {
  const AiActionSummary({
    required this.kind,
    required this.title,
    required this.amountLabel,
    required this.valueUsd,
    this.isBuy = true,
    this.feeLabel,
    this.toAddress,
    this.network,
    this.venue,
    this.assetSymbol,
    this.targetSymbol,
    this.source = 'unknown',
  });

  final AiActionKind kind;

  /// Localized, e.g. 'Купить SOL на MEXC'.
  final String title;

  /// E.g. '10 USDT'.
  final String amountLabel;

  /// USD value for the daily limit and the max position. null = unknown
  /// price: such an action never runs without the card + PIN. Never pass a
  /// quantity here when the price is unknown.
  final double? valueUsd;

  /// For the max position (it applies to buys only).
  final bool isBuy;

  /// E.g. '≈ $0.12 network fee' / '≈0.1% exchange fee'.
  final String? feeLabel;

  /// Sends: the recipient. Swaps / buys / sells: the router. Approve: the
  /// spender. Checked against the trusted lists.
  final String? toAddress;

  /// chainKey ('bsc', 'eth', 'solana', …).
  final String? network;

  /// exchangeId ('mexc', …) or router name.
  final String? venue;

  final String? assetSymbol;
  final String? targetSymbol;

  /// voice | marketChat | generalChat | delegate | automation | ui
  final String source;
}

enum AiGateOutcome {
  execute,
  prepareOnly,
  adviseOnly,
  blocked,
  cancelled,
  unavailable,
  busy,
}

/// The gate's answer. Only [AiActionGate] creates it.
///
/// A decision from [AiActionGate.precheck] is a candidate only: it never
/// [matches] anything, so it cannot authorize an execution. Executors check
/// `d.mayExecute && d.matches(summary)` before running.
class AiGateDecision {
  AiGateDecision._(
    this.outcome, {
    this.pinConfirmed = false,
    this.reason,
    AiActionSummary? bound,
    int? token,
    List<String> cardNotes = const [],
  })  : _bound = bound,
        _token = token,
        _cardNotes = cardNotes;

  final AiGateOutcome outcome;
  final bool pinConfirmed;

  /// Localized, user-facing.
  final String? reason;

  final AiActionSummary? _bound;
  final int? _token;

  /// Why the card is needed even with the PIN setting off (precheck only).
  final List<String> _cardNotes;

  bool get mayExecute => outcome == AiGateOutcome.execute;
  bool get withoutPin => mayExecute && !pinConfirmed;

  /// True only for a live decision from [AiActionGate.confirm] issued for
  /// the same kind, venue / network, symbols, side, recipient and (at most)
  /// the confirmed USD value. False once it was reported or released, or
  /// after the lock timed out.
  bool matches(AiActionSummary s) {
    final b = _bound;
    final token = _token;
    if (!mayExecute || b == null || token == null) return false;
    if (!AiActionGate.instance._isLive(token)) return false;
    if (s.kind != b.kind || s.isBuy != b.isBuy) return false;
    if (!_sameText(s.venue, b.venue) || !_sameText(s.network, b.network)) {
      return false;
    }
    if (!_sameText(s.assetSymbol, b.assetSymbol) ||
        !_sameText(s.targetSymbol, b.targetSymbol)) {
      return false;
    }
    if (!_sameAddress(s.toAddress, b.toAddress)) return false;
    return _valueWithin(s.valueUsd, b.valueUsd);
  }

  @override
  String toString() => 'AiGateDecision(${outcome.name}, pin: $pinConfirmed'
      '${reason == null ? '' : ', $reason'})';
}

bool _blank(String? v) => v == null || v.trim().isEmpty;

bool _sameText(String? a, String? b) {
  if (_blank(a) && _blank(b)) return true;
  if (_blank(a) || _blank(b)) return false;
  return a!.trim().toLowerCase() == b!.trim().toLowerCase();
}

bool _sameAddress(String? a, String? b) {
  if (_blank(a) && _blank(b)) return true;
  if (_blank(a) || _blank(b)) return false;
  return AddressKey.same(a!, b!);
}

/// The executed value may be lower than confirmed, never noticeably higher.
bool _valueWithin(double? actual, double? confirmed) {
  if (confirmed == null) return actual == null;
  if (actual == null) return false;
  return actual <= confirmed * 1.01 + 0.01;
}

enum _CardResult { confirmed, declined, timedOut, aborted, unavailable, pinFailed }

class _CardSession {
  final Completer<bool> result = Completer<bool>();

  /// Tells an open card to close with this answer.
  final ValueNotifier<bool?> answer = ValueNotifier<bool?>(null);
  _CardResult? why;

  void resolve(bool yes, {_CardResult? why}) {
    if (result.isCompleted) return;
    if (!yes) this.why = why;
    result.complete(yes);
    answer.value = yes;
  }
}

/// Cancels an open card when the app goes to the background.
class _LifecycleWatch with WidgetsBindingObserver {
  _LifecycleWatch(this.onLeave);

  final VoidCallback onLeave;

  void attach() {
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {}
  }

  void detach() {
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      onLeave();
    }
  }
}

class AiActionGate {
  AiActionGate._() {
    AiControlService.instance.addListener(_onAiSettingsChanged);
  }

  static final AiActionGate instance = AiActionGate._();

  static const _log = GuardianLogger('AiGate');

  /// The lock is released after this long without a result (card + PIN,
  /// then again from the moment execution is allowed).
  static const Duration lockTimeout = Duration(minutes: 3);

  /// An unanswered card closes itself (= cancel).
  static const Duration cardTimeout = Duration(minutes: 2);

  /// Official swap routers count as trusted contracts for AI swaps, so
  /// Autonomous swaps work in the STRICT profile too.
  static const List<String> _officialSwapRouters = [
    // 0x AllowanceHolder (Cancun chains: Ethereum, BSC, Polygon, Base,
    // Arbitrum, Optimism, Avalanche, …) — the swap's `to` and the spender.
    '0x0000000000001fF3684f28c67538d4D072C22734',
    // 0x AllowanceHolder (Shanghai chains).
    '0x0000000000005E88410CcDFaDe4a5EfaE4b49562',
    // 0x Exchange Proxy (v1).
    '0xDef1C0ded9bec7F1a1670819833240f027b25EfF',
    // Jupiter: the quote's router marker and the v6 aggregator program.
    'jupiter_v2',
    'JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4',
    // SunSwap V2 router (Tron).
    sunswapV2Router,
  ];

  static const Set<AiActionKind> _routerKinds = {
    AiActionKind.onChainSwap,
    AiActionKind.onChainBuy,
    AiActionKind.onChainSell,
    AiActionKind.delegatedTrade,
    AiActionKind.approve,
  };

  int _seq = 0;
  int? _lockToken;
  DateTime? _lockSince;
  _CardSession? _card;

  /// Tests: stands for the card AND the PIN (true = confirmed with PIN).
  /// Checked before the context / foreground checks.
  @visibleForTesting
  Future<bool> Function(AiActionSummary s)? confirmUiOverride;

  /// Tests: receives the «ИИ выполнил» notification instead of Android.
  @visibleForTesting
  void Function(String title, String body)? notifyOverride;

  /// Tests: replaces the "app is in the foreground" check.
  @visibleForTesting
  bool Function()? foregroundOverride;

  /// A confirmation card is waiting for an answer (voice «да»/«нет» can
  /// answer it).
  bool get hasOpenCard => _card != null;

  /// Voice «да» = tap «Подтвердить» (the PIN still follows); «нет»/«отмена»
  /// = cancel. Does nothing when no card is open.
  void answerByVoice(bool yes) {
    final card = _card;
    if (card == null) return;
    _log.i('Card answered by voice: ${yes ? 'yes' : 'no'}');
    card.resolve(yes, why: _CardResult.declined);
  }

  /// The caller's context when it is still mounted, else the root navigator.
  BuildContext? resolveContext([BuildContext? context]) {
    if (context != null && context.mounted) return context;
    return navigatorKey.currentContext;
  }

  // ── Precheck ───────────────────────────────────────────────────────────────

  /// Pure: no UI, no lock. In «Автономный» an `execute` result is only a
  /// candidate — run [confirm] to get a decision that may execute.
  AiGateDecision precheck(AiActionSummary s) {
    final settings = AiControlService.instance.settings;
    switch (settings.mode) {
      case AiMode.manual:
        return AiGateDecision._(
          AiGateOutcome.adviseOnly,
          reason: _t(
              'aiGateAdvisorOnly',
              'In «Advisor» mode the AI only advises: it opens and prepares '
                  'nothing. To let it act, choose «Manual» or «Autonomous» in '
                  'AI Center.'),
        );
      case AiMode.guarded:
        return AiGateDecision._(
          AiGateOutcome.prepareOnly,
          reason: _t(
              'aiGatePrepareOnly',
              'In «Manual» mode the AI prepares the operation and you '
                  'confirm it with your PIN.'),
        );
      case AiMode.fullAutonomy:
        break;
    }

    if (s.kind == AiActionKind.revoke) return _precheckRevoke(settings);

    final block = _blockReason(s, settings);
    if (block != null) {
      return AiGateDecision._(AiGateOutcome.blocked, reason: block);
    }
    return AiGateDecision._(AiGateOutcome.execute, cardNotes: _cardNotes(s));
  }

  /// Revoke only lowers allowances: EPK pause, expired AI permissions,
  /// limits and the mandate never block it. Without the AI permission it
  /// still runs, but only after the card + PIN.
  AiGateDecision _precheckRevoke(AiControlSettings settings) {
    final notes = <String>[
      if (!settings.isActive ||
          !settings.allowedActions.contains(AiAction.revoke))
        _t(
            'aiGateNoteRevokePermission',
            'AI permissions for revoking are off or have expired, so the AI '
                'asks you. Revoking only removes access to your tokens.'),
      if (!_vaultUnlocked()) _lockedNote(),
    ];
    return AiGateDecision._(AiGateOutcome.execute, cardNotes: notes);
  }

  String? _blockReason(AiActionSummary s, AiControlSettings settings) {
    if (!settings.isActive) {
      return _t('aiGateBlockedExpired',
          'AI permissions are off or have expired. Renew them in AI Center.');
    }
    if (!settings.allowedActions.contains(_requiredAction(s.kind))) {
      return _t('aiGateBlockedPermission',
          'This action is turned off for the AI in AI Center.');
    }

    final mandate = settings.mandate;
    // Over a limit / outside the mandate: refuse, never prepare a bypass.
    String refuse(String why) => '$why ${_raiseHint()}';

    final network = s.network?.trim();
    if (network != null &&
        network.isNotEmpty &&
        !mandate.allowsNetwork(network)) {
      final name = network.toUpperCase();
      return refuse(_t('aiGateBlockedMandateNetwork',
          '$name is outside the «AI Mandate» networks.', {'network': name}));
    }
    final assets = s.kind == AiActionKind.cexOrder
        ? [_baseAsset(s.assetSymbol)]
        : [s.assetSymbol, s.targetSymbol];
    for (final asset in assets) {
      if (!mandate.allowsAsset(asset)) {
        final name = asset!.toUpperCase();
        return refuse(_t('aiGateBlockedMandateAsset',
            '$name is outside the «AI Mandate» assets.', {'asset': name}));
      }
    }
    if (!mandate.allowsVenue(s.venue)) {
      final name = _venueLabel(s.venue!);
      return refuse(_t('aiGateBlockedMandateVenue',
          '$name is outside the «AI Mandate» venues.', {'venue': name}));
    }

    final value = _knownValue(s);
    if (value != null) {
      if (_maxPositionApplies(s) && value > mandate.maxPositionUsd) {
        final v = _usd(value);
        final cap = _usd(mandate.maxPositionUsd);
        return refuse(_t(
            'aiGateBlockedMaxPosition',
            'Over the AI position cap: $v, the cap is $cap.',
            {'value': v, 'cap': cap}));
      }
      if (_dailyApplies(s.kind) &&
          !DelegationController.instance.canSpend(value)) {
        final remaining = DelegationController.instance.remainingBudgetUsd;
        final v = _usd(value);
        final left = _usd(remaining < 0 ? 0 : remaining);
        return refuse(_t(
            'aiGateBlockedDaily',
            'Over the daily trading limit: this needs $v, $left left today.',
            {'value': v, 'left': left}));
      }
    }

    if (_isOnChain(s.kind) && !_epkActive()) {
      return _t(
          'aiGateBlockedEpkPaused',
          'EPK protection is paused, so the AI does nothing on-chain. '
              'Resume EPK first.');
    }
    return null;
  }

  /// Why D6 does not hold (the card + PIN are needed even with the PIN
  /// setting off). Empty = the AI may act by itself.
  List<String> _cardNotes(AiActionSummary s) => [
        if (_knownValue(s) == null)
          _t('aiGateNoteUnknownValue',
              'The USD value is unknown, so the AI asks you.'),
        if (_isOnChain(s.kind) && !_isTrustedTarget(s))
          _t(
              'aiGateNoteUntrusted',
              'New address: it is not in your trusted addresses, so the AI '
                  'asks you.'),
        if (!_vaultUnlocked()) _lockedNote(),
      ];

  // ── Confirm ────────────────────────────────────────────────────────────────

  /// Precheck, then (Full + PIN ON, or untrusted recipient / unknown value)
  /// card + PIN. Takes the global money-action lock on mayExecute; re-runs
  /// precheck after the PIN. Returns busy if another AI money action holds
  /// the lock. Voice callers must not await this inside the voice turn.
  Future<AiGateDecision> confirm(AiActionSummary s,
      {BuildContext? context}) async {
    final pre = precheck(s);
    if (!pre.mayExecute) {
      _log.i('${s.kind.name} from ${s.source}: ${pre.outcome.name}');
      return pre;
    }
    if (_lockLive()) {
      _log.i('${s.kind.name} from ${s.source}: busy');
      return AiGateDecision._(
        AiGateOutcome.busy,
        reason: _t(
            'aiGateBusy',
            'Another AI operation is waiting for confirmation or running. '
                'Finish or cancel it first.'),
      );
    }

    final token = _acquire();
    try {
      var current = pre;
      if (!AiControlService.instance.settings.pinRequiredForAi &&
          current._cardNotes.isEmpty &&
          await _waitForeground()) {
        current = precheck(s);
        if (!current.mayExecute) return _fail(token, current);
        if (current._cardNotes.isEmpty &&
            !AiControlService.instance.settings.pinRequiredForAi) {
          _log.i('${s.kind.name} from ${s.source}: execute without PIN');
          return _granted(token, s, pinConfirmed: false);
        }
      }

      final card = await _showCardAndPin(s, current._cardNotes, context);
      if (card != _CardResult.confirmed) {
        _log.i('${s.kind.name} from ${s.source}: card ${card.name}');
        return _fail(token, _cardFailure(card));
      }
      if (!_isLive(token)) {
        return _fail(token, _cardFailure(_CardResult.timedOut));
      }
      // Mode, permissions, EPK or the budget may have changed meanwhile.
      final again = precheck(s);
      if (!again.mayExecute) return _fail(token, again);
      _log.i('${s.kind.name} from ${s.source}: execute with PIN');
      return _granted(token, s, pinConfirmed: true);
    } catch (e) {
      _log.e('confirm failed', e);
      return _fail(
          token,
          AiGateDecision._(AiGateOutcome.unavailable,
              reason: _t('aiGateUnavailable',
                  'Could not show the confirmation. Nothing was done.')));
    }
  }

  Future<_CardResult> _showCardAndPin(
    AiActionSummary s,
    List<String> notes,
    BuildContext? context,
  ) async {
    final session = _CardSession();
    _card = session;
    Timer? ttl;
    _LifecycleWatch? watch;
    try {
      final override = confirmUiOverride;
      if (override != null) {
        // Tests: the override stands for the card and the PIN.
        unawaited(Future<bool>.sync(() => override(s)).then(
              (yes) => session.resolve(yes, why: _CardResult.declined),
              onError: (Object _) =>
                  session.resolve(false, why: _CardResult.declined),
            ));
        final yes = await session.result.future;
        return yes
            ? _CardResult.confirmed
            : (session.why ?? _CardResult.declined);
      }

      final ctx = resolveContext(context);
      if (ctx == null || !await _waitForeground()) {
        return _CardResult.unavailable;
      }
      ttl = Timer(cardTimeout,
          () => session.resolve(false, why: _CardResult.timedOut));
      watch = _LifecycleWatch(
          () => session.resolve(false, why: _CardResult.aborted))
        ..attach();
      unawaited(AiActionConfirmSheet.show(
        ctx,
        s,
        note: notes.isEmpty ? null : notes.join('\n'),
        answer: session.answer,
      ).then(
        (yes) => session.resolve(yes, why: _CardResult.declined),
        onError: (Object e) {
          _log.e('Confirmation card failed', e);
          session.resolve(false, why: _CardResult.unavailable);
        },
      ));
      final yes = await session.result.future;
      if (!yes) return session.why ?? _CardResult.declined;
    } finally {
      ttl?.cancel();
      watch?.detach();
      if (identical(_card, session)) _card = null;
    }

    // «Подтвердить» → PIN or biometrics.
    final pinContext = resolveContext(context);
    if (pinContext == null) return _CardResult.unavailable;
    final authed =
        await VaultUnlockScreen.requireAuth(pinContext, forceSetup: true);
    return authed ? _CardResult.confirmed : _CardResult.pinFailed;
  }

  AiGateDecision _cardFailure(_CardResult r) {
    switch (r) {
      case _CardResult.unavailable:
        return AiGateDecision._(AiGateOutcome.unavailable,
            reason: _t('aiGateUnavailableScreen',
                'Open the app to confirm this AI operation. Nothing was done.'));
      case _CardResult.timedOut:
        return AiGateDecision._(AiGateOutcome.cancelled,
            reason: _t('aiGateCardTimeout',
                'The confirmation expired. Nothing was done.'));
      case _CardResult.aborted:
        return AiGateDecision._(AiGateOutcome.cancelled,
            reason: _t(
                'aiGateCardAborted',
                'The confirmation was closed (the app or the AI mode '
                    'changed). Nothing was done.'));
      case _CardResult.pinFailed:
        return AiGateDecision._(AiGateOutcome.cancelled,
            reason: _t('aiGatePinNotConfirmed',
                'The PIN was not confirmed. Nothing was done.'));
      case _CardResult.confirmed:
      case _CardResult.declined:
        return AiGateDecision._(AiGateOutcome.cancelled,
            reason: _t('aiGateCancelled', 'Cancelled. Nothing was done.'));
    }
  }

  void _onAiSettingsChanged() {
    final card = _card;
    if (card == null) return;
    if (AiControlService.instance.settings.mode != AiMode.fullAutonomy) {
      card.resolve(false, why: _CardResult.aborted);
    }
  }

  // ── Report / release ───────────────────────────────────────────────────────

  /// Releases the lock. Audit always; the «ИИ выполнил: …» notification on
  /// success (with or without the PIN). Tapping it opens the history.
  Future<void> reportExecuted(
    AiActionSummary s,
    AiGateDecision d, {
    required bool success,
    String? detail,
    String? historyId,
  }) async {
    release(d);
    _audit(s, d, success: success, detail: detail);
    if (!d.mayExecute || !success) return;

    final title = NotificationService.aiActionDoneTitle(s.title);
    final body = _notificationBody(s, detail);
    final hook = notifyOverride;
    if (hook != null) {
      hook(title, body);
      return;
    }
    try {
      final shown = await NotificationService.instance.showAiActionDone(
        what: s.title,
        detail: body,
        historyId: historyId,
        kind: s.kind.name,
      );
      // Notifications blocked by Android: say it in the app at least.
      if (!shown) _snack('$title · $body');
    } catch (e) {
      _log.e('AI action notification failed', e);
      _snack('$title · $body');
    }
  }

  /// Cancel / error path. Idempotent.
  void release(AiGateDecision d) {
    final token = d._token;
    if (token != null) _releaseToken(token);
  }

  @visibleForTesting
  void resetForTest() {
    _card?.resolve(false, why: _CardResult.aborted);
    _card = null;
    _clearLock();
    confirmUiOverride = null;
    notifyOverride = null;
    foregroundOverride = null;
  }

  // ── Lock ───────────────────────────────────────────────────────────────────

  int _acquire() {
    final token = ++_seq;
    _lockToken = token;
    _lockSince = DateTime.now();
    return token;
  }

  bool _lockLive() {
    final since = _lockSince;
    if (_lockToken == null || since == null) return false;
    if (DateTime.now().difference(since) >= lockTimeout) {
      _log.w('AI action lock timed out and was released');
      _clearLock();
      return false;
    }
    return true;
  }

  bool _isLive(int token) => _lockToken == token && _lockLive();

  void _releaseToken(int token) {
    if (_lockToken == token) _clearLock();
  }

  void _clearLock() {
    _lockToken = null;
    _lockSince = null;
  }

  AiGateDecision _fail(int token, AiGateDecision d) {
    _releaseToken(token);
    return d;
  }

  AiGateDecision _granted(int token, AiActionSummary s,
      {required bool pinConfirmed}) {
    // The execution window starts now.
    _lockSince = DateTime.now();
    return AiGateDecision._(
      AiGateOutcome.execute,
      pinConfirmed: pinConfirmed,
      bound: s,
      token: token,
    );
  }

  // ── Environment ────────────────────────────────────────────────────────────

  /// Waits up to 2 s while the app is only `inactive` (notification shade,
  /// a system prompt); hidden / paused / detached = not in the foreground.
  /// An unknown state (before the first frame) counts as the foreground.
  Future<bool> _waitForeground() async {
    for (var i = 0; i < 10; i++) {
      final hook = foregroundOverride;
      if (hook != null) return hook();
      AppLifecycleState? state;
      try {
        state = WidgetsBinding.instance.lifecycleState;
      } catch (_) {
        state = null;
      }
      if (state == null || state == AppLifecycleState.resumed) return true;
      if (state != AppLifecycleState.inactive) return false;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  static bool _vaultUnlocked() => IBITIVaultService.instance.isUnlocked;

  static bool _epkActive() => EPKPolicyManager.instance.state.isActive;

  /// Trusted addresses / contracts, the user's own addresses and cards, and
  /// (for swaps / approvals) the official swap routers.
  static bool _isTrustedTarget(AiActionSummary s) {
    final to = s.toAddress?.trim() ?? '';
    if (to.isEmpty) return false;
    final profile = PolicyProfileStore.instance.current;
    if (profile.trustedAddresses.any((a) => AddressKey.same(a, to)) ||
        profile.trustedContracts.any((a) => AddressKey.same(a, to))) {
      return true;
    }
    final vault = IBITIVaultService.instance;
    final own = <String?>[
      vault.evmAddress,
      vault.solanaAddress,
      vault.tronAddress,
      ...vault.evmCardAddresses,
    ];
    if (own.any((a) => !_blank(a) && AddressKey.same(a!, to))) return true;
    return _routerKinds.contains(s.kind) && isOfficialSwapRouter(to);
  }

  /// 0x AllowanceHolder / Exchange Proxy, Jupiter, SunSwap.
  static bool isOfficialSwapRouter(String address) {
    final a = address.trim();
    if (a.isEmpty) return false;
    return _officialSwapRouters.any((r) => AddressKey.same(r, a));
  }

  // ── Rules ──────────────────────────────────────────────────────────────────

  static AiAction _requiredAction(AiActionKind kind) => switch (kind) {
        AiActionKind.onChainSend => AiAction.send,
        AiActionKind.approve => AiAction.approve,
        AiActionKind.revoke => AiAction.revoke,
        AiActionKind.cexOrder ||
        AiActionKind.onChainSwap ||
        AiActionKind.onChainBuy ||
        AiActionKind.onChainSell ||
        AiActionKind.delegatedTrade =>
          AiAction.swap,
      };

  static bool _isOnChain(AiActionKind kind) => kind != AiActionKind.cexOrder;

  /// The daily trading limit counts what the AI spends, not approvals or
  /// revokes.
  static bool _dailyApplies(AiActionKind kind) =>
      kind != AiActionKind.approve && kind != AiActionKind.revoke;

  /// The position cap applies to buys only (as in ExchangeOrderService).
  static bool _maxPositionApplies(AiActionSummary s) =>
      s.isBuy &&
      (s.kind == AiActionKind.cexOrder ||
          s.kind == AiActionKind.onChainSwap ||
          s.kind == AiActionKind.onChainBuy ||
          s.kind == AiActionKind.delegatedTrade);

  static double? _knownValue(AiActionSummary s) {
    final v = s.valueUsd;
    if (v == null || v.isNaN || v.isInfinite || v < 0) return null;
    return v;
  }

  /// 'SOLUSDT' / 'SOL/USDT' / 'SOL' → 'SOL' (as ExchangeOrderService).
  static String? _baseAsset(String? symbol) {
    if (_blank(symbol)) return symbol;
    final s = symbol!.toUpperCase().replaceAll(RegExp(r'[-/_]'), '');
    for (final quote in const ['USDT', 'USDC', 'EUR']) {
      if (s.length > quote.length && s.endsWith(quote)) {
        return s.substring(0, s.length - quote.length);
      }
    }
    return s;
  }

  // ── Texts ──────────────────────────────────────────────────────────────────

  /// [fallback] must already contain the values: the localization falls
  /// back to it as is when the key is missing.
  static String _t(String key, String fallback,
          [Map<String, Object> args = const {}]) =>
      LocalizationService.instance.t(key, {...args, 'default': fallback});

  static String _raiseHint() => _t(
      'aiGateRaiseLimitHint',
      'Want more? Raise the limit or change the «AI Mandate» in «Policy» '
          '(needs your PIN).');

  static String _lockedNote() => _t('aiGateNoteVaultLocked',
      'The wallet is locked, so the AI asks you.');

  static String _usd(double v) => '\$${v.toStringAsFixed(2)}';

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

  static String _notificationBody(AiActionSummary s, String? detail) {
    final where = !_blank(s.venue)
        ? _venueLabel(s.venue!)
        : (!_blank(s.network) ? s.network!.trim().toUpperCase() : '');
    final parts = <String>[
      s.amountLabel.trim(),
      where,
      if (!_blank(detail)) _shortDetail(detail!.trim()),
    ];
    return parts.where((p) => p.isNotEmpty).join(' · ');
  }

  /// Long ids (tx hashes) are shortened; ordinary text stays.
  static String _shortDetail(String d) {
    if (d.contains(' ') || d.length <= 24) return d;
    return '${d.substring(0, 10)}…${d.substring(d.length - 6)}';
  }

  // ── Audit / snackbar ──────────────────────────────────────────────────────

  void _audit(AiActionSummary s, AiGateDecision d,
      {required bool success, String? detail}) {
    final label = !d.mayExecute
        ? 'AI_ACTION_${d.outcome.name.toUpperCase()}'
        : success
            ? (d.pinConfirmed ? 'AI_EXECUTED_PIN' : 'AI_EXECUTED_NO_PIN')
            : 'AI_EXECUTION_FAILED';
    try {
      AuditLogService.instance.record(
        intentType: _intentFor(s),
        actionLabel: label,
        summary: '${s.title} · ${s.amountLabel}',
        result: ExecutionResult(
          success: success && d.mayExecute,
          message: detail ?? '',
          pathLabel: 'ai_gate:${s.source}',
          completedAt: DateTime.now(),
        ),
        executionSource: (s.source == 'automation' || s.source == 'delegate')
            ? ExecutionSource.automation
            : ExecutionSource.ai,
      );
    } catch (e) {
      _log.e('Audit write failed', e);
    }
  }

  static IntentType _intentFor(AiActionSummary s) => switch (s.kind) {
        AiActionKind.onChainSend => IntentType.sendAsset,
        AiActionKind.onChainSwap || AiActionKind.approve => IntentType.swapAsset,
        AiActionKind.revoke => IntentType.revokeApproval,
        AiActionKind.onChainBuy => IntentType.buyAsset,
        AiActionKind.onChainSell => IntentType.sellAsset,
        AiActionKind.cexOrder || AiActionKind.delegatedTrade =>
          s.isBuy ? IntentType.buyAsset : IntentType.sellAsset,
      };

  void _snack(String text) {
    try {
      final ctx = navigatorKey.currentContext;
      if (ctx == null) return;
      ScaffoldMessenger.maybeOf(ctx)
          ?.showSnackBar(SnackBar(content: Text(text)));
    } catch (_) {}
  }
}
