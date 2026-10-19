import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/localization/app_localizations.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/download_task.dart';
import '../controllers/downloads_controller.dart';

/// Compact floating progress panel shown once a download has been queued
/// from the format sheet (Snaptube-style flow).
///
/// It lives in the app shell above the tab content, so dismissing the sheet
/// never hides a running download. The panel is a pure view over
/// [DownloadsController]: it performs no work, starts no timers and holds no
/// state of its own beyond which tasks it is following and whether the user
/// closed it. Closing it only hides the UI, the queue keeps running.
class DownloadQueuePanel extends StatefulWidget {
  const DownloadQueuePanel({
    super.key,
    required this.onOpenDownloads,
    this.visible = true,
  });

  /// Opens the existing downloads screen.
  final VoidCallback onOpenDownloads;

  /// False while the downloads screen is open: that screen already lists
  /// every task, so the floating panel would only duplicate it.
  final bool visible;

  @override
  State<DownloadQueuePanel> createState() => _DownloadQueuePanelState();
}

/// Statuses for which the download is still being worked on. A download that
/// enters one of them is picked up by the panel even if the user closed it.
const Set<DownloadStatus> kLiveDownloadStatuses = {
  DownloadStatus.queued,
  DownloadStatus.preparing,
  DownloadStatus.resolving,
  DownloadStatus.connecting,
  DownloadStatus.downloading,
  DownloadStatus.saving,
  DownloadStatus.processing,
  DownloadStatus.paused,
};

class _DownloadQueuePanelState extends State<DownloadQueuePanel> {
  late final DownloadsController _downloads;

  /// Tasks the panel follows. They are kept until the user closes the panel,
  /// so a finished download keeps its result visible instead of vanishing.
  final Set<String> _tracked = <String>{};
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _downloads = context.read<DownloadsController>();
    _downloads.addListener(_trackActive);
    _trackActive();
  }

  @override
  void dispose() {
    _downloads.removeListener(_trackActive);
    super.dispose();
  }

  /// Picks up every download that reaches a live state. Starting a new
  /// download always brings the panel back, even after the user closed it.
  void _trackActive() {
    var added = false;
    for (final task in _downloads.tasks) {
      if (kLiveDownloadStatuses.contains(task.status) &&
          _tracked.add(task.id)) {
        added = true;
        _dismissed = false;
      }
    }
    if (added && mounted) setState(() {});
  }

  List<DownloadTask> _shown() {
    final out = <DownloadTask>[];
    for (final task in _downloads.tasks) {
      if (_tracked.contains(task.id)) out.add(task);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible || _dismissed) return const SizedBox.shrink();

    final shown = _shown();
    if (shown.isEmpty) return const SizedBox.shrink();

    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Material(
          color: cs.surfaceContainerHigh,
          elevation: 6,
          shadowColor: Colors.black.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final task in shown.take(3)) ...[
                  _DownloadRow(task: task, loc: loc, cs: cs),
                  const SizedBox(height: 10),
                ],
                if (shown.length > 3)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        loc.downloadQueueMore(shown.length - 3),
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  ),
                Row(
                  children: [
                    Icon(Icons.download_for_offline_outlined,
                        size: 16, color: cs.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        loc.navDownloads,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: widget.onOpenDownloads,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 36),
                      ),
                      child: Text(loc.viewDownloads),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: loc.close,
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _dismissed = true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DownloadRow extends StatelessWidget {
  const _DownloadRow({
    required this.task,
    required this.loc,
    required this.cs,
  });

  final DownloadTask task;
  final AppLocalizations loc;
  final ColorScheme cs;

  /// Byte progress is only reported while data is actually moving. For the
  /// states without byte progress the bar stays indeterminate instead of
  /// inventing a percentage.
  double? get _barValue {
    switch (task.status) {
      case DownloadStatus.downloading:
      case DownloadStatus.paused:
      case DownloadStatus.failed:
      case DownloadStatus.cancelled:
        return task.progress.clamp(0.0, 1.0);
      case DownloadStatus.completed:
        return 1.0;
      default:
        return null;
    }
  }

  Color get _statusColor {
    switch (task.status) {
      case DownloadStatus.completed:
        return AppColors.success;
      case DownloadStatus.failed:
        return AppColors.error;
      case DownloadStatus.cancelled:
        return cs.onSurfaceVariant;
      case DownloadStatus.queued:
        return AppColors.warning;
      default:
        return cs.primary;
    }
  }

  String _statusText() {
    switch (task.status) {
      case DownloadStatus.queued:
        return loc.statusQueued;
      case DownloadStatus.preparing:
        return task.step ?? loc.downloadStepPreparing;
      case DownloadStatus.resolving:
        return task.step ?? loc.statusResolving;
      case DownloadStatus.connecting:
        return task.step ?? loc.statusConnecting;
      case DownloadStatus.downloading:
        return '${task.progressFormatted}  ${task.speedFormatted}';
      case DownloadStatus.processing:
        return task.step ?? loc.statusMerging;
      case DownloadStatus.saving:
        return task.step ?? loc.statusSaving;
      case DownloadStatus.completed:
        return loc.statusCompleted;
      case DownloadStatus.failed:
        final retryText =
            task.retryCount > 0 ? loc.statusRetrying('${task.retryCount}') : '';
        return '${loc.localizedDownloadError(task.errorCode?.name)}$retryText';
      case DownloadStatus.cancelled:
        return loc.statusCancelled;
      case DownloadStatus.paused:
        return loc.statusPaused;
    }
  }

  @override
  Widget build(BuildContext context) {
    final thumb = task.thumbnail;
    final icon = task.mediaType == DownloadMediaType.audio
        ? Icons.music_note
        : Icons.movie_outlined;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: thumb == null || thumb.isEmpty
                  ? Container(
                      width: 34,
                      height: 34,
                      color: cs.surfaceContainerHighest,
                      child: Icon(icon, size: 18, color: cs.onSurfaceVariant),
                    )
                  : Image.network(
                      thumb,
                      width: 34,
                      height: 34,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 34,
                        height: 34,
                        color: cs.surfaceContainerHighest,
                        child:
                            Icon(icon, size: 18, color: cs.onSurfaceVariant),
                      ),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _statusText(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: _statusColor),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: _barValue,
            minHeight: 4,
            color: _statusColor,
            backgroundColor: cs.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }
}
