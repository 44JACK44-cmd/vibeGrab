import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibegrab/data/models/explore_video.dart';
import 'package:vibegrab/features/explore/controllers/explore_controller.dart';
import 'package:vibegrab/services/local_extraction_service.dart';

/// Extraction stub whose Shorts searches stay blocked until the test says
/// so, so the network path cannot hide a broken disk restore.
class _GateExtraction extends LocalExtractionService {
  _GateExtraction(this.gate, this.result);

  final Completer<void> gate;
  final List<ExploreVideo> result;
  int calls = 0;

  @override
  Future<List<ExploreVideo>> searchShorts(String query, {int limit = 12}) {
    calls++;
    return gate.future.then((_) => result);
  }
}

ExploreVideo _video(String id) => ExploreVideo(
      id: id,
      title: 'Short $id',
      url: 'https://y.example/$id',
    );

String _cacheEntry(List<ExploreVideo> items, {DateTime? at}) =>
    jsonEncode({
      'at': (at ?? DateTime.now()).millisecondsSinceEpoch,
      'items': items.map((v) => v.toJson()).toList(),
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cacheKey = 'explore_shorts_cache_v1';

  test('loadShorts shows the cached list before the network answers',
      () async {
    SharedPreferences.setMockInitialValues({
      cacheKey: _cacheEntry([_video('cached000001')]),
    });

    final gate = Completer<void>();
    final extraction = _GateExtraction(gate, const []);
    final c = ExploreController(extraction: extraction);

    final done = c.loadShorts();
    // Let the cache read finish while every network leg is still blocked.
    await Future<void>.delayed(Duration.zero);

    expect(c.shortsLoading, isTrue, reason: 'the refresh is still running');
    expect(c.shorts, isNotEmpty,
        reason: 'the cached list must be visible straight away');
    expect(c.shorts.first.id, 'cached000001');

    gate.complete();
    await done;

    expect(c.shortsLoading, isFalse);
    expect(extraction.calls, greaterThan(0), reason: 'a refresh still ran');
    expect(c.shorts.first.id, 'cached000001',
        reason: 'an empty refresh must not wipe the restored list');
  });

  test('loadShorts falls back to the network when nothing is cached',
      () async {
    SharedPreferences.setMockInitialValues({});
    final gate = Completer<void>();
    final extraction = _GateExtraction(gate, [_video('fresh0000001')]);
    final c = ExploreController(extraction: extraction);

    final done = c.loadShorts();
    await Future<void>.delayed(Duration.zero);
    expect(c.shorts, isEmpty,
        reason: 'nothing cached and nothing fetched yet');

    gate.complete();
    await done;

    expect(c.shortsLoading, isFalse);
    expect(c.shorts, isNotEmpty);
    expect(c.shorts.first.id, 'fresh0000001');
  });

  test('an expired Shorts cache is not resurrected', () async {
    SharedPreferences.setMockInitialValues({
      cacheKey: _cacheEntry(
        [_video('stale000001')],
        at: DateTime.now().subtract(const Duration(days: 2)),
      ),
    });

    final gate = Completer<void>();
    final c = ExploreController(extraction: _GateExtraction(gate, const []));
    final done = c.loadShorts();
    await Future<void>.delayed(Duration.zero);

    expect(c.shorts, isEmpty, reason: 'an expired list must be ignored');

    gate.complete();
    await done;
  });

  test('a failing refresh keeps the restored list alive', () async {
    SharedPreferences.setMockInitialValues({
      cacheKey: _cacheEntry([_video('cached000001')]),
    });

    final gate = Completer<void>();
    final extraction = _FailingExtraction(gate);
    final c = ExploreController(extraction: extraction);

    final done = c.loadShorts();
    await Future<void>.delayed(Duration.zero);
    expect(c.shorts, isNotEmpty);

    gate.completeError(Exception('offline'));
    await done;

    expect(c.shortsLoading, isFalse);
    expect(c.shorts.first.id, 'cached000001',
        reason: 'searches that throw must not clear the feed');
  });
}

/// Every search fails once the test releases the gate.
class _FailingExtraction extends LocalExtractionService {
  _FailingExtraction(this.gate);

  final Completer<void> gate;

  @override
  Future<List<ExploreVideo>> searchShorts(String query, {int limit = 12}) =>
      gate.future.then((_) => throw Exception('offline'));
}
