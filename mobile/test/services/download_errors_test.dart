import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/data/models/download_task.dart';
import 'package:vibegrab/services/download_errors.dart';

void main() {
  group('parseBackendError', () {
    test('reads the structured contract', () {
      final info = parseBackendError(
        502,
        jsonEncode({
          'success': false,
          'error_code': 'source_unavailable',
          'stage': 'extract',
          'detail': 'Extractor failed',
          'request_id': 'abc123',
        }),
      );

      expect(info.status, 502);
      expect(info.code, 'source_unavailable');
      expect(info.stage, 'extract');
      expect(info.detail, 'Extractor failed');
      expect(info.requestId, 'abc123');
    });

    test('keeps the old detail-only body working', () {
      final info = parseBackendError(502, '{"success":false,"detail":"boom"}');
      expect(info.detail, 'boom');
      expect(info.code, isNull);
    });

    test('survives a non-JSON proxy page', () {
      final info = parseBackendError(502, '<html>Bad gateway</html>');
      expect(info.status, 502);
      expect(info.isEmpty, isTrue);
    });
  });

  group('errorTypeOf', () {
    test('maps every stage to a specific type', () {
      expect(
        errorTypeOf(const BackendErrorInfo(
            status: 502, code: 'source_unavailable')),
        DownloadErrorType.sourceUnavailable,
      );
      expect(
        errorTypeOf(
            const BackendErrorInfo(status: 422, code: 'conversion_failed')),
        DownloadErrorType.conversionFailed,
      );
      expect(
        errorTypeOf(const BackendErrorInfo(status: 422, code: 'merge_failed')),
        DownloadErrorType.mergeFailed,
      );
      expect(
        errorTypeOf(const BackendErrorInfo(status: 413, code: 'file_too_large')),
        DownloadErrorType.fileTooLarge,
      );
      expect(
        errorTypeOf(
            const BackendErrorInfo(status: 400, code: 'invalid_request')),
        DownloadErrorType.invalidRequest,
      );
    });

    test('falls back to the HTTP status when the code is unknown', () {
      expect(
        errorTypeOf(const BackendErrorInfo(status: 503)),
        DownloadErrorType.httpError,
      );
      expect(
        errorTypeOf(const BackendErrorInfo(status: 403)),
        DownloadErrorType.http403,
      );
      expect(
        errorTypeOf(const BackendErrorInfo(status: 504)),
        DownloadErrorType.serverTimeout,
      );
      expect(
        errorTypeOf(const BackendErrorInfo(status: 409)),
        DownloadErrorType.unexpectedResponse,
      );
    });
  });

  group('describeBackendError', () {
    test('never leaks a signed URL', () {
      final detail = describeBackendError(
        const BackendErrorInfo(
          status: 502,
          code: 'source_unavailable',
          stage: 'extract',
          requestId: 'r1',
          detail:
              'failed https://rr3---sn-x.googlevideo.com/videoplayback?expire=1&sig=SECRET',
        ),
        operation: 'fetch',
      );

      expect(detail, contains('code=source_unavailable'));
      expect(detail, contains('request_id=r1'));
      expect(detail, contains('op=fetch'));
      expect(detail, contains('googlevideo.com'));
      expect(detail, isNot(contains('SECRET')));
      expect(detail, isNot(contains('expire=')));
    });

    test('collapses newlines so one failure stays one log line', () {
      final detail = describeBackendError(
        const BackendErrorInfo(
            status: 422, code: 'conversion_failed', detail: 'a\nb\r\nc'),
      );
      expect(detail.contains('\n'), isFalse);
      expect(detail.contains('a b c'), isTrue);
    });
  });

  group('matchesContainerHeader', () {
    test('accepts real MP3 signatures', () {
      expect(matchesContainerHeader([0x49, 0x44, 0x33, 0x04], 'mp3'), isTrue);
      expect(matchesContainerHeader([0xFF, 0xFB, 0x90, 0x64], 'mp3'), isTrue);
    });

    test('accepts MP4 and Matroska signatures', () {
      expect(
        matchesContainerHeader([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70], 'mp4'),
        isTrue,
      );
      expect(
        matchesContainerHeader([0, 0, 0, 0x10, 0x73, 0x74, 0x79, 0x70], 'm4a'),
        isTrue,
      );
      expect(
        matchesContainerHeader([0x1A, 0x45, 0xDF, 0xA3, 0x01], 'webm'),
        isTrue,
      );
    });

    test('rejects a different container or an error page', () {
      expect(matchesContainerHeader('<htm'.codeUnits, 'mp3'), isFalse);
      expect(matchesContainerHeader('<htm'.codeUnits, 'mp4'), isFalse);
      expect(matchesContainerHeader([0x49, 0x44, 0x33, 0x04], 'mp4'), isFalse);
      expect(matchesContainerHeader([0x49, 0x44], 'mp3'), isFalse);
    });

    test('does not judge extensions it does not know', () {
      expect(matchesContainerHeader([0x89, 0x50, 0x4E, 0x47], 'png'), isTrue);
    });
  });
}
