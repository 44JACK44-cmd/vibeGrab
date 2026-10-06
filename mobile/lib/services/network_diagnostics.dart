import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../core/constants/api_constants.dart';

/// One connectivity check result. Labels are localized by the UI.
class DiagResult {
  /// backend | stream | manifest | direct
  final String key;
  final bool ok;
  final int ms;
  final String detail;
  const DiagResult(this.key, this.ok, this.ms, this.detail);
}

/// End-to-end connectivity self-test: tells whether THIS phone can reach
/// each link of the playback chain (backend, stream URLs, device manifest,
/// direct googlevideo) and how long each takes. Run from Settings.
class NetworkDiagnostics {
  static const _testVideoId = 'dQw4w9WgXcQ';

  static Future<List<DiagResult>> run() async {
    final out = <DiagResult>[];
    String? videoUrl;

    // 1) Backend health.
    out.add(await _timed('backend', () async {
      final r = await http
          .get(Uri.parse(ApiConfig.healthUrl))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw Exception('http ${r.statusCode}');
      return 'ok';
    }));

    // 2) Server stream URLs.
    try {
      final sw = Stopwatch()..start();
      final r = await http
          .get(Uri.parse('${ApiConfig.exploreStreamUrl}?v=$_testVideoId'))
          .timeout(const Duration(seconds: 25));
      sw.stop();
      if (r.statusCode == 200) {
        final data = jsonDecode(r.body) as Map<String, dynamic>;
        if (data['success'] != false && data['video'] != null) {
          videoUrl = data['video'] as String?;
          out.add(DiagResult('stream', true, sw.elapsedMilliseconds,
              'video+audio urls ok'));
        } else {
          out.add(DiagResult('stream', false, sw.elapsedMilliseconds,
              '${data['detail'] ?? 'no urls'}'));
        }
      } else {
        out.add(DiagResult(
            'stream', false, sw.elapsedMilliseconds, 'http ${r.statusCode}'));
      }
    } catch (e) {
      out.add(DiagResult('stream', false, 25000, _short(e)));
    }

    // 3) On-device manifest (acts like the YouTube app's API call).
    YoutubeExplode? ytc;
    try {
      final sw = Stopwatch()..start();
      ytc = YoutubeExplode();
      final manifest = await ytc.videos.streamsClient
          .getManifest(_testVideoId)
          .timeout(const Duration(seconds: 25));
      sw.stop();
      out.add(DiagResult('manifest', true, sw.elapsedMilliseconds,
          '${manifest.muxed.length} muxed, ${manifest.audioOnly.length} audio'));
    } catch (e) {
      out.add(DiagResult('manifest', false, 25000, _short(e)));
    } finally {
      try {
        ytc?.close();
      } catch (_) {}
    }

    // 4) Direct googlevideo bytes (carrier blocking shows up here).
    if (videoUrl != null) {
      out.add(await _timed('direct', () async {
        final req = await http.Request('GET', Uri.parse(videoUrl!))
          ..headers['Range'] = 'bytes=0-1023'
          ..headers['User-Agent'] = 'Mozilla/5.0 (Linux; Android 14)';
        final res = await http.Response.fromStream(
            await req.send().timeout(const Duration(seconds: 20)));
        if (res.statusCode != 206 && res.statusCode != 200) {
          throw Exception('http ${res.statusCode}');
        }
        return 'http ${res.statusCode}';
      }));
    } else {
      out.add(const DiagResult('direct', false, 0, 'sin url'));
    }

    return out;
  }

  static Future<DiagResult> _timed(
      String key, Future<String> Function() fn) async {
    final sw = Stopwatch()..start();
    try {
      final detail = await fn();
      sw.stop();
      return DiagResult(key, true, sw.elapsedMilliseconds, detail);
    } catch (e) {
      sw.stop();
      return DiagResult(key, false, sw.elapsedMilliseconds, _short(e));
    }
  }

  static String _short(Object e) {
    final s = e.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length > 90 ? '${s.substring(0, 90)}…' : s;
  }
}
