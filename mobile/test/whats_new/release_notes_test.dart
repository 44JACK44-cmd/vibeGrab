import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/features/whats_new/data/release_notes.dart';

/// The notes file a release ships with, in both languages.
const _notes = '''
<!-- es -->
## ✨ Novedades
- 📥 **Sigue tus descargas** — Un panel con el progreso en cualquier pantalla.

## 🚀 Mejoras
- ⚡ **Explorer abre antes** — La portada ya no espera a la lista entera.

<!-- en -->
## ✨ What's new
- 📥 **Track your downloads** — A panel with the progress on any screen.

## 🚀 Improvements
- ⚡ **Explorer opens sooner** — The home screen no longer waits.
''';

/// What GitHub writes when the release has no notes file.
const _generated = '''
## What's Changed
* SonarCloud: seguridad, bugs, code smells y Dart limpio by @44JACK44-cmd in https://github.com/44JACK44-cmd/vibeGrab/pull/1

## New Contributors
* @44JACK44-cmd made their first contribution in https://github.com/44JACK44-cmd/vibeGrab/pull/1

**Full Changelog**: https://github.com/44JACK44-cmd/vibeGrab/compare/v1.1.35-40...v1.1.36-41
''';

void main() {
  group('ReleaseNotes.parse', () {
    test('reads the block written for the current language', () {
      final sections = ReleaseNotes.parse(_notes, 'es')!;
      expect(sections, hasLength(2));
      expect(sections.first.title, contains('Novedades'));
      expect(sections.first.items.single.title, 'Sigue tus descargas');
      expect(sections.first.items.single.emoji, '📥');
      expect(sections.first.items.single.body,
          'Un panel con el progreso en cualquier pantalla.');

      final en = ReleaseNotes.parse(_notes, 'en')!;
      expect(en.first.items.single.title, 'Track your downloads');
    });

    test('falls back to spanish for a language it was not written in', () {
      final sections = ReleaseNotes.parse(_notes, 'fr')!;
      expect(sections.first.items.single.title, 'Sigue tus descargas');
    });

    test('uses the whole text when it carries no language markers', () {
      const plain = '''
## 🛠️ Correcciones
- ▶️ **Un toque basta** — El botón ya no se queda mudo.
''';
      final sections = ReleaseNotes.parse(plain, 'en')!;
      expect(sections.single.title, contains('Correcciones'));
      expect(sections.single.items.single.title, 'Un toque basta');
      expect(sections.single.items.single.emoji, '▶️');
      expect(sections.single.items.single.body, 'El botón ya no se queda mudo.');
    });

    test('keeps a bold title with no description', () {
      const only = '''
## Novedades
- 🎬 **Shorts sigue al reproductor**
''';
      final item = ReleaseNotes.parse(only, 'es')!.single.items.single;
      expect(item.title, 'Shorts sigue al reproductor');
      expect(item.emoji, '🎬');
      expect(item.body, isEmpty);
    });

    test('drops the text GitHub generates from the commits', () {
      expect(ReleaseNotes.parse(_generated, 'es'), isNull);
    });

    test('keeps the human lines mixed into generated notes', () {
      const mixed = '''
## What's Changed
* Un cambio escrito a mano by @alguien in https://example.com/x
* Otra cosa escrita a mano

**Full Changelog**: https://example.com/compare/a...b
''';
      final sections = ReleaseNotes.parse(mixed, 'es')!;
      expect(sections.single.title, isEmpty,
          reason: 'el encabezado generado no se muestra');
      expect(sections.single.items.single.body, 'Otra cosa escrita a mano');
    });

    test('is null for an empty body', () {
      expect(ReleaseNotes.parse('', 'es'), isNull);
      expect(ReleaseNotes.parse('   \n\n  ', 'es'), isNull);
    });

    test('a paragraph with no header still becomes one note', () {
      final sections = ReleaseNotes.parse('sin secciones ni viñetas', 'es')!;
      expect(sections.single.title, isEmpty);
      expect(sections.single.items.single.body, 'sin secciones ni viñetas');
    });

    test('reads the file the way Windows writes it', () {
      final crlf = _notes.replaceAll('\n', '\r\n');
      final sections = ReleaseNotes.parse(crlf, 'es')!;
      expect(sections, hasLength(2));
      expect(sections.first.items.single.emoji, '📥');
    });
  });
}
