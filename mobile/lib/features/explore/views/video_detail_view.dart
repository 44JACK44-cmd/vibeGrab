import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../data/models/explore_video.dart';
import '../../../data/models/format_option.dart';
import '../../../data/models/download_task.dart';
import '../../../services/media_engine.dart';
import '../../../features/analyzer/controllers/analyze_controller.dart';
import '../../../features/downloads/controllers/downloads_controller.dart';
import '../../analyzer/widgets/format_selector.dart';

class VideoDetailView extends StatefulWidget {
  final ExploreVideo video;

  const VideoDetailView({super.key, required this.video});

  @override
  State<VideoDetailView> createState() => _VideoDetailViewState();
}

class _VideoDetailViewState extends State<VideoDetailView> {
  bool _showFormats = false;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final video = widget.video;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildVideoArea(cs),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          video.title,
                          style: TextStyle(
                            color: cs.onSurface,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            if (video.channel != null) ...[
                              Icon(Icons.person_outline, size: 16, color: cs.onSurfaceVariant),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  video.channel!,
                                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 12),
                            ],
                            if (video.viewCountFormatted.isNotEmpty)
                              Text(
                                video.viewCountFormatted,
                                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        _buildPlayButton(loc, cs),
                        const SizedBox(height: 8),
                        _buildDownloadButton(loc),
                        const SizedBox(height: 16),
                        if (_showFormats) _buildFormatSection(cs),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoArea(ColorScheme cs) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Hero(
          tag: 'explore_thumb_${widget.video.url}',
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: widget.video.thumbnail != null && widget.video.thumbnail!.isNotEmpty
                ? Image.network(
                    widget.video.thumbnail!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buildPlaceholder(cs),
                  )
                : _buildPlaceholder(cs),
          ),
        ),
        GestureDetector(
          onTap: () => _playVideo(context),
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.play_arrow, color: Colors.white, size: 40),
          ),
        ),
      ],
    );
  }

  Widget _buildPlaceholder(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: Icon(Icons.videocam, color: cs.onSurfaceVariant, size: 48),
      ),
    );
  }

  Widget _buildPlayButton(AppLocalizations loc, ColorScheme cs) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () => _playVideo(context),
        icon: const Icon(Icons.play_circle_outline, size: 20),
        label: Text('Play'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(double.infinity, 44),
          side: BorderSide(color: cs.primary),
          foregroundColor: cs.primary,
        ),
      ),
    );
  }

  void _playVideo(BuildContext context) {
    final engine = context.read<MediaEngine>();
    engine.playExploreVideo(widget.video);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Playing ${widget.video.title}'),
      backgroundColor: AppColors.success,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  Widget _buildDownloadButton(AppLocalizations loc) {
    return Consumer<AnalyzeController>(
      builder: (context, analyzeCtrl, _) {
        return SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: analyzeCtrl.isLoading ? null : () => _startAnalyze(),
            icon: analyzeCtrl.isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.download),
            label: Text(analyzeCtrl.isLoading ? loc.analyzing : loc.downloadVideo),
          ),
        );
      },
    );
  }

  Future<void> _startAnalyze() async {
    final analyzeCtrl = context.read<AnalyzeController>();
    await analyzeCtrl.analyze(widget.video.url);
    if (mounted && analyzeCtrl.result != null) {
      setState(() => _showFormats = true);
    }
  }

  Widget _buildFormatSection(ColorScheme cs) {
    return Consumer<AnalyzeController>(
      builder: (context, controller, _) {
        if (controller.result == null) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppLocalizations.of(context).formatAudio,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            FormatSelector(
              audioFormats: controller.audioFormats,
              videoFormats: controller.videoFormats,
              onSelected: (format) {
                _startDownload(format);
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _startDownload(FormatOption format) async {
    final downloadsCtrl = context.read<DownloadsController>();
    final video = widget.video;

    final task = DownloadTask(
      id: 'dl_${DateTime.now().millisecondsSinceEpoch}',
      url: video.url,
      title: video.title,
      formatId: format.id,
      thumbnail: video.thumbnail,
      source: video.channel,
      hasVideo: format.hasVideo,
      hasAudio: format.hasAudio,
      createdAt: DateTime.now().toIso8601String(),
    );

    downloadsCtrl.addTask(task);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context).downloadAdded(video.title)),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }
}
