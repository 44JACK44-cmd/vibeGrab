import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/services/local_download_service.dart';

void main() {
  group('download resume bookkeeping', () {
    final url = Uri.parse('https://cdn.example.com/video?id=abc&expire=1');

    test('partial files are stable for the same task and URL', () {
      final a = LocalDownloadService.partialPathFor(
          '/downloads/Video.mp4', 'dl_1', url);
      final b = LocalDownloadService.partialPathFor(
          '/downloads/Video.mp4', 'dl_1', Uri.parse(url.toString()));

      expect(a, b);
      expect(a, endsWith('.part'));
      expect(a, contains('dl_1'));
      expect(a, isNot('/downloads/Video.mp4'));
    });

    test('a different route never reuses another stream partial', () {
      final first = LocalDownloadService.partialPathFor(
          '/downloads/Video.mp4', 'dl_1', url);
      final second = LocalDownloadService.partialPathFor(
          '/downloads/Video.mp4',
          'dl_1',
          Uri.parse('https://relay.example.com/relay?v=abc'));

      expect(first, isNot(second));
    });

    test('Content-Range start is parsed for resumes', () {
      expect(
        LocalDownloadService.contentRangeStartForTest(
            'bytes 1048576-2097151/2097152'),
        1048576,
      );
      expect(
        LocalDownloadService.contentRangeStartForTest('bytes 0-99/100'),
        0,
      );
      expect(LocalDownloadService.contentRangeStartForTest(null), isNull);
      expect(
          LocalDownloadService.contentRangeStartForTest('garbage'), isNull);
    });
  });
}
