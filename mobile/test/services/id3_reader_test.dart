import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/services/id3_reader.dart';

/// Builds a real ID3v2.3 tag around [frames].
Uint8List _id3v23(List<Uint8List> frames) {
  final body = BytesBuilder();
  for (final frame in frames) {
    body.add(frame);
  }
  final payload = body.toBytes();
  final header = BytesBuilder();
  header.add([0x49, 0x44, 0x33, 3, 0, 0]); // "ID3", v2.3, no flags
  // Synchsafe size (7 bits per byte).
  header.add([
    (payload.length >> 21) & 0x7f,
    (payload.length >> 14) & 0x7f,
    (payload.length >> 7) & 0x7f,
    payload.length & 0x7f,
  ]);
  header.add(payload);
  return header.toBytes();
}

Uint8List _frame(String id, List<int> data) {
  final out = BytesBuilder();
  out.add(id.codeUnits);
  final size = data.length;
  out.add([
    (size >> 24) & 0xff,
    (size >> 16) & 0xff,
    (size >> 8) & 0xff,
    size & 0xff,
  ]);
  out.add([0, 0]); // flags
  out.add(data);
  return out.toBytes();
}

Uint8List _textFrame(String id, String value, {int encoding = 3}) {
  final bytes = switch (encoding) {
    1 => _utf16Le(value),
    0 => value.codeUnits, // ISO-8859-1
    _ => utf8.encode(value),
  };
  return _frame(id, [encoding, ...bytes]);
}

List<int> _utf16Le(String value) {
  final out = <int>[0xff, 0xfe];
  for (final unit in value.codeUnits) {
    out.add(unit & 0xff);
    out.add((unit >> 8) & 0xff);
  }
  return out;
}

Uint8List _apicFrame(String mime, List<int> picture) {
  final data = BytesBuilder();
  data.add([0]); // ISO-8859-1 for mime/description
  data.add(mime.codeUnits);
  data.add([0]); // mime terminator
  data.add([3]); // picture type: front cover
  data.add([0]); // empty description + terminator
  data.add(picture);
  return _frame('APIC', data.toBytes());
}

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('vibegrab_id3_');
  });
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('reads title, artist and album from ID3v2.3', () {
    final tag = _id3v23([
      _textFrame('TIT2', 'Mi canción'),
      _textFrame('TPE1', 'Artista'),
      _textFrame('TALB', 'Álbum'),
    ]);
    final file = File('${temp.path}/song.mp3')
      ..writeAsBytesSync([...tag, ...List<int>.filled(64, 0)]);

    final tags = Id3Reader.read(file);

    expect(tags.title, 'Mi canción');
    expect(tags.artist, 'Artista');
    expect(tags.album, 'Álbum');
    expect(tags.picture, isNull);
  });

  test('reads an UTF-16 (BOM) text frame', () {
    final file = File('${temp.path}/utf16.mp3')
      ..writeAsBytesSync(_id3v23([
        _textFrame('TIT2', 'Canción con acentos', encoding: 1),
      ]));

    expect(Id3Reader.read(file).title, 'Canción con acentos');
  });

  test('extracts the embedded cover', () {
    final picture = List<int>.generate(32, (i) => i);
    final file = File('${temp.path}/cover.mp3')
      ..writeAsBytesSync(_id3v23([
        _textFrame('TIT2', 'Song'),
        _apicFrame('image/jpeg', picture),
      ]));

    final tags = Id3Reader.read(file);

    expect(tags.pictureMime, 'image/jpeg');
    expect(tags.picture, isNotNull);
    expect(tags.picture!.length, picture.length);
    expect(tags.picture![0], 0);
  });

  test('falls back to the ID3v1 trailer', () {
    final bytes = <int>[
      ...List<int>.filled(200, 0x41), // audio-ish padding
      0x54, 0x41, 0x47, // "TAG"
      ...'Titulo v1'.codeUnits, ...List<int>.filled(30 - 'Titulo v1'.length, 0),
      ...'Artista v1'.codeUnits, ...List<int>.filled(30 - 'Artista v1'.length, 0),
      ...'Album v1'.codeUnits, ...List<int>.filled(30 - 'Album v1'.length, 0),
      ...List<int>.filled(35, 0), // year + comment + genre
    ];
    final file = File('${temp.path}/v1.mp3')..writeAsBytesSync(bytes);

    final tags = Id3Reader.read(file);

    expect(tags.title, 'Titulo v1');
    expect(tags.artist, 'Artista v1');
    expect(tags.album, 'Album v1');
  });

  test('returns empty tags for a file without tags', () {
    final file = File('${temp.path}/plain.mp3')
      ..writeAsBytesSync(List<int>.filled(512, 0x55));

    expect(Id3Reader.read(file).isEmpty, isTrue);
  });

  test('never throws on a corrupted tag', () {
    final file = File('${temp.path}/broken.mp3')
      ..writeAsBytesSync(<int>[
        0x49, 0x44, 0x33, 3, 0, 0,
        0x7f, 0x7f, 0x7f, 0x7f, // claims a huge tag
        ...List<int>.filled(20, 0xff),
      ]);

    final tags = Id3Reader.read(file);

    expect(tags.isEmpty, isTrue);
  });

  test('missing file yields empty tags', () {
    expect(Id3Reader.read(File('${temp.path}/nope.mp3')).isEmpty, isTrue);
  });
}
