import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_animations.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../data/models/format_option.dart';
import '../../../data/models/download_task.dart';
import '../../../features/downloads/controllers/downloads_controller.dart';
import '../../../services/media_engine.dart';
import '../../../data/models/library_file.dart';
import '../../../services/storage_service.dart';
import '../controllers/shared_download_controller.dart';

class SharedDownloadSheet extends StatefulWidget {
  const SharedDownloadSheet({super.key});

  static Future<void> show(BuildContext context, SharedDownloadController controller) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (_) => ChangeNotifierProvider.value(
        value: controller,
        child: const SharedDownloadSheet(),
      ),
    );
  }

  @override
  State<SharedDownloadSheet> createState() => _SharedDownloadSheetState();
}

class _SharedDownloadSheetState extends State<SharedDownloadSheet> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final loc = AppLocalizations.of(context);
    final controller = context.watch<SharedDownloadController>();

    return AnimatedContainer(
      duration: AppDurations.normal,
      curve: AppCurves.easeOut,
      child: DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.3,
        maxChildSize: 0.85,
        builder: (context, scrollController) {
          return Container(
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Column(
              children: [
                _buildDragHandle(cs),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                    children: [
                      _buildTitle(loc, cs),
                      const SizedBox(height: 16),
                      if (controller.isAnalyzing) _buildAnalyzing(loc, cs),
                      if (controller.isReady && controller.hasResult) ...[
                        _buildMediaInfo(controller, cs, loc),
                        const SizedBox(height: 20),
                        if (controller.audioFormats.isNotEmpty)
                          _buildFormatSection(loc, cs, controller, isAudio: true),
                        if (controller.videoFormats.isNotEmpty) ...[
                          if (controller.audioFormats.isNotEmpty) const SizedBox(height: 16),
                          _buildFormatSection(loc, cs, controller, isAudio: false),
                        ],
                        if (controller.allFormats.isEmpty)
                          _buildNoFormats(loc, cs),
                      ],
                      if (controller.status == SharedSheetStatus.error)
                        _buildError(loc, cs, controller),
                      if (controller.status == SharedSheetStatus.downloading)
                        _buildDownloading(loc, cs),
                      if (controller.status == SharedSheetStatus.completed)
                        _buildCompleted(loc, cs),
                    ],
                  ),
                ),
                if (controller.isReady && controller.selectedFormat != null)
                  _buildDownloadButton(loc, cs, controller),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildDragHandle(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: cs.onSurfaceVariant.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildTitle(AppLocalizations loc, ColorScheme cs) {
    return Text(
      loc.shareDownloadTitle,
      style: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: cs.onSurface,
      ),
    );
  }

  Widget _buildAnalyzing(AppLocalizations loc, ColorScheme cs) {
    return FadeSlideIn(
      child: Column(
        children: [
          const SizedBox(height: 20),
          const CircularProgressIndicator(strokeWidth: 3),
          const SizedBox(height: 16),
          Text(
            loc.shareAnalyzing,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
          ),
          const SizedBox(height: 20),
          ShimmerLoading(width: double.infinity, height: 100, borderRadius: 12),
          const SizedBox(height: 12),
          ShimmerLoading(width: double.infinity, height: 44, borderRadius: 10),
          const SizedBox(height: 8),
          ShimmerLoading(width: double.infinity, height: 44, borderRadius: 10),
        ],
      ),
    );
  }

  Widget _buildMediaInfo(SharedDownloadController controller, ColorScheme cs, AppLocalizations loc) {
    final media = controller.media;
    if (media == null) return const SizedBox.shrink();

    return FadeSlideIn(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (media.thumbnail != null && media.thumbnail!.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                media.thumbnail!,
                width: 120,
                height: 72,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildThumbnailPlaceholder(cs),
              ),
            )
          else
            _buildThumbnailPlaceholder(cs),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  media.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (media.uploader != null && media.uploader!.isNotEmpty) ...[
                      Icon(Icons.person_outline, size: 13, color: cs.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          media.uploader!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    if (media.duration != null && media.duration! > 0) ...[
                      Icon(Icons.access_time, size: 13, color: cs.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text(
                        media.durationFormatted,
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
                if (controller.platform != null && controller.platform != 'youtube')
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      controller.platform!,
                      style: TextStyle(fontSize: 11, color: cs.primary, fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThumbnailPlaceholder(ColorScheme cs) {
    return Container(
      width: 120,
      height: 72,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(Icons.play_circle_outline, color: cs.onSurfaceVariant.withValues(alpha: 0.5), size: 32),
    );
  }

  Widget _buildFormatSection(AppLocalizations loc, ColorScheme cs, SharedDownloadController controller, {required bool isAudio}) {
    final formats = isAudio ? controller.audioFormats : controller.videoFormats;
    final label = isAudio ? loc.shareAudio : loc.shareVideo;
    final color = isAudio ? cs.secondary : cs.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(width: 3, height: 14, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...formats.map((f) => _buildFormatTile(f, controller, cs)),
      ],
    );
  }

  Widget _buildFormatTile(FormatOption format, SharedDownloadController controller, ColorScheme cs) {
    final isSelected = controller.selectedFormat?.id == format.id;
    final isAudio = format.type == 'audio';
    final accent = isAudio ? cs.secondary : cs.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: isSelected
            ? accent.withValues(alpha: 0.1)
            : cs.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: isSelected ? accent : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: InkWell(
          onTap: () => controller.selectFormat(format),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: AppDurations.fast,
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected ? accent : cs.onSurfaceVariant.withValues(alpha: 0.4),
                      width: 2,
                    ),
                    color: isSelected ? accent : Colors.transparent,
                  ),
                  child: isSelected
                      ? const Icon(Icons.check, size: 14, color: Colors.white)
                      : null,
                ),
                const SizedBox(width: 12),
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    isAudio ? Icons.audiotrack_rounded : Icons.videocam_rounded,
                    color: accent,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _formatTitle(format),
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _formatSubtitle(format),
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatTitle(FormatOption format) {
    final ext = format.extension.toUpperCase();
    if (format.type == 'audio') return ext;
    final q = format.quality ?? ext;
    return '$ext $q';
  }

  String _formatSubtitle(FormatOption format) {
    if (format.type == 'audio') return format.quality ?? 'Audio';
    final parts = <String>['Video'];
    if (format.hasAudio) parts.add('Audio');
    if (!format.hasAudio) parts.add('Video only');
    return parts.join(' · ');
  }

  Widget _buildNoFormats(AppLocalizations loc, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        children: [
          Icon(Icons.info_outline, size: 32, color: cs.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(
            loc.shareNoFormats,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildError(AppLocalizations loc, ColorScheme cs, SharedDownloadController controller) {
    final errorKey = controller.error ?? 'analysis_failed';
    String message;
    switch (errorKey) {
      case 'configure_server':
        message = loc.shareConfigureServer;
        break;
      case 'server_unavailable':
        message = loc.shareServerUnavailable;
        break;
      case 'timeout':
        message = loc.shareTimeout;
        break;
      case 'no_internet':
        message = loc.shareNoInternet;
        break;
      case 'unsupported_platform':
        message = loc.shareUnsupportedPlatform;
        break;
      case 'content_unavailable':
        message = loc.shareContentUnavailable;
        break;
      case 'analysis_failed':
        message = loc.shareAnalysisFailed;
        break;
      default:
        message = errorKey;
    }

    return FadeSlideIn(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: cs.error.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.error_outline, size: 32, color: cs.error),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              style: TextStyle(color: cs.onSurface, fontSize: 14, fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () {
                if (controller.url != null) {
                  controller.analyzeUrl(controller.url!);
                }
              },
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(loc.shareRetry),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(140, 44),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloading(AppLocalizations loc, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          const CircularProgressIndicator(strokeWidth: 3),
          const SizedBox(height: 16),
          Text(
            loc.sharePreparingDownload,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildCompleted(AppLocalizations loc, ColorScheme cs) {
    return FadeSlideIn(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_outline, size: 32, color: Colors.green),
            ),
            const SizedBox(height: 16),
            Text(
              loc.shareDownloadStarted,
              style: TextStyle(color: cs.onSurface, fontSize: 14, fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadButton(AppLocalizations loc, ColorScheme cs, SharedDownloadController controller) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton(
            onPressed: controller.isDownloading ? null : () => _startDownload(controller, loc),
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            child: controller.isDownloading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                  )
                : Text(loc.shareDownload),
          ),
        ),
      ),
    );
  }

  void _startDownload(SharedDownloadController controller, AppLocalizations loc) async {
    if (controller.isDownloading) return;
    if (controller.selectedFormat == null || controller.url == null) return;

    final downloadsController = context.read<DownloadsController>();
    final format = controller.selectedFormat!;
    final media = controller.media;

    controller.setDownloading();

    final task = DownloadTask(
      id: 'dl_${DateTime.now().millisecondsSinceEpoch}',
      url: controller.url!,
      title: media?.title ?? 'Untitled',
      formatId: format.id,
      thumbnail: media?.thumbnail,
      source: media?.source,
      hasVideo: format.hasVideo,
      hasAudio: format.hasAudio,
      directUrl: format.directUrl,
      fileExt: format.extension,
      totalBytes: format.sizeBytes,
      mediaType: format.type == 'audio' ? DownloadMediaType.audio : DownloadMediaType.video,
      createdAt: DateTime.now().toIso8601String(),
    );

    downloadsController.addTask(task);

    controller.setCompleted();

    Future.delayed(const Duration(seconds: 2), () {
      if (context.mounted) {
        Navigator.of(context).pop();
        controller.reset();
      }
    });
  }
}
