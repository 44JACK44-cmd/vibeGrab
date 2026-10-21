import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../services/media_engine.dart';
import '../../../services/player_style_service.dart';
import '../../../data/models/explore_video.dart';
import '../../explore/views/video_detail_view.dart';
import '../views/audio_player_view.dart';
import '../views/video_fullscreen_view.dart';
import 'equalizer_sheet.dart';
import 'lyrics_sheet.dart';
import 'media_artwork.dart';
import 'player_backdrop.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: PlayerStyleService.instance,
      builder: (context, _) => _buildPlayer(context, cs),
    );
  }

  Widget _buildPlayer(BuildContext context, ColorScheme cs) {
    final style = PlayerStyleService.instance.style;

    return Consumer<MediaEngine>(
      builder: (context, engine, _) {
        // In PiP the system draws its own transport controls from the
        // media session; the in-app bar must not render inside the
        // floating window.
        final visible = engine.hasMedia && !engine.isInPiP;

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          transitionBuilder: (child, animation) {
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
              )),
              child: FadeTransition(
                opacity: animation,
                child: child,
              ),
            );
          },
          child: visible
              ? GestureDetector(
                  key: const ValueKey('mini_player'),
                  onTap: () => _openFullPlayer(context, engine),
                  child: Container(
                    height: 64,
                    decoration: BoxDecoration(
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 8,
                          offset: const Offset(0, -2),
                        ),
                      ],
                    ),
                    child: PlayerBackdrop(
                      style: style,
                      artworkPath: engine.currentThumbnailPath,
                      artworkUrl: engine.currentThumbnail,
                      child: Column(
                      children: [
                        _buildProgressBar(engine, cs),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(
                              children: [
                                _buildThumbnail(engine, cs),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        engine.currentTitle ?? '',
                                        style: TextStyle(
                                          color: cs.onSurface,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${engine.positionFormatted} / ${engine.durationFormatted}',
                                        style: TextStyle(
                                          color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (engine.queue.length > 1)
                                  IconButton(
                                    icon: const Icon(Icons.skip_previous, size: 24),
                                    color: cs.onSurface,
                                    onPressed: () => engine.skipToPrevious(),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                  ),
                                IconButton(
                                  icon: Icon(
                                    engine.isPlaying ? Icons.pause : Icons.play_arrow,
                                    color: cs.primary,
                                    size: 28,
                                  ),
                                  onPressed: () => engine.togglePlayPause(),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                ),
                                if (engine.queue.length > 1)
                                  IconButton(
                                    icon: const Icon(Icons.skip_next, size: 24),
                                    color: cs.onSurface,
                                    onPressed: () => engine.skipToNext(),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                  ),
                                const SizedBox(width: 4),
                                PopupMenuButton<String>(
                                  icon: Icon(Icons.more_vert,
                                      color: cs.onSurfaceVariant, size: 20),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  onSelected: (value) {
                                    if (value == 'equalizer') {
                                      showEqualizerSheet(context);
                                    } else if (value == 'lyrics') {
                                      showLyricsSheet(context);
                                    }
                                  },
                                  itemBuilder: (_) => [
                                    PopupMenuItem(
                                      value: 'equalizer',
                                      child: ListTile(
                                        dense: true,
                                        contentPadding: EdgeInsets.zero,
                                        leading: const Icon(Icons.equalizer,
                                            size: 20),
                                        title: Text(
                                            AppLocalizations.of(context)
                                                .equalizer),
                                      ),
                                    ),
                                    PopupMenuItem(
                                      value: 'lyrics',
                                      child: ListTile(
                                        dense: true,
                                        contentPadding: EdgeInsets.zero,
                                        leading: const Icon(Icons.lyrics_outlined,
                                            size: 20),
                                        title: Text(
                                            AppLocalizations.of(context)
                                                .lyrics),
                                      ),
                                    ),
                                  ],
                                ),
                                IconButton(
                                  icon: Icon(Icons.close, color: cs.onSurfaceVariant, size: 20),
                                  onPressed: () => engine.stop(),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(key: ValueKey('mini_player_empty')),
        );
      },
    );
  }

  Widget _buildProgressBar(MediaEngine engine, ColorScheme cs) {
    return SizedBox(
      height: 2,
      child: LinearProgressIndicator(
        value: engine.progress,
        backgroundColor: cs.surfaceContainerHighest,
      ),
    );
  }

  Widget _buildThumbnail(MediaEngine engine, ColorScheme cs) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: cs.surfaceContainerHighest,
      ),
      clipBehavior: Clip.antiAlias,
      child: mediaArtwork(engine, cs, iconSize: 20),
    );
  }

  /// Extracts the 11-char YouTube id for detail-page features.
  String _videoIdFromUrl(String url) {
    final match = RegExp(r'(?:v=|youtu\.be/|shorts/|embed/)([A-Za-z0-9_-]{11})')
        .firstMatch(url);
    return match?.group(1) ?? '';
  }

  void _openFullPlayer(BuildContext context, MediaEngine engine) {
    if (engine.currentMediaId == null) return;
    if (engine.isVideo) {
      final mediaId = engine.currentMediaId!;
      final isRemote = mediaId.startsWith('http://') ||
          mediaId.startsWith('https://');
      if (isRemote) {
        // YouTube-like: tapping opens the video page (with retry + error
        // state), not a bare fullscreen that gets stuck loading.
        final videoId = _videoIdFromUrl(mediaId);
        // Carry the engine's queue over so next/previous keep working after
        // reopening the page (every explore item is stored as its URL id).
        final items = engine.queue;
        final remoteQueue = items.isNotEmpty &&
                items.every((it) => it.id.startsWith('http'))
            ? items
                .map((it) => ExploreVideo(
                      id: _videoIdFromUrl(it.id),
                      title: it.title,
                      url: it.id,
                      thumbnail: it.artUri?.toString(),
                      channel: it.artist,
                      duration: it.duration?.inSeconds,
                    ))
                .toList()
            : null;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => VideoDetailView(
              video: ExploreVideo(
                id: videoId.isNotEmpty ? videoId : mediaId,
                title: engine.currentTitle ?? '',
                url: mediaId,
                thumbnail: engine.currentThumbnail,
                channel: engine.currentArtist,
                duration: engine.state.duration.inSeconds > 0
                    ? engine.state.duration.inSeconds
                    : null,
              ),
              queue: remoteQueue,
            ),
          ),
        );
        return;
      }
      Navigator.push(
        context,
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => ChangeNotifierProvider.value(
            value: engine,
            child: const VideoPlayerFullScreen(),
          ),
          transitionDuration: const Duration(milliseconds: 400),
          reverseTransitionDuration: const Duration(milliseconds: 300),
          transitionsBuilder: (_, animation, __, child) {
            final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
            return SlideTransition(
              position: Tween<Offset>(begin: const Offset(0, 0.1), end: Offset.zero).animate(curved),
              child: FadeTransition(
                opacity: CurvedAnimation(parent: animation, curve: const Interval(0.3, 1.0)),
                child: child,
              ),
            );
          },
        ),
      );
    } else {
      // Same full audio screen as the library: EQ, lyrics, queue and media
      // session controls live there. Opening it must not restart the song.
      openAudioPlayer(context);
    }
  }
}
