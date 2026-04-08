import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RemoveAdsPurchaseService extends ChangeNotifier {
  RemoveAdsPurchaseService._();

  static final RemoveAdsPurchaseService instance = RemoveAdsPurchaseService._();

  static const String productId = 'remove_ads_199';
  static const String _entitlementPrefKey = 'iap_remove_ads_entitlement';

  final InAppPurchase _inAppPurchase = InAppPurchase.instance;

  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;

  bool _initialized = false;
  bool _isLoading = false;
  bool _isPurchasing = false;
  bool _storeAvailable = false;
  bool _adsRemoved = false;

  ProductDetails? _removeAdsProduct;
  String? _errorMessage;

  bool get isInitialized => _initialized;
  bool get isLoading => _isLoading;
  bool get isPurchasing => _isPurchasing;
  bool get isStoreAvailable => _storeAvailable;
  bool get adsRemoved => _adsRemoved;
  String? get errorMessage => _errorMessage;

  ProductDetails? get removeAdsProduct => _removeAdsProduct;

  String get displayPrice => _removeAdsProduct?.price ?? '₹200';

  Future<void> initialize() async {
    if (_initialized) return;

    debugPrint('[IAP] initialize() called');
    _isLoading = true;
    notifyListeners();

    await _loadCachedEntitlement();
    debugPrint('[IAP] cached entitlement: adsRemoved=$_adsRemoved');

    _purchaseSub = _inAppPurchase.purchaseStream.listen(
      _onPurchaseUpdated,
      onError: (Object error) {
        debugPrint('[IAP] purchase stream error: $error');
        _errorMessage = 'Purchase stream error: $error';
        _isPurchasing = false;
        notifyListeners();
      },
    );

    _storeAvailable = await _inAppPurchase.isAvailable();
    debugPrint('[IAP] store available: $_storeAvailable');
    if (_storeAvailable) {
      await _queryProductDetails();
      if (!_adsRemoved) {
        debugPrint('[IAP] no cached entitlement — auto-restoring purchases');
        try {
          await _inAppPurchase.restorePurchases();
        } catch (e) {
          debugPrint('[IAP] auto-restore failed: $e');
        }
      }
    } else if (!_adsRemoved) {
      debugPrint(
        '[IAP] store unavailable — billing not configured or Play not present',
      );
      _errorMessage = 'Store is currently unavailable.';
    }

    _initialized = true;
    _isLoading = false;
    notifyListeners();
    debugPrint(
      '[IAP] initialize() done — product: ${_removeAdsProduct?.id}, error: $_errorMessage',
    );
  }

  Future<bool> buyRemoveAds() async {
    debugPrint(
      '[IAP] buyRemoveAds() called — storeAvailable=$_storeAvailable, product=$_removeAdsProduct, platform=$defaultTargetPlatform',
    );
    await initialize();

    if (_adsRemoved) {
      debugPrint('[IAP] already purchased — skipping');
      return true;
    }
    if (!_storeAvailable) {
      debugPrint('[IAP] store unavailable');
      _errorMessage = 'Store is unavailable on this device.';
      notifyListeners();
      return false;
    }
    if (_removeAdsProduct == null) {
      debugPrint('[IAP] product null — not found in store response');
      _errorMessage = 'Remove Ads product is not configured in store.';
      notifyListeners();
      return false;
    }

    _errorMessage = null;
    _isPurchasing = true;
    notifyListeners();

    final productDetails = _removeAdsProduct!;
    debugPrint(
      '[IAP] product type: ${productDetails.runtimeType}, price: ${productDetails.price}',
    );
    final PurchaseParam purchaseParam;
    if (defaultTargetPlatform == TargetPlatform.android) {
      purchaseParam = GooglePlayPurchaseParam(
        productDetails: productDetails as GooglePlayProductDetails,
      );
    } else {
      purchaseParam = PurchaseParam(productDetails: productDetails);
    }

    debugPrint('[IAP] calling buyNonConsumable...');
    final started = await _inAppPurchase.buyNonConsumable(
      purchaseParam: purchaseParam,
    );
    debugPrint('[IAP] buyNonConsumable returned: $started');

    if (!started) {
      _isPurchasing = false;
      _errorMessage = 'Unable to start purchase flow.';
      notifyListeners();
    }

    return started;
  }

  Future<void> restorePurchases() async {
    await initialize();

    if (!_storeAvailable) {
      _errorMessage = 'Store is unavailable on this device.';
      notifyListeners();
      return;
    }

    _errorMessage = null;
    _isPurchasing = true;
    notifyListeners();

    await _inAppPurchase.restorePurchases();
  }

  Future<void> _queryProductDetails() async {
    debugPrint('[IAP] queryProductDetails() querying: $productId');
    final response = await _inAppPurchase.queryProductDetails({productId});
    debugPrint(
      '[IAP] query response — found: ${response.productDetails.length}, notFound: ${response.notFoundIDs}, error: ${response.error}',
    );

    if (response.error != null) {
      debugPrint(
        '[IAP] query error code=${response.error!.code} message=${response.error!.message} details=${response.error!.details}',
      );
      _errorMessage = response.error!.message;
      return;
    }

    if (response.productDetails.isEmpty) {
      debugPrint(
        '[IAP] product "$productId" not found — notFoundIDs=${response.notFoundIDs}',
      );
      _errorMessage = 'Product "$productId" not found in store.';
      return;
    }

    _removeAdsProduct = response.productDetails.firstWhere(
      (p) => p.id == productId,
    );
    debugPrint(
      '[IAP] product loaded: id=${_removeAdsProduct!.id} price=${_removeAdsProduct!.price} type=${_removeAdsProduct!.runtimeType}',
    );
  }

  Future<void> _onPurchaseUpdated(List<PurchaseDetails> updates) async {
    debugPrint('[IAP] _onPurchaseUpdated: ${updates.length} update(s)');
    for (final purchase in updates) {
      debugPrint(
        '[IAP] purchase productID=${purchase.productID} status=${purchase.status} pendingComplete=${purchase.pendingCompletePurchase} error=${purchase.error}',
      );
      if (purchase.productID == productId) {
        switch (purchase.status) {
          case PurchaseStatus.pending:
            debugPrint('[IAP] status=pending');
            _isPurchasing = true;
            break;
          case PurchaseStatus.purchased:
          case PurchaseStatus.restored:
            debugPrint(
              '[IAP] status=${purchase.status} — granting entitlement',
            );
            await _grantRemoveAdsEntitlement();
            break;
          case PurchaseStatus.error:
            debugPrint(
              '[IAP] status=error code=${purchase.error?.code} msg=${purchase.error?.message} details=${purchase.error?.details}',
            );
            final errMsg = purchase.error?.message.toLowerCase() ?? '';
            final errDetails =
                purchase.error?.details.toString().toLowerCase() ?? '';
            if (errMsg.contains('already owned') ||
                errDetails.contains('already owned') ||
                errMsg.contains('already own') ||
                errDetails.contains('already own')) {
              debugPrint('[IAP] "already owned" — attempting restore');
              try {
                await _inAppPurchase.restorePurchases();
              } catch (e) {
                debugPrint('[IAP] restore after already-owned failed: $e');
                _isPurchasing = false;
                _errorMessage =
                    'Restore failed. Please try "Restore Purchases".';
              }
            } else {
              _isPurchasing = false;
              _errorMessage = purchase.error?.message ?? 'Purchase failed.';
            }
            break;
          case PurchaseStatus.canceled:
            debugPrint('[IAP] status=canceled');
            _isPurchasing = false;
            _errorMessage = 'Purchase canceled.';
            break;
        }
      }

      if (purchase.pendingCompletePurchase) {
        debugPrint('[IAP] completing purchase for ${purchase.productID}');
        await _inAppPurchase.completePurchase(purchase);
      }
    }

    notifyListeners();
  }

  Future<void> _grantRemoveAdsEntitlement() async {
    _adsRemoved = true;
    _isPurchasing = false;
    _errorMessage = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_entitlementPrefKey, true);
  }

  Future<void> _loadCachedEntitlement() async {
    final prefs = await SharedPreferences.getInstance();
    _adsRemoved = prefs.getBool(_entitlementPrefKey) ?? false;
  }

  @override
  void dispose() {
    _purchaseSub?.cancel();
    super.dispose();
  }
}
