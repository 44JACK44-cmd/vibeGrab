import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../services/media_engine.dart';
import '../../../data/models/library_file.dart';
import '../../../data/models/media_state.dart';
import '../widgets/equalizer_sheet.dart';
import '../widgets/lyrics_sheet.dart';
import '../widgets/play_mode_button.dart';

class AudioPlayerView extends StatefulWidget {
  final LibraryFile file;

  const AudioPlayerView({super.key, required this.file});

  @override
  State<AudioPlayerView> createState() => _AudioPlayerViewState();
}

class _AudioPlayerViewState extends State<AudioPlayerView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<MediaEngine>().playFile(widget.file);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.file.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.queue_music),
            onPressed: () => _showQueueSheet(context),
          ),
        ],
      ),
  body: Consumer<MediaEngine>(
        builder: (context, engine, _) {
        // PiP window: minimal artwork + title only. The system renders
        // play/pause/prev/next itself from the media session.
        if (engine.isInPiP) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.music_note,
                      size: 56, color: cs.primary),
                  const SizedBox(height: 12),
                  Text(
                    engine.currentTitle ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 15,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          );
        }
        return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              children: [
                const Spacer(flex: 2),
                _buildCoverArt(cs),
                const Spacer(),
                _buildFileInfo(cs),
                const Spacer(),
                _buildProgress(engine),
                const SizedBox(height: 8),
                _buildTimeLabels(engine, cs),
                const Spacer(),
                _buildControls(context, cs, engine),
                const Spacer(flex: 2),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildCoverArt(ColorScheme cs) {
    return Consumer<MediaEngine>(
      builder: (context, engine, _) {
        final thumbnailPath = engine.currentThumbnailPath;
        final thumbnail = widget.file.thumbnail ?? engine.currentThumbnail;
        return Container(
          width: 240,
          height: 240,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: cs.surfaceContainerHighest,
            boxShadow: [
              BoxShadow(
                color: cs.primary.withValues(alpha: 0.15),
                blurRadius: 30,
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
    return Column(
      children: [
        Text(
          widget.file.title,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: cs.onSurface,
          ),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (widget.file.source != null) ...[
          const SizedBox(height: 6),
          Text(
            widget.file.source!,
            style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant.withValues(alpha: 0.7)),
          ),
        ],
      ],
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
