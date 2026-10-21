import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/core/theme/player_style.dart';
import 'package:vibegrab/services/lyrics_service.dart';

void main() {
  group('player style', () {
    test('parses a stored style and rejects unknown values', () {
      expect(PlayerStyleInfo.parse('immersive'), PlayerStyle.immersive);
      expect(PlayerStyleInfo.parse('classic'), PlayerStyle.classic);
      expect(PlayerStyleInfo.parse('compact'), PlayerStyle.compact);
      expect(PlayerStyleInfo.parse('nope'), isNull);
      expect(PlayerStyleInfo.parse(null), isNull);
    });

    test('every style has a label and a description key', () {
      for (final style in PlayerStyle.values) {
        expect(style.labelKey, isNotEmpty);
        expect(style.descriptionKey, isNotEmpty);
      }
    });
  });

  group('lyrics matching', () {
    test('cleans the noise of a video title', () {
      expect(
        LyricsService.cleanTitle('Song Name (Official Music Video)'),
        'Song Name',
      );
      expect(
        LyricsService.cleanTitle('Song Name [Official Video]'),
        'Song Name',
      );
      expect(
        LyricsService.cleanTitle('Song Name - Official Audio'),
        'Song Name',
      );
    });

    test('splits "Artist - Song" for the search fallback', () {
      final parts = LyricsService.splitArtistTitle('Adele - Hello');
      expect(parts.artist, 'Adele');
      expect(parts.title, 'Hello');
    });

    test('does not invent an artist for an ambiguous title', () {
      final parts = LyricsService.splitArtistTitle('Hello');
      expect(parts.artist, '');
      expect(parts.title, 'Hello');
    });

    test('finds the line that is playing', () {
      final lines = [
        const LyricLine(Duration(seconds: 5), 'one'),
        const LyricLine(Duration(seconds: 10), 'two'),
        const LyricLine(Duration(seconds: 15), 'three'),
      ];
      expect(LyricsService.lineIndexAt(lines, const Duration(seconds: 0)), -1);
      expect(
          LyricsService.lineIndexAt(lines, const Duration(seconds: 7)), 0);
      expect(
          LyricsService.lineIndexAt(lines, const Duration(seconds: 12)), 1);
      expect(
          LyricsService.lineIndexAt(lines, const Duration(seconds: 40)), 2);
    });
  });
}
