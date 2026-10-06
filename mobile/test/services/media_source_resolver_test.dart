import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/services/media_source.dart';
import 'package:vibegrab/services/media_source_resolver.dart';

void main() {
  group('MediaSourceResolver', () {
    test('expiryOf parses the googlevideo expire parameter', () {
      final exp = MediaSourceResolver.expiryOf(
          'https://x.googlevideo.com/v?expire=1791340812&id=abc');
      expect(exp, isNotNull);
      expect(
          exp!.millisecondsSinceEpoch, equals(1791340812 * 1000));
    });

    test('expiryOf returns null without expire', () {
      expect(
          MediaSourceResolver.expiryOf('https://x.example.com/v?id=1'),
          isNull);
      expect(MediaSourceResolver.expiryOf('not a url'), isNull);
    });

    test('isExpired honors the safety margin', () {
      final now = DateTime.now();
      final past = now
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch ~/
          1000;
      final soon = now.add(const Duration(minutes: 3)).millisecondsSinceEpoch ~/
          1000;
      final later = now.add(const Duration(hours: 2)).millisecondsSinceEpoch ~/
          1000;
      expect(MediaSourceResolver.isExpired('https://x/?expire=$past'),
          isTrue);
      // 3 min left < 5 min margin => treated as expired.
      expect(MediaSourceResolver.isExpired('https://x/?expire=$soon'),
          isTrue);
      expect(MediaSourceResolver.isExpired('https://x/?expire=$later'),
          isFalse);
      expect(MediaSourceResolver.isExpired('https://x/'), isFalse);
    });

    test('qualityLabel formats heights', () {
      expect(MediaSourceResolver.qualityLabel(720), '720p');
      expect(MediaSourceResolver.qualityLabel(1080), '1080p');
    });

    MediaSourceResolver resolverWith({
      StreamUrlsPayload? payload,
      int? failTimes,
    }) {
      var calls = 0;
      return MediaSourceResolver(
        fetchUrls: (videoId) async {
          calls++;
          if (failTimes != null && calls <= failTimes) {
            throw Exception('boom');
          }
          return payload;
        },
        fetchManifest: (_) async => null,
      );
    }

    test('ranking is direct, proxy, relay, then device', () async {
      final r = resolverWith(
        payload: const StreamUrlsPayload(
          video: 'https://x.googlevideo.com/v?expire=9999999999',
          audio: 'https://x.googlevideo.com/a?expire=9999999999',
        ),
      );
      final stages = <String>[];
      final res = await r.resolve('abc123abc12',
          onStage: stages.add);
      expect(stages,
          containsAll(['playStageServer', 'playStageDirect']));
      expect(res.fetchError, isNull);
      expect(res.video.map((c) => c.kind), [
        MediaSourceKind.directVideo,
        MediaSourceKind.proxyVideo,
        MediaSourceKind.relayMerge,
      ]);
      expect(res.audioUri.toString(), contains('/api/explore/proxy?u='));
      expect(res.qualities, isEmpty);
      expect(res.manifest, isNull);
    });

    test('expired URLs are skipped but relay remains', () async {
      final r = resolverWith(
        payload: const StreamUrlsPayload(
          video: 'https://x.googlevideo.com/v?expire=1000',
          audio: 'https://x.googlevideo.com/a?expire=1000',
        ),
      );
      final res = await r.resolve('abc123abc12', onStage: (_) {});
      expect(res.video.map((c) => c.kind),
          [MediaSourceKind.relayMerge]);
      expect(res.audioUri, isNull);
    });

    test('failed fetch still offers the relay', () async {
      final r = resolverWith(payload: null);
      final res =
          await r.resolve('abc123abc12', onStage: (_) {});
      expect(res.fetchError, isNotNull);
      expect(res.video.map((c) => c.kind),
          [MediaSourceKind.relayMerge]);
      expect(res.audioUri, isNull);
    });

    test('server payload is cached between resolves', () async {
      var calls = 0;
      final r = MediaSourceResolver(
        fetchUrls: (videoId) async {
          calls++;
          return const StreamUrlsPayload(
            video: 'https://x.googlevideo.com/v?expire=9999999999',
          );
        },
        fetchManifest: (_) async => null,
      );
      await r.resolve('abc123abc12', onStage: (_) {});
      await r.resolve('abc123abc12', onStage: (_) {});
      expect(calls, 1);
      r.drop('abc123abc12');
      await r.resolve('abc123abc12', onStage: (_) {});
      expect(calls, 2);
    });

    test('muxedUrlFor and qualitiesFor empty without manifest', () {
      final r = resolverWith();
      expect(r.muxedUrlFor('abc123abc12', 720), isNull);
      expect(r.qualitiesFor('abc123abc12'), isEmpty);
    });
  });
}
