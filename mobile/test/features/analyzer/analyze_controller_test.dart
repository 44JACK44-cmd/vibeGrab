import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:vibegrab/data/models/analyze_response.dart';
import 'package:vibegrab/data/models/media_info.dart';
import 'package:vibegrab/features/analyzer/controllers/analyze_controller.dart';
import 'package:vibegrab/services/api_service.dart';
import 'package:vibegrab/services/local_extraction_service.dart';

/// Both halves of the device-vs-backend race answer from the same gate, so a
/// test can decide which request answers first and how slowly.
Future<AnalyzeResponse> _gate(String url) =>
    _gates.putIfAbsent(url, Completer<AnalyzeResponse>.new).future;

final Map<String, Completer<AnalyzeResponse>> _gates = {};

class _FakeApi extends ApiService {
  _FakeApi() : super();

  @override
  Future<AnalyzeResponse> analyze(String url) => _gate(url);
}

class _FakeExtraction extends LocalExtractionService {
  @override
  Future<AnalyzeResponse> extractMedia(String url,
          {void Function(MediaInfo media)? onMetadata}) =>
      _gate(url);
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
  setUp(_gates.clear);

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
}
