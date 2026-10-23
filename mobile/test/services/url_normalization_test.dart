import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/services/analysis_failure.dart';
import 'package:vibegrab/services/local_extraction_service.dart';

const _id = 'dQw4w9WgXcQ';
const _canonical = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';

void main() {
  group('sanitizeUrl canonicalization', () {
    test('every equivalent YouTube spelling becomes one URL', () {
      final inputs = <String>[
        'https://www.youtube.com/watch?v=$_id',
        'https://youtu.be/$_id',
        'https://youtu.be/$_id?si=tracking',
        'https://m.youtube.com/watch?v=$_id&feature=share',
        'https://music.youtube.com/watch?v=$_id',
        'https://www.youtube.com/shorts/$_id',
        'https://www.youtube.com/embed/$_id',
        'https://www.youtube.com/live/$_id',
        'https://www.youtube-nocookie.com/embed/$_id',
        'youtu.be/$_id',
        'youtube.com/watch?v=$_id',
        '  https://youtu.be/$_id  ',
        'Mira este video: https://youtu.be/$_id (imperdible)',
        'https://youtu.be/$_id.   ',
      ];
      for (final input in inputs) {
        expect(
          LocalExtractionService.sanitizeUrl(input),
          _canonical,
          reason: 'input: $input',
        );
      }
    });

    test('removes tracking parameters and the fragment', () {
      expect(
        LocalExtractionService.sanitizeUrl(
            'https://example.com/page?utm_source=x&utm_medium=y&id=7#top'),
        'https://example.com/page?id=7',
      );
    });

    test('keeps a bare 11-character video id', () {
      expect(LocalExtractionService.sanitizeUrl(_id), _id);
    });

    test('never adds a scheme to arbitrary text', () {
      final cleaned = LocalExtractionService.sanitizeUrl('just some words');
      expect(LocalExtractionService.looksLikeUrl(cleaned), isFalse);
    });

    test('a playlist URL is not mistaken for a video', () {
      final cleaned = LocalExtractionService.sanitizeUrl(
          'https://www.youtube.com/playlist?list=PL1234567890');
      expect(cleaned.contains('/playlist'), isTrue);
      expect(LocalExtractionService.looksLikeUrl(cleaned), isTrue);
    });
  });

  group('platform detection', () {
    test('accepts all YouTube hosts, including scheme-less input', () {
      for (final url in const [
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        'https://youtu.be/dQw4w9WgXcQ',
        'https://m.youtube.com/watch?v=dQw4w9WgXcQ',
        'https://music.youtube.com/watch?v=dQw4w9WgXcQ',
        'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ',
        'youtu.be/dQw4w9WgXcQ',
      ]) {
        expect(LocalExtractionService.supportsPlatform(url), isTrue,
            reason: url);
        expect(LocalExtractionService.detectPlatform(url), 'youtube');
      }
    });

    test('rejects other platforms', () {
      for (final url in const [
        'https://www.tiktok.com/@user/video/123',
        'https://vimeo.com/123456',
        'https://example.com/video',
      ]) {
        expect(LocalExtractionService.supportsPlatform(url), isFalse,
            reason: url);
      }
    });
  });

  group('extractMedia rejects bad input locally', () {
    test('malformed text fails as invalidUrl without network', () async {
      await expectLater(
        LocalExtractionService().extractMedia('not a url at all'),
        throwsA(isA<AnalysisException>().having(
          (e) => e.type,
          'type',
          AnalysisFailureType.invalidUrl,
        )),
      );
    });

    test('an unsupported host fails as unsupportedPlatform', () async {
      await expectLater(
        LocalExtractionService()
            .extractMedia('https://www.tiktok.com/@user/video/123'),
        throwsA(isA<AnalysisException>().having(
          (e) => e.type,
          'type',
          AnalysisFailureType.unsupportedPlatform,
        )),
      );
    });

    test('a YouTube playlist fails as unsupportedPlatform (no video id)',
        () async {
      await expectLater(
        LocalExtractionService().extractMedia(
            'https://www.youtube.com/playlist?list=PL1234567890'),
        throwsA(isA<AnalysisException>()
            .having((e) => e.type, 'type',
                AnalysisFailureType.unsupportedPlatform)
            .having((e) => e.code, 'code', 'no_video_id')),
      );
    });
  });
}
