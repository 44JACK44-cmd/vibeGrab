import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/data/models/analyze_response.dart';
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

/// The backend leg never answers: these tests are about the device path.
class _SilentApi extends ApiService {
  @override
  Future<AnalyzeResponse> analyze(String url) =>
      Completer<AnalyzeResponse>().future;
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
}
