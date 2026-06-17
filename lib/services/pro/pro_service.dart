import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:ibiti_guardian/models/pro_status.dart';
import 'package:ibiti_guardian/models/subscription_plan.dart';
import 'package:ibiti_guardian/services/pro/billing_service.dart';
import 'package:ibiti_guardian/services/alerts/notification_service.dart';

class ProService extends ChangeNotifier {
  static final ProService instance = ProService._internal();
  ProService._internal();

  static const _log = GuardianLogger('ProService');

  /// If true, all PRO features are unlocked and billing checks are skipped (for Play Store review).
  /// Build with: flutter build apk --dart-define=REVIEW_BUILD=true
  static const bool isReviewBuild =
      bool.fromEnvironment('REVIEW_BUILD', defaultValue: false);

  static const String _key = 'pro_status';
  ProStatus _status = ProStatus.free();

  ProStatus get status => _status;

  Future<void> init() async {
    await load();
    // Listen to billing updates for real-time sync
    BillingService.instance.addListener(() {
      _syncWithBilling();
    });
    // Initial sync attempt (Billing initialization might have finished before we added listener)
    _syncWithBilling();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_key);
    if (jsonStr != null) {
      try {
        final Map<String, dynamic> jsonMap = json.decode(jsonStr);
        _status = ProStatus.fromJson(jsonMap);

        // Cache-only check for UI responsiveness
        if (_status.isPro && _status.isExpired) {
          _log.d('Cached status is expired, marking as FREE');
          await updateStatus(ProStatus.free());
        } else if (_status.isPro && _status.expiryDate != null) {
          NotificationService.instance
              .scheduleSubscriptionExpiry(_status.expiryDate!);
        }
      } catch (e) {
        _status = ProStatus.free();
      }
    } else {
      _status = ProStatus.free();
    }
    notifyListeners();
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = json.encode(_status.toJson());
    await prefs.setString(_key, jsonStr);
  }

  void _syncWithBilling() async {
    final billing = BillingService.instance;
    final activePurchases = billing.activePurchases;

    if (billing.status == BillingStatus.loading) return;

    PurchaseDetails? active;
    SubscriptionPlan? plan;

    // Direct search for yearly first (priority)
    try {
      active = activePurchases.firstWhere((p) =>
          p.productID == 'pro_yearly' &&
          (p.status == PurchaseStatus.purchased ||
              p.status == PurchaseStatus.restored));
      plan = SubscriptionPlan.yearly;
    } catch (_) {
      // Not found, check monthly
      try {
        active = activePurchases.firstWhere((p) =>
            p.productID == 'pro_monthly' &&
            (p.status == PurchaseStatus.purchased ||
                p.status == PurchaseStatus.restored));
        plan = SubscriptionPlan.monthly;
      } catch (_) {
        active = null;
      }
    }

    if (active != null && plan != null) {
      if (_status.isPro &&
          _status.purchaseId == active.purchaseID &&
          !_status.isExpired) {
        return;
      }

      _log.d('Sync: Entitlement FOUND (${active.productID})');
      await updateStatus(_createProStatus(plan, active.purchaseID));
    } else {
      if (_status.isPro) {
        _log.d('Sync: Entitlement LOST, downgrading to FREE');
        await updateStatus(ProStatus.free());
      }
    }
  }

  ProStatus _createProStatus(SubscriptionPlan plan, String? purchaseId) {
    final now = DateTime.now();
    final expiry = plan == SubscriptionPlan.yearly
        ? now.add(const Duration(days: 365))
        : now.add(const Duration(days: 30));

    return ProStatus(
      isPro: true,
      plan: plan,
      expiryDate: expiry,
      autoRenewing: true, // Simplified for now
      maxWallets: 5,
      monitoringEnabledByPlan: true,
      bulkRevokeEnabled: true,
      premiumAlertsEnabled: true,
      purchaseId: purchaseId,
      lastVerified: now,
    );
  }

  bool isProActive() {
    if (isReviewBuild) return true; // Unlocked for review
    if (!_status.isPro) return false;
    if (_status.expiryDate == null) return true;
    return _status.expiryDate!.isAfter(DateTime.now());
  }

  bool canUseBulkRevoke() => isProActive();
  bool canUsePremiumAlerts() => isProActive();
  bool canUseMonitoring() => isProActive();
  int maxWallets() => isProActive() ? 5 : 1;

  Future<void> updateStatus(ProStatus newStatus) async {
    _status = newStatus;
    await save();

    if (_status.isPro && _status.expiryDate != null) {
      NotificationService.instance
          .scheduleSubscriptionExpiry(_status.expiryDate!);
    }

    notifyListeners();
  }
}
