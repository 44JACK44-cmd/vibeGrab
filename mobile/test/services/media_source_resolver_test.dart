import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/services/media_source.dart';
import 'package:vibegrab/services/media_source_resolver.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

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

    test('a prefetch and the resolve that follows share one request', () async {
      // The engine starts the resolve while the previous player is still being
      // torn down. That prefetch and the play that consumes it must not ask
      // the server twice for the same video.
      var calls = 0;
      final gate = Completer<void>();
      final r = MediaSourceResolver(
        fetchUrls: (videoId) async {
          calls++;
          await gate.future;
          return const StreamUrlsPayload(
            video: 'https://x.googlevideo.com/v?expire=9999999999',
          );
        },
        fetchManifest: (_) async => null,
      );

      final prefetch = r.resolve('abc123abc12', onStage: (_) {});
      final resolve = r.resolve('abc123abc12', onStage: (_) {});
      gate.complete();
      final results = await Future.wait([prefetch, resolve]);

      expect(calls, 1);
      expect(results.every((res) => res.fetchError == null), isTrue);
    });

    test('server payload is cached between resolves', () async {      var calls = 0;
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

    test('resolve does not wait for the device manifest', () async {
      // A slow manifest used to sit on the critical path of every first
      // frame (up to 25s). It is now returned for background use only.
      final gate = Completer<StreamManifest?>();
      var manifestCalls = 0;
      final r = MediaSourceResolver(
        fetchUrls: (_) async => const StreamUrlsPayload(
          video: 'https://x.googlevideo.com/v?expire=9999999999',
        ),
        fetchManifest: (_) {
          manifestCalls++;
          return gate.future;
        },
      );
      final res = await r
          .resolve('abc123abc12', onStage: (_) {})
          .timeout(const Duration(seconds: 1));
      expect(res.manifest, isNull);
      expect(res.manifestAsync, isNotNull);
      // Only one manifest request even for concurrent resolves.
      await r.resolve('abc123abc12', onStage: (_) {});
      expect(manifestCalls, 1);
      gate.complete(null);
      expect(await res.manifestAsync, isNull);
    });

    test('a cached manifest is used without waiting on a new fetch', () async {
      var calls = 0;
      final r = MediaSourceResolver(
        fetchUrls: (_) async => const StreamUrlsPayload(
          video: 'https://x.googlevideo.com/v?expire=9999999999',
        ),
        fetchManifest: (_) async {
          calls++;
          return StreamManifest(const <StreamInfo>[]);
        },
      );
      await r.resolve('abc123abc12', onStage: (_) {}).then((_) {});
      // Let the background manifest land, then resolve again: the second
      // resolve must expose it synchronously (manifest, not manifestAsync).
      await Future<void>.delayed(Duration.zero);
      final res = await r.resolve('abc123abc12', onStage: (_) {});
      expect(calls, 1);
      expect(res.manifest, isNotNull);
      expect(res.manifestAsync, isNotNull);
    });
  });
}
