import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/tv_detector.dart';

import 'consent_service.dart';
import 'remove_ads_purchase_service.dart';

/// AdMob ad unit IDs. Replace with your production IDs before release.
/// Test IDs: https://developers.google.com/admob/android/test-ads
class AdUnitIds {
  AdUnitIds._();

  static String get banner => Platform.isAndroid
      ? 'ca-app-pub-2596031675923197/2825823206'
      : 'ca-app-pub-3940256099942544/2934735716';

  static String get interstitial => Platform.isAndroid
      ? 'ca-app-pub-2596031675923197/3756449851'
      : 'ca-app-pub-3940256099942544/4411468910';
}

/// Manages AdMob initialization, interstitial ads, and session-based ad timing.
///
/// ## How Ads Work (Both Phone and TV)
///
/// ### Banner Ads
/// - Shown on the home screen (no restrictions).
/// - On TV, banner ads may have lower fill rates but are still attempted.
///
/// ### Interstitial Ads
/// Shown when exiting a game session, with two rules:
///
/// 1. **Under 30 minutes cumulative play**:
///    - Interstitial shown every 3rd game exit.
///    - Exit counter persists across app restarts.
///
/// 2. **30+ minutes cumulative play**:
///    - Interstitial shown immediately on exit (no matter what).
///    - Both exit counter AND session timer are reset.
///    - This ensures users see at least one ad per 30 minutes of play.
///
/// ## Session Tracking
/// - [startSession] / [endSession] track cumulative gaming time.
/// - [shouldShowTimeBasedAd] returns true if 30+ minutes have elapsed.
/// - [resetAll] resets both session time and exit counter.
class AdService {
  AdService._();
  static final AdService instance = AdService._();

  bool _initialized = false;

  /// Cumulative session time in seconds (resets after 30-min ad).
  int _cumulativeSessionSeconds = 0;

  /// When the current gaming session started (null if not in a session).
  DateTime? _sessionStartTime;

  /// Exit counter (resets after showing an ad or after 30-min threshold).
  int _exitCount = 0;

  /// Show interstitial every N exits (when under 30 mins).
  static const int _exitsPerAd = 3;

  /// 30 minutes in seconds — threshold for forced interstitial.
  static const int _thirtyMinutesInSeconds = 30 * 60;

  // ── Persistent keys for session/exit counters ──
  // Persisted so force-killing the app can't bypass the ad cadence.
  static const String _keyExitCount = 'ad_exit_count';
  static const String _keyCumulativeSeconds = 'ad_cumulative_seconds';
  bool _countersLoaded = false;

  Future<void> _loadCountersIfNeeded() async {
    if (_countersLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _exitCount = prefs.getInt(_keyExitCount) ?? 0;
      _cumulativeSessionSeconds = prefs.getInt(_keyCumulativeSeconds) ?? 0;
      _countersLoaded = true;
      debugPrint(
        'AdService: loaded counters — exits=$_exitCount, cumulative=${_cumulativeSessionSeconds}s',
      );
    } catch (e) {
      debugPrint('AdService: failed to load counters — $e');
      _countersLoaded = true;
    }
  }

  Future<void> _persistCounters() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyExitCount, _exitCount);
      await prefs.setInt(_keyCumulativeSeconds, _cumulativeSessionSeconds);
    } catch (e) {
      debugPrint('AdService: failed to persist counters — $e');
    }
  }

  /// Call at app startup. Safe to call multiple times.
  /// Initializes MobileAds ONLY if UMP consent allows it.
  Future<void> initializeWithConsent(ConsentService consentService) async {
    if (_initialized) return;
    if (RemoveAdsPurchaseService.instance.adsRemoved) {
      debugPrint('AdService: skipping init (remove ads entitlement active)');
      return;
    }
    try {
      // 1. Request UMP consent (shows dialog if in EEA and consent is missing/expired)
      final canRequestAds = await consentService.requestConsent();

      // 2. Gate AdMob init behind consent decision
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

  /// Returns true if ads are available (Android/iOS, after init).
  /// Excludes TV devices — AdMob does not support Android TV.
  bool get isAvailable =>
      _initialized &&
      (Platform.isAndroid || Platform.isIOS) &&
      !TvDetector.isTV &&
      !RemoveAdsPurchaseService.instance.adsRemoved;

  // ─────────────────────────────────────────────────────────────────
  // Session Time Tracking
  // ─────────────────────────────────────────────────────────────────

  /// Call when a gaming session starts (e.g., game_screen initState).
  void startSession() {
    _sessionStartTime = DateTime.now();
    debugPrint(
      'AdService: session started, cumulative=${_cumulativeSessionSeconds}s, exits=$_exitCount',
    );
  }

  /// Call when a gaming session ends (e.g., exiting game_screen).
  /// Adds elapsed time to cumulative total.
  void endSession() {
    if (_sessionStartTime != null) {
      final elapsed = DateTime.now().difference(_sessionStartTime!).inSeconds;
      _cumulativeSessionSeconds += elapsed;
      _sessionStartTime = null;
      debugPrint(
        'AdService: session ended, cumulative=${_cumulativeSessionSeconds}s',
      );
      // Fire-and-forget; losing a few seconds of cumulative time on a
      // crash during persist is acceptable.
      _persistCounters();
    }
  }

  /// Returns true if cumulative session time >= 30 minutes.
  bool shouldShowTimeBasedAd() {
    var totalSeconds = _cumulativeSessionSeconds;
    if (_sessionStartTime != null) {
      totalSeconds += DateTime.now().difference(_sessionStartTime!).inSeconds;
    }
    return totalSeconds >= _thirtyMinutesInSeconds;
  }

  /// Increment exit counter and return true if an ad should be shown.
  /// Call this when user exits a game session.
  ///
  /// Logic:
  /// - If 30+ mins played → always return true (and reset all on ad shown).
  /// - Otherwise → return true every 3rd exit.
  bool shouldShowExitAd() {
    if (RemoveAdsPurchaseService.instance.adsRemoved) {
      return false;
    }

    // First check the 30-minute rule
    if (shouldShowTimeBasedAd()) {
      debugPrint('AdService: 30-min threshold reached, showing ad');
      return true;
    }

    // Otherwise, check exit counter
    _exitCount++;
    debugPrint('AdService: exit count = $_exitCount / $_exitsPerAd');
    _persistCounters();
    return _exitCount >= _exitsPerAd;
  }

  /// Reset exit counter only (after showing a regular exit ad).
  void resetExitCount() {
    _exitCount = 0;
    debugPrint('AdService: exit count reset');
    _persistCounters();
  }

  /// Reset everything (after showing the 30-minute forced ad).
  /// Resets both session time and exit counter.
  void resetAll() {
    _cumulativeSessionSeconds = 0;
    _sessionStartTime = null;
    _exitCount = 0;
    debugPrint('AdService: all counters reset (30-min ad shown)');
    _persistCounters();
  }

  /// Get current cumulative session time in minutes (for debugging).
  int get cumulativeMinutes {
    var totalSeconds = _cumulativeSessionSeconds;
    if (_sessionStartTime != null) {
      totalSeconds += DateTime.now().difference(_sessionStartTime!).inSeconds;
    }
    return totalSeconds ~/ 60;
  }

  // ─────────────────────────────────────────────────────────────────
  // Rewarded Video Ads — Premium Feature Unlocks
  // ─────────────────────────────────────────────────────────────────

  /// Number of free save state slots (0-2 are free)
  static const int freeSaveSlots = 3;

  /// Total save state slots available (0-5)
  static const int totalSaveSlots = 6;

  // Persistent keys for unlocked features
  static const String _keyPremiumSlotsUnlocked = 'ad_premium_slots_unlocked';
  static const String _keyCheatsUnlocked = 'ad_cheats_unlocked';
  static const String _keyLinkCableUnlocked = 'ad_link_cable_unlocked';

  // In-memory cache of unlock states (loaded from prefs)
  bool _premiumSlotsUnlocked = false;
  bool _cheatsUnlocked = false;
  bool _linkCableUnlocked = false;
  bool _prefsLoaded = false;

  /// Whether premium save slots (3-5) are unlocked.
  /// Always true on TV (ads not available).
  bool get premiumSlotsUnlocked => TvDetector.isTV || _premiumSlotsUnlocked;

  /// Whether cheats are unlocked.
  /// Always true on TV (ads not available).
  bool get cheatsUnlocked => TvDetector.isTV || _cheatsUnlocked;

  /// Whether link cable is unlocked.
  /// Always true on TV (ads not available).
  bool get linkCableUnlocked => TvDetector.isTV || _linkCableUnlocked;

  /// Load persisted unlock states from SharedPreferences.
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

  /// Check if a save slot requires a rewarded ad to use.
  /// Slots 0-2 are free. Slots 3-5 require watching a rewarded video.
  bool isSlotLocked(int slot) {
    if (slot < freeSaveSlots) return false;
    return !_premiumSlotsUnlocked;
  }

  /// Check if loading from a slot requires a rewarded ad.
  /// Slots 0-2 are free. Slots 3-5 require unlock.
  bool isLoadSlotLocked(int slot) {
    if (slot < freeSaveSlots) return false;
    return !_premiumSlotsUnlocked;
  }

  /// Unlock premium save slots (3-5) after watching rewarded video.
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

  /// Unlock cheats after watching rewarded video.
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

  /// Unlock link cable after watching rewarded video.
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

  /// [DEPRECATED] Rewarded ads were removed. This now instantly grants the reward.
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

  /// Ensure unlock states are loaded (call after initialize).
  Future<void> ensureUnlockStatesLoaded() async {
    await _loadUnlockStates();
    await _loadCountersIfNeeded();
  }
}
