import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/features/browser/url_detector/browser_url_detector.dart';

void main() {
  group('BrowserUrlDetector.downloadableUrl', () {
    test('matches YouTube watch pages (desktop, m., music.)', () {
      expect(
        BrowserUrlDetector.downloadableUrl(
            'https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
        isNotNull,
      );
      expect(
        BrowserUrlDetector.downloadableUrl(
            'https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=42s'),
        isNotNull,
      );
      expect(
        BrowserUrlDetector.downloadableUrl(
            'https://music.youtube.com/watch?v=dQw4w9WgXcQ&feature=share'),
        isNotNull,
      );
    });

    test('matches youtu.be short links and Shorts/Live paths', () {
      expect(
        BrowserUrlDetector.downloadableUrl('https://youtu.be/dQw4w9WgXcQ'),
        isNotNull,
      );
      expect(
        BrowserUrlDetector.downloadableUrl(
            'https://www.youtube.com/shorts/dQw4w9WgXcQ'),
        isNotNull,
      );
      expect(
        BrowserUrlDetector.downloadableUrl(
            'https://www.youtube.com/live/dQw4w9WgXcQ'),
        isNotNull,
      );
    });

    test('rejects YouTube browse pages', () {
      expect(BrowserUrlDetector.downloadableUrl('https://www.youtube.com/'),
          isNull);
      expect(
        BrowserUrlDetector.downloadableUrl(
            'https://www.youtube.com/results?search_query=music'),
        isNull,
      );
      expect(
        BrowserUrlDetector.downloadableUrl(
            'https://www.youtube.com/@SomeChannel'),
        isNull,
      );
      expect(
        BrowserUrlDetector.downloadableUrl(
            'https://www.youtube.com/shorts/'),
        isNull,
      );
    });

    test('matches TikTok video pages but not profiles', () {
      expect(
        BrowserUrlDetector.downloadableUrl(
            'https://www.tiktok.com/@user/video/7123456789012345678'),
        isNotNull,
      );
      expect(
        BrowserUrlDetector.downloadableUrl('https://vm.tiktok.com/ZMabcdef/'),
        isNotNull,
      );
      expect(
        BrowserUrlDetector.downloadableUrl('https://www.tiktok.com/@user'),
        isNull,
      );
    });

    test('matches Instagram reels/posts but not profiles', () {
      expect(
        BrowserUrlDetector.downloadableUrl(
            'https://www.instagram.com/reel/ABC123def/'),
        isNotNull,
      );
      expect(
        BrowserUrlDetector.downloadableUrl(
            'https://www.instagram.com/p/ABC123def/'),
        isNotNull,
      );
      expect(
        BrowserUrlDetector.downloadableUrl(
            'https://www.instagram.com/someuser/'),
        isNull,
      );
    });

    test('matches X/Twitter status posts but not profiles', () {
      expect(
        BrowserUrlDetector.downloadableUrl(
            'https://x.com/someuser/status/1234567890'),
        isNotNull,
      );
      expect(
        BrowserUrlDetector.downloadableUrl(
            'https://twitter.com/someuser/status/1234567890?s=20'),
        isNotNull,
      );
      expect(
        BrowserUrlDetector.downloadableUrl('https://x.com/someuser'),
        isNull,
      );
    });

    test('matches Vimeo video ids', () {
      expect(
        BrowserUrlDetector.downloadableUrl('https://vimeo.com/123456789'),
        isNotNull,
      );
      expect(BrowserUrlDetector.downloadableUrl('https://vimeo.com/'), isNull);
    });

    test('matches Dailymotion videos but not home', () {
      expect(
        BrowserUrlDetector.downloadableUrl(
            'https://www.dailymotion.com/video/x8abcde'),
        isNotNull,
      );
      expect(
          BrowserUrlDetector.downloadableUrl('https://www.dailymotion.com/'),
          isNull);
    });

    test('matches SoundCloud tracks but not home', () {
      expect(
        BrowserUrlDetector.downloadableUrl(
            'https://soundcloud.com/artist/track-name'),
        isNotNull,
      );
      expect(
          BrowserUrlDetector.downloadableUrl('https://soundcloud.com/'),
          isNull);
    });

    test('rejects Facebook watch/reel pages', () {
      expect(
        BrowserUrlDetector.downloadableUrl(
            'https://www.facebook.com/watch/?v=123456789'),
        isNotNull,
      );
      expect(
        BrowserUrlDetector.downloadableUrl(
            'https://www.facebook.com/reel/123456789'),
        isNotNull,
      );
      expect(
        BrowserUrlDetector.downloadableUrl('https://www.facebook.com/'),
        isNull,
      );
    });

    test('rejects unsupported or invalid URLs', () {
      expect(BrowserUrlDetector.downloadableUrl(''), isNull);
      expect(BrowserUrlDetector.downloadableUrl('not a url'), isNull);
      expect(
          BrowserUrlDetector.downloadableUrl('https://example.com/'), isNull);
      expect(
        BrowserUrlDetector.downloadableUrl('ftp://youtube.com/watch?v=abc'),
        isNull,
      );
    });
  });
}
