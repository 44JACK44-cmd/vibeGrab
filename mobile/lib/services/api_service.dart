import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants/api_constants.dart';
import '../data/models/analyze_response.dart';
import '../data/models/download_task.dart';
import '../data/models/library_file.dart';
import '../data/models/app_settings.dart';
import '../data/models/explore_video.dart';

class NetworkException implements Exception {
  final String message;
  final String type;
  final int? statusCode;

  const NetworkException(this.message, {this.type = 'unknown', this.statusCode});

  @override
  String toString() => message;

  static NetworkException fromError(Object e) {
    if (e is TimeoutException) {
      return const NetworkException(
        'Connection timed out. Check your network and server.',
        type: 'timeout',
      );
    }
    if (e is http.ClientException) {
      return const NetworkException(
        'Could not connect to server.',
        type: 'connection',
      );
    }
    if (e is NetworkException) return e;
    return NetworkException(e.toString(), type: 'unknown');
  }
}

class ApiService {
  final http.Client _client;
  final Duration _shortTimeout;
  final Duration _mediumTimeout;
  final Duration _longTimeout;

  ApiService({
    http.Client? client,
    Duration? shortTimeout,
    Duration? mediumTimeout,
    Duration? longTimeout,
  })  : _client = client ?? http.Client(),
        _shortTimeout = shortTimeout ?? const Duration(seconds: 8),
        _mediumTimeout = mediumTimeout ?? const Duration(seconds: 15),
        _longTimeout = longTimeout ?? const Duration(seconds: 45);

  Future<bool> checkHealth() async {
    try {
      final response = await _client
          .get(Uri.parse(ApiConfig.healthUrl))
          .timeout(_shortTimeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<AnalyzeResponse> analyze(String url) async {
    try {
      final response = await _client
          .post(
            Uri.parse(ApiConfig.analyzeUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'url': url}),
          )
          .timeout(_longTimeout);

      final body = jsonDecode(response.body);
      if (response.statusCode == 200) {
        return AnalyzeResponse.fromJson(body);
      }
      throw NetworkException(
        body['detail'] ?? 'Analysis failed',
        type: 'http',
        statusCode: response.statusCode,
      );
    } catch (e) {
      throw NetworkException.fromError(e);
    }
  }

  Future<DownloadTask> startDownload({
    required String url,
    required String formatId,
    String? title,
    String? thumbnail,
    String? source,
    bool hasVideo = true,
    bool hasAudio = true,
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse(ApiConfig.downloadsUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'url': url,
              'format_id': formatId,
              if (title != null) 'title': title,
              if (thumbnail != null) 'thumbnail': thumbnail,
              if (source != null) 'source': source,
              'has_video': hasVideo,
              'has_audio': hasAudio,
            }),
          )
          .timeout(_mediumTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return DownloadTask(
          id: data['task_id'],
          url: url,
          title: title ?? 'Untitled',
          formatId: formatId,
          thumbnail: thumbnail,
          source: source,
          hasVideo: hasVideo,
          hasAudio: hasAudio,
          createdAt: DateTime.now().toIso8601String(),
        );
      }
      throw NetworkException('Failed to start download', statusCode: response.statusCode);
    } catch (e) {
      throw NetworkException.fromError(e);
    }
  }

  Future<DownloadTask> getDownloadStatus(String taskId) async {
    try {
      final response = await _client
          .get(Uri.parse('${ApiConfig.downloadsUrl}/$taskId'))
          .timeout(_shortTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return DownloadTask.fromJson(data['task']);
      }
      throw NetworkException('Failed to get download status', statusCode: response.statusCode);
    } catch (e) {
      throw NetworkException.fromError(e);
    }
  }

  Future<List<DownloadTask>> getAllDownloads() async {
    try {
      final response = await _client
          .get(Uri.parse(ApiConfig.downloadsUrl))
          .timeout(_shortTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return (data['tasks'] as List)
            .map((t) => DownloadTask.fromJson(t))
            .toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  Future<void> cancelDownload(String taskId) async {
    try {
      await _client
          .post(Uri.parse('${ApiConfig.downloadsUrl}/$taskId/cancel'))
          .timeout(_shortTimeout);
    } catch (_) {}
  }

  Future<DownloadTask> retryDownload(String taskId) async {
    try {
      final response = await _client
          .post(Uri.parse('${ApiConfig.downloadsUrl}/$taskId/retry'))
          .timeout(_mediumTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return DownloadTask(
          id: data['task_id'],
          url: '',
          title: 'Retrying...',
          formatId: '',
          createdAt: DateTime.now().toIso8601String(),
        );
      }
      throw NetworkException('Failed to retry download', statusCode: response.statusCode);
    } catch (e) {
      throw NetworkException.fromError(e);
    }
  }

  Future<List<LibraryFile>> getLibrary() async {
    try {
      final response = await _client
          .get(Uri.parse(ApiConfig.libraryUrl))
          .timeout(_shortTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return (data['files'] as List)
            .map((f) => LibraryFile.fromJson(f))
            .toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  Future<void> deleteLibraryFile(String filename) async {
    try {
      await _client
          .delete(Uri.parse(ApiConfig.libraryDeleteUrl(filename)))
          .timeout(_shortTimeout);
    } catch (_) {}
  }

  Future<AppSettings> getSettings() async {
    try {
      final response = await _client
          .get(Uri.parse(ApiConfig.settingsUrl))
          .timeout(_shortTimeout);

      if (response.statusCode == 200) {
        return AppSettings.fromJson(jsonDecode(response.body));
      }
      throw NetworkException('Failed to load settings', statusCode: response.statusCode);
    } catch (e) {
      throw NetworkException.fromError(e);
    }
  }

  Future<AppSettings> saveSettings(AppSettings settings) async {
    try {
      final response = await _client
          .put(
            Uri.parse(ApiConfig.settingsUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(settings.toJson()),
          )
          .timeout(_shortTimeout);

      if (response.statusCode == 200) {
        return AppSettings.fromJson(jsonDecode(response.body));
      }
      throw NetworkException('Failed to save settings', statusCode: response.statusCode);
    } catch (e) {
      throw NetworkException.fromError(e);
    }
  }

  Future<List<ExploreVideo>> searchExplore(String query, {int limit = 10}) async {
    try {
      final response = await _client
          .get(Uri.parse(
              '${ApiConfig.exploreSearchUrl}?q=${Uri.encodeComponent(query)}&limit=$limit'))
          .timeout(_mediumTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return (data['results'] as List)
            .map((v) => ExploreVideo.fromJson(v))
            .toList();
      }
      throw NetworkException('Search failed', statusCode: response.statusCode);
    } catch (e) {
      throw NetworkException.fromError(e);
    }
  }
}
