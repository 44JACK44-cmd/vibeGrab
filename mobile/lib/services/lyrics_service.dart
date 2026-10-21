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

  static const _headers = {
    'User-Agent': 'VibeGrab/1.0 (https://github.com/44JACK44-cmd/vibeGrab)',
  };

  /// Values that mean "the player could not read real tags", not an artist.
  static const _genericArtists = {
    'youtube',
    'youtu.be',
    'vibegrab',
    'unknown',
    'unknown artist',
    'desconocido',
    'artista desconocido',
    'music',
    'música',
  };

  static bool _isGenericArtist(String artist) {
    final a = artist.trim().toLowerCase();
    return a.isEmpty || _genericArtists.contains(a);
  }

  /// Best-effort cleanup so "Title (Official Video)" still matches.
  static String cleanTitle(String title) {
    var t = title.replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), ' ').trim();
    for (final rx in [
      RegExp(
          r'\s*[\(\[][^\)\]]*(official|video|audio|lyric|visualizer|remaster|hd|4k|mv|m/v)[^\)\]]*[\)\]]',
          caseSensitive: false),
      RegExp(r'\s*[-–—]\s*(official|video|audio|lyric|visualizer).*',
          caseSensitive: false),
      RegExp(r'\s+(official|lyric)\s+(video|audio)\s*$',
          caseSensitive: false),
    ]) {
      t = t.replaceAll(rx, '');
    }
    t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return t;
  }

  /// Splits "Artist - Song" without inventing an artist for ambiguous titles.
  /// Used only as a search hint, never as the sole query.
  @visibleForTesting
  static ({String artist, String title}) splitArtistTitle(String raw) {
    final cleaned = cleanTitle(raw);
    final parts = cleaned.split(RegExp(r'\s+[-–—]\s+'));
    if (parts.length == 2) {
      final left = parts[0].trim();
      final right = parts[1].trim();
      if (left.isNotEmpty && right.isNotEmpty) {
        return (artist: left, title: right);
      }
    }
    return (artist: '', title: cleaned);
  }

  static String _norm(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9áéíóúüñ ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<Lyrics?> fetch(String artist, String title, {String? album}) async {
    var a = artist.trim();
    var t = cleanTitle(title);
    if (t.isEmpty) return null;

    if (_isGenericArtist(a)) {
      // Do not ask lrclib for artist "YouTube". Try to recover a real artist
      // from a "Artist - Song" title, and let the search endpoint do the rest.
      a = splitArtistTitle(title).artist;
    }

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
        final l = Lyrics(
            plain: m['plain'] as String?, synced: synced, fromCache: true);
        _mem[key] = l;
        return l;
      }
    } catch (_) {}

    try {
      // Exact lookup first when we have a credible artist.
      if (!_isGenericArtist(a)) {
        final exact = await _getExact(a, t, album);
        if (exact != null) return await _remember(key, exact);
      }
      // Search by the full title (often includes the artist) and by the
      // separated track name. lrclib matches partial metadata here, which is
      // what makes YouTube-style titles findable.
      final found = await _search(a, t);
      if (found != null) return await _remember(key, found);
    } catch (e) {
      debugPrint('[LYRICS] fetch failed: $e');
    }
    return null;
  }

  Future<Lyrics?> _getExact(String artist, String title, String? album) async {
    final uri = Uri.https('lrclib.net', '/api/get', {
      'artist_name': artist,
      'track_name': title,
      if (album != null && album.isNotEmpty) 'album_name': album,
    });
    final res = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    return _lyricsFromJson(jsonDecode(res.body));
  }

  Future<Lyrics?> _search(String artist, String title) async {
    final queries = <String>{
      title,
      if (artist.isNotEmpty) '$artist $title',
      if (artist.isNotEmpty) title.replaceFirst(artist, '').trim(),
    }.where((q) => q.trim().isNotEmpty).toList();

    for (final query in queries) {
      final uri = Uri.https('lrclib.net', '/api/search', {'q': query});
      final res = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) continue;
      final decoded = jsonDecode(res.body);
      if (decoded is! List) continue;
      final candidates = decoded
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      if (candidates.isEmpty) continue;
      candidates.sort((x, y) =>
          _score(y, artist, title).compareTo(_score(x, artist, title)));
      for (final candidate in candidates.take(4)) {
        final lyrics = _lyricsFromJson(candidate);
        if (lyrics != null && !lyrics.isEmpty) return lyrics;
      }
    }
    return null;
  }

  static int _score(Map<String, dynamic> item, String artist, String title) {
    final wantedTitle = _norm(title);
    final gotTitle = _norm((item['trackName'] as String?) ?? '');
    final gotArtist = _norm((item['artistName'] as String?) ?? '');
    var score = 0;
    if (gotTitle == wantedTitle) {
      score += 60;
    } else if (gotTitle.contains(wantedTitle) ||
        wantedTitle.contains(gotTitle)) {
      score += 35;
    }
    if (artist.isNotEmpty && gotArtist == _norm(artist)) score += 30;
    if ((item['syncedLyrics'] as String?)?.trim().isNotEmpty == true) score += 5;
    return score;
  }

  static Lyrics? _lyricsFromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final plain = (m['plainLyrics'] as String?)?.trim();
    final syncedRaw = (m['syncedLyrics'] as String?)?.trim();
    if ((plain == null || plain.isEmpty) &&
        (syncedRaw == null || syncedRaw.isEmpty)) {
      return null;
    }
    return Lyrics(plain: plain, synced: _parseLrc(syncedRaw));
  }

  Future<Lyrics> _remember(String key, Lyrics lyrics) async {
    _mem[key] = lyrics;
    try {
      final prefs = await SharedPreferences.getInstance();
      final synced = lyrics.synced
          .map((line) => '[${line.at.inMinutes}:'
              '${(line.at.inSeconds % 60).toString().padLeft(2, '0')}.'
              '${(line.at.inMilliseconds % 1000).toString().padLeft(3, '0')}]'
              '${line.text}')
          .join('\n');
      await prefs.setString(
          key, jsonEncode({'plain': lyrics.plain, 'synced': synced}));
    } catch (_) {}
    return lyrics;
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
