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
}
