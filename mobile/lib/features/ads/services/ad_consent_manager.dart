import 'dart:async';

import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../config/ad_config.dart';

/// Google User Messaging Platform (UMP) wrapper.
///
/// Consent is requested before the SDK is initialised and before any ad request
/// can be made. If the consent update fails or times out, ads stay disabled and
/// the rest of VibeGrab continues normally.
class AdConsentManager {
  bool _canRequestAds = false;
  bool _privacyOptionsRequired = false;

  bool get canRequestAds => _canRequestAds;
  bool get privacyOptionsRequired => _privacyOptionsRequired;

  Future<bool> requestConsent() async {
    if (!AdConfig.enabled) {
      _canRequestAds = false;
      _privacyOptionsRequired = false;
      return false;
    }

    final completer = Completer<bool>();
    void finish(bool value) {
      _canRequestAds = value;
      if (!completer.isCompleted) completer.complete(value);
    }

    try {
      ConsentInformation.instance.requestConsentInfoUpdate(
        ConsentRequestParameters(),
        () {
          ConsentForm.loadAndShowConsentFormIfRequired((formError) {
            _readCanRequestAds(finish);
          }).catchError((Object error) {
            finish(false);
          });
        },
        (formError) {
          finish(false);
        },
      );
    } catch (_) {
      finish(false);
    }

    return completer.future.timeout(
      AdConfig.consentTimeout,
      onTimeout: () {
        _canRequestAds = false;
        return false;
      },
    );
  }

  Future<void> _readCanRequestAds(void Function(bool) finish) async {
    try {
      final canRequest = await ConsentInformation.instance.canRequestAds();
      try {
        final status = await ConsentInformation.instance
            .getPrivacyOptionsRequirementStatus();
        _privacyOptionsRequired =
            status == PrivacyOptionsRequirementStatus.required;
      } catch (_) {
        _privacyOptionsRequired = false;
      }
      finish(canRequest);
    } catch (_) {
      _privacyOptionsRequired = false;
      finish(false);
    }
  }

  /// Opens the privacy options form when the user's region requires one.
  /// Returns true only when the form was shown and dismissed without an error.
  Future<bool> showPrivacyOptions() async {
    if (!AdConfig.enabled) return false;

    try {
      final status = await ConsentInformation.instance
          .getPrivacyOptionsRequirementStatus();
      if (status != PrivacyOptionsRequirementStatus.required) return false;

      final completer = Completer<bool>();
      await ConsentForm.showPrivacyOptionsForm((formError) {
        if (!completer.isCompleted) completer.complete(formError == null);
      });
      final result = await completer.future.timeout(
        AdConfig.consentTimeout,
        onTimeout: () => false,
      );
      if (result) await _refreshConsentState();
      return result;
    } catch (_) {
      return false;
    }
  }

  Future<void> _refreshConsentState() async {
    try {
      _canRequestAds = await ConsentInformation.instance.canRequestAds();
    } catch (_) {
      _canRequestAds = false;
    }
    try {
      final status = await ConsentInformation.instance
          .getPrivacyOptionsRequirementStatus();
      _privacyOptionsRequired =
          status == PrivacyOptionsRequirementStatus.required;
    } catch (_) {
      _privacyOptionsRequired = false;
    }
  }
}
