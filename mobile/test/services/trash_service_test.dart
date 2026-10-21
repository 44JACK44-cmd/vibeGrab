import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/services/trash_service.dart';

void main() {
  group('TrashEntry', () {
    test('keeps a separate stored name for collision-free trash files', () {
      final entry = TrashEntry(
        filename: 'song.mp3',
        storedName: 'song (1700000000000-1).mp3',
        size: 1234,
        deletedAt: 1700000000000,
        thumbName: 'song (1700000000000-1).mp3.thumb.jpg',
      );
      final restored = TrashEntry.fromJson(entry.toJson());
      expect(restored.filename, 'song.mp3');
      expect(restored.storedName, 'song (1700000000000-1).mp3');
      expect(restored.thumbName, endsWith('.thumb.jpg'));
      expect(restored.size, 1234);
    });

    test('reads old indexes that only have filename', () {
      final entry = TrashEntry.fromJson({
        'filename': 'old.mp4',
        'size': 50,
        'deletedAt': 10,
      });
      expect(entry.filename, 'old.mp4');
      expect(entry.storedName, 'old.mp4');
      expect(entry.hasThumb, isFalse);
    });

    test('baseNameOf and extensionOf handle names without dots', () {
      expect(TrashService.baseNameOf('clip.mp4'), 'clip');
      expect(TrashService.baseNameOf('README'), 'README');
      expect(TrashService.extensionOf('clip.mp4'), '.mp4');
      expect(TrashService.extensionOf('README'), '');
    });
  });
}
