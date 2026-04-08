import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../services/ad_service.dart';
import '../services/consent_service.dart';
import '../services/remove_ads_purchase_service.dart';
import '../utils/tv_detector.dart';

class BannerAdWidget extends StatefulWidget {
  const BannerAdWidget({super.key});

  @override
  State<BannerAdWidget> createState() => _BannerAdWidgetState();
}

class _BannerAdWidgetState extends State<BannerAdWidget> {
  BannerAd? _bannerAd;
  bool _isLoaded = false;
  bool _canShowAd = false;

  @override
  void initState() {
    super.initState();
    RemoveAdsPurchaseService.instance.addListener(_onPurchaseStateChanged);
    _checkAndLoadAd();
  }

  void _onPurchaseStateChanged() {
    if (!mounted) return;
    if (RemoveAdsPurchaseService.instance.adsRemoved) {
      _bannerAd?.dispose();
      _bannerAd = null;
      setState(() {
        _isLoaded = false;
        _canShowAd = false;
      });
    }
  }

  Future<void> _checkAndLoadAd() async {
    final canShow = await _shouldShowAds();
    if (mounted && canShow) {
      setState(() => _canShowAd = true);
      _loadAd();
    }
  }

  Future<bool> _shouldShowAds() async {
    await RemoveAdsPurchaseService.instance.initialize();
    if (RemoveAdsPurchaseService.instance.adsRemoved) return false;
    if (!AdService.instance.isAvailable) return false;
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    if (TvDetector.isTV) return false;
    final hasConsent = await ConsentService.instance.canRequestAds;
    return hasConsent;
  }

  void _loadAd() {
    _bannerAd = BannerAd(
      adUnitId: AdUnitIds.banner,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (mounted) setState(() => _isLoaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          debugPrint('BannerAd: failed to load — ${error.message}');
          ad.dispose();
        },
      ),
    )..load();
  }

  @override
  void dispose() {
    RemoveAdsPurchaseService.instance.removeListener(_onPurchaseStateChanged);
    _bannerAd?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_canShowAd) return const SizedBox.shrink();
    if (!_isLoaded || _bannerAd == null) {
      return SizedBox(
        height: AdSize.banner.height.toDouble(),
        child: const Center(child: SizedBox.shrink()),
      );
    }
    return ExcludeFocus(
      child: Container(
        alignment: Alignment.center,
        width: _bannerAd!.size.width.toDouble(),
        height: _bannerAd!.size.height.toDouble(),
        color: const Color(0xFF1A1A2E),
        child: AdWidget(ad: _bannerAd!),
      ),
    );
  }
}
