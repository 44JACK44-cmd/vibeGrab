import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibegrab/data/models/analyze_response.dart';
import 'package:vibegrab/data/models/explore_video.dart';
import 'package:vibegrab/data/models/media_info.dart';
import 'package:vibegrab/features/explore/controllers/explore_controller.dart';
import 'package:vibegrab/features/share/controllers/shared_download_controller.dart';
import 'package:vibegrab/services/api_service.dart';
import 'package:vibegrab/services/local_extraction_service.dart';
import 'package:vibegrab/services/media_source_resolver.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Latency injected into every slow leg. Scaled down from the real caps (a
/// device manifest leg is capped at 25s, the analysis race at 25s) so the
/// suite stays fast, but the RELATIONSHIP measured is the one the user sees:
/// the slow leg used to sit in front of the UI, now it runs behind it.
const Duration kSlowLeg = Duration(milliseconds: 600);

Future<AnalyzeResponse> _response(String id) async => AnalyzeResponse(
      success: true,
      media: MediaInfo(id: id, title: 'title $id', source: 'youtube'),
      formats: const [],
    );

/// Backend that answers every URL after [latency] and counts the requests.
class _CountingApi extends ApiService {
  _CountingApi(this.latency);

  final Duration latency;
  int totalCalls = 0;

  @override
  Future<AnalyzeResponse> analyze(String url) {
    totalCalls++;
    return Future<AnalyzeResponse>.delayed(latency, () => _response(url));
  }
}

/// Device side of the race that never answers: the measurement is only about
/// the backend leg, and this keeps the two from masking each other.
class _SilentExtraction extends LocalExtractionService {
  @override
  Future<AnalyzeResponse> extractMedia(String url,
          {void Function(MediaInfo media)? onMetadata}) =>
      Completer<AnalyzeResponse>().future;
}

class _SlowShortsExtraction extends LocalExtractionService {
  _SlowShortsExtraction(this.result, this.latency);

  final List<ExploreVideo> result;
  final Duration latency;

  @override
  Future<List<ExploreVideo>> searchShorts(String query, {int limit = 12}) =>
      Future<List<ExploreVideo>>.delayed(latency, () => result);
}

ExploreVideo _video(String id) => ExploreVideo(
      id: id,
      title: 'Short $id',
      url: 'https://y.example/$id',
    );

String _cacheEntry(List<ExploreVideo> items) => jsonEncode({
      'at': DateTime.now().millisecondsSinceEpoch,
      'items': items.map((v) => v.toJson()).toList(),
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('EXPLORE: the first frame no longer waits for the device manifest',
      () async {
    var manifestCalls = 0;
    final r = MediaSourceResolver(
      fetchUrls: (_) async => const StreamUrlsPayload(
        video: 'https://x.googlevideo.com/v?expire=9999999999',
      ),
      fetchManifest: (_) {
        manifestCalls++;
        return Future<StreamManifest?>.delayed(kSlowLeg, () => null);
      },
    );

    final sw = Stopwatch()..start();
    final res = await r.resolve('abc123abc12', onStage: (_) {});
    final resolveMs = sw.elapsedMilliseconds;

    // A second resolve while the manifest is still in flight must not
    // duplicate the request.
    await r.resolve('abc123abc12', onStage: (_) {});
    expect(manifestCalls, 1);

    await res.manifestAsync;
    final manifestMs = sw.elapsedMilliseconds;

    // ignore: avoid_print
    print('[tiempo] EXPLORE primer frame = ${resolveMs}ms '
        '(antes: primer frame + ${manifestMs}ms de manifiesto bloqueando)');

    expect(resolveMs, lessThan(kSlowLeg.inMilliseconds ~/ 2),
        reason: 'resolve must not sit behind the manifest leg');
    expect(manifestMs, greaterThanOrEqualTo(kSlowLeg.inMilliseconds));
  });

  test('SHORTS: the cached feed is on screen before the network answers',
      () async {
    SharedPreferences.setMockInitialValues({
      'explore_shorts_cache_v1': _cacheEntry([_video('cached000001')]),
    });

    final c = ExploreController(
        extraction: _SlowShortsExtraction(const [], kSlowLeg));

    final sw = Stopwatch()..start();
    final done = c.loadShorts();
    // The cache read needs no waiting: one microtask turn is enough.
    await Future<void>.delayed(Duration.zero);
    final cachedMs = sw.elapsedMilliseconds;

    expect(c.shorts, isNotEmpty,
        reason: 'the cached feed must be on screen before any network leg');
    expect(c.shorts.first.id, 'cached000001');

    await done;
    final refreshMs = sw.elapsedMilliseconds;

    // ignore: avoid_print
    print('[tiempo] SHORTS feed visible = ${cachedMs}ms '
        '(refresco de red completo: ${refreshMs}ms, en segundo plano)');

    expect(cachedMs, lessThan(kSlowLeg.inMilliseconds ~/ 2));
    expect(refreshMs, greaterThanOrEqualTo(kSlowLeg.inMilliseconds));
  });

  test('DESCARGAS: one URL costs one analysis, repeats included', () async {
    final api = _CountingApi(kSlowLeg);
    final c = SharedDownloadController(
      extraction: _SilentExtraction(),
      api: api,
    );
    const urlA = 'https://www.youtube.com/watch?v=aaaaaaaaaaa';
    const urlB = 'https://www.youtube.com/watch?v=bbbbbbbbbbb';

    final sw = Stopwatch()..start();
    await c.analyzeUrl(urlA);
    final coldMs = sw.elapsedMilliseconds;

    final sw2 = Stopwatch()..start();
    await c.analyzeUrl(urlA);
    final repeatMs = sw2.elapsedMilliseconds;

    // Two concurrent analyses of a NEW url: one request, shared result.
    final sw3 = Stopwatch()..start();
    await Future.wait([c.analyzeUrl(urlB), c.analyzeUrl(urlB)]);
    final doubleTapMs = sw3.elapsedMilliseconds;

    // ignore: avoid_print
    print('[tiempo] DESCARGAS análisis = ${coldMs}ms | repetido = '
        '${repeatMs}ms | doble toque = ${doubleTapMs}ms '
        '(llamadas de red: ${api.totalCalls})');

    expect(coldMs, greaterThanOrEqualTo(kSlowLeg.inMilliseconds));
    expect(repeatMs, lessThan(kSlowLeg.inMilliseconds ~/ 2),
        reason: 'the cache must answer without a new network leg');
    expect(api.totalCalls, 2,
        reason: 'two distinct URLs, one request each: repeats and double '
            'taps reuse the one in flight');
  });
}
