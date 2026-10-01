import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../../../services/media_engine.dart';
import '../../../data/models/library_file.dart';

class VideoPlayerView extends StatefulWidget {
  final LibraryFile file;

  const VideoPlayerView({super.key, required this.file});

  @override
  State<VideoPlayerView> createState() => _VideoPlayerViewState();
}

class _VideoPlayerViewState extends State<VideoPlayerView> {
  bool _showControls = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<MediaEngine>().playFile(widget.file);
      _startHideTimer();
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && context.read<MediaEngine>().isPlaying) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _startHideTimer();
  }

  void _toggleFullscreen() {
    if (_showControls) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    }
    setState(() => _showControls = !_showControls);
    if (_showControls) _startHideTimer();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Consumer<MediaEngine>(
        builder: (context, engine, _) {
          return GestureDetector(
            onTap: _toggleControls,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (engine.videoController != null &&
                    engine.videoController!.value.isInitialized)
                  Center(
                    child: AspectRatio(
                      aspectRatio: engine.videoController!.value.aspectRatio,
                      child: VideoPlayer(engine.videoController!),
                    ),
                  )
                else
                  const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                AnimatedOpacity(
                  opacity: _showControls ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 250),
                  child: IgnorePointer(
                    ignoring: !_showControls,
                    child: _buildOverlay(engine),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildOverlay(MediaEngine engine) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent, Colors.transparent, Colors.black54],
          stops: [0, 0.2, 0.8, 1],
        ),
      ),
      child: Column(
        children: [
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Text(
                      widget.file.title,
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.picture_in_picture_alt, color: Colors.white),
                    onPressed: () async {
                      final available = await engine.isPiPAvailable();
                      final entered = available && await engine.enterPiP();
                      if (!entered && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('PiP not available on this device')),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          _buildControls(engine),
          const Spacer(),
          _buildBottomBar(engine),
        ],
      ),
    );
  }

  Widget _buildControls(MediaEngine engine) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (engine.queue.length > 1)
          IconButton(
            icon: Icon(Icons.skip_previous, color: engine.hasPrevious ? Colors.white : Colors.white30, size: 32),
            onPressed: engine.hasPrevious ? () => engine.skipToPrevious() : null,
          ),
        if (engine.queue.length > 1) const SizedBox(width: 12),
        IconButton(
          icon: const Icon(Icons.replay_10, color: Colors.white, size: 32),
          onPressed: () {
            final newPos = engine.position - const Duration(seconds: 10);
            engine.seek(newPos.isNegative ? Duration.zero : newPos);
          },
        ),
        const SizedBox(width: 24),
        Container(
          decoration: const BoxDecoration(
            color: Colors.white24,
            shape: BoxShape.circle,
          ),
          child: IconButton(
            icon: Icon(
              engine.isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
              size: 48,
            ),
            onPressed: () {
              if (engine.isPlaying) {
                engine.pause();
              } else if (engine.state.isPaused) {
                engine.resume();
              } else {
                engine.playFile(widget.file);
              }
              _startHideTimer();
            },
          ),
        ),
        const SizedBox(width: 24),
        IconButton(
          icon: const Icon(Icons.forward_30, color: Colors.white, size: 32),
          onPressed: () {
            final newPos = engine.position + const Duration(seconds: 30);
            engine.seek(newPos > engine.duration ? engine.duration : newPos);
          },
        ),
        if (engine.queue.length > 1) const SizedBox(width: 12),
        if (engine.queue.length > 1)
          IconButton(
            icon: Icon(Icons.skip_next, color: engine.hasNext ? Colors.white : Colors.white30, size: 32),
            onPressed: engine.hasNext ? () => engine.skipToNext() : null,
          ),
      ],
    );
  }

  Widget _buildBottomBar(MediaEngine engine) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: engine.progress,
              onChanged: (v) => engine.seekProgress(v),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                engine.positionFormatted,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              IconButton(
                icon: const Icon(Icons.fullscreen, color: Colors.white, size: 22),
                onPressed: _toggleFullscreen,
              ),
              Text(
                engine.durationFormatted,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
