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
    // A payload that passes the APK sanity check: a ZIP header, a body and
    // the end of central directory record.
    final payload = <int>[
      0x50, 0x4B, 0x03, 0x04,
      ...List<int>.generate(500 * 1024, (i) => i % 256),
      0x50, 0x4B, 0x05, 0x06,
    ];
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

    test('the real versionCode of each APK is known', () {
      // Flutter builds the per-ABI APKs as abi * 1000 + build.
      expect(UpdateService.effectiveBuild('vibegrab.apk', 52), 52);
      expect(UpdateService.effectiveBuild('vibegrab-armeabi-v7a.apk', 52), 1052);
      expect(UpdateService.effectiveBuild('vibegrab-arm64-v8a.apk', 52), 2052);
      expect(UpdateService.effectiveBuild('vibegrab-x86_64.apk', 52), 3052);
      expect(UpdateService.effectiveBuild(null, 52), 52);
    });

    test('an installed APK por ABI is compared by the release build', () {
      // 2052 is build 51... 52 of the arm64 split, not "newer than 52".
      expect(UpdateService.tagBuild(52), 52);
      expect(UpdateService.tagBuild(1052), 52);
      expect(UpdateService.tagBuild(2052), 52);
      expect(UpdateService.tagBuild(3052), 52);
      // Un versionCode grande que no sea de un split no se toca.
      expect(UpdateService.tagBuild(5000), 5000);
    });
  });

  group('APK validation', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('vibegrab_apk_check');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    File write(String name, List<int> bytes) {
      final f = File('${dir.path}/$name');
      f.writeAsBytesSync(bytes);
      return f;
    }

    test('a real APK is accepted', () {
      final bytes = <int>[
        0x50, 0x4B, 0x03, 0x04,
        ...List.filled(500 * 1024, 0),
        0x50, 0x4B, 0x05, 0x06,
      ];
      expect(UpdateService.looksLikeApk(write('ok.apk', bytes)), isTrue);
    });

    test('a saved error page is rejected', () {
      const html = '<html><body>404 Not Found</body></html>';
      final bytes = List<int>.filled(400 * 1024, 0x20);
      final page = html.codeUnits;
      for (var i = 0; i < page.length; i++) {
        bytes[i] = page[i];
      }
      expect(UpdateService.looksLikeApk(write('error.apk', bytes)), isFalse);
    });

    test('a cut download is rejected even with a valid start', () {
      final bytes = <int>[
        0x50, 0x4B, 0x03, 0x04,
        ...List.filled(500 * 1024, 0),
      ];
      expect(UpdateService.looksLikeApk(write('cut.apk', bytes)), isFalse);
    });

    test('a tiny file is rejected', () {
      expect(
        UpdateService.looksLikeApk(
          write('tiny.apk', <int>[0x50, 0x4B, 0x03, 0x04, 0, 0]),
        ),
        isFalse,
      );
    });
  });
}
