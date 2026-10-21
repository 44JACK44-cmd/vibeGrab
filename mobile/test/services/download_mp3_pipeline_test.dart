import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/data/models/download_task.dart';
import 'package:vibegrab/features/downloads/controllers/downloads_controller.dart';
import 'package:vibegrab/services/local_download_service.dart';
import 'package:vibegrab/services/local_extraction_service.dart';

DownloadTask _task({
  String id = 'dl_1',
  String url = 'https://www.youtube.com/watch?v=abc123abc12',
  String formatId = '140',
  String? fileExt = 'm4a',
  DownloadMediaType mediaType = DownloadMediaType.audio,
  DownloadStatus status = DownloadStatus.queued,
}) {
  return DownloadTask(
    id: id,
    url: url,
    title: 'Song',
    formatId: formatId,
    fileExt: fileExt,
    mediaType: mediaType,
    status: status,
    createdAt: '2026-01-01T00:00:00.000Z',
  );
}

void main() {
  group('LocalDownloadService.wantsMp3', () {
    late LocalDownloadService service;

    setUp(() => service = LocalDownloadService());
    tearDown(() => service.dispose());

    test('routes a normal MP3 audio task through the MP3 pipeline', () {
      expect(service.wantsMp3(_task(fileExt: 'mp3')), isTrue);
    });

    test('routes the synthetic __mp3 id even with stale media metadata', () {
      expect(
        service.wantsMp3(_task(
          formatId: '140__mp3',
          fileExt: 'mp3',
          mediaType: DownloadMediaType.video,
        )),
        isTrue,
      );
      expect(
        service.wantsMp3(_task(
          formatId: '140__mp3',
          fileExt: null,
          mediaType: DownloadMediaType.video,
        )),
        isTrue,
      );
    });

    test('legacy audio tasks with no extension still ask for MP3', () {
      expect(service.wantsMp3(_task(fileExt: null)), isTrue);
    });

    test('a real M4A or a video task is not converted to MP3', () {
      expect(service.wantsMp3(_task(fileExt: 'm4a')), isFalse);
      expect(
        service.wantsMp3(_task(
          fileExt: 'mp4',
          mediaType: DownloadMediaType.video,
        )),
        isFalse,
      );
    });
  });

  group('synthetic MP3 source', () {
    test('carries the signed audio URL instead of forcing a new manifest', () {
      final url = Uri.parse(
        'https://rr1---sn.example.googlevideo.com/videoplayback'
        '?mime=audio%2Fmp4&itag=140&expire=999',
      );
      final option = LocalExtractionService.mp3FormatOption(
        tag: '140',
        sizeBytes: 123456,
        url: url,
      );

      expect(option, isNotNull);
      expect(option!.id, '140__mp3');
      expect(option.type, 'audio');
      expect(option.extension, 'mp3');
      expect(option.hasAudio, isTrue);
      expect(option.hasVideo, isFalse);
      expect(option.directUrl, url.toString());
      expect(option.sizeBytes, 123456);
    });

    test('returns null without a source tag', () {
      expect(
        LocalExtractionService.mp3FormatOption(tag: ''),
        isNull,
      );
    });
  });

  group('DownloadsController duplicate guard', () {
    test('same active job is rejected', () {
      final first = _task();
      final second = _task(id: 'dl_2');
      expect(DownloadsController.isSameActiveJob(second, first), isTrue);
    });

    test('a completed job can be downloaded again', () {
      final first = _task(status: DownloadStatus.completed);
      final second = _task(id: 'dl_2');
      expect(DownloadsController.isSameActiveJob(second, first), isFalse);
    });

    test('different format or media type is a different job', () {
      final first = _task();
      expect(
        DownloadsController.isSameActiveJob(
          _task(id: 'dl_2', formatId: '251'),
          first,
        ),
        isFalse,
      );
      expect(
        DownloadsController.isSameActiveJob(
          _task(id: 'dl_2', mediaType: DownloadMediaType.video),
          first,
        ),
        isFalse,
      );
    });

    test('the same task id is always rejected', () {
      final first = _task(status: DownloadStatus.completed);
      expect(DownloadsController.isSameActiveJob(_task(), first), isTrue);
    });
  });
}
