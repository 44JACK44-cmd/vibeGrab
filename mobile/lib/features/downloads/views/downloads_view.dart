import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_animations.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../data/models/download_task.dart';
import '../../../data/models/library_file.dart';
import '../../../services/media_engine.dart';
import '../controllers/downloads_controller.dart';
import '../widgets/download_card.dart';

class DownloadsView extends StatelessWidget {
  static const _appChannel = MethodChannel('com.example.vibegrab/app');
  static const _statusChannel = MethodChannel('com.example.vibegrab/status');

  final VoidCallback? onNavigateToAnalyze;

  const DownloadsView({super.key, this.onNavigateToAnalyze});

  String _mimeFor(DownloadTask task) {
    final ext = (task.fileExt ?? '').toLowerCase();
    if (task.hasVideo) {
      if (ext == 'webm') return 'video/webm';
      return 'video/mp4';
    }
    if (ext == 'opus' || ext == 'ogg') return 'audio/ogg';
    if (ext == 'wav') return 'audio/wav';
    if (ext == 'm4a' || ext == 'mp4') return 'audio/mp4';
    return 'audio/mpeg';
  }

  Future<void> _openFile(BuildContext context, DownloadTask task) async {
    final path = task.filePath;
    if (path == null || path.isEmpty) return;
    try {
      final ok = await _appChannel.invokeMethod<bool>(
          'openFile', {'path': path, 'mime': _mimeFor(task)});
      if (ok != true && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).openFileFailed)));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).openFileFailed)));
      }
    }
  }

  Future<void> _shareFile(BuildContext context, DownloadTask task) async {
    final path = task.filePath;
    if (path == null || path.isEmpty) return;
    try {
      await _statusChannel.invokeMethod('shareFile', {
        'path': path,
        'name': task.title,
        'mime': _mimeFor(task),
      });
    } catch (_) {}
  }

  /// Plays a finished download inside VibeGrab (same engine as everything).
  Future<void> _playInApp(BuildContext context, DownloadTask task) async {
    final path = task.filePath;
    if (path == null || path.isEmpty) return;
    final name = path.split(Platform.pathSeparator).last;
    final file = LibraryFile(
      filename: name,
      title: task.title.isNotEmpty ? task.title : name,
      filePath: path,
      fileSize: task.totalBytes ?? 0,
      fileSizeFormatted: task.sizeFormatted,
      fileType: task.hasVideo ? 'video' : 'audio',
      extension: task.fileExt ?? '',
      createdAt: task.createdAt,
      source: task.source,
      sourceType: 'downloaded',
    );
    if (!context.mounted) return;
    await context.read<MediaEngine>().playFile(file);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.downloadsTitle),
        actions: [
          Consumer<DownloadsController>(
            builder: (context, controller, _) {
              if (controller.tasks.isNotEmpty) {
                return IconButton(
                  icon: const Icon(Icons.delete_sweep),
                  tooltip: loc.clearCompleted,
                  onPressed: () {
                    controller.clearCompleted();
                  },
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
      body: Consumer<DownloadsController>(
        builder: (context, controller, _) {
          // Controllers have no BuildContext localization; keep the
          // notification fallback text in sync with the UI language.
          controller.unknownErrorFallback = loc.unknownError;
          if (controller.tasks.isEmpty) {
            return _buildEmpty(cs, loc, context);
          }

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: controller.tasks.length,
            itemBuilder: (context, index) {
              final task = controller.tasks[index];
              return DownloadCard(
                task: task,
                onCancel: () => controller.cancelTask(task.id),
                onRetry: () => controller.retryTask(task.id),
                onDelete: () => _confirmDelete(context, controller, task),
                onOpen: () => _openFile(context, task),
                onShare: () => _shareFile(context, task),
                onPlay: (task.hasVideo || task.hasAudio)
                    ? () => _playInApp(context, task)
                    : null,
              );
            },
          );
        },
      ),
    );
  }

  void _confirmDelete(BuildContext context, DownloadsController controller, DownloadTask task) {
    final loc = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.deleteConfirmTitle),
        content: Text(loc.deleteConfirmContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(loc.cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              controller.removeTask(task.id);
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: Text(loc.delete),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(ColorScheme cs, AppLocalizations loc, BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: FadeSlideIn(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.download_rounded, size: 40, color: cs.primary.withValues(alpha: 0.5)),
              ),
              const SizedBox(height: 24),
              Text(
                loc.noDownloads,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                loc.noDownloadsHint,
                style: TextStyle(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                  fontSize: 14,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              ElevatedButton.icon(
                onPressed: onNavigateToAnalyze,
                icon: const Icon(Icons.link, size: 18),
                label: Text(loc.navAnalyze),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(160, 44),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
