import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/data/models/explore_video.dart';
import 'package:vibegrab/features/explore/views/shorts_view.dart';

ExploreVideo _video(String n) => ExploreVideo(
      id: 'id$n',
      title: 'Short $n',
      url: 'https://y.example/$n',
    );

/// The feed at [start..] and the ids the engine reports for its queue.
List<ExploreVideo> _feed(int count, {int start = 1}) =>
    [for (var i = start; i < start + count; i++) _video('$i')];

List<String> _ids(int count, {int start = 1}) =>
    [for (var i = start; i < start + count; i++) 'https://y.example/$i'];

int? _page({
  required int engineIndex,
  required List<ExploreVideo> feed,
  required int shown,
  List<String>? queue,
  int queueStart = 1,
}) =>
    shortsPageForEngineIndex(
      engineIndex: engineIndex,
      shorts: feed,
      shownIndex: shown,
      engineQueueIds: queue ?? _ids(feed.length, start: queueStart),
    );

void main() {
  group('shortsPageForEngineIndex', () {
    test('does not move when the feed is already where the player is', () {
      expect(
        _page(engineIndex: 3, feed: _feed(6), shown: 3),
        isNull,
      );
    });

    test('follows the auto-advance at the end of a short', () {
      expect(_page(engineIndex: 4, feed: _feed(6), shown: 3), 4);
    });

    test('follows a previous (notification or lockscreen controls)', () {
      expect(_page(engineIndex: 1, feed: _feed(6), shown: 2), 1);
    });

    test('follows the wrap of repeat-all back to the first short', () {
      expect(_page(engineIndex: 0, feed: _feed(6), shown: 5), 0);
    });

    test('stays put when the player has no queue', () {
      expect(_page(engineIndex: -1, feed: _feed(6), shown: 0), isNull);
      expect(_page(engineIndex: 0, feed: _feed(6), shown: 1, queue: []),
          isNull);
    });

    test('stays put when the index is beyond the feed', () {
      expect(_page(engineIndex: 6, feed: _feed(6), shown: 5), isNull);
    });

    test(
        'stays put when the player is driving another screen\u2019s queue',
        () {
      // Same positions, different videos: another screen replaced the queue
      // while this feed was in the background. Moving the feed here would
      // show a short that is not what is playing.
      expect(
        _page(
          engineIndex: 4,
          feed: _feed(6),
          shown: 3,
          queue: _ids(6, start: 100),
        ),
        isNull,
      );
    });

    test('follows the feed again once the player comes back to it', () {
      expect(
        _page(
          engineIndex: 4,
          feed: _feed(6),
          shown: 3,
          queue: _ids(4, start: 100),
        ),
        isNull,
        reason: 'only the first positions belong to the other queue',
      );
      expect(
        _page(engineIndex: 4, feed: _feed(6), shown: 3),
        4,
        reason: 'the feed is the queue again',
      );
    });
  });
}
