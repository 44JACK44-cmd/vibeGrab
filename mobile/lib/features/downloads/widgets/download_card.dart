import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_animations.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../data/models/download_task.dart';

class DownloadCard extends StatefulWidget {
  final DownloadTask task;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;
  final VoidCallback? onDelete;
  final VoidCallback? onOpen;
  final VoidCallback? onShare;

  const DownloadCard(
      {super.key,
      required this.task,
      this.onCancel,
      this.onRetry,
      this.onDelete,
      this.onOpen,
      this.onShare});

  @override
  State<DownloadCard> createState() => _DownloadCardState();
}

class _DownloadCardState extends State<DownloadCard> with SingleTickerProviderStateMixin {
  late AnimationController _progressController;
  Animation<double>? _progressAnim;

  @override
  void initState() {
    super.initState();
    _progressController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _updateProgress();
  }

  @override
  void didUpdateWidget(DownloadCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.task.progress != oldWidget.task.progress) {
      _updateProgress();
    }
  }

  void _updateProgress() {
    final target = widget.task.progress;
    _progressAnim = Tween<double>(
      begin: _progressAnim?.value ?? 0.0,
      end: target,
    ).animate(CurvedAnimation(parent: _progressController, curve: AppCurves.easeOut));
    _progressController.forward(from: 0.0);
  }

  @override
  void dispose() {
    _progressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final task = widget.task;

    final isActive = task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.preparing ||
        task.status == DownloadStatus.resolving ||
        task.status == DownloadStatus.connecting ||
        task.status == DownloadStatus.saving ||
        task.status == DownloadStatus.queued ||
        task.status == DownloadStatus.processing;

    Color statusColor;
    IconData statusIcon;
    String statusText;

    switch (task.status) {
      case DownloadStatus.queued:
        statusColor = AppColors.warning;
        statusIcon = Icons.hourglass_empty;
        statusText = loc.statusQueued;
        break;
      case DownloadStatus.preparing:
        statusColor = cs.primary;
        statusIcon = Icons.sync;
        statusText = task.step ?? loc.downloadStepPreparing;
        break;
      case DownloadStatus.resolving:
        statusColor = cs.primary;
        statusIcon = Icons.sync;
        statusText = task.step ?? loc.statusResolving;
        break;
      case DownloadStatus.connecting:
        statusColor = cs.primary;
        statusIcon = Icons.sync;
        statusText = task.step ?? loc.statusConnecting;
        break;
      case DownloadStatus.downloading:
        statusColor = cs.primary;
        statusIcon = Icons.download;
        final eta = task.etaFormatted;
        statusText = '${task.progressFormatted}  ${task.speedFormatted}'
            '${eta.isNotEmpty ? '  •  ${loc.timeLeft(eta)}' : ''}';
        break;
      case DownloadStatus.processing:
        statusColor = cs.secondary;
        statusIcon = Icons.build;
        statusText = task.step ?? loc.statusMerging;
        break;
      case DownloadStatus.saving:
        statusColor = cs.primary;
        statusIcon = Icons.save;
        statusText = task.step ?? loc.statusSaving;
        break;
      case DownloadStatus.completed:
        statusColor = AppColors.success;
        statusIcon = Icons.check_circle;
        statusText = '${loc.statusCompleted}${task.sizeFormatted.isNotEmpty ? ' \u2022 ${task.sizeFormatted}' : ''}';
        break;
      case DownloadStatus.failed:
        statusColor = AppColors.error;
        statusIcon = Icons.error_outline;
        final retryText = task.retryCount > 0 ? loc.statusRetrying('${task.retryCount}') : '';
        statusText = '${loc.localizedDownloadError(task.errorCode?.name)}$retryText';
        break;
      case DownloadStatus.cancelled:
        statusColor = cs.onSurfaceVariant;
        statusIcon = Icons.cancel_outlined;
        statusText = loc.statusCancelled;
        break;
      case DownloadStatus.paused:
        statusColor = AppColors.warning;
        statusIcon = Icons.pause_circle_outline;
        statusText = loc.statusPaused;
        break;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildThumbnail(cs),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                      fontSize: 14,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(statusIcon, size: 14, color: statusColor),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          statusText,
                          style: TextStyle(color: statusColor, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  if (isActive) ...[
                    const SizedBox(height: 8),
                    _buildAnimatedProgress(cs),
                  ],
                  if (task.status == DownloadStatus.completed) ...[
                    const SizedBox(height: 8),
                    _buildCompletedBar(cs),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            _buildAction(loc, cs),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(ColorScheme cs) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: widget.task.thumbnail != null
          ? Image.network(
              widget.task.thumbnail!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Icon(Icons.play_circle_outline, color: cs.onSurfaceVariant, size: 24),
            )
          : Icon(Icons.play_circle_outline, color: cs.onSurfaceVariant, size: 24),
    );
  }

  Widget _buildAnimatedProgress(ColorScheme cs) {
    return AnimatedBuilder(
      animation: _progressController,
      builder: (context, _) {
        final value = _progressAnim?.value ?? 0.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: value,
                minHeight: 4,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${widget.task.sizeFormatted.isNotEmpty ? '${widget.task.sizeFormatted} \u2022 ' : ''}${widget.task.progress}%',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCompletedBar(ColorScheme cs) {
    return Container(
      height: 4,
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: AppColors.success,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    );
  }

  Widget _buildAction(AppLocalizations loc, ColorScheme cs) {
    if (widget.task.status == DownloadStatus.downloading ||
        widget.task.status == DownloadStatus.preparing ||
        widget.task.status == DownloadStatus.resolving ||
        widget.task.status == DownloadStatus.connecting ||
        widget.task.status == DownloadStatus.saving ||
        widget.task.status == DownloadStatus.processing ||
        widget.task.status == DownloadStatus.queued) {
      return IconButton(
        icon: const Icon(Icons.close, size: 20),
        onPressed: widget.onCancel,
        color: cs.onSurfaceVariant,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      );
    }

    if (widget.task.status == DownloadStatus.failed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: widget.onRetry,
            color: cs.primary,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: widget.onDelete,
            color: AppColors.error,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      );
    }

if (widget.task.status == DownloadStatus.completed ||
    widget.task.status == DownloadStatus.cancelled) {
  final completed = widget.task.status == DownloadStatus.completed;
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (completed && widget.onOpen != null)
        IconButton(
          icon: const Icon(Icons.open_in_new, size: 20),
          onPressed: widget.onOpen,
          color: cs.primary,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      if (completed && widget.onOpen != null) const SizedBox(width: 8),
      if (completed && widget.onShare != null)
        IconButton(
          icon: const Icon(Icons.share_outlined, size: 20),
          onPressed: widget.onShare,
          color: cs.onSurfaceVariant,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      if (completed && widget.onShare != null) const SizedBox(width: 8),
      IconButton(
        icon: Icon(
          completed ? Icons.delete_outline : Icons.cancel_outlined,
          size: 20,
        ),
        onPressed: widget.onDelete,
        color: completed ? AppColors.error : cs.onSurfaceVariant,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      ),
    ],
  );
}

    return const SizedBox.shrink();
  }
}
