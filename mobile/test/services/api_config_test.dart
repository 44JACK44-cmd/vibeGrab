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
  });
}
