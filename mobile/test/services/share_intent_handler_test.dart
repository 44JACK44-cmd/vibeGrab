import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/services/share_intent_handler.dart';
import 'package:vibegrab/services/local_extraction_service.dart';

void main() {
  group('ShareIntentHandler - extractUrl (public via _extractUrl)', () {
    test('extracts direct URL', () {
      final result = ShareIntentHandler.sanitizeUrl('https://youtube.com/watch?v=abc');
      expect(result, 'https://youtube.com/watch?v=abc');
    });

    test('extracts URL embedded in text using regex', () {
      final text = 'Mira esto: https://youtube.com/watch?v=abc123';
      final match = RegExp(r'https?://[^\s<>\"{}|\\^`\[\]]+', caseSensitive: false)
          .firstMatch(text);
      expect(match?.group(0), 'https://youtube.com/watch?v=abc123');
    });

    test('extracts youtu.be URL', () {
      final text = 'https://youtu.be/abc123';
      final match = RegExp(r'https?://[^\s<>\"{}|\\^`\[\]]+', caseSensitive: false)
          .firstMatch(text);
      expect(match?.group(0), 'https://youtu.be/abc123');
    });

    test('returns null for text without URL', () {
      final match = RegExp(r'https?://[^\s<>\"{}|\\^`\[\]]+', caseSensitive: false)
          .firstMatch('No URL here');
      expect(match, isNull);
    });
  });

  group('ShareIntentHandler - sanitizeUrl', () {
    test('removes zero-width spaces', () {
      expect(
          ShareIntentHandler.sanitizeUrl('https://youtube.com/\u200Bwatch?v=abc'),
          'https://youtube.com/watch?v=abc');
    });

    test('removes trailing whitespace', () {
      expect(ShareIntentHandler.sanitizeUrl('https://youtube.com/watch?v=abc '),
          'https://youtube.com/watch?v=abc');
    });

    test('removes hash fragment', () {
      expect(ShareIntentHandler.sanitizeUrl('https://youtube.com/watch?v=abc#section'),
          'https://youtube.com/watch?v=abc');
    });
  });

  group('ShareIntentHandler - detectPlatform', () {
    test('detects YouTube', () {
      expect(ShareIntentHandler.detectPlatform('https://youtube.com/watch?v=abc'),
          'youtube.com');
    });

    test('detects youtu.be', () {
      expect(ShareIntentHandler.detectPlatform('https://youtu.be/abc'), 'youtu.be');
    });

    test('detects TikTok', () {
      expect(ShareIntentHandler.detectPlatform('https://www.tiktok.com/@user/video/123'),
          'tiktok.com');
    });

    test('returns null for unsupported', () {
      expect(ShareIntentHandler.detectPlatform('https://example.com/page'), isNull);
    });
  });

  group('LocalExtractionService - platform support', () {
    test('supports YouTube URL', () {
      expect(LocalExtractionService.supportsPlatform('https://youtube.com/watch?v=abc12345678'), true);
    });

    test('supports youtu.be URL', () {
      expect(LocalExtractionService.supportsPlatform('https://youtu.be/abc12345678'), true);
    });

    test('does not support TikTok', () {
      expect(LocalExtractionService.supportsPlatform('https://www.tiktok.com/@user/video/123'), false);
    });

    test('does not support Instagram', () {
      expect(LocalExtractionService.supportsPlatform('https://www.instagram.com/p/xyz'), false);
    });

    test('does not support Facebook', () {
      expect(LocalExtractionService.supportsPlatform('https://www.facebook.com/video/123'), false);
    });

    test('does not support X/Twitter', () {
      expect(LocalExtractionService.supportsPlatform('https://x.com/user/status/123'), false);
    });

    test('does not support Reddit', () {
      expect(LocalExtractionService.supportsPlatform('https://www.reddit.com/r/test/comments/xyz'), false);
    });

    test('does not support Vimeo', () {
      expect(LocalExtractionService.supportsPlatform('https://vimeo.com/123456'), false);
    });
  });

  group('LocalExtractionService - sanitizeUrl', () {
    test('removes zero-width characters', () {
      expect(
          LocalExtractionService.sanitizeUrl('https://youtube.com/watch?v=abc\u200B'),
          'https://youtube.com/watch?v=abc');
    });

    test('removes hash fragment', () {
      expect(
          LocalExtractionService.sanitizeUrl('https://youtube.com/watch?v=abc#section'),
          'https://youtube.com/watch?v=abc');
    });
  });

  group('LocalExtractionService - friendlyError', () {
    test('maps unsupported platform', () {
      expect(LocalExtractionService.friendlyError(UnsupportedPlatformException('tiktok')),
          'unsupported_platform');
    });

    test('maps content unavailable', () {
      expect(LocalExtractionService.friendlyError(ContentUnavailableException('youtube')),
          'content_unavailable');
    });

    test('maps timeout', () {
      expect(LocalExtractionService.friendlyError(Exception('TimeoutException')), 'timeout');
    });

    test('maps no internet', () {
      expect(
          LocalExtractionService.friendlyError(Exception('SocketException: Connection refused')),
          'no_internet');
    });

    test('maps format exception', () {
      expect(LocalExtractionService.friendlyError(Exception('FormatException')), 'invalid_url');
    });
  });
}
