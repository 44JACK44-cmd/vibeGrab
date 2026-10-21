import 'package:flutter/foundation.dart';

/// Publicidad de VibeGrab.
///
/// La app usa Google AdMob (SDK oficial) con identificadores de prueba en
/// desarrollo. Una compilación de release solo activa anuncios si se pasan
/// identificadores reales por `--dart-define`; de lo contrario la app sigue
/// funcionando sin publicidad y sin mostrar anuncios de prueba a usuarios.
class AdConfig {
  AdConfig._();

  // Identificadores oficiales de prueba de Google. Nunca generan ingresos.
  static const String testAppId = 'ca-app-pub-3940256099942544~3347511713';
  static const String testBannerUnitId =
      'ca-app-pub-3940256099942544/6300978111';
  static const String testInterstitialUnitId =
      'ca-app-pub-3940256099942544/1033173712';

  static const bool _enabledFlag = bool.fromEnvironment(
    'ADMOB_ENABLED',
    defaultValue: false,
  );
  static const String _bannerUnitId = String.fromEnvironment('ADMOB_BANNER_ID');
  static const String _interstitialUnitId = String.fromEnvironment(
    'ADMOB_INTERSTITIAL_ID',
  );
  static const int _bannerDelaySeconds = int.fromEnvironment(
    'ADMOB_BANNER_DELAY_SECONDS',
    defaultValue: 20,
  );

  /// En debug se usan los anuncios de prueba. En release hace falta activar
  /// explícitamente el proveedor y aportar un bloque de anuncios real.
  static bool get enabled {
    if (kDebugMode) return true;
    return _enabledFlag && _bannerUnitId.isNotEmpty;
  }

  static bool get usingTestAds => kDebugMode || _bannerUnitId.isEmpty;

  static String get bannerUnitId =>
      kDebugMode ? testBannerUnitId : _bannerUnitId;

  static String get interstitialUnitId =>
      kDebugMode ? testInterstitialUnitId : _interstitialUnitId;

  static bool get canShowInterstitials => interstitialUnitId.isNotEmpty;

  /// El banner no se pide durante el arranque: deja pasar la sesión inicial
  /// para que la app nunca abra con publicidad encima de la pantalla.
  static const Duration initialBannerDelay = Duration(
    seconds: _bannerDelaySeconds,
  );

  /// Límites de producto. La red publicitaria puede imponer límites distintos;
  /// AdPolicy y AdFrequencyController son el único punto de decisión.
  static const Duration interstitialCooldown = Duration(minutes: 10);
  static const Duration interstitialSessionGrace = Duration(seconds: 60);
  static const int maxInterstitialsPerSession = 3;

  static const Duration bannerRequestTimeout = Duration(seconds: 20);
  static const Duration consentTimeout = Duration(seconds: 30);
}
