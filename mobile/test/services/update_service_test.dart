import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/services/update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late HttpServer server;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('vibegrab_update_svc');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    // The app asks the device which ABI it is to pick the smallest APK.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.example.vibegrab/app'),
      (call) async {
        if (call.method == 'getDeviceAbi') return 'arm64-v8a';
        if (call.method == 'getVersion') {
          return {'version': '1.1.42', 'build': 50};
        }
        return null;
      },
    );

    // The test binding replaces every HttpClient with one that answers 400.
    // The download has to reach a real (local) server to be tested.
    HttpOverrides.global = null;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await server.close(force: true);
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('the download follows the redirect of the release asset', () async {
    final payload = List<int>.generate(4096, (i) => i % 256);
    server.listen((request) async {
      if (request.uri.path == '/redirect') {
        // This is what GitHub answers for a release asset.
        request.response
          ..statusCode = 302
          ..headers.set('location', '/apk')
          ..close();
        return;
      }
      request.response
        ..statusCode = 200
        ..headers.contentLength = payload.length
        ..add(payload)
        ..close();
    });

    final progress = <double>[];
    final path = await UpdateService.download(
      UpdateInfo(
        versionName: '1.1.42',
        buildNumber: 49,
        notes: '',
        apkUrl: 'http://${server.address.address}:${server.port}/redirect',
      ),
      progress.add,
    );

    final file = File(path);
    expect(file.existsSync(), isTrue);
    expect(file.readAsBytesSync(), payload);
    expect(progress, isNotEmpty);
    expect(progress.last, closeTo(1.0, 0.001));
  });

  test('a failed download is reported instead of leaving a broken file',
      () async {
    server.listen((request) async {
      request.response.statusCode = 404;
      await request.response.close();
    });

    var failed = false;
    try {
      await UpdateService.download(
        UpdateInfo(
          versionName: '1.1.42',
          buildNumber: 49,
          notes: '',
          apkUrl: 'http://${server.address.address}:${server.port}/missing.apk',
        ),
        (_) {},
      );
    } catch (_) {
      failed = true;
    }
    expect(failed, isTrue);
  });

  group('asset selection', () {
    final assets = <dynamic>[
      {
        'name': 'VibeGrab.apk',
        'browser_download_url': 'https://x/VibeGrab.apk',
      },
      {
        'name': 'VibeGrab-arm64-v8a.apk',
        'browser_download_url': 'https://x/VibeGrab-arm64-v8a.apk',
      },
      {
        'name': 'VibeGrab-armeabi-v7a.apk',
        'browser_download_url': 'https://x/VibeGrab-armeabi-v7a.apk',
      },
      {
        'name': 'SHA256SUMS.txt',
        'browser_download_url': 'https://x/SHA256SUMS.txt',
      },
    ];

    test('the APK of the device architecture is chosen', () {
      expect(
        UpdateService.pickApkUrl(assets, 'arm64-v8a'),
        'https://x/VibeGrab-arm64-v8a.apk',
      );
      expect(
        UpdateService.pickApkUrl(assets, 'armeabi-v7a'),
        'https://x/VibeGrab-armeabi-v7a.apk',
      );
    });

    test('an unknown architecture falls back to the universal APK', () {
      expect(
        UpdateService.pickApkUrl(assets, 'x86_64'),
        'https://x/VibeGrab.apk',
      );
      expect(UpdateService.pickApkUrl(assets, ''), 'https://x/VibeGrab.apk');
    });

    test('a release without a universal APK still works', () {
      final onlyAbi = <dynamic>[
        {
          'name': 'VibeGrab-arm64-v8a.apk',
          'browser_download_url': 'https://x/VibeGrab-arm64-v8a.apk',
        },
      ];
      expect(
        UpdateService.pickApkUrl(onlyAbi, 'x86_64'),
        isNull,
      );
      expect(
        UpdateService.pickApkUrl(onlyAbi, 'arm64-v8a'),
        'https://x/VibeGrab-arm64-v8a.apk',
      );
    });
  });
}
