import 'dart:async';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

enum NotificationActionType { cancel, retry, openLibrary }

class NotificationAction {
  final NotificationActionType type;
  final String? taskId;
  const NotificationAction(this.type, [this.taskId]);
}

class DownloadNotificationService {
  static const _channel = MethodChannel('com.example.vibegrab/downloads');

  static final _instance = DownloadNotificationService._();
  factory DownloadNotificationService() => _instance;
  DownloadNotificationService._();

  final _actionController = StreamController<NotificationAction>.broadcast();
  Stream<NotificationAction> get onAction => _actionController.stream;

  bool _initialized = false;

  void init() {
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNotificationAction') {
        final args = call.arguments as Map;
        final action = args['action'] as String;
        final taskId = args['taskId'] as String?;
        switch (action) {
          case 'cancel':
            _actionController.add(NotificationAction(NotificationActionType.cancel, taskId));
          case 'retry':
            _actionController.add(NotificationAction(NotificationActionType.retry, taskId));
          case 'open':
            _actionController.add(const NotificationAction(NotificationActionType.openLibrary));
        }
      }
    });

    _checkPendingAction();
  }

  Future<void> _checkPendingAction() async {
    try {
      final result = await _channel.invokeMethod('getPendingNotificationAction');
      if (result != null) {
        final args = result as Map;
        final action = args['action'] as String;
        final taskId = args['taskId'] as String?;
        switch (action) {
          case 'cancel':
            _actionController.add(NotificationAction(NotificationActionType.cancel, taskId));
          case 'retry':
            _actionController.add(NotificationAction(NotificationActionType.retry, taskId));
          case 'open':
            _actionController.add(const NotificationAction(NotificationActionType.openLibrary));
        }
      }
    } catch (_) {}
  }

  Future<void> startService() async {
    try {
      await _channel.invokeMethod('startService');
    } catch (_) {}
  }

  Future<void> updateProgress({
    required String taskId,
    required String title,
    required double progress,
  }) async {
    try {
      await _channel.invokeMethod('updateNotification', {
        'taskId': taskId,
        'title': title,
        'progress': progress,
      });
    } catch (_) {}
  }

  Future<void> showCompleted({
    required String taskId,
    required String title,
  }) async {
    try {
      await _channel.invokeMethod('showCompleted', {
        'taskId': taskId,
        'title': title,
      });
    } catch (_) {}
  }

  Future<void> showFailed({
    required String taskId,
    required String title,
    required String error,
  }) async {
    try {
      await _channel.invokeMethod('showFailed', {
        'taskId': taskId,
        'title': title,
        'error': error,
      });
    } catch (_) {}
  }

  Future<void> stopService() async {
    try {
      await _channel.invokeMethod('stopService');
    } catch (_) {}
  }

  Future<bool> requestPermission() async {
    final status = await Permission.notification.status;
    if (status.isGranted) return true;
    final result = await Permission.notification.request();
    return result.isGranted;
  }

  void dispose() {
    _actionController.close();
  }
}
