import 'package:ibiti_guardian/models/transaction_request.dart';
import 'package:ibiti_guardian/services/policy/delegation_store.dart';
import 'package:ibiti_guardian/services/security/ai_control_service.dart';

/// Validates whether a requested AI action firmly sits inside its delegated authority bounds.
///
/// Implements a reserve → commit/rollback pattern:
/// - [reserveSpend] locks the amount BEFORE execution (prevents race conditions)
/// - [commitReservation] confirms it AFTER on-chain success
/// - [rollbackReservation] releases it on failure/timeout/revert
///
/// Zombie protection with adaptive TTL:
/// - Reservations WITHOUT a bound txHash expire after [_orphanTtl] (30s)
///   → dispatch likely never happened
/// - Reservations WITH a bound txHash expire after [_polledTtl] (180s)
///   → poller is running but chain is slow; generous window before rollback
class DelegationController {
  DelegationController._();
  static final instance = DelegationController._();

  final DelegationStore store = InMemoryDelegationStore();

  /// Monotonic counter for globally unique reservation keys.
  int _reservationCounter = 0;

  /// Total USD executed by the agent so far today.
  double _usedTodayUsd = 0;

  /// Total USD reserved (in-flight) but not yet confirmed on-chain.
  double _reservedUsd = 0;

  /// Active reservations: key → (amount, createdAt).
  final Map<String, _Reservation> _reservations = {};

  /// Reservation → txHash binding (set after dispatch returns a hash).
  final Map<String, String> _reservationToHash = {};

  DateTime _lastReset = DateTime.now();

  /// TTL for reservations that never got a txHash bound.
  /// Short: if dispatch didn't return a hash within 30s, it failed silently.
  static const Duration _orphanTtl = Duration(seconds: 30);

  /// TTL for reservations bound to a txHash (poller is running).
  /// Long: gives congested chains up to 3 minutes to confirm.
  /// Still finite to prevent permanent budget lock on poller crash.
  static const Duration _polledTtl = Duration(seconds: 180);

  /// Generate a globally unique reservation key.
  /// Uses monotonic counter + microsecond timestamp to avoid collisions.
  String generateReservationKey(TransactionRequest tx) {
    _reservationCounter++;
    return 'res_${_reservationCounter}_${DateTime.now().microsecondsSinceEpoch}';
  }

  /// Evaluate if the Sandbox is allowed to pass this raw transaction natively
  bool isAuthorized(TransactionRequest tx) {
    final scope = store.getActive();
    if (scope == null) return false;

    _checkDailyReset();
    _purgeExpiredReservations();

    // 1. Action Check
    final actionName = tx.type.toString().split('.').last.toUpperCase();
    if (!scope.allowedActions.contains(actionName)) {
      return false; // Type of transaction strictly forbidden for auto
    }

    // 2. Spending Limit (includes reservations)
    if (tx.amount != null) {
      final potentialUsage = _usedTodayUsd + _reservedUsd + tx.amount!;
      if (potentialUsage > scope.maxAmountUsd) {
        return false; // Blown the absolute spending limit
      }
    }

    // 3. Known Verified Smart Contract check
    if (tx.spenderAddress != null && scope.allowedContracts.isNotEmpty) {
      final isContractTrusted = scope.allowedContracts.any(
        (addr) => addr.toLowerCase() == tx.spenderAddress!.toLowerCase(),
      );
      if (!isContractTrusted) {
        return false;
      }
    }

    return true;
  }

  /// Returns true if [amountUsd] fits within the remaining daily budget
  /// (accounting for both committed usage and in-flight reservations).
  bool canSpend(double amountUsd) {
    _checkDailyReset();
    _purgeExpiredReservations();
    final effectiveLimit = _effectiveDailyLimit();
    return (_usedTodayUsd + _reservedUsd + amountUsd) <= effectiveLimit;
  }

  /// Reserve [amountUsd] BEFORE execution starts.
  /// Returns the reservation key, or null if the amount doesn't fit.
  String? reserveSpend(String txKey, double amountUsd) {
    _checkDailyReset();
    _purgeExpiredReservations();
    final effectiveLimit = _effectiveDailyLimit();
    if ((_usedTodayUsd + _reservedUsd + amountUsd) > effectiveLimit) {
      return null;
    }
    _reservedUsd += amountUsd;
    _reservations[txKey] = _Reservation(amountUsd, DateTime.now());
    return txKey;
  }

  /// Bind a reservation to the actual txHash received after dispatch.
  /// This extends the reservation's TTL from [_orphanTtl] to [_polledTtl],
  /// preventing false rollback on congested chains.
  void bindHash(String reservationKey, String txHash) {
    _reservationToHash[reservationKey] = txHash;
  }

  /// Look up the txHash bound to a reservation, if any.
  String? hashForReservation(String reservationKey) =>
      _reservationToHash[reservationKey];

  /// Heartbeat: refresh the reservation's last-active timestamp.
  ///
  /// Called by the TxStatusPoller on every non-terminal status event.
  /// This prevents the adaptive TTL from killing a reservation while
  /// the poller is still actively running — solving the TTL ↔ Poller
  /// sync problem.
  ///
  /// Result: as long as the poller is alive and calling touch(),
  /// the reservation NEVER expires. Once the poller stops (crash,
  /// app kill, terminal event), touches stop, and the TTL kicks in.
  void touchReservation(String txKey) {
    final res = _reservations[txKey];
    if (res != null) {
      res.lastTouchedAt = DateTime.now();
    }
  }

  /// Confirm a reservation after on-chain success.
  void commitReservation(String txKey) {
    final res = _reservations.remove(txKey);
    _reservationToHash.remove(txKey);
    if (res != null) {
      _reservedUsd -= res.amount;
      _usedTodayUsd += res.amount;
    }
  }

  /// Release a reservation after on-chain failure, timeout, or revert.
  void rollbackReservation(String txKey) {
    final res = _reservations.remove(txKey);
    _reservationToHash.remove(txKey);
    if (res != null) {
      _reservedUsd -= res.amount;
    }
  }

  /// Legacy: directly deduct value.
  void commitUsage(double amountUsd) {
    _checkDailyReset();
    _usedTodayUsd += amountUsd;
  }

  // ── Public read-only accessors (for SpendReconciler, UI telemetry) ──────

  /// Committed daily usage in USD (excludes in-flight reservations).
  double get usedTodayUsd {
    _checkDailyReset();
    return _usedTodayUsd;
  }

  /// In-flight reserved amount in USD (not yet confirmed on-chain).
  double get reservedUsd {
    _checkDailyReset();
    _purgeExpiredReservations();
    return _reservedUsd;
  }

  /// The effective daily limit currently enforced (strictest of scope + AI settings).
  double get effectiveDailyLimit => _effectiveDailyLimit();

  /// Remaining available budget (limit - used - reserved).
  double get remainingBudgetUsd {
    _checkDailyReset();
    _purgeExpiredReservations();
    return _effectiveDailyLimit() - _usedTodayUsd - _reservedUsd;
  }

  /// Telemetry text for UI/preview cards.
  String usageSummary() {
    _checkDailyReset();
    _purgeExpiredReservations();
    final limit = _effectiveDailyLimit();
    final inFlight = _reservedUsd > 0
        ? ' (+ \$${_reservedUsd.toStringAsFixed(2)} in-flight)'
        : '';
    return 'Daily usage: \$${_usedTodayUsd.toStringAsFixed(2)}$inFlight / '
        '\$${limit.toStringAsFixed(2)} (resets daily)';
  }

  // ── Private ─────────────────────────────────────────────────────────────────

  double _effectiveDailyLimit() {
    final scope = store.getActive();
    final aiDailyLimit = AiControlService.instance.settings.dailyLimit;
    if (scope == null) return aiDailyLimit;
    return scope.maxAmountUsd < aiDailyLimit
        ? scope.maxAmountUsd
        : aiDailyLimit;
  }

  /// Adaptive TTL purge with heartbeat awareness:
  /// - Uses [lastTouchedAt] (not createdAt) so poller heartbeats keep
  ///   reservations alive during chain congestion.
  /// - Orphaned (no hash bound): [_orphanTtl] (30s) since last touch
  /// - Hash-bound (poller running): [_polledTtl] (180s) since last touch
  void _purgeExpiredReservations() {
    if (_reservations.isEmpty) return;
    final now = DateTime.now();
    final expired = <String>[];

    for (final entry in _reservations.entries) {
      final key = entry.key;
      final res = entry.value;
      final hasBoundHash = _reservationToHash.containsKey(key);
      final ttl = hasBoundHash ? _polledTtl : _orphanTtl;
      // Use lastTouchedAt — refreshed by poller heartbeats.
      if (now.difference(res.lastTouchedAt) > ttl) {
        expired.add(key);
      }
    }

    for (final key in expired) {
      final res = _reservations.remove(key);
      _reservationToHash.remove(key);
      if (res != null) {
        _reservedUsd -= res.amount;
      }
    }
  }

  void _checkDailyReset() {
    final now = DateTime.now();
    if (now.day != _lastReset.day ||
        now.month != _lastReset.month ||
        now.year != _lastReset.year) {
      _usedTodayUsd = 0;
      _reservedUsd = 0;
      _reservations.clear();
      _reservationToHash.clear();
      _lastReset = now;
    }
  }

  void resetUsageForTest() {
    _usedTodayUsd = 0;
    _reservedUsd = 0;
    _reservations.clear();
    _reservationToHash.clear();
  }
}

/// Internal reservation record with heartbeat-aware TTL.
class _Reservation {
  final double amount;
  final DateTime createdAt;

  /// Last time a heartbeat extended this reservation's life.
  /// Updated by [DelegationController.touchReservation].
  /// Used by [_purgeExpiredReservations] instead of [createdAt].
  DateTime lastTouchedAt;

  _Reservation(this.amount, DateTime now)
      : createdAt = now,
        lastTouchedAt = now;
}
