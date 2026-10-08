import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../data/models/explore_video.dart';
import '../../../services/media_engine.dart';

class SearchResultCard extends StatelessWidget {
  final ExploreVideo video;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;

  /// Opens the download/analyzer flow for this video (optional).
  final VoidCallback? onDownload;

  const SearchResultCard({
    super.key,
    required this.video,
    this.onTap,
    this.onPlay,
    this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final loc = AppLocalizations.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildThumbnail(cs, loc),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          video.title,
                          style: TextStyle(
                            color: cs.onSurface,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            if (video.channel != null &&
                                video.channel!.isNotEmpty) ...[
                              Icon(Icons.person_outline,
                                  size: 14, color: cs.onSurfaceVariant),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  video.channel!,
                                  style:
                                      TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              _dot(cs),
                            ],
                            if (video.viewCountLocalized(loc).isNotEmpty)
                              Text(
                                video.viewCountLocalized(loc),
                                style: TextStyle(
                                    color: cs.onSurfaceVariant, fontSize: 12),
                              ),
                            if (video.age != null && video.age!.isNotEmpty) ...[
                              _dot(cs),
                              Text(
                                video.age!,
                                style: TextStyle(
                                    color: cs.onSurfaceVariant, fontSize: 12),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  _LikeButton(video),
                  if (onPlay != null)
                    IconButton(
                      icon: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: cs.primary,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.play_arrow,
                            color: Colors.white, size: 20),
                      ),
                      onPressed: onPlay,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                  _menu(context, loc, cs),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dot(ColorScheme cs) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text('•',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
      );

  Widget _menu(BuildContext context, AppLocalizations loc, ColorScheme cs) {
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, size: 20, color: cs.onSurfaceVariant),
      padding: EdgeInsets.zero,
      onSelected: (value) async {
        switch (value) {
          case 'queue':
            context.read<MediaEngine>().addToQueueExplore(video);
            _snack(context, loc.addedToQueue);
            break;
          case 'copy':
            await Clipboard.setData(ClipboardData(text: video.url));
            _snack(context, loc.linkCopied);
            break;
          case 'download':
            if (onDownload != null) onDownload!();
            break;
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'queue',
          child: Row(
            children: [
              const Icon(Icons.queue_music, size: 18),
              const SizedBox(width: 10),
              Text(loc.queue),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'copy',
          child: Row(
            children: [
              const Icon(Icons.link, size: 18),
              const SizedBox(width: 10),
              Text(loc.copyLink),
            ],
          ),
        ),
        if (onDownload != null)
          PopupMenuItem(
            value: 'download',
            child: Row(
              children: [
                const Icon(Icons.download_outlined, size: 18),
                const SizedBox(width: 10),
                Text(loc.downloadVideo),
              ],
            ),
          ),
      ],
    );
  }

  void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Widget _buildThumbnail(ColorScheme cs, AppLocalizations loc) {
    return Hero(
      tag: 'explore_thumb_${video.url}',
      child: Stack(
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: video.thumbnail != null && video.thumbnail!.isNotEmpty
                ? Image.network(
                    video.thumbnail!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => _buildPlaceholder(cs),
                  )
                : _buildPlaceholder(cs),
          ),
          if (video.durationFormatted.isNotEmpty)
            Positioned(
              bottom: 8,
              right: 8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  video.durationFormatted,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          if (!video.isYouTube)
            Positioned(
              top: 8,
              left: 8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.public, size: 11, color: Colors.white),
                    const SizedBox(width: 4),
                    Text(
                      video.provider,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (video.hasResume)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 3,
                    color: Colors.black.withValues(alpha: 0.4),
                    alignment: Alignment.centerLeft,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final progress = video.duration != null &&
                                video.duration! > 0
                            ? (video.resumeMs! / 1000 / video.duration!)
                                .clamp(0.0, 1.0)
                            : 0.0;
                        return Container(
                          width: constraints.maxWidth * progress,
                          height: 3,
                          color: Colors.redAccent,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
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
}

/// Heart icon that subscribes ONLY to its own like state, so a like tap
/// (or any MediaEngine position tick) rebuilds this icon and never the
/// whole card — this was the source of the thumbnail flicker.
class _LikeButton extends StatelessWidget {
  const _LikeButton(this.video);

  final ExploreVideo video;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final loc = AppLocalizations.of(context);
    final liked = context.select<MediaEngine, bool>(
      (engine) => engine.isRemoteLiked(video.url),
    );
    return IconButton(
      icon: Icon(
        liked ? Icons.favorite : Icons.favorite_border,
        size: 20,
        color: liked ? Colors.redAccent : cs.onSurfaceVariant,
      ),
      tooltip: loc.likedVideosTitle,
      onPressed: () => context.read<MediaEngine>().toggleRemoteLike(
            url: video.url,
            title: video.title,
            artist: video.channel,
            thumbnail: video.thumbnail,
            isVideo: true,
          ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
    );
  }
}
