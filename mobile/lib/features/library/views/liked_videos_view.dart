import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../data/models/liked_video.dart';
import '../../../services/media_engine.dart';
import '../../../services/media_metadata_service.dart';

/// "Videos que me gustan": remote Explorer/YouTube videos the user liked.
/// Kept separate from songs on purpose. Tapping a video opens the player.
class LikedVideosView extends StatelessWidget {
  const LikedVideosView({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(loc.likedVideosTitle)),
      body: Consumer<MediaMetadataService>(
        builder: (context, meta, _) {
          final videos = meta.likedVideoItems;
          if (videos.isEmpty) return _empty(loc, cs);
          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: videos.length,
            itemBuilder: (context, index) {
              final v = videos[index];
              return _LikedVideoTile(key: ValueKey('liked_${v.url}'), video: v);
            },
          );
        },
      ),
    );
  }

  Widget _empty(AppLocalizations loc, ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.favorite_border,
                size: 64, color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(
              loc.likedVideosEmpty,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

class _LikedVideoTile extends StatelessWidget {
  final LikedVideo video;

  const _LikedVideoTile({super.key, required this.video});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          final engine = context.read<MediaEngine>();
          engine.playUrl(
            video.url,
            title: video.title,
            artist: video.artist,
            thumbnail: video.thumbnail,
            isVideo: true,
          );
        },
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              _thumb(cs),
              const SizedBox(width: 12),
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
                    Text(
                      video.artist ?? '',
                      style: TextStyle(
                          color: cs.onSurfaceVariant, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _dateLabel(video.savedAt),
                      style: TextStyle(
                          color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                          fontSize: 11),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: loc.unlike,
                icon: const Icon(Icons.favorite,
                    size: 20, color: Colors.redAccent),
                onPressed: () => context
                    .read<MediaMetadataService>()
                    .removeLikedVideo(video.url),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thumb(ColorScheme cs) {
    if (video.thumbnail != null && video.thumbnail!.isNotEmpty) {
      return Container(
        width: 96,
        height: 60,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: cs.surfaceContainerHighest,
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.network(
          video.thumbnail!,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _thumbFallback(cs),
        ),
      );
    }
    return _thumbFallback(cs);
  }

  Widget _thumbFallback(ColorScheme cs) {
    return Container(
      width: 96,
      height: 60,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: cs.surfaceContainerHighest,
      ),
      child: Icon(Icons.videocam_outlined,
          color: cs.onSurfaceVariant, size: 28),
    );
  }

  String _dateLabel(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }
}

/// Compact horizontal card for a remote AUDIO like (Explorer songs).
class OnlineLikeCard extends StatelessWidget {
  final LikedVideo like;

  const OnlineLikeCard({super.key, required this.like});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 128,
      margin: const EdgeInsets.only(right: 8),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            context.read<MediaEngine>().playUrl(
                  like.url,
                  title: like.title,
                  artist: like.artist,
                  thumbnail: like.thumbnail,
                  isVideo: false,
                );
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (like.thumbnail != null && like.thumbnail!.isNotEmpty)
                      Image.network(
                        like.thumbnail!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                            color: cs.surfaceContainerHighest),
                      )
                    else
                      Container(color: cs.surfaceContainerHighest),
                    const Center(
                      child: Icon(Icons.play_circle_fill,
                          color: Colors.white70, size: 32),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                child: Text(
                  like.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Text(
                  like.artist ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: cs.onSurfaceVariant, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
