import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MediaMetadata {
  final String filename;
  bool isFavorite;
  String? lastPlayedAt;
  int lastPositionMs;
  int durationMs;

  MediaMetadata({
    required this.filename,
    this.isFavorite = false,
    this.lastPlayedAt,
    this.lastPositionMs = 0,
    this.durationMs = 0,
  });

  double get resumeProgress =>
      durationMs > 0 ? (lastPositionMs / durationMs).clamp(0.0, 1.0) : 0.0;

  bool get hasResume => lastPositionMs > 10000 && resumeProgress < 0.95;

  String get resumeFormatted {
    final d = Duration(milliseconds: lastPositionMs);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Map<String, dynamic> toJson() => {
        'filename': filename,
        'isFavorite': isFavorite,
        'lastPlayedAt': lastPlayedAt,
        'lastPositionMs': lastPositionMs,
        'durationMs': durationMs,
      };

  factory MediaMetadata.fromJson(Map<String, dynamic> json) => MediaMetadata(
        filename: json['filename'] ?? '',
        isFavorite: json['isFavorite'] ?? false,
        lastPlayedAt: json['lastPlayedAt'],
        lastPositionMs: json['lastPositionMs'] ?? 0,
        durationMs: json['durationMs'] ?? 0,
      );
}

class HistoryEntry {
  final String filename;
  final String title;
  final String? thumbnail;
  final String? source;
  final String fileType;
  final String playedAt;

  HistoryEntry({
    required this.filename,
    required this.title,
    this.thumbnail,
    this.source,
    required this.fileType,
    required this.playedAt,
  });

  Map<String, dynamic> toJson() => {
        'filename': filename,
        'title': title,
        'thumbnail': thumbnail,
        'source': source,
        'fileType': fileType,
        'playedAt': playedAt,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        filename: json['filename'] ?? '',
        title: json['title'] ?? '',
        thumbnail: json['thumbnail'],
        source: json['source'],
        fileType: json['fileType'] ?? 'unknown',
        playedAt: json['playedAt'] ?? '',
      );
}

class MediaMetadataService extends ChangeNotifier {
  static final MediaMetadataService _instance = MediaMetadataService._();
  factory MediaMetadataService() => _instance;
  MediaMetadataService._();

  Map<String, MediaMetadata> _metadata = {};
  List<HistoryEntry> _history = [];

  static const _metadataKey = 'vibegrab_media_metadata';
  static const _historyKey = 'vibegrab_history';
  static const _maxHistory = 200;

  Map<String, MediaMetadata> get metadata => Map.unmodifiable(_metadata);
  List<HistoryEntry> get history => List.unmodifiable(_history);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final metaJson = prefs.getString(_metadataKey);
    if (metaJson != null) {
      try {
        final raw = jsonDecode(metaJson) as Map<String, dynamic>;
        _metadata = raw.map((k, v) => MapEntry(k, MediaMetadata.fromJson(v)));
      } catch (_) {
        _metadata = {};
      }
    }
    final histJson = prefs.getString(_historyKey);
    if (histJson != null) {
      try {
        final raw = jsonDecode(histJson) as List;
        _history = raw.map((e) => HistoryEntry.fromJson(e)).toList();
      } catch (_) {
        _history = [];
      }
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _metadataKey,
      jsonEncode(_metadata.map((k, v) => MapEntry(k, v.toJson()))),
    );
    await prefs.setString(
      _historyKey,
      jsonEncode(_history.map((e) => e.toJson()).toList()),
    );
  }

  MediaMetadata getMeta(String filename) {
    return _metadata[filename] ?? MediaMetadata(filename: filename);
  }

  bool isFavorite(String filename) {
    return _metadata[filename]?.isFavorite ?? false;
  }

  Future<void> toggleFavorite(String filename) async {
    final meta = getMeta(filename);
    meta.isFavorite = !meta.isFavorite;
    _metadata[filename] = meta;
    notifyListeners();
    await _save();
  }

  Future<void> recordPlay({
    required String filename,
    required String title,
    String? thumbnail,
    required String fileType,
    String? source,
  }) async {
    final now = DateTime.now().toIso8601String();
    final meta = getMeta(filename);
    meta.lastPlayedAt = now;
    _metadata[filename] = meta;

    _history.removeWhere((h) => h.filename == filename);
    _history.insert(0, HistoryEntry(
      filename: filename,
      title: title,
      thumbnail: thumbnail,
      source: source,
      fileType: fileType,
      playedAt: now,
    ));

    if (_history.length > _maxHistory) {
      _history = _history.sublist(0, _maxHistory);
    }

    notifyListeners();
    await _save();
  }

  Future<void> savePosition({
    required String filename,
    required int positionMs,
    required int durationMs,
  }) async {
    final meta = getMeta(filename);
    meta.lastPositionMs = positionMs;
    meta.durationMs = durationMs;
    _metadata[filename] = meta;
    await _save();
  }

  int getResumePosition(String filename) {
    return _metadata[filename]?.lastPositionMs ?? 0;
  }

  Future<void> removeFileData(String filename) async {
    _metadata.remove(filename);
    _history.removeWhere((h) => h.filename == filename);
    notifyListeners();
    await _save();
  }

  List<HistoryEntry> getHistoryForDate(String dateLabel) {
    return _history.where((h) {
      final d = DateTime.tryParse(h.playedAt);
      if (d == null) return false;
      final now = DateTime.now();
      if (dateLabel == 'today') {
        return d.year == now.year && d.month == now.month && d.day == now.day;
      }
      if (dateLabel == 'yesterday') {
        final y = now.subtract(const Duration(days: 1));
        return d.year == y.year && d.month == y.month && d.day == y.day;
      }
      return false;
    }).toList();
  }

  String dateLabelFor(String isoDate) {
    final d = DateTime.tryParse(isoDate);
    if (d == null) return '';
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) return 'today';
    final y = now.subtract(const Duration(days: 1));
    if (d.year == y.year && d.month == y.month && d.day == y.day) return 'yesterday';
    return '${d.day} ${_monthName(d.month)}';
  }

  static const _months = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _monthName(int m) => m >= 1 && m <= 12 ? _months[m] : '';

  List<HistoryEntry> groupHistory() {
    final Map<String, List<HistoryEntry>> grouped = {};
    for (final h in _history) {
      final label = dateLabelFor(h.playedAt);
      grouped.putIfAbsent(label, () => []).add(h);
    }
    return grouped.entries.expand((e) => e.value).toList();
  }
}
