import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/tv_detector.dart';

import 'consent_service.dart';
import 'remove_ads_purchase_service.dart';

class AdUnitIds {
  AdUnitIds._();

  static String get banner => Platform.isAndroid
      ? 'ca-app-pub-2596031675923197/2825823206'
      : 'ca-app-pub-3940256099942544/2934735716';

  static String get interstitial => Platform.isAndroid
      ? 'ca-app-pub-2596031675923197/3756449851'
      : 'ca-app-pub-3940256099942544/4411468910';
}

class AdService {
  AdService._();
  static final AdService instance = AdService._();

  bool _initialized = false;

  int _cumulativeSessionSeconds = 0;

  DateTime? _sessionStartTime;

  int _exitCount = 0;

  static const int _exitsPerAd = 3;

  static const int _thirtyMinutesInSeconds = 30 * 60;

  Future<void> initializeWithConsent(ConsentService consentService) async {
    if (_initialized) return;
    if (RemoveAdsPurchaseService.instance.adsRemoved) {
      debugPrint('AdService: skipping init (remove ads entitlement active)');
      return;
    }
    try {
      final canRequestAds = await consentService.requestConsent();
      if (canRequestAds) {
        await MobileAds.instance.initialize();
        _initialized = true;
        debugPrint('AdService: initialized (consent granted)');
      } else {
        debugPrint('AdService: skipping init (consent denied or not required)');
      }
    } catch (e) {
      debugPrint('AdService: init failed — $e');
    }
  }

  bool get isAvailable =>
      _initialized &&
      (Platform.isAndroid || Platform.isIOS) &&
      !TvDetector.isTV &&
      !RemoveAdsPurchaseService.instance.adsRemoved;

  void startSession() {
    _sessionStartTime = DateTime.now();
    debugPrint(
      'AdService: session started, cumulative=${_cumulativeSessionSeconds}s, exits=$_exitCount',
    );
  }

  void endSession() {
    if (_sessionStartTime != null) {
      final elapsed = DateTime.now().difference(_sessionStartTime!).inSeconds;
      _cumulativeSessionSeconds += elapsed;
      _sessionStartTime = null;
      debugPrint(
        'AdService: session ended, cumulative=${_cumulativeSessionSeconds}s',
      );
    }
  }

  bool shouldShowTimeBasedAd() {
    var totalSeconds = _cumulativeSessionSeconds;
    if (_sessionStartTime != null) {
      totalSeconds += DateTime.now().difference(_sessionStartTime!).inSeconds;
    }
    return totalSeconds >= _thirtyMinutesInSeconds;
  }

  bool shouldShowExitAd() {
    if (RemoveAdsPurchaseService.instance.adsRemoved) {
      return false;
    }
    if (shouldShowTimeBasedAd()) {
      debugPrint('AdService: 30-min threshold reached, showing ad');
      return true;
    }
    _exitCount++;
    debugPrint('AdService: exit count = $_exitCount / $_exitsPerAd');
    return _exitCount >= _exitsPerAd;
  }

  void resetExitCount() {
    _exitCount = 0;
    debugPrint('AdService: exit count reset');
  }

  void resetAll() {
    _cumulativeSessionSeconds = 0;
    _sessionStartTime = null;
    _exitCount = 0;
    debugPrint('AdService: all counters reset (30-min ad shown)');
  }

  int get cumulativeMinutes {
    var totalSeconds = _cumulativeSessionSeconds;
    if (_sessionStartTime != null) {
      totalSeconds += DateTime.now().difference(_sessionStartTime!).inSeconds;
    }
    return totalSeconds ~/ 60;
  }

  static const int freeSaveSlots = 3;

  static const int totalSaveSlots = 6;
  static const String _keyPremiumSlotsUnlocked = 'ad_premium_slots_unlocked';
  static const String _keyCheatsUnlocked = 'ad_cheats_unlocked';
  static const String _keyLinkCableUnlocked = 'ad_link_cable_unlocked';
  bool _premiumSlotsUnlocked = false;
  bool _cheatsUnlocked = false;
  bool _linkCableUnlocked = false;
  bool _prefsLoaded = false;

  bool get premiumSlotsUnlocked => TvDetector.isTV || _premiumSlotsUnlocked;

  bool get cheatsUnlocked => TvDetector.isTV || _cheatsUnlocked;

  bool get linkCableUnlocked => TvDetector.isTV || _linkCableUnlocked;

  Future<void> _loadUnlockStates() async {
    if (_prefsLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _premiumSlotsUnlocked = prefs.getBool(_keyPremiumSlotsUnlocked) ?? false;
      _cheatsUnlocked = prefs.getBool(_keyCheatsUnlocked) ?? false;
      _linkCableUnlocked = prefs.getBool(_keyLinkCableUnlocked) ?? false;
      _prefsLoaded = true;
      debugPrint(
        'AdService: loaded unlock states — slots=$_premiumSlotsUnlocked, cheats=$_cheatsUnlocked, linkCable=$_linkCableUnlocked',
      );
    } catch (e) {
      debugPrint('AdService: failed to load unlock states — $e');
    }
  }

  bool isSlotLocked(int slot) {
    if (slot < freeSaveSlots) return false;
    return !_premiumSlotsUnlocked;
  }

  bool isLoadSlotLocked(int slot) {
    if (slot < freeSaveSlots) return false;
    return !_premiumSlotsUnlocked;
  }

  Future<void> unlockPremiumSlots() async {
    _premiumSlotsUnlocked = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyPremiumSlotsUnlocked, true);
      debugPrint('AdService: premium slots unlocked');
    } catch (e) {
      debugPrint('AdService: failed to persist premium slots unlock — $e');
    }
  }

  Future<void> unlockCheats() async {
    _cheatsUnlocked = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyCheatsUnlocked, true);
      debugPrint('AdService: cheats unlocked');
    } catch (e) {
      debugPrint('AdService: failed to persist cheats unlock — $e');
    }
  }

  Future<void> unlockLinkCable() async {
    _linkCableUnlocked = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyLinkCableUnlocked, true);
      debugPrint('AdService: link cable unlocked');
    } catch (e) {
      debugPrint('AdService: failed to persist link cable unlock — $e');
    }
  }

  void showRewardedAd({
    required String feature,
    required VoidCallback onRewarded,
    VoidCallback? onDismissed,
    VoidCallback? onFailed,
  }) {
    debugPrint('AdService: auto-granting reward for $feature (ads removed)');
    switch (feature) {
      case 'slots':
        unlockPremiumSlots();
        break;
      case 'cheats':
        unlockCheats();
        break;
      case 'linkCable':
        unlockLinkCable();
        break;
    }
    onRewarded();
  }

  Future<void> ensureUnlockStatesLoaded() async {
    await _loadUnlockStates();
  }
}
