import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/data/models/media_info.dart';

MediaInfo _media(String? thumbnail) => MediaInfo(
      id: 'id1',
      title: 'Title',
      thumbnail: thumbnail,
      source: 'youtube',
    );

void main() {
  group('MediaInfo.hasDownloadableImage', () {
    test('is false without a thumbnail', () {
      expect(_media(null).hasDownloadableImage, isFalse);
      expect(_media('').hasDownloadableImage, isFalse);
      expect(_media('   ').hasDownloadableImage, isFalse);
    });

    test('is false for values that are not absolute http(s) URLs', () {
      expect(_media('not a url').hasDownloadableImage, isFalse);
      expect(_media('/images/cover.jpg').hasDownloadableImage, isFalse);
      expect(_media('data:image/png;base64,iVBOR').hasDownloadableImage,
          isFalse);
      expect(_media('file:///sdcard/cover.jpg').hasDownloadableImage, isFalse);
    });

    test('is false for a page preview with no image extension', () {
      // A page URL is not an image: saving it would write HTML as a cover.
      expect(_media('https://example.com/video/12345').hasDownloadableImage,
          isFalse);
      expect(_media('https://example.com/cover').hasDownloadableImage, isFalse);
    });

    test('is true for a thumbnail on a known image host', () {
      expect(
        _media('https://i.ytimg.com/vi/abc123/hqdefault.jpg')
            .hasDownloadableImage,
        isTrue,
      );
      // No extension at all, but the host is known to serve image files.
      expect(
        _media('https://i.ytimg.com/vi_webp/abc123/hqdefault')
            .hasDownloadableImage,
        isTrue,
      );
    });

    test('is true for any URL with a real image extension', () {
      expect(_media('https://cdn.example.com/a/Cover.JPG').hasDownloadableImage,
          isTrue);
      expect(_media('https://cdn.example.com/a/cover.png').hasDownloadableImage,
          isTrue);
      expect(_media('https://cdn.example.com/a/cover.webp').hasDownloadableImage,
          isTrue);
    });

    test('does not accept an extension that is not an image', () {
      expect(_media('https://cdn.example.com/a/clip.mp4').hasDownloadableImage,
          isFalse);
      expect(_media('https://cdn.example.com/a/page.html').hasDownloadableImage,
          isFalse);
    });
  });

  group('MediaInfo.imageExtension', () {
    test('takes the extension from the URL', () {
      expect(_media('https://i.ytimg.com/vi/abc/maxresdefault.jpg').imageExtension,
          'jpg');
      expect(_media('https://cdn.example.com/cover.jpeg').imageExtension, 'jpeg');
      expect(_media('https://cdn.example.com/cover.png').imageExtension, 'png');
      expect(_media('https://cdn.example.com/cover.webp').imageExtension, 'webp');
    });

    test('ignores the query string', () {
      expect(
        _media('https://cdn.example.com/cover.png?width=640&v=2').imageExtension,
        'png',
      );
    });

    test('defaults to jpg when the URL carries no extension', () {
      expect(_media('https://i.ytimg.com/vi_webp/abc/hqdefault').imageExtension,
          'jpg');
      expect(_media(null).imageExtension, 'jpg');
    });
  });
}
