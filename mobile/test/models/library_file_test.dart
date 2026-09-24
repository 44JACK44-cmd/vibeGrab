import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/data/models/library_file.dart';

void main() {
  group('LibraryFile.fromJson', () {
    test('parses full JSON', () {
      final json = {
        'filename': 'video.mp4',
        'title': 'My Video',
        'file_path': '/downloads/video.mp4',
        'file_size': 1048576,
        'file_size_formatted': '1.0 MB',
        'file_type': 'video',
        'extension': 'mp4',
        'created_at': '2026-01-01T00:00:00Z',
        'thumbnail': 'https://img.youtube.com/vi/abc/maxresdefault.jpg',
        'source': 'youtube',
      };

      final file = LibraryFile.fromJson(json);
      expect(file.filename, 'video.mp4');
      expect(file.title, 'My Video');
      expect(file.filePath, '/downloads/video.mp4');
      expect(file.fileSize, 1048576);
      expect(file.fileSizeFormatted, '1.0 MB');
      expect(file.fileType, 'video');
      expect(file.extension, 'mp4');
      expect(file.thumbnail, 'https://img.youtube.com/vi/abc/maxresdefault.jpg');
      expect(file.source, 'youtube');
    });

    test('handles missing fields', () {
      final file = LibraryFile.fromJson({});
      expect(file.filename, '');
      expect(file.title, 'Untitled');
      expect(file.fileSize, 0);
      expect(file.fileType, 'unknown');
      expect(file.thumbnail, isNull);
      expect(file.source, isNull);
    });
  });

  group('type checks', () {
    test('isVideo for video type', () {
      final file = LibraryFile(
        filename: 'a.mp4', title: 't', filePath: 'p',
        fileSize: 0, fileSizeFormatted: '0', fileType: 'video',
        extension: 'mp4', createdAt: '',
      );
      expect(file.isVideo, isTrue);
      expect(file.isAudio, isFalse);
    });

    test('isAudio for audio type', () {
      final file = LibraryFile(
        filename: 'a.mp3', title: 't', filePath: 'p',
        fileSize: 0, fileSizeFormatted: '0', fileType: 'audio',
        extension: 'mp3', createdAt: '',
      );
      expect(file.isAudio, isTrue);
      expect(file.isVideo, isFalse);
    });
  });
}
