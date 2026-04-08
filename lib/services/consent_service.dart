import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

class ConsentService {
  ConsentService._();
  static final ConsentService instance = ConsentService._();

  bool _consentChecked = false;

  bool get isConsentChecked => _consentChecked;

  Future<bool> get canRequestAds async {
    try {
      return await ConsentInformation.instance.canRequestAds();
    } catch (e) {
      debugPrint('ConsentService: canRequestAds error — $e');
      return false;
    }
  }

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

  Future<bool> requestConsent() async {
    try {
      final params = ConsentRequestParameters(
        tagForUnderAgeOfConsent: false,
        
      );

      await _requestConsentInfoUpdate(params);
      await _loadAndShowConsentFormIfRequired();

      _consentChecked = true;
      final allowed = await canRequestAds;
      debugPrint('ConsentService: consent settled — canRequestAds=$allowed');
      return allowed;
    } catch (e) {
      debugPrint('ConsentService: requestConsent error — $e');
      _consentChecked = true;
      return await canRequestAds;
    }
  }

  Future<void> showPrivacyOptionsForm() async {
    try {
      await _showPrivacyOptionsFormAsync();
      debugPrint('ConsentService: privacy options form shown');
    } catch (e) {
      debugPrint('ConsentService: showPrivacyOptionsForm error — $e');
    }
  }

  void resetConsent() {
    try {
      ConsentInformation.instance.reset();
      _consentChecked = false;
      debugPrint('ConsentService: consent reset');
    } catch (e) {
      debugPrint('ConsentService: reset error — $e');
    }
  }

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
        completer.complete(); 
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
