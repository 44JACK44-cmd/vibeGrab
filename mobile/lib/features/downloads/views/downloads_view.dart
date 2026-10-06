import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_animations.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../data/models/download_task.dart';
import '../controllers/downloads_controller.dart';
import '../widgets/download_card.dart';

class DownloadsView extends StatelessWidget {
  final VoidCallback? onNavigateToAnalyze;

  const DownloadsView({super.key, this.onNavigateToAnalyze});

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
