import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/data/models/analyze_response.dart';
import 'package:vibegrab/data/models/format_option.dart';
import 'package:vibegrab/data/models/media_info.dart';
import 'package:vibegrab/features/share/controllers/shared_download_controller.dart';
import 'package:vibegrab/services/api_service.dart';
import 'package:vibegrab/services/local_extraction_service.dart';

/// Device extraction with both legs under the test's control: the metadata
/// (title/thumbnail) and the format list arrive at different times, like the
/// real two-round-trip extraction.
class _EarlyExtraction extends LocalExtractionService {
  final Completer<void> metadata = Completer<void>();
  final Completer<void> formats = Completer<void>();

  @override
  Future<AnalyzeResponse> extractMedia(String url,
      {void Function(MediaInfo media)? onMetadata}) async {
    await metadata.future;
    final media = MediaInfo(
      id: 'abc123abc12',
      title: 'Titulo temprano',
      thumbnail: 'https://i.ytimg.com/vi/abc123abc12/hq.jpg',
      source: 'youtube',
      platform: 'youtube',
    );
    onMetadata?.call(media);
    await formats.future;
    return AnalyzeResponse(success: true, media: media, formats: const []);
  }
}

/// Device extraction whose metadata is released per URL, so the test can make
/// an older analysis answer after a newer one started.
class _PerUrlExtraction extends LocalExtractionService {
  final Map<String, Completer<void>> gates = {};

  Completer<void> gateFor(String url) =>
      gates.putIfAbsent(url, () => Completer<void>());

  @override
  Future<AnalyzeResponse> extractMedia(String url,
      {void Function(MediaInfo media)? onMetadata}) async {
    await gateFor(url).future;
    final media = MediaInfo(id: url, title: 'Titulo $url', source: 'youtube');
    onMetadata?.call(media);
    return AnalyzeResponse(success: true, media: media, formats: const []);
  }
}

/// Device extraction that reports its metadata only when the test says so,
/// after the backend leg may have answered already.
class _LateExtraction extends LocalExtractionService {
  final Completer<void> metadata = Completer<void>();
  final Completer<void> done = Completer<void>();

  @override
  Future<AnalyzeResponse> extractMedia(String url,
      {void Function(MediaInfo media)? onMetadata}) async {
    await metadata.future;
    final media =
        MediaInfo(id: 'abc123abc12', title: 'Titulo temprano', source: 'youtube');
    onMetadata?.call(media);
    await done.future;
    return AnalyzeResponse(success: true, media: media, formats: const []);
  }
}

/// Backend leg that answers immediately.
class _FastApi extends ApiService {
  @override
  Future<AnalyzeResponse> analyze(String url) async => AnalyzeResponse(
        success: true,
        media:
            MediaInfo(id: 'abc123abc12', title: 'Del backend', source: 'youtube'),
        formats: const [],
      );
}

/// The backend leg never answers: these tests are about the device path.
class _SilentApi extends ApiService {
  @override
  Future<AnalyzeResponse> analyze(String url) =>
      Completer<AnalyzeResponse>().future;
}

/// Backend leg that counts its calls: used to prove the analysis cache.
class _CountingApi extends ApiService {
  int calls = 0;

  @override
  Future<AnalyzeResponse> analyze(String url) async {
    calls++;
    return _tiktokPhotoResponse();
  }
}

/// A TikTok photo post whose only asset is the image; some deployments also
/// expose the attached music as an audio format.
AnalyzeResponse _tiktokPhotoResponse() => AnalyzeResponse(
      success: true,
      media: MediaInfo(
        id: '7100000000000000000',
        title: 'Foto con música',
        thumbnail: 'https://i.ibb.co/xyz/photo.jpg',
        source: 'tiktok',
        platform: 'tiktok',
      ),
      formats: [
        FormatOption(
          id: 'aud1',
          type: 'audio',
          extension: 'mp3',
          hasAudio: true,
          hasVideo: false,
          quality: '128k',
        ),
      ],
    );

AnalyzeResponse _tiktokVideoResponse() => AnalyzeResponse(
      success: true,
      media: MediaInfo(
        id: '7100000000000000000',
        title: 'Video',
        thumbnail: 'https://i.ibb.co/xyz/video.jpg',
        source: 'tiktok',
        platform: 'tiktok',
      ),
      formats: [
        FormatOption(
          id: 'vid1',
          type: 'video',
          extension: 'mp4',
          hasVideo: true,
          hasAudio: true,
          quality: '480p',
        ),
      ],
    );

/// Backend leg for the "TikTok photo with music" case.
class _TikTokPhotoWithMusicApi extends ApiService {
  @override
  Future<AnalyzeResponse> analyze(String url) async => _tiktokPhotoResponse();
}

/// Backend leg for the "TikTok video" case.
class _TikTokVideoApi extends ApiService {
  @override
  Future<AnalyzeResponse> analyze(String url) async => _tiktokVideoResponse();
}

void main() {
  test('metadata is shown while the format list is still loading', () async {
    final extraction = _EarlyExtraction();
    final controller =
        SharedDownloadController(extraction: extraction, api: _SilentApi());

    final pending = controller
        .analyzeUrl('https://www.youtube.com/watch?v=abc123abc12');
    await Future<void>.delayed(Duration.zero);

    expect(controller.isAnalyzing, isTrue);
    expect(controller.media, isNull);

    extraction.metadata.complete();
    await Future<void>.delayed(Duration.zero);

    // Title and thumbnail are already there although the analysis is running.
    expect(controller.isAnalyzing, isTrue);
    expect(controller.hasResult, isFalse);
    expect(controller.media?.title, 'Titulo temprano');
    expect(controller.media?.thumbnail, isNotNull);

    extraction.formats.complete();
    await pending;

    expect(controller.status, SharedSheetStatus.ready);
    expect(controller.hasResult, isTrue);
    expect(controller.media?.title, 'Titulo temprano');
  });

  test('metadata from an abandoned analysis never paints the new one', () async {
    final extraction = _PerUrlExtraction();
    final controller =
        SharedDownloadController(extraction: extraction, api: _SilentApi());

    const first = 'https://www.youtube.com/watch?v=aaaaaaaaaaa';
    const second = 'https://www.youtube.com/watch?v=bbbbbbbbbbb';

    final firstRun = controller.analyzeUrl(first);
    final secondRun = controller.analyzeUrl(second);
    await Future<void>.delayed(Duration.zero);

    // The older analysis answers late: it must not overwrite the sheet the
    // user is looking at now.
    extraction.gateFor(first).complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.media, isNull);

    extraction.gateFor(second).complete();
    await secondRun;
    await firstRun;

    expect(controller.media?.title, 'Titulo $second');
    expect(controller.status, SharedSheetStatus.ready);
  });

  test('late device metadata cannot overwrite a finished response', () async {
    final extraction = _LateExtraction();
    final controller =
        SharedDownloadController(extraction: extraction, api: _FastApi());

    await controller
        .analyzeUrl('https://www.youtube.com/watch?v=abc123abc12');
    expect(controller.status, SharedSheetStatus.ready);
    expect(controller.media?.title, 'Del backend');

    // The device leg finally reports its own metadata after the backend has
    // already answered: the sheet keeps the authoritative response.
    extraction.metadata.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.media?.title, 'Del backend');

    extraction.done.complete();
  });

  test('analysisDurationMs is measured, not an invention', () async {
    final extraction = _EarlyExtraction();
    final controller =
        SharedDownloadController(extraction: extraction, api: _SilentApi());

    final run = controller.analyzeUrl('https://www.youtube.com/watch?v=abc123abc12');
    extraction.metadata.complete();
    extraction.formats.complete();
    await run;

    expect(controller.analysisDurationMs, isNotNull);
    expect(controller.analysisDurationMs, greaterThanOrEqualTo(0));
    expect(controller.hasResult, isTrue);
  });

  test('a TikTok photo with music offers image and audio options', () async {
    final controller = SharedDownloadController(api: _TikTokPhotoWithMusicApi());

    await controller.analyzeUrl('https://www.tiktok.com/@user/photo/7100000000000000000');

    expect(controller.status, SharedSheetStatus.ready);
    final media = controller.media;
    expect(media?.source, 'tiktok');
    // The image can be downloaded as itself.
    expect(media?.hasDownloadableImage, isTrue);
    expect(media?.imageExtension, isNotEmpty);
    // And there is a real music format to download as audio.
    expect(controller.audioFormats, isNotEmpty);
    expect(controller.selectedFormat?.type, 'audio');
    expect(controller.allFormats.where((f) => f.type == 'audio'), isNotEmpty);
  });

  test('a video post keeps both the video and audio options', () async {
    final controller = SharedDownloadController(api: _TikTokVideoApi());

    await controller.analyzeUrl('https://www.tiktok.com/@user/video/7100000000000000000');

    expect(controller.status, SharedSheetStatus.ready);
    expect(controller.videoFormats, isNotEmpty);
    // The video format carries its audio: the user can still ask for a
    // video with audio, and the audio-only option exists in the list.
    expect(controller.allFormats.any((f) => f.hasVideo && f.hasAudio), isTrue);
  });

  test('a cached analysis does not repeat the network call', () async {
    final api = _CountingApi();
    final controller = SharedDownloadController(api: api);

    await controller.analyzeUrl('https://www.tiktok.com/@user/photo/7100000000000000000');
    await controller.analyzeUrl('https://www.tiktok.com/@user/photo/7100000000000000000');

    expect(api.calls, 1);
    expect(controller.status, SharedSheetStatus.ready);
  });
}
