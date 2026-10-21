import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibegrab/services/download_notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.example.vibegrab/downloads');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  test('the terminal notification asks for an auto-dismiss timeout', () async {
    final service = DownloadNotificationService();
    await service.showCompleted(taskId: 'task-1', title: 'Song');

    expect(calls, hasLength(1));
    expect(calls.first.method, 'showCompleted');
    final args = calls.first.arguments as Map;
    expect(args['taskId'], 'task-1');
    expect(args['timeoutMs'], 10000);
  });

  test('a failure notification carries the timeout too', () async {
    final service = DownloadNotificationService();
    await service.showFailed(
        taskId: 'task-2', title: 'Song', error: 'network');

    expect(calls.first.method, 'showFailed');
    final args = calls.first.arguments as Map;
    expect(args['error'], 'network');
    expect(args['timeoutMs'], 10000);
  });

  test('the timeout is never below the ten second minimum', () async {
    final service = DownloadNotificationService();
    await service.showCompleted(
      taskId: 'task-3',
      title: 'Song',
      timeout: const Duration(seconds: 2),
    );

    final args = calls.first.arguments as Map;
    expect(args['timeoutMs'], 10000);
  });

  test('a longer timeout is honoured', () async {
    final service = DownloadNotificationService();
    await service.showCompleted(
      taskId: 'task-4',
      title: 'Song',
      timeout: const Duration(seconds: 45),
    );

    final args = calls.first.arguments as Map;
    expect(args['timeoutMs'], 45000);
  });

  test('progress updates do not carry a dismissal timeout', () async {
    final service = DownloadNotificationService();
    await service.updateProgress(
        taskId: 'task-5', title: 'Song', progress: 0.5);

    expect(calls.first.method, 'updateNotification');
    final args = calls.first.arguments as Map;
    expect(args.containsKey('timeoutMs'), isFalse);
  });
}
