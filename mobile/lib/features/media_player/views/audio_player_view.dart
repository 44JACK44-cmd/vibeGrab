import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../core/theme/player_style.dart';
import '../../../services/media_engine.dart';
import '../../../services/player_style_service.dart';
import '../../../data/models/library_file.dart';
import '../widgets/equalizer_sheet.dart';
import '../widgets/lyrics_sheet.dart';
import '../widgets/play_mode_button.dart';
import '../widgets/player_backdrop.dart';

/// Opens the full audio player. The engine is the source of truth, so the
/// mini player can open the same screen without restarting the song.
void openAudioPlayer(BuildContext context, {LibraryFile? file}) {
  Navigator.push(
    context,
    PageRouteBuilder(
      pageBuilder: (_, __, ___) => AudioPlayerView(file: file),
      transitionDuration: const Duration(milliseconds: 400),
      reverseTransitionDuration: const Duration(milliseconds: 300),
      transitionsBuilder: (_, animation, __, child) {
        final curved =
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return SlideTransition(
          position:
              Tween<Offset>(begin: const Offset(0, 0.1), end: Offset.zero)
                  .animate(curved),
          child: FadeTransition(
            opacity: CurvedAnimation(
                parent: animation, curve: const Interval(0.3, 1.0)),
            child: child,
          ),
        );
      },
    ),
  );
}

class AudioPlayerView extends StatefulWidget {
  /// Only set when this screen starts a new song. Opening it from the mini
  /// player leaves it null so the current playback is not restarted.
  final LibraryFile? file;

  const AudioPlayerView({super.key, this.file});

  @override
  State<AudioPlayerView> createState() => _AudioPlayerViewState();
}

class _AudioPlayerViewState extends State<AudioPlayerView> {
  @override
  void initState() {
    super.initState();
    final file = widget.file;
    if (file == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<MediaEngine>().playFile(file);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: PlayerStyleService.instance,
      builder: (context, _) {
        final style = PlayerStyleService.instance.style;
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Consumer<MediaEngine>(
            builder: (context, engine, _) {
              // PiP window: minimal artwork + title only. The system renders
              // play/pause/prev/next itself from the media session. The
              // backdrop is black like the video window: a floating media
              // window must never paint the light page background.
              if (engine.isInPiP) {
                return Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.music_note,
                            size: 56, color: Colors.white70),
                        const SizedBox(height: 12),
                        Text(
                          engine.currentTitle ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                );
              }
              return Stack(
                children: [
                  Positioned.fill(
                    child: PlayerBackdrop(
                      style: style,
                      artworkPath: engine.currentThumbnailPath,
                      artworkUrl: engine.currentThumbnail,
                      child: const SizedBox.shrink(),
                    ),
                  ),
                  SafeArea(
                    child: Column(
                      children: [
                        _buildHeader(context, engine),
                        Expanded(
                          child: _buildContent(context, engine, style),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, MediaEngine engine) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              engine.currentTitle ?? widget.file?.title ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.queue_music),
            onPressed: () => _showQueueSheet(context),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(
      BuildContext context, MediaEngine engine, PlayerStyle style) {
    final cs = Theme.of(context).colorScheme;
    final compact = style == PlayerStyle.compact;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 20 : 32),
      child: Column(
        children: [
          if (!compact) const Spacer(flex: 2),
          _buildCoverArt(cs, style),
          if (!compact) const Spacer(),
          _buildFileInfo(cs),
          if (!compact) const Spacer(),
          _buildProgress(engine),
          const SizedBox(height: 8),
          _buildTimeLabels(engine, cs),
          const Spacer(),
          _buildControls(context, cs, engine),
          if (!compact) const Spacer(flex: 2),
        ],
      ),
    );
  }

  Widget _buildCoverArt(ColorScheme cs, PlayerStyle style) {
    final compact = style == PlayerStyle.compact;
    final immersive = style == PlayerStyle.immersive;
    final size = compact ? 96.0 : (immersive ? 280.0 : 240.0);
    return Consumer<MediaEngine>(
      builder: (context, engine, _) {
        final thumbnailPath = engine.currentThumbnailPath;
        final thumbnail = engine.currentThumbnail ?? widget.file?.thumbnail;
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius:
                immersive ? BorderRadius.circular(size / 2) : BorderRadius.circular(16),
            color: cs.surfaceContainerHighest,
            boxShadow: [
              BoxShadow(
                color: cs.primary.withValues(alpha: immersive ? 0.28 : 0.15),
                blurRadius: immersive ? 48 : 30,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: thumbnailPath != null && thumbnailPath.isNotEmpty && File(thumbnailPath).existsSync()
              ? Image.file(File(thumbnailPath), fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _buildDefaultCover(cs))
              : (thumbnail != null && thumbnail.isNotEmpty
                  ? (thumbnail.startsWith('http')
                      ? Image.network(thumbnail, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _buildDefaultCover(cs))
                      : Image.file(File(thumbnail), fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _buildDefaultCover(cs)))
                  : _buildDefaultCover(cs)),
        );
      },
    );
  }

  Widget _buildDefaultCover(ColorScheme cs) {
    return Center(
      child: Icon(Icons.music_note, size: 80, color: cs.onSurfaceVariant),
    );
  }

  Widget _buildFileInfo(ColorScheme cs) {
    return Consumer<MediaEngine>(
      builder: (context, engine, _) {
        final artist = engine.currentArtist ?? widget.file?.source;
        return Column(
          children: [
            Text(
              engine.currentTitle ?? widget.file?.title ?? '',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: cs.onSurface,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (artist != null && artist.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                artist,
                style: TextStyle(
                    fontSize: 14,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7)),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildProgress(MediaEngine engine) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      ),
      child: Slider(
        value: engine.progress,
        onChanged: (v) => engine.seekProgress(v),
      ),
    );
  }

  Widget _buildTimeLabels(MediaEngine engine, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            engine.positionFormatted,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant.withValues(alpha: 0.7)),
          ),
          Text(
            engine.durationFormatted,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant.withValues(alpha: 0.7)),
          ),
        ],
      ),
    );
  }

  Widget _buildControls(
      BuildContext context, ColorScheme cs, MediaEngine engine) {
    final loc = AppLocalizations.of(context);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: Icon(
                engine.state.isShuffle ? Icons.shuffle : Icons.shuffle,
                color: engine.state.isShuffle ? cs.primary : cs.onSurface,
              ),
              onPressed: () => engine.toggleShuffle(),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.skip_previous, size: 32),
              color: cs.onSurface,
              onPressed: () => engine.skipToPrevious(),
            ),
            const SizedBox(width: 12),
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: cs.primary,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: Icon(
                  engine.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                  size: 42,
                ),
                onPressed: () => engine.togglePlayPause(),
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              icon: const Icon(Icons.skip_next, size: 32),
              color: cs.onSurface,
              onPressed: () => engine.skipToNext(),
            ),
            const SizedBox(width: 8),
            const PlayModeButton(),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.replay_10, size: 28),
              color: cs.onSurface,
              onPressed: () => engine.skipBackward(const Duration(seconds: 10)),
            ),
            IconButton(
              tooltip: loc.like,
              icon: Icon(
                engine.isCurrentFavorite
                    ? Icons.favorite
                    : Icons.favorite_border,
                size: 26,
                color: engine.isCurrentFavorite
                    ? cs.error
                    : cs.onSurface,
              ),
              onPressed: () => engine.toggleFavoriteCurrent(),
            ),
            IconButton(
              tooltip: loc.equalizer,
              icon: const Icon(Icons.equalizer, size: 26),
              color: cs.onSurface,
              onPressed: () => showEqualizerSheet(context),
            ),
            IconButton(
              tooltip: loc.lyrics,
              icon: const Icon(Icons.lyrics_outlined, size: 26),
              color: cs.onSurface,
              onPressed: () => showLyricsSheet(context),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.forward_30, size: 28),
              color: cs.onSurface,
              onPressed: () => engine.skipForward(const Duration(seconds: 30)),
            ),
          ],
        ),
      ],
    );
  }

  void _showQueueSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<MediaEngine>(),
        child: _QueueSheet(),
      ),
    );
  }
}

class _QueueSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final loc = AppLocalizations.of(context);
    return Consumer<MediaEngine>(
      builder: (context, engine, _) {
        return Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Text(loc.queue, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: cs.onSurface)),
                    const SizedBox(width: 8),
                    Text('(${engine.queue.length})', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14)),
                    const Spacer(),
                    TextButton(
                      onPressed: () => engine.clearQueue(),
                      child: Text(loc.clearQueue, style: TextStyle(color: cs.error)),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: engine.queue.length,
                  itemBuilder: (context, index) {
                    final item = engine.queue[index];
                    final isCurrent = index == engine.currentIndex;
                    return ListTile(
                      leading: Container(
                        width: 40, height: 40,
                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), color: cs.surfaceContainerHighest),
                        clipBehavior: Clip.antiAlias,
                        child: item.artUri != null
                            ? Image.network(item.artUri!.toString(), fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Icon(Icons.music_note, size: 18, color: cs.onSurfaceVariant))
                            : Icon(Icons.music_note, size: 18, color: cs.onSurfaceVariant),
                      ),
                      title: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCurrent ? cs.primary : cs.onSurface,
                          fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                      trailing: IconButton(
                        icon: Icon(Icons.close, size: 18, color: cs.onSurfaceVariant),
                        onPressed: () => engine.removeFromQueue(index),
                      ),
                      onTap: () => engine.skipToIndex(index),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
