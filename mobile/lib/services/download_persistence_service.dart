import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/models/download_task.dart';

class DownloadPersistenceService {
  static const _key = 'vibegrab_download_tasks';
  static const _maxTasks = 200;

  Future<List<DownloadTask>> loadTasks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return [];
      final List<dynamic> decoded = jsonDecode(raw);
      return decoded.map((e) => DownloadTask.fromJson(Map<String, dynamic>.from(e))).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveTasks(List<DownloadTask> tasks) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final toSave = tasks.length > _maxTasks ? tasks.sublist(0, _maxTasks) : tasks;
      final encoded = jsonEncode(toSave.map((t) => t.toJson()).toList());
      await prefs.setString(_key, encoded);
    } catch (_) {}
  }

  Future<void> saveTask(DownloadTask task) async {
    final tasks = await loadTasks();
    final idx = tasks.indexWhere((t) => t.id == task.id);
    if (idx != -1) {
      tasks[idx] = task;
    } else {
      tasks.insert(0, task);
    }
    await saveTasks(tasks);
  }

  Future<void> removeTask(String taskId) async {
    final tasks = await loadTasks();
    tasks.removeWhere((t) => t.id == taskId);
    await saveTasks(tasks);
  }

  Future<void> clearCompleted() async {
    final tasks = await loadTasks();
    tasks.removeWhere((t) => t.status == DownloadStatus.completed || t.status == DownloadStatus.cancelled);
    await saveTasks(tasks);
  }
}
