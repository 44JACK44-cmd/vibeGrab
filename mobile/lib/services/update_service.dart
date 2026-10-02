import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class UpdateInfo {
  final String versionName;
  final int buildNumber;
  final String notes;
  final String apkUrl;

  const UpdateInfo({
    required this.versionName,
    required this.buildNumber,
    required this.notes,
    required this.apkUrl,
  });
}

class UpdateService {
  static const _channel = MethodChannel('com.example.vibegrab/app');
  static const _releasesUrl =
      'https://api.github.com/repos/44JACK44-cmd/vibeGrab/releases/latest';
  static const _fallbackApkUrl =
      'https://github.com/44JACK44-cmd/vibeGrab/releases/latest/download/VibeGrab.apk';

  static Future<({String version, int build})> currentVersion() async {
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>('getVersion');
      final version = info?['version']?.toString() ?? '0.0.0';
      final build = int.tryParse('${info?['build']}') ?? 0;
      return (version: version, build: build);
    } catch (_) {
      return (version: '0.0.0', build: 0);
    }
  }

  static bool _isNewer(String remote, int remoteBuild, String local, int localBuild) {
    List<int> parts(String v) =>
        v.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final a = parts(remote);
    final b = parts(local);
    final len = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < len; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return remoteBuild > localBuild;
  }

  static Future<UpdateInfo?> checkForUpdate() async {
    final current = await currentVersion();
    final response = await http
        .get(
          Uri.parse(_releasesUrl),
          headers: {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'VibeGrab',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return null;

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final tag = ((data['tag_name'] as String?) ?? '').trim();
    final match = RegExp(r'^v(\d+)\.(\d+)\.(\d+)-(\d+)$').firstMatch(tag);
    if (match == null) return null;

    final remoteVersion = '${match[1]}.${match[2]}.${match[3]}';
    final remoteBuild = int.parse(match[4]!);
    if (!_isNewer(remoteVersion, remoteBuild, current.version, current.build)) {
      return null;
    }

    var apkUrl = _fallbackApkUrl;
    final assets = (data['assets'] as List<dynamic>?) ?? [];
    for (final asset in assets) {
      final name = '${(asset as Map)['name']}'.toLowerCase();
      if (name.endsWith('.apk')) {
        apkUrl = '${asset['browser_download_url']}';
        break;
      }
    }

    return UpdateInfo(
      versionName: remoteVersion,
      buildNumber: remoteBuild,
      notes: (data['body'] as String?) ?? '',
      apkUrl: apkUrl,
    );
  }

  static Future<String> download(
    UpdateInfo info,
    void Function(double progress) onProgress,
  ) async {
    final dir = await getApplicationSupportDirectory();
    final updateDir = Directory('${dir.path}/update');
    if (!updateDir.existsSync()) {
      updateDir.createSync(recursive: true);
    }
    final file = File('${updateDir.path}/VibeGrab.apk');
    if (file.existsSync()) file.deleteSync();

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(info.apkUrl));
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final total = response.contentLength ?? -1;
      var received = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            onProgress((received / total).clamp(0.0, 1.0));
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (total > 0 && received != total) {
        throw Exception('Incomplete download ($received/$total)');
      }
      return file.path;
    } finally {
      client.close();
    }
  }

  static Future<void> install(String path) =>
      _channel.invokeMethod('installApk', {'path': path});
}
