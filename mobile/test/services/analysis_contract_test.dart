import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vibegrab/services/analysis_failure.dart';
import 'package:vibegrab/services/api_service.dart';

const _url = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';

http.Response _json(Object body, {int status = 200}) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> _successBody({List<Object>? formats}) => {
      'success': true,
      'media': {
        'id': 'dQw4w9WgXcQ',
        'title': 'A video',
        'source': 'youtube',
      },
      'formats': formats ??
          [
            {
              'id': '18',
              'type': 'video',
              'extension': 'mp4',
              'quality': '360p',
              'has_video': true,
              'has_audio': true,
            }
          ],
    };

ApiService _service(
  Future<http.Response> Function(http.Request request) handler, {
  Duration? longTimeout,
}) =>
    ApiService(
      client: MockClient(handler),
      longTimeout: longTimeout,
    );

void main() {
  group('ApiService.analyze contract', () {
    test('a valid response is parsed with its formats', () async {
      final api = _service((_) async => _json(_successBody()));
      final response = await api.analyze(_url);

      expect(response.success, isTrue);
      expect(response.media.title, 'A video');
      expect(response.formats, hasLength(1));
      expect(response.formats.first.extension, 'mp4');
    });

    test('success:false + source_unavailable is a typed unavailable failure',
        () async {
      final api = _service((_) async => _json({
            'success': false,
            'error_code': 'source_unavailable',
            'stage': 'extract',
            'detail': 'private video',
            'request_id': 'abc',
          }));

      await expectLater(
        api.analyze(_url),
        throwsA(
          isA<AnalysisException>()
              .having((e) => e.type, 'type', AnalysisFailureType.unavailable)
              .having((e) => e.code, 'code', 'source_unavailable'),
        ),
      );
    });

    test('HTTP 400 with unsupported_url is not reported as a server error',
        () async {
      final api = _service((_) async => _json({
            'success': false,
            'error_code': 'unsupported_url',
          }, status: 400));

      await expectLater(
        api.analyze(_url),
        throwsA(isA<AnalysisException>().having(
          (e) => e.type,
          'type',
          AnalysisFailureType.unsupportedPlatform,
        )),
      );
    });

    test('HTTP 502 without an error_code is an HTTP failure', () async {
      final api = _service((_) async =>
          http.Response('<html>bad gateway</html>', 502));

      await expectLater(
        api.analyze(_url),
        throwsA(isA<AnalysisException>().having(
          (e) => e.type,
          'type',
          AnalysisFailureType.httpError,
        )),
      );
    });

    test('an HTML 200 page is a malformed response, never a format list',
        () async {
      final api = _service((_) async => http.Response(
            '<!doctype html><html>captive portal</html>',
            200,
            headers: {'content-type': 'text/html'},
          ));

      await expectLater(
        api.analyze(_url),
        throwsA(isA<AnalysisException>().having(
          (e) => e.type,
          'type',
          AnalysisFailureType.malformedResponse,
        )),
      );
    });

    test('a success response with no formats is a typed no_formats failure',
        () async {
      final api = _service((_) async => _json(_successBody(formats: [])));

      await expectLater(
        api.analyze(_url),
        throwsA(isA<AnalysisException>().having(
          (e) => e.type,
          'type',
          AnalysisFailureType.noFormats,
        )),
      );
    });

    test('a request that exceeds the budget times out', () async {
      final api = _service(
        (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 120));
          return _json(_successBody());
        },
        longTimeout: const Duration(milliseconds: 20),
      );

      await expectLater(
        api.analyze(_url),
        throwsA(isA<AnalysisException>().having(
          (e) => e.type,
          'type',
          AnalysisFailureType.timeout,
        )),
      );
    });

    test('a socket failure is a network failure, not a malformed response',
        () async {
      final api = _service((_) async {
        throw http.ClientException('Connection refused');
      });

      await expectLater(
        api.analyze(_url),
        throwsA(isA<AnalysisException>().having(
          (e) => e.type,
          'type',
          AnalysisFailureType.network,
        )),
      );
    });
  });

  group('AnalysisException.fromBackend', () {
    test('invalid_request maps to an invalid URL', () {
      final e = AnalysisException.fromBackend(400, {'error_code': 'invalid_request'});
      expect(e.type, AnalysisFailureType.invalidUrl);
      expect(e.messageKey, 'analysisInvalidUrl');
    });

    test('no_formats keeps its own message', () {
      final e = AnalysisException.fromBackend(422, {'error_code': 'no_formats'});
      expect(e.type, AnalysisFailureType.noFormats);
      expect(e.messageKey, 'analysisNoFormats');
    });

    test('unknown 4xx is treated as source unavailable', () {
      final e = AnalysisException.fromBackend(409, null);
      expect(e.type, AnalysisFailureType.unavailable);
    });

    test('source_unavailable says the source refused, not "private"', () {
      final e = AnalysisException.fromBackend(422, {
        'error_code': 'source_unavailable',
        'detail': 'Sign in to confirm you are not a bot',
      });
      expect(e.type, AnalysisFailureType.unavailable);
      expect(e.messageKey, 'analysisSourceBlocked');
    });

    test('5xx is an HTTP error', () {
      final e = AnalysisException.fromBackend(500, null);
      expect(e.type, AnalysisFailureType.httpError);
    });

    test('every type has a stable localization key', () {
      for (final type in AnalysisFailureType.values) {
        final key = AnalysisException(type).messageKey;
        expect(key, startsWith('analysis'));
      }
    });
  });
}
