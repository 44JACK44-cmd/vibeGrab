import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/services/status_service.dart';

void main() {
  group('StatusFile.mimeType', () {
    StatusFile file(String ext, {required bool isVideo}) => StatusFile(
          file: File('/tmp/status.$ext'),
          name: 'status.$ext',
          path: '/tmp/status.$ext',
          ext: ext,
          size: 10,
          isVideo: isVideo,
          modifiedMs: 0,
        );

    test('reports the real image container', () {
      expect(file('heic', isVideo: false).mimeType, 'image/heic');
      expect(file('avif', isVideo: false).mimeType, 'image/avif');
      expect(file('webp', isVideo: false).mimeType, 'image/webp');
      expect(file('png', isVideo: false).mimeType, 'image/png');
    });

    test('reports the real video container', () {
      expect(file('mp4', isVideo: true).mimeType, 'video/mp4');
      expect(file('3gp', isVideo: true).mimeType, 'video/3gpp');
      expect(file('webm', isVideo: true).mimeType, 'video/webm');
    });
  });
}
