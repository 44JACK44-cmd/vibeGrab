import 'dart:io' show Platform;

import 'package:shared_preferences/shared_preferences.dart';

class ApiConfig {
  static String? _customBaseUrl;
  static const String _prefKey = 'vibegrab_backend_url';
  static const String _defaultBaseUrl = 'https://vibegrab-api.onrender.com';

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _customBaseUrl = prefs.getString(_prefKey);
  }

  static Future<void> setBaseUrl(String url) async {
    _customBaseUrl = url.isEmpty ? null : url;
    final prefs = await SharedPreferences.getInstance();
    if (url.isEmpty) {
      await prefs.remove(_prefKey);
    } else {
      await prefs.setString(_prefKey, url);
    }
  }

  static String get baseUrl {
    if (_customBaseUrl != null && _customBaseUrl!.isNotEmpty) {
      return _customBaseUrl!;
    }
    return _defaultBaseUrl;
  }

  static bool get isCustomBackend => _customBaseUrl != null && _customBaseUrl!.isNotEmpty;

  static String get displayUrl => baseUrl;

  /// Feed locale for the backend (YouTube innertube hl/gl): `lang=es&gl=ES`.
  /// Derived from the device locale so trending/search match the region.
  static String get feedLocaleQuery {
    try {
      final parts = Platform.localeName.split(RegExp(r'[_\-.]'));
      var lang = parts.isNotEmpty ? parts.first.toLowerCase() : 'en';
      if (lang.length > 3) lang = lang.substring(0, 2);
      if (!RegExp(r'^[a-z]{2,3}$').hasMatch(lang)) lang = 'en';
      var gl = parts.length > 1 ? parts[1].toUpperCase() : '';
      if (!RegExp(r'^[A-Z]{2}$').hasMatch(gl)) {
        gl = lang == 'es' ? 'ES' : 'US';
      }
      return 'lang=$lang&gl=$gl';
    } catch (_) {
      return 'lang=en&gl=US';
    }
  }

  /// True when the device speaks Spanish (picks localized feed seed queries).
  static bool get isSpanishLocale {
    try {
      return Platform.localeName.toLowerCase().startsWith('es');
    } catch (_) {
      return false;
    }
  }

  static const String analyzeEndpoint = '/api/analyze';
  static const String downloadsEndpoint = '/api/downloads';
  static const String libraryEndpoint = '/api/library';
  static const String settingsEndpoint = '/api/settings';
  static const String healthEndpoint = '/api/health';
  static const String statusEndpoint = '/api/status';
  static const String exploreEndpoint = '/api/explore';

  static String get analyzeUrl => '$baseUrl$analyzeEndpoint';
  static String get downloadsUrl => '$baseUrl$downloadsEndpoint';
  static String get libraryUrl => '$baseUrl$libraryEndpoint';
  static String get settingsUrl => '$baseUrl$settingsEndpoint';
  static String get healthUrl => '$baseUrl$healthEndpoint';
  static String get statusUrl => '$baseUrl$statusEndpoint';
  static String libraryStreamUrl(String filename) => '$baseUrl$libraryEndpoint/$filename/stream';
  static String libraryDeleteUrl(String filename) => '$baseUrl$libraryEndpoint/$filename';
  static String get exploreSearchUrl => '$baseUrl$exploreEndpoint/search';
  static String get exploreRelatedUrl => '$baseUrl$exploreEndpoint/related';
  static String get exploreCommentsUrl => '$baseUrl$exploreEndpoint/comments';
  static String get exploreStreamUrl => '$baseUrl$exploreEndpoint/stream-url';
  static String get exploreTrendingUrl => '$baseUrl$exploreEndpoint/trending';
  static String get exploreLinkMetadataUrl =>
      '$baseUrl$exploreEndpoint/link-metadata';
}
