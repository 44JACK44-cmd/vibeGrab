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

  /// Flutter builds the per-ABI APKs with `versionCode = abi * 1000 + build`
  /// (armeabi-v7a = 1, arm64-v8a = 2, x86_64 = 3) while the universal APK
  /// keeps `versionCode = build`.
  static const Map<String, int> _abiOrder = {
    'armeabi-v7a': 1,
    'arm64-v8a': 2,
    'x86_64': 3,
  };

  /// Build number of the release that produced an installed `versionCode`.
  ///
  /// Strips the ABI offset of the per-ABI APKs (`abi * 1000 + build`, abi in
  /// 1..3, so the value stays below 4000 while the build numbers are in the
  /// hundreds). The universal APK keeps its build. Without this, a phone with
  /// an APK por ABI veia la MISMA version como mas nueva y se le ofrecia una
  /// actualizacion que solo cambiaba el empaquetado.
  static int tagBuild(int versionCode) {
    if (versionCode >= 1000 && versionCode < 4000) {
      return versionCode % 1000;
    }
    return versionCode;
  }

  /// Real `versionCode` of an APK of this release.
  static int effectiveBuild(String? assetName, int build) {
    if (assetName == null) return build;
    final abi = RegExp(r'^vibegrab-(.+)\.apk$')
        .firstMatch(assetName.toLowerCase())
        ?.group(1);
    final index = abi == null ? null : _abiOrder[abi];
    return index == null ? build : index * 1000 + build;
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

    // Un APK por ABI: el universal pesa cuatro veces mas y en una descarga
    // por movil se corta con facilidad. Se elige el de la arquitectura del
    // telefono y, si no existe, el universal.
    final assets = (data['assets'] as List<dynamic>?) ?? [];
    final phoneAbi = await deviceAbi();
    final picked = pickApk(assets, phoneAbi);
    final apkUrl = picked?.url ?? _fallbackApkUrl;

    // Se compara el numero de build del tag, no el versionCode bruto: los
    // APK por ABI llevan `abi * 1000 + build`, asi que compararlos contra el
    // tag hacia que la MISMA version pareciese nueva solo por el empaquetado
    // y la app ofrecia "actualizar" a lo que ya tenia instalado.
    final installedBuild = tagBuild(current.build);
    if (!_isNewer(remoteVersion, remoteBuild, current.version, installedBuild)) {
      return null;
    }

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
      // El servidor puede contestar 200 con una pagina de error (proxy,
      // portal cautivo, redireccion rota). Entregar eso al instalador acaba
      // en "el paquete no parece valido", asi que se comprueba antes.
      if (!looksLikeApk(file)) {
        try {
          file.deleteSync();
        } catch (_) {
          // Si no se puede borrar, el siguiente intento lo sobrescribe.
        }
        throw Exception('Downloaded file is not a valid APK');
      }
      return file.path;
    } finally {
      client.close();
    }
  }

  static Future<void> install(String path) =>
      _channel.invokeMethod('installApk', {'path': path});

  /// An APK is a ZIP that starts with `PK\x03\x04` and ends with the central
  /// directory record (`PK\x05\x06`). Checking both catches a saved error page
  /// and a cut download (the second one even when the server did not announce
  /// the length).
  @visibleForTesting
  static bool looksLikeApk(File file) {
    try {
      final length = file.lengthSync();
      // Ningun APK real baja de unos cientos de KB.
      if (length < 400 * 1024) return false;
      final raf = file.openSync();
      try {
        final head = raf.readSync(4);
        if (head.length < 4 || head[0] != 0x50 || head[1] != 0x4B) {
          return false;
        }
        final tailSize = length < 65536 ? length : 65536;
        raf.setPositionSync(length - tailSize);
        final tail = raf.readSync(tailSize);
        for (var i = 0; i + 3 < tail.length; i++) {
          if (tail[i] == 0x50 &&
              tail[i + 1] == 0x4B &&
              tail[i + 2] == 0x05 &&
              tail[i + 3] == 0x06) {
            return true;
          }
        }
        return false;
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return false;
    }
  }

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
  static String? pickApkUrl(List<dynamic> assets, String deviceAbi) =>
      pickApk(assets, deviceAbi)?.url;

  /// Same as [pickApkUrl] but also returns the file name, needed to know the
  /// real `versionCode` of the chosen APK.
  @visibleForTesting
  static ({String name, String url})? pickApk(
      List<dynamic> assets, String deviceAbi) {
    ({String name, String url})? universal;
    final byAbi = <String, ({String name, String url})>{};
    for (final asset in assets) {
      if (asset is! Map) continue;
      final name = '${asset['name']}'.toLowerCase();
      if (!name.endsWith('.apk')) continue;
      final url = '${asset['browser_download_url']}';
      if (name == 'vibegrab.apk') {
        universal = (name: name, url: url);
        continue;
      }
      final abi = RegExp(r'^vibegrab-(.+)\.apk$').firstMatch(name);
      if (abi != null) byAbi[abi.group(1)!] = (name: name, url: url);
    }
    if (deviceAbi.isNotEmpty) {
      final exact = byAbi[deviceAbi];
      if (exact != null) return exact;
    }
    return universal;
  }
}
