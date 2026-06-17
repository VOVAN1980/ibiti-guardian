import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:ibiti_guardian/utils/guardian_logger.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:ibiti_guardian/services/pro/pro_service.dart';

enum BillingStatus { loading, ready, error, processing }

class BillingService extends ChangeNotifier {
  static final BillingService instance = BillingService._();
  BillingService._();

  static const _log = GuardianLogger('Billing');

  final InAppPurchase _iap = InAppPurchase.instance;
  late StreamSubscription<List<PurchaseDetails>> _subscription;

  BillingStatus _status = BillingStatus.loading;
  BillingStatus get status => _status;

  List<ProductDetails> _products = [];
  List<ProductDetails> get products => _products;

  final List<PurchaseDetails> _activePurchases = [];
  List<PurchaseDetails> get activePurchases => _activePurchases;

  final Set<String> _productIds = {'pro_monthly', 'pro_yearly'};

  Future<void> init() async {
    _log.d('Initializing (kIsWeb=$kIsWeb, review=${ProService.isReviewBuild})');

    if (ProService.isReviewBuild) {
      _log.d('Review build detected, skipping billing init');
      _status = BillingStatus.ready;
      notifyListeners();
      return;
    }

    // Web does not support in_app_purchase usually, and it's a common hang point
    if (kIsWeb) {
      _log.d('Web detected, skipping billing init');
      _status = BillingStatus.ready;
      notifyListeners();
      return;
    }

    try {
      final bool available = await _iap.isAvailable().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _log.w('isAvailable() timed out after 5s');
          return false;
        },
      );

      _log.d('IAP available: $available');
      if (!available) {
        _status = BillingStatus.error;
        notifyListeners();
        return;
      }

      final purchaseUpdated = _iap.purchaseStream;
      _subscription = purchaseUpdated.listen(
        _onPurchaseUpdate,
        onDone: () {
          _log.d('stream done');
          _subscription.cancel();
        },
        onError: (error) => _log.e('stream error', error),
      );

      await loadProducts().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          _log.w('loadProducts() timed out after 10s');
        },
      );

      _log.d('Initialization complete');
    } catch (e) {
      _log.e('CRITICAL Error during init', e);
      _status = BillingStatus.error;
    } finally {
      if (_status == BillingStatus.loading) {
        _status = BillingStatus.ready; // Ensure we don't hang UI
      }
      notifyListeners();
    }
  }

  Future<void> loadProducts() async {
    _log.d('loadProducts() started');
    _status = BillingStatus.loading;
    notifyListeners();

    try {
      final response = await _iap.queryProductDetails(_productIds).timeout(
            const Duration(seconds: 7),
          );
      if (response.notFoundIDs.isNotEmpty) {
        _log.w('Products not found: ${response.notFoundIDs}');
      }
      _products = response.productDetails;
      _status = BillingStatus.ready;
      _log.d('Products loaded: ${_products.length}');
    } catch (e) {
      _log.e('Failed to load products', e);
      _status = BillingStatus.error;
    }
    notifyListeners();
  }

  Future<void> buyMonthly() async {
    final product = _products.firstWhere(
      (p) => p.id == 'pro_monthly',
      orElse: () => throw Exception("Monthly product not found"),
    );
    await _buy(product);
  }

  Future<void> buyYearly() async {
    final product = _products.firstWhere(
      (p) => p.id == 'pro_yearly',
      orElse: () => throw Exception("Yearly product not found"),
    );
    await _buy(product);
  }

  Future<void> _buy(ProductDetails product) async {
    _status = BillingStatus.processing;
    notifyListeners();

    final PurchaseParam purchaseParam = PurchaseParam(productDetails: product);
    try {
      await _iap.buyNonConsumable(purchaseParam: purchaseParam);
    } catch (e) {
      _status = BillingStatus.ready;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> restorePurchases() async {
    _status = BillingStatus.processing;
    notifyListeners();
    try {
      await _iap.restorePurchases();
    } catch (e) {
      _log.e('Restore error', e);
    } finally {
      _status = BillingStatus.ready;
      notifyListeners();
    }
  }

  Future<void> manageSubscription() async {
    // In a real app, this would open the Play Store / App Store subscription management page.
    // For now, it's a placeholder.
    _log.d('Opening subscription management');
  }

  void _onPurchaseUpdate(List<PurchaseDetails> purchaseDetailsList) {
    bool hasNewPurchases = false;

    for (var purchase in purchaseDetailsList) {
      if (purchase.status == PurchaseStatus.pending) {
        _status = BillingStatus.processing;
      } else if (purchase.status == PurchaseStatus.error) {
        _status = BillingStatus.ready;
        _log.e('Purchase error', purchase.error);
      } else if (purchase.status == PurchaseStatus.purchased ||
          purchase.status == PurchaseStatus.restored) {
        _status = BillingStatus.ready;

        // Update active purchases
        final index = _activePurchases
            .indexWhere((p) => p.productID == purchase.productID);
        if (index != -1) {
          _activePurchases[index] = purchase;
        } else {
          _activePurchases.add(purchase);
        }
        hasNewPurchases = true;

        if (purchase.pendingCompletePurchase) {
          _iap.completePurchase(purchase);
        }
      } else if (purchase.status == PurchaseStatus.canceled) {
        _activePurchases.removeWhere((p) => p.productID == purchase.productID);
        hasNewPurchases = true;
        _status = BillingStatus.ready;
      }
    }

    if (hasNewPurchases) {
      notifyListeners();
    } else {
      // If we got a list but nothing is purchased/restored/pending,
      // we might need to notify anyway if we are expecting a sync.
      notifyListeners();
    }
  }

  bool hasActiveEntitlement(String productId) {
    return _activePurchases.any((p) =>
        p.productID == productId &&
        (p.status == PurchaseStatus.purchased ||
            p.status == PurchaseStatus.restored));
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
