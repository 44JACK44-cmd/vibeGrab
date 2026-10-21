import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/services/network_diagnostics.dart';

void main() {
  group('NetworkDiagnostics.sanitize', () {
    test('drops signed query strings from URLs', () {
      final text = NetworkDiagnostics.sanitize(
        Exception(
          'ClientException: '
          'https://rr3---sn.googlevideo.com/videoplayback?expire=1&sig=SECRET'
          '&token=ALSO_SECRET failed',
        ),
      );
      expect(text, contains('https://rr3---sn.googlevideo.com/videoplayback'));
      expect(text, isNot(contains('SECRET')));
      expect(text, isNot(contains('expire=')));
    });

    test('keeps a short exception class and message', () {
      final text = NetworkDiagnostics.sanitize(
        const SocketException('Connection refused'),
      );
      expect(text, contains('Connection refused'));
    });

    test('truncates long messages', () {
      final text = NetworkDiagnostics.sanitize('x' * 500);
      expect(text.length, lessThanOrEqualTo(121));
    });
  });

  group('DiagResult', () {
    test('serializes typed fields without prose parsing', () {
      const result = DiagResult(
        'backend',
        false,
        120,
        'http 502',
        operation: 'health',
        stage: 'request',
        platform: 'android',
        httpStatus: 502,
        exceptionType: 'HttpException',
        requestId: 'req-123',
      );
      final json = result.toJson();
      expect(json['check'], 'backend');
      expect(json['ok'], isFalse);
      expect(json['duration_ms'], 120);
      expect(json['operation'], 'health');
      expect(json['stage'], 'request');
      expect(json['http_status'], 502);
      expect(json['exception'], 'HttpException');
      expect(json['request_id'], 'req-123');
    });
  });
}
