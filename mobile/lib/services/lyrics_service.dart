import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// A synced lyric line.
class LyricLine {
  final Duration at;
  final String text;
  const LyricLine(this.at, this.text);
}

/// Lyrics result: plain text and/or timestamped lines.
class Lyrics {
  final String? plain;
  final List<LyricLine> synced;
  final bool fromCache;
  const Lyrics({this.plain, this.synced = const [], this.fromCache = false});

  bool get isEmpty => (plain == null || plain!.trim().isEmpty) && synced.isEmpty;
  bool get isSynced => synced.isNotEmpty;
}

/// Free lyrics backend (lrclib.net, no API key needed), with on-disk cache.
class LyricsService {
  static final LyricsService instance = LyricsService._();
  LyricsService._();

  final Map<String, Lyrics> _mem = {};

  String _key(String artist, String title) {
    final k = '${artist.trim().toLowerCase()}|${title.trim().toLowerCase()}';
    return 'vibegrab_lyrics_${k.hashCode}';
  }

  /// Best-effort cleanup so "Title (Official Video)" still matches.
  String _cleanTitle(String title) {
    var t = title;
    for (final rx in [
      RegExp(r'\s*[\(\[].*?(official|video|audio|lyric|visualizer|remaster|hd|4k).*?[\)\]]', caseSensitive: false),
      RegExp(r'\s*[-–—]\s*(official|video|audio|lyric).*', caseSensitive: false),
    ]) {
      t = t.replaceAll(rx, '');
    }
    return t.trim();
  }

  Future<Lyrics?> fetch(String artist, String title, {String? album}) async {
    final a = artist.trim();
    var t = _cleanTitle(title);
    if (a.isEmpty || t.isEmpty) return null;
    final key = _key(a, t);
    if (_mem.containsKey(key)) {
      final c = _mem[key]!;
      return Lyrics(plain: c.plain, synced: c.synced, fromCache: true);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw != null) {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        final synced = _parseLrc(m['synced'] as String?);
        final l = Lyrics(plain: m['plain'] as String?, synced: synced, fromCache: true);
        _mem[key] = l;
        return l;
      }
    } catch (_) {}

    try {
      final uri = Uri.https('lrclib.net', '/api/get', {
        'artist_name': a,
        'track_name': t,
        if (album != null && album.isNotEmpty) 'album_name': album,
      });
      final res = await http.get(uri, headers: {
        'User-Agent': 'VibeGrab/1.0 (https://github.com/44JACK44-cmd/vibeGrab)',
      }).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      final m = jsonDecode(res.body) as Map<String, dynamic>;
      final plain = (m['plainLyrics'] as String?)?.trim();
      final syncedRaw = (m['syncedLyrics'] as String?)?.trim();
      if ((plain == null || plain.isEmpty) &&
          (syncedRaw == null || syncedRaw.isEmpty)) {
        return null;
      }
      final synced = _parseLrc(syncedRaw);
      final lyrics = Lyrics(plain: plain, synced: synced);
      _mem[key] = lyrics;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
            key, jsonEncode({'plain': plain, 'synced': syncedRaw}));
      } catch (_) {}
      return lyrics;
    } catch (e) {
      debugPrint('[LYRICS] fetch failed: $e');
      return null;
    }
  }

  static final _lrcLine = RegExp(r'^\s*\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]\s*(.*)$');

  static List<LyricLine> _parseLrc(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    final out = <LyricLine>[];
    for (final line in raw.split('\n')) {
      final m = _lrcLine.firstMatch(line);
      if (m == null) continue;
      final min = int.tryParse(m.group(1)!) ?? 0;
      final sec = int.tryParse(m.group(2)!) ?? 0;
      var ms = 0;
      final frac = m.group(3);
      if (frac != null) {
        if (frac.length == 2) {
          ms = (int.tryParse(frac) ?? 0) * 10;
        } else if (frac.length == 3) {
          ms = int.tryParse(frac) ?? 0;
        }
      }
      final text = (m.group(4) ?? '').trim();
      if (text.isEmpty) continue;
      out.add(LyricLine(
          Duration(minutes: min, seconds: sec, milliseconds: ms), text));
    }
    out.sort((a, b) => a.at.compareTo(b.at));
    return out;
  }

  /// Index of the line playing at [position] (-1 if none yet).
  static int lineIndexAt(List<LyricLine> lines, Duration position) {
    var idx = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].at <= position) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }
}
