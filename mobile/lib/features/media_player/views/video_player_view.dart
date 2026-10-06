import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../services/display_service.dart';
import '../../../services/media_engine.dart';
import '../../../data/models/library_file.dart';
import '../widgets/mini_player.dart' show VideoPlayerFullScreen;
import '../widgets/video_controls_controller.dart';
import '../widgets/video_controls_overlay.dart';

class VideoPlayerView extends StatefulWidget {
  final LibraryFile file;

  const VideoPlayerView({super.key, required this.file});

  @override
  State<VideoPlayerView> createState() => _VideoPlayerViewState();
}

class _VideoPlayerViewState extends State<VideoPlayerView> {
  late final VideoControlsController _controls;
  bool _dragH = false;
  bool _dragV = false;
  bool _dragLeft = true;
  double _accDx = 0;
  double _accDy = 0;
  double _baseBright = 0.5;
  double _baseVol = 1.0;
  Duration _seekBase = Duration.zero;

  @override
  void initState() {
    super.initState();
    _controls = VideoControlsController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<MediaEngine>().playFile(widget.file);
      _controls.canHide = () => context.read<MediaEngine>().isPlaying;
      _controls.show();
    });
  }

  @override
  void dispose() {
    _controls.dispose();
    DisplayService.resetBrightness();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Duration _clampedSeek(MediaEngine engine, Duration target) {
    if (target < Duration.zero) return Duration.zero;
    if (target > engine.duration) return engine.duration;
    return target;
  }

  void _openFullscreen() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const VideoPlayerFullScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Consumer<MediaEngine>(
        builder: (context, engine, _) {
          final vc = engine.videoController;
          final ready =
              vc != null && vc.value.isInitialized && !vc.value.hasError;
          return Stack(
            fit: StackFit.expand,
            children: [
              if (ready)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _controls.toggle,
                    onDoubleTap: () {
                      final target = _clampedSeek(engine,
                          engine.position + const Duration(seconds: 10));
                      engine.seek(target);
                      _controls.flashHint(
                          '+10s  ${_fmt(target)}', Icons.forward_10);
                      _controls.poke();
                    },
                    onHorizontalDragStart: (_) {
                      _dragH = true;
                      _accDx = 0;
                      _seekBase = engine.position;
                    },
                    onHorizontalDragUpdate: (d) {
                      if (!_dragH) return;
                      _accDx += d.delta.dx;
                      final target = _clampedSeek(
                          engine,
                          _seekBase +
                              Duration(seconds: (_accDx / 8).round()));
                      _controls.flashHint(_fmt(target), Icons.fast_forward);
                    },
                    onHorizontalDragEnd: (_) {
                      if (!_dragH) return;
                      _dragH = false;
                      final target = _clampedSeek(
                          engine,
                          _seekBase +
                              Duration(seconds: (_accDx / 8).round()));
                      engine.seek(target);
                      _controls.clearHint();
                      _controls.show();
                    },
                    onVerticalDragStart: (d) async {
                      _dragV = true;
                      _accDy = 0;
                      _dragLeft = d.globalPosition.dx <
                          MediaQuery.of(context).size.width / 2;
                      if (_dragLeft) {
                        final b = await DisplayService.brightness();
                        _baseBright = b < 0 ? 0.5 : b;
                      } else {
                        _baseVol = engine.videoVolume;
                      }
                    },
                    onVerticalDragUpdate: (d) {
                      if (!_dragV) return;
                      _accDy += d.delta.dy;
                      if (_dragLeft) {
                        final v =
                            (_baseBright - _accDy / 400).clamp(0.05, 1.0);
                        DisplayService.setBrightness(v);
                        _controls.flashHint(
                            '${(v * 100).round()}%', Icons.brightness_6);
                      } else {
                        final v =
                            (_baseVol - _accDy / 300).clamp(0.0, 1.0);
                        engine.setVideoVolume(v);
                        _controls.flashHint('${(v * 100).round()}%',
                            v == 0 ? Icons.volume_off : Icons.volume_up);
                      }
                    },
                    onVerticalDragEnd: (_) {
                      _dragV = false;
                      _controls.clearHint();
                      _controls.show();
                    },
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: vc.value.aspectRatio,
                        child: VideoPlayer(vc),
                      ),
                    ),
                  ),
                )
              else
                const Center(
                    child: CircularProgressIndicator(color: Colors.white)),
              ProVideoOverlay(
                controls: _controls,
                title: widget.file.title,
                isFullscreen: false,
                onBack: () => Navigator.pop(context),
                onToggleFullscreen: _openFullscreen,
              ),
            ],
          );
        },
      ),
    );
  }
}
