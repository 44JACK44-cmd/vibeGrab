import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vibegrab/core/constants/api_constants.dart';
import 'package:vibegrab/services/api_service.dart';

/// True when the header map contains `x-api-key` (case-insensitive).
bool _hasApiKey(Map<String, String>? headers) => headers == null
    ? false
    : headers.keys.any((k) => k.toLowerCase() == 'x-api-key');

void main() {
  group('ApiConfig.apiKey', () {
    test('is empty by default so auth stays disabled', () {
      // Tests are compiled without --dart-define, so this mirrors a normal
      // build: no key is sent and the backend keeps working unauthenticated.
      expect(ApiConfig.apiKey, isEmpty);
      expect(ApiConfig.authHeaders, isEmpty);
    });

    test('streamHeaders always carry a User-Agent', () {
      expect(ApiConfig.streamHeaders['User-Agent'], isNotEmpty);
      expect(ApiConfig.streamUserAgent, isNotEmpty);
    });
  });

  group('ApiHttpClient', () {
    test('adds X-API-Key when a key is configured', () async {
      Map<String, String>? seen;
      final mock = MockClient((request) async {
        seen = request.headers;
        return http.Response('{}', 200);
      });
      final client = ApiHttpClient(mock, 'secret');

      await client.get(Uri.parse('https://example.test/api/status'));

      expect(seen?['X-API-Key'], 'secret');
    });

    test('adds no key when the key is empty', () async {
      Map<String, String>? seen;
      final mock = MockClient((request) async {
        seen = request.headers;
        return http.Response('{}', 200);
      });
      final client = ApiHttpClient(mock, '');

      await client.get(Uri.parse('https://example.test/api/status'));

      expect(_hasApiKey(seen), isFalse);
    });

    test('preserves existing request headers', () async {
      Map<String, String>? seen;
      final mock = MockClient((request) async {
        seen = request.headers;
        return http.Response(jsonEncode({'ok': true}), 200);
      });
      final client = ApiHttpClient(mock, 'secret');

      await client.get(
        Uri.parse('https://example.test/api/status'),
        headers: {'Accept': 'application/json'},
      );

      expect(seen?['Accept'], 'application/json');
      expect(seen?['X-API-Key'], 'secret');
    });
  });
}
