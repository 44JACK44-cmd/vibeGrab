import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../../../services/media_engine.dart';
import '../../../data/models/media_state.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Consumer<MediaEngine>(
      builder: (context, engine, _) {
        final visible = engine.hasMedia;

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
                      color: cs.surface,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 8,
                          offset: const Offset(0, -2),
                        ),
                      ],
                    ),
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
    final thumbPath = engine.currentThumbnailPath;
    final thumb = engine.currentThumbnail;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: cs.surfaceContainerHighest,
      ),
      clipBehavior: Clip.antiAlias,
      child: thumbPath != null && thumbPath.isNotEmpty && File(thumbPath).existsSync()
          ? Image.file(File(thumbPath), fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Icon(
                engine.isVideo ? Icons.videocam : Icons.music_note,
                size: 20, color: cs.onSurfaceVariant,
              ))
          : (thumb != null && thumb.isNotEmpty
              ? (thumb.startsWith('http')
                  ? Image.network(thumb, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Icon(
                        engine.isVideo ? Icons.videocam : Icons.music_note,
                        size: 20, color: cs.onSurfaceVariant,
                      ))
                  : Image.file(File(thumb), fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Icon(
                        engine.isVideo ? Icons.videocam : Icons.music_note,
                        size: 20, color: cs.onSurfaceVariant,
                      )))
              : Icon(
                  engine.isVideo ? Icons.videocam : Icons.music_note,
                  size: 20, color: cs.onSurfaceVariant,
                )),
    );
  }

  void _openFullPlayer(BuildContext context, MediaEngine engine) {
    if (engine.currentMediaId == null) return;
    if (engine.isVideo) {
      Navigator.push(
        context,
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => ChangeNotifierProvider.value(
            value: engine,
            child: const _VideoPlayerFullScreen(),
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
      Navigator.push(
        context,
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => ChangeNotifierProvider.value(
            value: engine,
            child: const _AudioPlayerFullScreen(),
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
    }
  }
}

class _VideoPlayerFullScreen extends StatelessWidget {
  const _VideoPlayerFullScreen();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Consumer<MediaEngine>(
        builder: (context, engine, _) {
          return Column(
            children: [
              Expanded(
                child: engine.videoController != null && engine.videoController!.value.isInitialized
                    ? Center(
                        child: AspectRatio(
                          aspectRatio: engine.videoController!.value.aspectRatio,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              VideoPlayer(engine.videoController!),
                              GestureDetector(
                                onTap: () => engine.togglePlayPause(),
                                child: AnimatedOpacity(
                                  opacity: engine.isPlaying ? 0.0 : 1.0,
                                  duration: const Duration(milliseconds: 200),
                                  child: Container(
                                    width: 72, height: 72,
                                    decoration: const BoxDecoration(
                                      color: Colors.black45,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      engine.isPlaying ? Icons.pause : Icons.play_arrow,
                                      color: Colors.white, size: 48,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : const Center(child: CircularProgressIndicator(color: Colors.white)),
              ),
              Container(
                color: cs.surface,
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      engine.currentTitle ?? '',
                      style: TextStyle(color: cs.onSurface, fontSize: 16, fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Slider(
                      value: engine.progress,
                      onChanged: (v) => engine.seekProgress(v),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(engine.positionFormatted, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
                        Text(engine.durationFormatted, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: Icon(Icons.replay_10, color: cs.onSurface, size: 28),
                          onPressed: () => engine.skipBackward(const Duration(seconds: 10)),
                        ),
                        if (engine.queue.length > 1)
                          IconButton(
                            icon: Icon(Icons.skip_previous, color: cs.onSurface, size: 28),
                            onPressed: () => engine.skipToPrevious(),
                          ),
                        const SizedBox(width: 12),
                        Container(
                          width: 56, height: 56,
                          decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
                          child: IconButton(
                            icon: Icon(engine.isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 32),
                            onPressed: () => engine.togglePlayPause(),
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (engine.queue.length > 1)
                          IconButton(
                            icon: Icon(Icons.skip_next, color: cs.onSurface, size: 28),
                            onPressed: () => engine.skipToNext(),
                          ),
                        IconButton(
                          icon: Icon(Icons.forward_30, color: cs.onSurface, size: 28),
                          onPressed: () => engine.skipForward(const Duration(seconds: 30)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AudioPlayerFullScreen extends StatelessWidget {
  const _AudioPlayerFullScreen();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Consumer<MediaEngine>(
          builder: (_, engine, __) => Text(
            engine.currentTitle ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.repeat),
            onPressed: () => context.read<MediaEngine>().toggleRepeat(),
          ),
          IconButton(
            icon: const Icon(Icons.queue_music),
            onPressed: () => _showQueueSheet(context),
          ),
        ],
      ),
      body: Consumer<MediaEngine>(
        builder: (context, engine, _) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              children: [
                const Spacer(flex: 2),
                Container(
                  width: 240, height: 240,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: cs.surfaceContainerHighest,
                    boxShadow: [BoxShadow(color: cs.primary.withValues(alpha: 0.15), blurRadius: 30, offset: const Offset(0, 10))],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: (() {
                    final tp = engine.currentThumbnailPath;
                    final t = engine.currentThumbnail;
                    if (tp != null && tp.isNotEmpty && File(tp).existsSync()) {
                      return Image.file(File(tp), fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Icon(Icons.music_note, size: 80, color: cs.onSurfaceVariant));
                    } else if (t != null && t.isNotEmpty) {
                      return Image.network(t, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Icon(Icons.music_note, size: 80, color: cs.onSurfaceVariant));
                    }
                    return Icon(Icons.music_note, size: 80, color: cs.onSurfaceVariant);
                  })(),
                ),
                const Spacer(),
                Text(engine.currentTitle ?? '', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: cs.onSurface),
                  textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (engine.currentArtist != null) ...[
                  const SizedBox(height: 6),
                  Text(engine.currentArtist!, style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant.withValues(alpha: 0.7))),
                ],
                const Spacer(),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 16)),
                  child: Slider(value: engine.progress, onChanged: (v) => engine.seekProgress(v)),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text(engine.positionFormatted, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant.withValues(alpha: 0.7))),
                    Text(engine.durationFormatted, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant.withValues(alpha: 0.7))),
                  ]),
                ),
                const Spacer(),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
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
                  Container(width: 72, height: 72, decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
                    child: IconButton(
                      icon: Icon(engine.isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 42),
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
                  IconButton(
                    icon: Icon(
                      engine.state.repeatMode == PlayerRepeatMode.none
                          ? Icons.repeat
                          : engine.state.repeatMode == PlayerRepeatMode.one
                              ? Icons.repeat_one
                              : Icons.repeat,
                      color: engine.state.repeatMode != PlayerRepeatMode.none ? cs.primary : cs.onSurface,
                    ),
                    onPressed: () => engine.toggleRepeat(),
                  ),
                ]),
                const Spacer(flex: 2),
              ],
            ),
          );
        },
      ),
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
                    Text('Queue', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: cs.onSurface)),
                    const SizedBox(width: 8),
                    Text('(${engine.queue.length})', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14)),
                    const Spacer(),
                    TextButton(
                      onPressed: () => engine.clearQueue(),
                      child: Text('Clear', style: TextStyle(color: cs.error)),
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
                      subtitle: Text(item.artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
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
