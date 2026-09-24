import 'package:shared_preferences/shared_preferences.dart';

class ApiConfig {
  static String? _customBaseUrl;
  static const String _prefKey = 'vibegrab_backend_url';
  static const String _defaultEmulatorUrl = 'http://10.0.2.2:8000';

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
    return _defaultEmulatorUrl;
  }

  static bool get isCustomBackend => _customBaseUrl != null && _customBaseUrl!.isNotEmpty;
  static bool get isBackendConfigured => isCustomBackend;

  static String get displayUrl => _customBaseUrl ?? 'Not configured';

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
}
