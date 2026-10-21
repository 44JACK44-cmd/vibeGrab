import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:vibegrab/data/models/analyze_response.dart';
import 'package:vibegrab/data/models/media_info.dart';
import 'package:vibegrab/features/analyzer/controllers/analyze_controller.dart';
import 'package:vibegrab/services/api_service.dart';
import 'package:vibegrab/services/local_extraction_service.dart';

/// Both halves of the device-vs-backend race answer from the same gate, so a
/// test can decide which request answers first and how slowly.
Future<AnalyzeResponse> _gate(String url) {
  final failure = _failures[url];
  if (failure != null) return Future<AnalyzeResponse>.error(failure);
  return _gates.putIfAbsent(url, Completer<AnalyzeResponse>.new).future;
}

final Map<String, Completer<AnalyzeResponse>> _gates = {};
final Map<String, Object> _failures = {};
var apiCalls = 0;
var extractionCalls = 0;

class _FakeApi extends ApiService {
  _FakeApi() : super();

  @override
  Future<AnalyzeResponse> analyze(String url) {
    apiCalls++;
    return _gate(url);
  }
}

class _FakeExtraction extends LocalExtractionService {
  @override
  Future<AnalyzeResponse> extractMedia(String url,
      {void Function(MediaInfo media)? onMetadata}) {
    extractionCalls++;
    return _gate(url);
  }
}

AnalyzeResponse _response(String id) => AnalyzeResponse(
      success: true,
      media: MediaInfo(id: id, title: 'title $id', source: 'youtube'),
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
    apiCalls = 0;
    extractionCalls = 0;
  });

  test('a single analysis resolves and clears the loading flag', () async {
    final controller = _controller();
    final pending = controller.analyze('one');
    expect(controller.isLoading, isTrue);

    _gates['one']!.complete(_response('one'));
    await pending;

    expect(controller.result?.media.id, 'one');
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

  test('a slow older response never overwrites a newer one', () async {
    final controller = _controller();

    final first = controller.analyze('slow');
    final second = controller.analyze('fast');

    _gates['fast']!.complete(_response('fast'));
    await second;
    expect(controller.result?.media.id, 'fast');
    expect(controller.isLoading, isFalse);

    // The older request answers afterwards: it must be dropped entirely,
    // including its effect on the loading flag.
    _gates['slow']!.complete(_response('slow'));
    await first;
    expect(controller.result?.media.id, 'fast');
    expect(controller.isLoading, isFalse);
    expect(controller.error, isNull);
  });

  test('clear() abandons an in-flight analysis', () async {
    final controller = _controller();
    final pending = controller.analyze('one');

    controller.clear();
    _gates['one']!.complete(_response('one'));
    await pending;

    expect(controller.result, isNull);
    expect(controller.error, isNull);
    expect(controller.isLoading, isFalse);
  });

  test('two taps for the same URL share one device+backend race', () async {
    final controller = _controller();
    final first = controller.analyze('same');
    final second = controller.analyze('same');

    expect(extractionCalls, 1);
    expect(apiCalls, 1);

    _gates['same']!.complete(_response('same'));
    await Future.wait([first, second]);

    expect(controller.result?.media.id, 'same');
    expect(extractionCalls, 1);
    expect(apiCalls, 1);
    expect(controller.isLoading, isFalse);
  });

  test('a completed analysis is reused without touching the network', () async {
    final controller = _controller();
    final first = controller.analyze('cached');
    _gates['cached']!.complete(_response('cached'));
    await first;
    expect(extractionCalls, 1);

    await controller.analyze('cached');

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

    final first = controller.analyze('expiring');
    _gates['expiring']!.complete(_response('expiring'));
    await first;
    expect(extractionCalls, 1);

    now = now.add(const Duration(minutes: 6));
    await controller.analyze('expiring');

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

    final first = controller.analyze('refresh');
    _gates['refresh']!.complete(_response('refresh'));
    await first;
    expect(controller.result?.media.id, 'refresh');

    now = now.add(const Duration(minutes: 2));
    _failures['refresh'] = const NetworkException('offline', type: 'connection');
    await controller.analyze('refresh');

    expect(controller.result?.media.id, 'refresh');
    expect(controller.error, 'serverUnreachable');
    expect(controller.isLoading, isFalse);
  });
}
