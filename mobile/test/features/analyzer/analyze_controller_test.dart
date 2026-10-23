import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:vibegrab/data/models/analyze_response.dart';
import 'package:vibegrab/data/models/media_info.dart';
import 'package:vibegrab/features/analyzer/controllers/analyze_controller.dart';
import 'package:vibegrab/services/analysis_failure.dart';
import 'package:vibegrab/services/api_service.dart';
import 'package:vibegrab/services/local_extraction_service.dart';

// The controller validates the URL locally and canonicalizes it before any
// request, so the fakes are keyed by the normalized URL, not by a nickname.
const _one = 'https://www.youtube.com/watch?v=aaaaaaaaaaa';
const _slow = 'https://www.youtube.com/watch?v=bbbbbbbbbbb';
const _fast = 'https://www.youtube.com/watch?v=ccccccccccc';
const _same = 'https://www.youtube.com/watch?v=ddddddddddd';
const _cached = 'https://www.youtube.com/watch?v=eeeeeeeeeee';
const _expiring = 'https://www.youtube.com/watch?v=fffffffffff';
const _refresh = 'https://www.youtube.com/watch?v=ggggggggggg';

/// Both halves of the device-vs-backend race answer from the same gate, so a
/// test can decide which request answers first and how slowly.
Future<AnalyzeResponse> _gate(String url) {
  final failure = _failures[url];
  if (failure != null) return Future<AnalyzeResponse>.error(failure);
  return _gates.putIfAbsent(url, Completer<AnalyzeResponse>.new).future;
}

final Map<String, Completer<AnalyzeResponse>> _gates = {};
final Map<String, Object> _failures = {};

/// Failures that only one half of the race sees, to prove which cause wins.
final Map<String, Object> _deviceFailures = {};
final Map<String, Object> _apiFailures = {};
var apiCalls = 0;
var extractionCalls = 0;

class _FakeApi extends ApiService {
  _FakeApi() : super();

  @override
  Future<AnalyzeResponse> analyze(String url) {
    apiCalls++;
    final failure = _apiFailures[url];
    if (failure != null) return Future<AnalyzeResponse>.error(failure);
    return _gate(url);
  }
}

class _FakeExtraction extends LocalExtractionService {
  @override
  Future<AnalyzeResponse> extractMedia(String url,
      {void Function(MediaInfo media)? onMetadata}) {
    extractionCalls++;
    final failure = _deviceFailures[url];
    if (failure != null) return Future<AnalyzeResponse>.error(failure);
    return _gate(url);
  }
}

AnalyzeResponse _response(String id) => AnalyzeResponse(
      success: true,
      media: MediaInfo(id: id, title: 'title $id', source: 'youtube'),
      // The controller only rejects an EMPTY format list coming from the real
      // backend client; these fakes model the resolved response.
      formats: const [],
    );

AnalyzeController _controller() => AnalyzeController(
      extraction: _FakeExtraction(),
      api: _FakeApi(),
    );

void main() {
  setUp(() {
    _gates.clear();
    _failures.clear();
    _deviceFailures.clear();
    _apiFailures.clear();
    apiCalls = 0;
    extractionCalls = 0;
  });

  test('a single analysis resolves and clears the loading flag', () async {
    final controller = _controller();
    final pending = controller.analyze(_one);
    expect(controller.isLoading, isTrue);

    _gates[_one]!.complete(_response('one'));
    await pending;

    expect(controller.result?.media.id, 'one');
    expect(controller.analyzedUrl, _one);
    expect(controller.isLoading, isFalse);
    expect(controller.error, isNull);
  });

  test('reports an empty url without touching the network', () async {
    final controller = _controller();
    await controller.analyze('   ', emptyUrlMessage: 'enterUrl');

    expect(controller.error, 'enterUrl');
    expect(controller.isLoading, isFalse);
    expect(_gates, isEmpty);
  });

  test('a malformed url is rejected locally without the network', () async {
    final controller = _controller();
    await controller.analyze('this is not a url');

    expect(controller.error, 'analysisInvalidUrl');
    expect(controller.isLoading, isFalse);
    expect(controller.result, isNull);
    expect(_gates, isEmpty);
    expect(apiCalls, 0);
    expect(extractionCalls, 0);
  });

  test('a typed backend cause wins over a device timeout', () async {
    final controller = _controller();
    _deviceFailures[_one] =
        const AnalysisException(AnalysisFailureType.timeout);
    _apiFailures[_one] = const AnalysisException(
      AnalysisFailureType.unavailable,
      statusCode: 422,
      code: 'source_unavailable',
    );

    await controller.analyze(_one);

    // "The source refused the request" is what the user needs; "the phone
    // timed out" would hide the real cause.
    expect(controller.error, 'analysisSourceBlocked');
    expect(controller.isLoading, isFalse);
    expect(controller.result, isNull);
  });

  test('equivalent YouTube links share one analysis', () async {
    final controller = _controller();
    final first = controller.analyze('https://youtu.be/aaaaaaaaaaa?si=track1');
    final second = controller.analyze(
        'https://m.youtube.com/watch?v=aaaaaaaaaaa&feature=share');
    final third = controller.analyze(
        'https://www.youtube.com/shorts/aaaaaaaaaaa');

    expect(extractionCalls, 1);
    expect(apiCalls, 1);

    _gates[_one]!.complete(_response('one'));
    await Future.wait([first, second, third]);

    expect(controller.result?.media.id, 'one');
    expect(controller.analyzedUrl, _one);
  });

  test('a slow older response never overwrites a newer one', () async {
    final controller = _controller();

    final first = controller.analyze(_slow);
    final second = controller.analyze(_fast);

    _gates[_fast]!.complete(_response('fast'));
    await second;
    expect(controller.result?.media.id, 'fast');
    expect(controller.isLoading, isFalse);

    // The older request answers afterwards: it must be dropped entirely,
    // including its effect on the loading flag.
    _gates[_slow]!.complete(_response('slow'));
    await first;
    expect(controller.result?.media.id, 'fast');
    expect(controller.isLoading, isFalse);
    expect(controller.error, isNull);
  });

  test('clear() abandons an in-flight analysis', () async {
    final controller = _controller();
    final pending = controller.analyze(_one);

    controller.clear();
    _gates[_one]!.complete(_response('one'));
    await pending;

    expect(controller.result, isNull);
    expect(controller.error, isNull);
    expect(controller.isLoading, isFalse);
  });

  test('two taps for the same URL share one device+backend race', () async {
    final controller = _controller();
    final first = controller.analyze(_same);
    final second = controller.analyze(_same);

    expect(extractionCalls, 1);
    expect(apiCalls, 1);

    _gates[_same]!.complete(_response('same'));
    await Future.wait([first, second]);

    expect(controller.result?.media.id, 'same');
    expect(extractionCalls, 1);
    expect(apiCalls, 1);
    expect(controller.isLoading, isFalse);
  });

  test('a completed analysis is reused without touching the network', () async {
    final controller = _controller();
    final first = controller.analyze(_cached);
    _gates[_cached]!.complete(_response('cached'));
    await first;
    expect(extractionCalls, 1);

    await controller.analyze(_cached);

    expect(controller.result?.media.id, 'cached');
    expect(controller.isLoading, isFalse);
    expect(extractionCalls, 1);
    expect(apiCalls, 1);
  });

  test('the cache expires after its TTL', () async {
    var now = DateTime(2026, 1, 1, 12);
    final controller = AnalyzeController(
      extraction: _FakeExtraction(),
      api: _FakeApi(),
      cacheTtl: const Duration(minutes: 5),
      clock: () => now,
    );

    final first = controller.analyze(_expiring);
    _gates[_expiring]!.complete(_response('expiring'));
    await first;
    expect(extractionCalls, 1);

    now = now.add(const Duration(minutes: 6));
    await controller.analyze(_expiring);

    expect(extractionCalls, 2);
  });

  test('a failed refresh keeps the previous result of the same URL', () async {
    var now = DateTime(2026, 1, 1, 12);
    final controller = AnalyzeController(
      extraction: _FakeExtraction(),
      api: _FakeApi(),
      cacheTtl: const Duration(minutes: 1),
      clock: () => now,
    );

    final first = controller.analyze(_refresh);
    _gates[_refresh]!.complete(_response('refresh'));
    await first;
    expect(controller.result?.media.id, 'refresh');

    now = now.add(const Duration(minutes: 2));
    _failures[_refresh] = const NetworkException('offline', type: 'connection');
    await controller.analyze(_refresh);

    expect(controller.result?.media.id, 'refresh');
    expect(controller.analyzedUrl, _refresh);
    expect(controller.error, 'serverUnreachable');
    expect(controller.isLoading, isFalse);
  });
}
