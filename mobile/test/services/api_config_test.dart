import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/core/constants/api_constants.dart';

void main() {
  group('ApiConfig', () {
    test('healthUrl is correct', () {
      expect(ApiConfig.healthUrl, contains('/api/health'));
    });

    test('statusUrl is correct', () {
      expect(ApiConfig.statusUrl, contains('/api/status'));
    });

    test('libraryStreamUrl includes filename', () {
      final url = ApiConfig.libraryStreamUrl('video.mp4');
      expect(url, contains('video.mp4'));
      expect(url, contains('/api/library/'));
      expect(url, contains('/stream'));
    });

    test('libraryDeleteUrl includes filename', () {
      final url = ApiConfig.libraryDeleteUrl('video.mp4');
      expect(url, contains('video.mp4'));
      expect(url, contains('/api/library/'));
    });

    test('exploreSearchUrl has search endpoint', () {
      expect(ApiConfig.exploreSearchUrl, contains('/api/explore/search'));
    });

    test('all URLs use http or https scheme', () {
      expect(ApiConfig.analyzeUrl, startsWith('http'));
      expect(ApiConfig.downloadsUrl, startsWith('http'));
      expect(ApiConfig.libraryUrl, startsWith('http'));
      expect(ApiConfig.statusUrl, startsWith('http'));
    });

    test('custom backend accepts HTTPS', () {
      expect(ApiConfig.isAllowedBaseUrl('https://api.example.com'), isTrue);
      expect(ApiConfig.isAllowedBaseUrl('https://api.example.com:8443/v1'),
          isTrue);
    });

    test('custom backend rejects public cleartext', () {
      expect(ApiConfig.isAllowedBaseUrl('http://api.example.com'), isFalse);
      expect(ApiConfig.isAllowedBaseUrl('http://192.0.2.10:8000'), isFalse);
      expect(ApiConfig.isAllowedBaseUrl('http://8.8.8.8'), isFalse);
      // A hostname that merely starts with a private prefix is not private.
      expect(ApiConfig.isAllowedBaseUrl('http://10.evil.example'), isFalse);
      expect(ApiConfig.isAllowedBaseUrl('http://192.168.evil.example'),
          isFalse);
    });

    test('custom backend accepts explicit development hosts', () {
      expect(ApiConfig.isAllowedBaseUrl('http://localhost:8000'), isTrue);
      expect(ApiConfig.isAllowedBaseUrl('http://127.0.0.1:8000'), isTrue);
      expect(ApiConfig.isAllowedBaseUrl('http://10.0.2.2:8000'), isTrue);
      expect(ApiConfig.isAllowedBaseUrl('http://192.168.1.20:8000'), isTrue);
      expect(ApiConfig.isAllowedBaseUrl('http://172.16.0.5:8000'), isTrue);
    });

    test('custom backend rejects non-http schemes and malformed URLs', () {
      expect(ApiConfig.isAllowedBaseUrl('ftp://example.com'), isFalse);
      expect(ApiConfig.isAllowedBaseUrl('file:///etc/passwd'), isFalse);
      expect(ApiConfig.isAllowedBaseUrl('not a url'), isFalse);
      expect(ApiConfig.isAllowedBaseUrl(''), isFalse);
    });
  });
}
