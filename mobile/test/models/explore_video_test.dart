import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/data/models/explore_video.dart';

void main() {
  group('ExploreVideo.fromJson', () {
    test('parses full JSON', () {
      final json = {
        'id': 'abc123',
        'title': 'Test Video',
        'url': 'https://youtube.com/watch?v=abc123',
        'thumbnail': 'https://img.youtube.com/vi/abc123/maxresdefault.jpg',
        'channel': 'TestChannel',
        'duration': 180,
        'duration_string': '3:00',
        'view_count': 1500000,
      };

      final video = ExploreVideo.fromJson(json);
      expect(video.id, 'abc123');
      expect(video.title, 'Test Video');
      expect(video.url, 'https://youtube.com/watch?v=abc123');
      expect(video.thumbnail, 'https://img.youtube.com/vi/abc123/maxresdefault.jpg');
      expect(video.channel, 'TestChannel');
      expect(video.duration, 180);
      expect(video.durationString, '3:00');
      expect(video.viewCount, 1500000);
    });

    test('handles missing fields gracefully', () {
      final video = ExploreVideo.fromJson({});
      expect(video.id, '');
      expect(video.title, 'Untitled');
      expect(video.url, '');
      expect(video.thumbnail, isNull);
      expect(video.channel, isNull);
      expect(video.duration, isNull);
      expect(video.viewCount, isNull);
    });
  });

  group('viewCountFormatted', () {
    test('formats billions', () {
      final v = ExploreVideo(id: '1', title: 't', url: 'u', viewCount: 2500000000);
      expect(v.viewCountFormatted, '2.5B views');
    });

    test('formats millions', () {
      final v = ExploreVideo(id: '1', title: 't', url: 'u', viewCount: 3200000);
      expect(v.viewCountFormatted, '3.2M views');
    });

    test('formats thousands', () {
      final v = ExploreVideo(id: '1', title: 't', url: 'u', viewCount: 45600);
      expect(v.viewCountFormatted, '46K views');
    });

    test('formats small numbers', () {
      final v = ExploreVideo(id: '1', title: 't', url: 'u', viewCount: 42);
      expect(v.viewCountFormatted, '42 views');
    });

    test('returns empty for null', () {
      final v = ExploreVideo(id: '1', title: 't', url: 'u');
      expect(v.viewCountFormatted, '');
    });
  });

  group('durationFormatted', () {
    test('uses durationString when available', () {
      final v = ExploreVideo(id: '1', title: 't', url: 'u', durationString: '5:30');
      expect(v.durationFormatted, '5:30');
    });

    test('formats seconds to mm:ss', () {
      final v = ExploreVideo(id: '1', title: 't', url: 'u', duration: 125);
      expect(v.durationFormatted, '02:05');
    });

    test('formats hours to h:mm:ss', () {
      final v = ExploreVideo(id: '1', title: 't', url: 'u', duration: 3661);
      expect(v.durationFormatted, '1:01:01');
    });

    test('returns empty for null duration', () {
      final v = ExploreVideo(id: '1', title: 't', url: 'u');
      expect(v.durationFormatted, '');
    });

    test('returns empty for zero duration', () {
      final v = ExploreVideo(id: '1', title: 't', url: 'u', duration: 0);
      expect(v.durationFormatted, '');
    });
  });
}
