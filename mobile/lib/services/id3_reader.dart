import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Metadata read from an audio file's own tags.
///
/// Downloaded MP3s written by the backend carry ID3v2 tags and an embedded
/// cover (see backend/app/services/audio_service.py). The player used to rely
/// only on the small `.meta.json` sidecar, so a file whose sidecar was missing
/// showed no artwork even though the cover was inside it. This reads the file.
class AudioTags {
  final String? title;
  final String? artist;
  final String? album;
  final Uint8List? picture;
  final String? pictureMime;

  const AudioTags({
    this.title,
    this.artist,
    this.album,
    this.picture,
    this.pictureMime,
  });

  bool get isEmpty =>
      title == null && artist == null && album == null && picture == null;
}

class Id3Reader {
  /// Parses ID3v2 (2.2/2.3/2.4) tags and falls back to the ID3v1 trailer.
  ///
  /// Returns an empty [AudioTags] when the file has no readable tags; it never
  /// throws for malformed data, a broken tag must not break playback.
  static AudioTags read(File file) {
    try {
      if (!file.existsSync()) return const AudioTags();
      final length = file.lengthSync();
      final raf = file.openSync();
      try {
        final head = _read(raf, 0, length < 10 ? length : 10);
        if (head.length >= 10 && _isId3v2(head)) {
          return _readId3v2(raf, head, length);
        }
        return _readId3v1(raf, length);
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return const AudioTags();
    }
  }

  static bool _isId3v2(Uint8List head) =>
      head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33;

  static Uint8List _read(RandomAccessFile raf, int offset, int count) {
    if (count <= 0) return Uint8List(0);
    raf.setPositionSync(offset);
    return raf.readSync(count);
  }

  static int _synchsafe(Uint8List bytes, int start) {
    var value = 0;
    for (var i = 0; i < 4; i++) {
      value = (value << 7) | (bytes[start + i] & 0x7f);
    }
    return value;
  }

  static int _be32(Uint8List bytes, int start) =>
      (bytes[start] << 24) |
      (bytes[start + 1] << 16) |
      (bytes[start + 2] << 8) |
      bytes[start + 3];

  static AudioTags _readId3v2(
    RandomAccessFile raf,
    Uint8List header,
    int fileLength,
  ) {
    final major = header[3];
    final flags = header[5];
    final tagSize = _synchsafe(header, 6);
    if (tagSize <= 0) return const AudioTags();

    var bodyOffset = 0;
    var body = _read(raf, 0, fileLength < tagSize + 10 ? fileLength : tagSize + 10);
    if (body.length > 10) {
      body = Uint8List.sublistView(body, 10);
    } else {
      return const AudioTags();
    }

    // Unsynchronisation: 0xFF 0x00 pairs stand for a single 0xFF byte.
    if (flags & 0x80 != 0) {
      body = _deunsynchronise(body);
    }
    // Extended header: skip it (its size field differs between versions).
    if (flags & 0x40 != 0 && body.length >= 4) {
      final size = major >= 4 ? _synchsafe(body, 0) : _be32(body, 0);
      bodyOffset = size + (major >= 4 ? 0 : 4);
    }

    String? title;
    String? artist;
    String? album;
    Uint8List? picture;
    String? pictureMime;

    var pos = bodyOffset;
    final idLength = major == 2 ? 3 : 4;
    while (pos + idLength + (major == 2 ? 3 : 6) <= body.length) {
      final id = ascii.decode(body.sublist(pos, pos + idLength), allowInvalid: true);
      if (id.codeUnits.every((c) => c == 0)) break;
      int size;
      int headerSize;
      if (major == 2) {
        size = (body[pos + 3] << 16) | (body[pos + 4] << 8) | body[pos + 5];
        headerSize = 6;
      } else {
        size = major >= 4 ? _synchsafe(body, pos + 4) : _be32(body, pos + 4);
        headerSize = 10;
      }
      if (size <= 0 || pos + headerSize + size > body.length) break;
      final frame = Uint8List.sublistView(
        body,
        pos + headerSize,
        pos + headerSize + size,
      );
      pos += headerSize + size;

      switch (id) {
        case 'TIT2':
        case 'TT2':
          title = _decodeText(frame);
        case 'TPE1':
        case 'TP1':
          artist = _decodeText(frame);
        case 'TALB':
        case 'TAL':
          album = _decodeText(frame);
        case 'APIC':
        case 'PIC':
          final parsed = _decodePicture(frame, major == 2);
          if (parsed != null) {
            picture = parsed.data;
            pictureMime = parsed.mime;
          }
      }
    }

    if (title == null && artist == null && album == null && picture == null) {
      final v1 = _readId3v1(raf, fileLength);
      return v1;
    }
    return AudioTags(
      title: _clean(title),
      artist: _clean(artist),
      album: _clean(album),
      picture: picture,
      pictureMime: pictureMime,
    );
  }

  static Uint8List _deunsynchronise(Uint8List input) {
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < input.length; i++) {
      out.addByte(input[i]);
      if (input[i] == 0xff && i + 1 < input.length && input[i + 1] == 0x00) {
        i++; // drop the inserted zero
      }
    }
    return out.toBytes();
  }

  /// Text frame: encoding byte followed by the text.
  static String? _decodeText(Uint8List frame) {
    if (frame.isEmpty) return null;
    final encoding = frame[0];
    var data = Uint8List.sublistView(frame, 1);
    // A UTF-16 text frame ends with a null terminator; some writers pad it.
    switch (encoding) {
      case 0: // ISO-8859-1
        final end = data.indexOf(0);
        if (end >= 0) data = Uint8List.sublistView(data, 0, end);
        return latin1.decode(data, allowInvalid: true);
      case 1: // UTF-16 with BOM
        return _decodeUtf16(data, withBom: true);
      case 2: // UTF-16BE
        return _decodeUtf16(data, withBom: false);
      default: // UTF-8
        final end = data.indexOf(0);
        if (end >= 0) data = Uint8List.sublistView(data, 0, end);
        return utf8.decode(data, allowMalformed: true);
    }
  }

  static String _decodeUtf16(Uint8List data, {required bool withBom}) {
    var bytes = data;
    var bigEndian = true;
    if (withBom && bytes.length >= 2) {
      if (bytes[0] == 0xff && bytes[1] == 0xfe) {
        bigEndian = false;
        bytes = Uint8List.sublistView(bytes, 2);
      } else if (bytes[0] == 0xfe && bytes[1] == 0xff) {
        bytes = Uint8List.sublistView(bytes, 2);
      }
    }
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final unit = bigEndian
          ? (bytes[i] << 8) | bytes[i + 1]
          : (bytes[i + 1] << 8) | bytes[i];
      if (unit == 0) break;
      units.add(unit);
    }
    return String.fromCharCodes(units);
  }

  /// APIC/PIC frame: encoding, mime (or 3-letter type in v2.2), picture type,
  /// description, then the image bytes.
  static _Picture? _decodePicture(Uint8List frame, bool v22) {
    if (frame.length < 5) return null;
    final encoding = frame[0];
    var pos = 1;
    String mime;
    if (v22) {
      mime = ascii.decode(
        Uint8List.sublistView(frame, pos, pos + 3),
        allowInvalid: true,
      );
      pos += 3;
      mime = mime == 'JPG' ? 'image/jpeg' : 'image/png';
    } else {
      final end = frame.indexOf(0, pos);
      if (end < 0) return null;
      mime = ascii.decode(Uint8List.sublistView(frame, pos, end), allowInvalid: true);
      pos = end + 1;
    }
    if (pos >= frame.length) return null;
    pos += 1; // picture type
    // Description: terminated in the frame's encoding.
    if (encoding == 1 || encoding == 2) {
      while (pos + 1 < frame.length &&
          !(frame[pos] == 0 && frame[pos + 1] == 0)) {
        pos += 2;
      }
      pos += 2;
    } else {
      final end = frame.indexOf(0, pos);
      pos = end < 0 ? pos : end + 1;
    }
    if (pos >= frame.length) return null;
    return _Picture(Uint8List.sublistView(frame, pos), mime);
  }

  static AudioTags _readId3v1(RandomAccessFile raf, int fileLength) {
    if (fileLength < 128) return const AudioTags();
    final tag = _read(raf, fileLength - 128, 128);
    if (tag.length < 128 || tag[0] != 0x54 || tag[1] != 0x41 ||
        tag[2] != 0x47) {
      return const AudioTags();
    }
    String field(int start, int length) {
      final slice = Uint8List.sublistView(tag, start, start + length);
      final end = slice.indexOf(0);
      final bytes = end < 0 ? slice : Uint8List.sublistView(slice, 0, end);
      return latin1.decode(bytes, allowInvalid: true).trim();
    }

    return AudioTags(
      title: _clean(field(3, 30)),
      artist: _clean(field(33, 30)),
      album: _clean(field(63, 30)),
    );
  }

  static String? _clean(String? value) {
    if (value == null) return null;
    final trimmed = value.replaceAll('\u0000', '').trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

class _Picture {
  final Uint8List data;
  final String mime;
  const _Picture(this.data, this.mime);
}
