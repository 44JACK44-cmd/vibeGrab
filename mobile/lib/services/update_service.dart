import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
    // Se aceptan cuatro componentes por compatibilidad con tags antiguos
    // (v1.1.40.2-47). Para publicar usa siempre tres: las apps ya instaladas
    // y la web no detectan un tag de cuatro componentes.
    final match =
        RegExp(r'^v(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?-(\d+)$').firstMatch(tag);
    if (match == null) return null;

    final remoteVersion = match[4] == null
        ? '${match[1]}.${match[2]}.${match[3]}'
        : '${match[1]}.${match[2]}.${match[3]}.${match[4]}';
    final remoteBuild = int.parse(match[5]!);
    if (!_isNewer(remoteVersion, remoteBuild, current.version, current.build)) {
      return null;
    }

    // Un APK por ABI: el universal pesa cuatro veces mas y en una descarga
    // por movil se corta con facilidad. Se elige el de la arquitectura del
    // telefono y, si no existe, el universal.
    final assets = (data['assets'] as List<dynamic>?) ?? [];
    final phoneAbi = await deviceAbi();
    final apkUrl = pickApkUrl(assets, phoneAbi) ?? _fallbackApkUrl;

    return UpdateInfo(
      versionName: remoteVersion,
      buildNumber: remoteBuild,
      notes: (data['body'] as String?) ?? '',
      apkUrl: apkUrl,
    );
  }

  /// Downloads the APK of the release.
  ///
  /// The URL of a GitHub release asset answers with a 302 to the CDN, and
  /// `http.Client.send()` does NOT follow redirects (only `get`/`post` do).
  /// Without following them the download always failed with "HTTP 302" and
  /// the update could never be installed.
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
      var url = Uri.parse(info.apkUrl);
      http.StreamedResponse response;
      var redirects = 0;
      while (true) {
        final request = http.Request('GET', url)
          ..headers['User-Agent'] = 'VibeGrab';
        response = await client.send(request);
        final status = response.statusCode;
        if (status == 301 ||
            status == 302 ||
            status == 303 ||
            status == 307 ||
            status == 308) {
          final location = response.headers['location'];
          // The body of a redirect must be drained or the socket stays busy.
          await response.stream.drain<void>();
          if (location == null || location.isEmpty) {
            throw Exception('Redirect without location');
          }
          if (redirects >= 5) {
            throw Exception('Too many redirects');
          }
          url = url.resolve(location);
          redirects++;
          continue;
        }
        break;
      }

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

  /// True when the user already allowed this app to install packages.
  /// Android 8+ asks for that permission the first time an APK is opened.
  static Future<bool> canInstallPackages() async {
    try {
      final ok = await _channel.invokeMethod<bool>('canInstallPackages');
      return ok ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Primary ABI of the device (arm64-v8a, armeabi-v7a, x86_64...).
  /// Used to pick the smallest APK that the phone can install.
  static Future<String> deviceAbi() async {
    try {
      final abi = await _channel.invokeMethod<String>('getDeviceAbi');
      return abi ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Picks the APK to download out of the release assets: the one built for
  /// [deviceAbi] if the release has it, the universal one otherwise.
  @visibleForTesting
  static String? pickApkUrl(List<dynamic> assets, String deviceAbi) {
    String? universalUrl;
    final byAbi = <String, String>{};
    for (final asset in assets) {
      if (asset is! Map) continue;
      final name = '${asset['name']}'.toLowerCase();
      if (!name.endsWith('.apk')) continue;
      final url = '${asset['browser_download_url']}';
      if (name == 'vibegrab.apk') {
        universalUrl = url;
        continue;
      }
      final abi = RegExp(r'^vibegrab-(.+)\.apk$').firstMatch(name);
      if (abi != null) byAbi[abi.group(1)!] = url;
    }
    if (deviceAbi.isNotEmpty) {
      final exact = byAbi[deviceAbi];
      if (exact != null) return exact;
    }
    return universalUrl;
  }
}
