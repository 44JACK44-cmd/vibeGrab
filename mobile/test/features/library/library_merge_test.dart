import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/data/models/library_file.dart';
import 'package:vibegrab/features/library/controllers/library_controller.dart';

LibraryFile _file({
  String filename = 'Song.m4a',
  String? contentUri,
  String sourceType = 'downloaded',
  String title = 'Song',
  String? artist,
  int durationMs = 0,
}) {
  return LibraryFile(
    filename: filename,
    title: title,
    filePath: 'C:/Download/VibeGrab/$filename',
    fileSize: 1024,
    fileSizeFormatted: '1 KB',
    fileType: 'audio',
    extension: 'm4a',
    createdAt: '2026-01-01T00:00:00.000Z',
    sourceType: sourceType,
    contentUri: contentUri,
    artist: artist,
    durationMs: durationMs == 0 ? null : durationMs,
  );
}

void main() {
  test('a download present in MediaStore and in the folder is one card', () {
    final device = _file(
      contentUri: 'content://media/external/audio/media/42',
      sourceType: 'local',
      artist: 'Artist',
      durationMs: 123000,
    );
    final downloaded = _file(title: 'Song from sidecar');

    final merged = LibraryController.mergeUnique([device], [downloaded]);

    expect(merged, hasLength(1));
    expect(merged.single.contentUri, contains('media/42'));
    // MediaStore wins for playback but keeps the extra metadata.
    expect(merged.single.artist, 'Artist');
    expect(merged.single.durationMs, 123000);
  });

  test('two MediaStore rows with the same filename collapse', () {
    final first = _file(
      contentUri: 'content://media/external/audio/media/1',
      sourceType: 'local',
    );
    final second = _file(
      contentUri: 'content://media/external/audio/media/2',
      sourceType: 'local',
    );

    final merged = LibraryController.mergeUnique([first, second], const []);

    expect(merged, hasLength(1));
    expect(merged.single.contentUri, contains('media/1'));
  });

  test('a downloaded file still appears when MediaStore has not indexed it', () {
    final merged = LibraryController.mergeUnique(
      const [],
      [_file(filename: 'OnlyHere.mp3')],
    );

    expect(merged, hasLength(1));
    expect(merged.single.filename, 'OnlyHere.mp3');
  });

  test('filename identity is case insensitive', () {
    final merged = LibraryController.mergeUnique(
      [_file(filename: 'Track.MP3', contentUri: 'content://1')],
      [_file(filename: 'track.mp3')],
    );

    expect(merged, hasLength(1));
  });
}
