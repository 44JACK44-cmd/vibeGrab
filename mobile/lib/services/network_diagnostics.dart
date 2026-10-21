import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../core/constants/api_constants.dart';

/// One connectivity check result.
///
/// Fields are typed so a support report never depends on parsing a prose
/// message: operation, stage, HTTP status, exception class, duration and the
/// server request id are separate. [detail] is user-facing and is sanitized
/// (never contains tokens, cookies or signed URL query strings).
class DiagResult {
  /// backend | stream | manifest | direct
  final String key;
  final bool ok;
  final int ms;
  final String detail;

  /// Logical operation (health, explore_stream, manifest, range_read).
  final String operation;

  /// Pipeline stage (request, transfer, parse).
  final String stage;
  final String platform;
  final int? httpStatus;
  final String? exceptionType;
  final String? requestId;

  const DiagResult(
    this.key,
    this.ok,
    this.ms,
    this.detail, {
    this.operation = '',
    this.stage = '',
    this.platform = '',
    this.httpStatus,
    this.exceptionType,
    this.requestId,
  });

  Map<String, Object?> toJson() => {
        'check': key,
        'ok': ok,
        'duration_ms': ms,
        'operation': operation,
        'stage': stage,
        'platform': platform,
        'http_status': httpStatus,
        'exception': exceptionType,
        'request_id': requestId,
        'detail': detail,
      };

  @override
  String toString() => jsonEncode(toJson());
}

/// End-to-end connectivity self-test: tells whether THIS phone can reach
/// each link of the playback chain (backend, stream URLs, device manifest,
/// direct googlevideo) and how long each takes. Run from Settings.
class NetworkDiagnostics {
  static const _testVideoId = 'dQw4w9WgXcQ';
  static final _platform =
      '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';

  static Future<List<DiagResult>> run() async {
    final out = <DiagResult>[];
    String? videoUrl;

    // 1) Backend health.
    final healthSw = Stopwatch()..start();
    try {
      final r = await http
          .get(
            Uri.parse(ApiConfig.healthUrl),
            headers: ApiConfig.authHeaders,
          )
          .timeout(const Duration(seconds: 15));
      healthSw.stop();
      final ok = r.statusCode == 200;
      out.add(DiagResult(
        'backend',
        ok,
        healthSw.elapsedMilliseconds,
        ok ? 'ok' : 'http ${r.statusCode}',
        operation: 'health',
        stage: 'request',
        platform: _platform,
        httpStatus: r.statusCode,
        requestId: _requestId(r.headers),
      ));
    } catch (e) {
      healthSw.stop();
      out.add(DiagResult(
        'backend',
        false,
        healthSw.elapsedMilliseconds,
        sanitize(e),
        operation: 'health',
        stage: 'request',
        platform: _platform,
        exceptionType: e.runtimeType.toString(),
      ));
    }

    // 2) Server stream URLs.
    final streamSw = Stopwatch()..start();
    try {
      final r = await http
          .get(
            Uri.parse('${ApiConfig.exploreStreamUrl}?v=$_testVideoId'),
            headers: ApiConfig.authHeaders,
          )
          .timeout(const Duration(seconds: 25));
      streamSw.stop();
      final requestId = _requestId(r.headers);
      if (r.statusCode == 200) {
        final data = jsonDecode(r.body) as Map<String, dynamic>;
        if (data['success'] != false && data['video'] != null) {
          videoUrl = data['video'] as String?;
          out.add(DiagResult(
            'stream',
            true,
            streamSw.elapsedMilliseconds,
            'video+audio urls ok',
            operation: 'explore_stream',
            stage: 'parse',
            platform: _platform,
            httpStatus: r.statusCode,
            requestId: requestId,
          ));
        } else {
          out.add(DiagResult(
            'stream',
            false,
            streamSw.elapsedMilliseconds,
            '${data['detail'] ?? 'no urls'}',
            operation: 'explore_stream',
            stage: 'parse',
            platform: _platform,
            httpStatus: r.statusCode,
            requestId: requestId,
          ));
        }
      } else {
        out.add(DiagResult(
          'stream',
          false,
          streamSw.elapsedMilliseconds,
          'http ${r.statusCode}',
          operation: 'explore_stream',
          stage: 'request',
          platform: _platform,
          httpStatus: r.statusCode,
          requestId: requestId,
        ));
      }
    } catch (e) {
      streamSw.stop();
      out.add(DiagResult(
        'stream',
        false,
        streamSw.elapsedMilliseconds,
        sanitize(e),
        operation: 'explore_stream',
        stage: 'request',
        platform: _platform,
        exceptionType: e.runtimeType.toString(),
      ));
    }

    // 3) On-device manifest (acts like the YouTube app's API call).
    YoutubeExplode? ytc;
    final manifestSw = Stopwatch()..start();
    try {
      ytc = YoutubeExplode();
      final manifest = await ytc.videos.streamsClient
          .getManifest(_testVideoId)
          .timeout(const Duration(seconds: 25));
      manifestSw.stop();
      out.add(DiagResult(
        'manifest',
        true,
        manifestSw.elapsedMilliseconds,
        '${manifest.muxed.length} muxed, ${manifest.audioOnly.length} audio',
        operation: 'device_manifest',
        stage: 'parse',
        platform: _platform,
      ));
    } catch (e) {
      manifestSw.stop();
      out.add(DiagResult(
        'manifest',
        false,
        manifestSw.elapsedMilliseconds,
        sanitize(e),
        operation: 'device_manifest',
        stage: 'request',
        platform: _platform,
        exceptionType: e.runtimeType.toString(),
      ));
    } finally {
      try {
        ytc?.close();
      } catch (_) {}
    }

    // 4) Direct googlevideo bytes (carrier blocking shows up here).
    if (videoUrl != null) {
      final directSw = Stopwatch()..start();
      try {
        final req = http.Request('GET', Uri.parse(videoUrl))
          ..headers['Range'] = 'bytes=0-1023'
          ..headers['User-Agent'] = 'Mozilla/5.0 (Linux; Android 14)';
        final res = await http.Response.fromStream(
            await req.send().timeout(const Duration(seconds: 20)));
        directSw.stop();
        final ok = res.statusCode == 206 || res.statusCode == 200;
        out.add(DiagResult(
          'direct',
          ok,
          directSw.elapsedMilliseconds,
          ok ? 'http ${res.statusCode}' : 'http ${res.statusCode}',
          operation: 'range_read',
          stage: 'transfer',
          platform: _platform,
          httpStatus: res.statusCode,
          requestId: _requestId(res.headers),
        ));
      } catch (e) {
        directSw.stop();
        out.add(DiagResult(
          'direct',
          false,
          directSw.elapsedMilliseconds,
          sanitize(e),
          operation: 'range_read',
          stage: 'transfer',
          platform: _platform,
          exceptionType: e.runtimeType.toString(),
        ));
      }
    } else {
      out.add(const DiagResult(
        'direct',
        false,
        0,
        'no url from the server',
        operation: 'range_read',
        stage: 'skipped',
        platform: '',
      ));
    }

    return out;
  }

  static String? _requestId(Map<String, String> headers) {
    for (final key in const [
      'x-request-id',
      'x-correlation-id',
      'x-render-request-id',
      'cf-ray',
    ]) {
      final value = headers[key];
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  /// Exception text with every URL reduced to scheme/host/path. Signed query
  /// strings (`sig`, `token`, `key`) and long headers are never logged or
  /// shown in a support dialog.
  static String sanitize(Object e) {
    var s = e.toString();
    s = s.replaceAllMapped(RegExp(r'https?://[^\s]+'), (match) {
      final parsed = Uri.tryParse(match.group(0)!);
      if (parsed == null) return '<url>';
      return '${parsed.scheme}://${parsed.host}${parsed.path}';
    });
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }
}
