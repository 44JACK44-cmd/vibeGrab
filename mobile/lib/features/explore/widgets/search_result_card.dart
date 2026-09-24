import 'package:flutter/material.dart';
import '../../../data/models/explore_video.dart';

class SearchResultCard extends StatelessWidget {
  final ExploreVideo video;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;

  const SearchResultCard({super.key, required this.video, this.onTap, this.onPlay});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildThumbnail(cs),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
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
                            if (video.channel != null) ...[
                              Icon(Icons.person_outline, size: 14, color: cs.onSurfaceVariant),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  video.channel!,
                                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            if (video.viewCountFormatted.isNotEmpty)
                              Text(
                                video.viewCountFormatted,
                                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (onPlay != null)
                    IconButton(
                      icon: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: cs.primary,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.play_arrow, color: Colors.white, size: 20),
                      ),
                      onPressed: onPlay,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(ColorScheme cs) {
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
                    errorBuilder: (_, __, ___) => _buildPlaceholder(cs),
                  )
                : _buildPlaceholder(cs),
          ),
          if (video.durationFormatted.isNotEmpty)
            Positioned(
              bottom: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
