import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Manages GDPR/UMP consent for AdMob ads.
///
/// The UMP SDK is bundled inside `google_mobile_ads` — no extra dependency.
///
/// ## Flow (called once at app startup)
/// 1. [requestConsent] → checks if consent is needed (EEA/UK users).
/// 2. If needed, shows the Google-hosted consent form automatically.
/// 3. After the form, [canRequestAds] reflects the user's choice.
///
/// ## AdMob Console Setup (required!)
/// You MUST create the relevant messages in AdMob → Privacy & messaging:
/// 1. Expected GDPR message for EEA/UK.
/// 2. Expected US state regulations message for CPRA/CCPA.
/// Without them, the UMP SDK has nothing to show and silently skips consent.
class ConsentService {
  ConsentService._();
  static final ConsentService instance = ConsentService._();

  bool _consentChecked = false;

  /// Whether the UMP consent flow has completed (regardless of outcome).
  bool get isConsentChecked => _consentChecked;

  /// Whether ads can be requested based on the user's consent status.
  /// Returns `true` for non-EEA users (consent not required) and for
  /// EEA users who granted consent.
  Future<bool> get canRequestAds async {
    try {
      return await ConsentInformation.instance.canRequestAds();
    } catch (e) {
      debugPrint('ConsentService: canRequestAds error — $e');
      return false;
    }
  }

  /// Whether a privacy options entry point is required by the consent
  /// framework (TCF). If true, the app must show a "Manage Ad Preferences"
  /// button somewhere accessible (e.g., Settings screen).
  Future<bool> get isPrivacyOptionsRequired async {
    try {
      final status = await ConsentInformation.instance
          .getPrivacyOptionsRequirementStatus();
      return status == PrivacyOptionsRequirementStatus.required;
    } catch (e) {
      debugPrint('ConsentService: privacyOptionsStatus error — $e');
      return false;
    }
  }

  /// Request consent info update and show the consent form if required.
  ///
  /// This is safe to call on every app launch — the UMP SDK caches the
  /// user's choice and only re-shows the form when consent expires or
  /// hasn't been collected yet.
  ///
  /// Returns `true` if ads can be requested after consent is settled.
  Future<bool> requestConsent() async {
    try {
      // Create a ConsentRequestParameters object.
      // - tagForUnderAgeOfConsent: false (set to true if app targets users underage)
      final params = ConsentRequestParameters(
        tagForUnderAgeOfConsent: false,
        
        // Uncomment the section below to test GDPR (EEA) or CCPA (US) consent flows.
        // It forces the geography of your test device.
        /*
        consentDebugSettings: ConsentDebugSettings(
          // Option to test US State Regulations (CCPA/CPRA)
          // debugGeography: DebugGeography.debugGeographyRegulatedUsState,
          
          // Option to test GDPR (EEA/UK)
          // debugGeography: DebugGeography.debugGeographyEea,
          
          testIdentifiers: ['YOUR_TEST_DEVICE_HASHED_ID'],
        ),
        */
      );

      await _requestConsentInfoUpdate(params);

      // Show the consent form if the UMP SDK determines it's required
      await _loadAndShowConsentFormIfRequired();

      _consentChecked = true;
      final allowed = await canRequestAds;
      debugPrint('ConsentService: consent settled — canRequestAds=$allowed');
      return allowed;
    } catch (e) {
      debugPrint('ConsentService: requestConsent error — $e');
      _consentChecked = true;
      // On error, check if we can still request ads (cached consent)
      return await canRequestAds;
    }
  }

  /// Show the privacy options form so the user can change their consent.
  /// Call from a "Manage Ad Preferences" button in Settings.
  Future<void> showPrivacyOptionsForm() async {
    try {
      await _showPrivacyOptionsFormAsync();
      debugPrint('ConsentService: privacy options form shown');
    } catch (e) {
      debugPrint('ConsentService: showPrivacyOptionsForm error — $e');
    }
  }

  /// Reset consent state. Only for debugging — remove before release.
  void resetConsent() {
    try {
      ConsentInformation.instance.reset();
      _consentChecked = false;
      debugPrint('ConsentService: consent reset');
    } catch (e) {
      debugPrint('ConsentService: reset error — $e');
    }
  }

  // ── Private helpers wrapping callback-based UMP API into Futures ──

  Future<void> _requestConsentInfoUpdate(ConsentRequestParameters params) {
    final completer = Completer<void>();
    ConsentInformation.instance.requestConsentInfoUpdate(
      params,
      () => completer.complete(),
      (FormError error) =>
          completer.completeError('UMP update error: ${error.message}'),
    );
    return completer.future;
  }

  Future<void> _loadAndShowConsentFormIfRequired() {
    final completer = Completer<void>();
    ConsentForm.loadAndShowConsentFormIfRequired(
      (FormError? error) {
        if (error != null) {
          debugPrint('ConsentService: form error — ${error.message}');
        }
        completer.complete(); // Complete even on error — consent flow done
      },
    );
    return completer.future;
  }

  Future<void> _showPrivacyOptionsFormAsync() {
    final completer = Completer<void>();
    ConsentForm.showPrivacyOptionsForm(
      (FormError? error) {
        if (error != null) {
          debugPrint('ConsentService: privacy form error — ${error.message}');
        }
        completer.complete();
      },
    );
    return completer.future;
  }
}
