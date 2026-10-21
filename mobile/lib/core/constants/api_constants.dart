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

  /// A custom backend must use HTTPS, except on explicit development hosts
  /// (emulator loopback / localhost). Accepting `http://` here would send the
  /// API key and download requests in clear text over the network.
  static bool isAllowedBaseUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return false;
    if (uri.scheme == 'https') return true;
    if (uri.scheme != 'http') return false;
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
      return true;
    }
    return _isPrivateIpv4(host);
  }

  /// True only for RFC 1918 addresses. A suffix/prefix check would accept
  /// hostnames such as `10.evil.example` and allow cleartext to the internet.
  static bool _isPrivateIpv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final octets = <int>[];
    for (final part in parts) {
      if (part.isEmpty || !RegExp(r'^\d{1,3}$').hasMatch(part)) return false;
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return false;
      octets.add(value);
    }
    if (octets[0] == 10) return true;
    if (octets[0] == 192 && octets[1] == 168) return true;
    if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) return true;
    return false;
  }

  static Future<bool> setBaseUrl(String url) async {
    if (url.isNotEmpty && !isAllowedBaseUrl(url)) return false;
    _customBaseUrl = url.isEmpty ? null : url;
    final prefs = await SharedPreferences.getInstance();
    if (url.isEmpty) {
      await prefs.remove(_prefKey);
    } else {
      await prefs.setString(_prefKey, url);
    }
    return true;
  }

  static String get baseUrl {
    final custom = _customBaseUrl;
    if (custom != null && custom.isNotEmpty && isAllowedBaseUrl(custom)) {
      return custom;
    }
    return _defaultBaseUrl;
  }

  static bool get isCustomBackend => _customBaseUrl != null && _customBaseUrl!.isNotEmpty;

  static String get displayUrl => baseUrl;

  /// Optional shared secret sent as `X-API-Key` on every backend request.
  ///
  /// Baked in at build time so it never lives in the repo:
  ///   flutter build apk --dart-define=VIBEGRAB_API_KEY=xxxx
  /// Empty (the default) means the backend has auth disabled, matching
  /// current production.
  static const String apiKey =
      String.fromEnvironment('VIBEGRAB_API_KEY', defaultValue: '');

  /// Headers required by the backend on every /api/* request.
  static Map<String, String> get authHeaders =>
      apiKey.isEmpty ? const {} : {'X-API-Key': apiKey};

  /// UA used when the app streams media (googlevideo, our relay/proxy).
  static const String streamUserAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36';

  /// Headers for media streams: harmless on direct CDN URLs, required on the
  /// backend relay/proxy once API-key auth is enabled there.
  static Map<String, String> get streamHeaders => {
        'User-Agent': streamUserAgent,
        ...authHeaders,
      };

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
  static const String convertAudioEndpoint = '/api/convert/audio';
  static const String mergeEndpoint = '/api/merge';
  static const String downloadsEndpoint = '/api/downloads';
  static const String libraryEndpoint = '/api/library';
  static const String settingsEndpoint = '/api/settings';
  static const String healthEndpoint = '/api/health';
  static const String statusEndpoint = '/api/status';
  static const String exploreEndpoint = '/api/explore';

  static String get analyzeUrl => '$baseUrl$analyzeEndpoint';
  static String get convertAudioUrl => '$baseUrl$convertAudioEndpoint';
  static String get mergeUrl => '$baseUrl$mergeEndpoint';
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
