import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../services/media_engine.dart';
import '../../../services/media_source.dart';
import '../widgets/play_mode_button.dart';
import '../widgets/equalizer_sheet.dart';
import 'video_controls_controller.dart';

const _speedSteps = [1.0, 1.25, 1.5, 2.0, 0.5, 0.75];

/// Professional video controls overlay shared by local and Explorer playback:
/// top bar (back, title, favorite, EQ, PiP), center transport, bottom bar
/// (times, slider, speed, mode, fullscreen). Visibility is driven by
/// [VideoControlsController]; transient gesture hints render centered.
class ProVideoOverlay extends StatelessWidget {
  final VideoControlsController controls;
  final String title;
  final bool isFullscreen;
  final VoidCallback onBack;
  final VoidCallback onToggleFullscreen;

  const ProVideoOverlay({
    super.key,
    required this.controls,
    required this.title,
    required this.isFullscreen,
    required this.onBack,
    required this.onToggleFullscreen,
  });

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: controls,
      builder: (context, _) {
        return Stack(
          fit: StackFit.expand,
          children: [
            // Taps on empty overlay area keep controls alive without
            // toggling (buttons handle their own taps).
            if (controls.visible)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: controls.poke,
                  child: const SizedBox.expand(),
                ),
              ),
            AnimatedOpacity(
              opacity: controls.visible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 250),
              child: IgnorePointer(
                ignoring: !controls.visible,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black54,
                        Colors.transparent,
                        Colors.transparent,
                        Colors.black54
                      ],
                      stops: [0, 0.25, 0.75, 1],
                    ),
                  ),
                  child: Column(
                    children: [
                      _topBar(context, loc),
                      const Spacer(),
                      _centerRow(context, loc),
                      const Spacer(),
                      _bottomBar(context, loc),
                    ],
                  ),
                ),
              ),
            ),
            if (controls.visible && controls.hintText != null)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (controls.hintIcon != null)
                        Icon(controls.hintIcon,
                            color: Colors.white, size: 20),
                      if (controls.hintIcon != null)
                        const SizedBox(width: 8),
                      Text(
                        controls.hintText!,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _topBar(BuildContext context, AppLocalizations loc) {
    return Consumer<MediaEngine>(
      builder: (context, engine, _) {
        return SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                      isFullscreen ? Icons.fullscreen_exit : Icons.arrow_back,
                      color: Colors.white),
                  onPressed: () {
                    controls.poke();
                    onBack();
                  },
                ),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: loc.like,
                  icon: Icon(
                    engine.isCurrentFavorite
                        ? Icons.favorite
                        : Icons.favorite_border,
                    color: engine.isCurrentFavorite
                        ? Colors.redAccent
                        : Colors.white,
                    size: 22,
                  ),
                  onPressed: () {
                    controls.poke();
                    engine.toggleFavoriteCurrent();
                  },
                ),
                IconButton(
                  tooltip: loc.equalizer,
                  icon:
                      const Icon(Icons.equalizer, color: Colors.white, size: 22),
                  onPressed: () {
                    controls.poke();
                    showEqualizerSheet(context);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.picture_in_picture_alt,
                      color: Colors.white, size: 22),
                  onPressed: () async {
                    controls.poke();
                    final available = await engine.isPiPAvailable();
                    final entered =
                        available && await engine.enterPiP();
                    if (!entered && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(loc.piPNotAvailable),
                        behavior: SnackBarBehavior.floating,
                      ));
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _centerRow(BuildContext context, AppLocalizations loc) {
    return Consumer<MediaEngine>(
      builder: (context, engine, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (engine.queue.length > 1)
              IconButton(
                icon: Icon(Icons.skip_previous,
                    color: engine.hasPrevious ? Colors.white : Colors.white30,
                    size: 32),
                onPressed: engine.hasPrevious
                    ? () {
                        controls.poke();
                        engine.skipToPrevious();
                      }
                    : null,
              ),
            if (engine.queue.length > 1) const SizedBox(width: 8),
            IconButton(
              icon:
                  const Icon(Icons.replay_10, color: Colors.white, size: 30),
              onPressed: () {
                controls.poke();
                final target =
                    engine.position - const Duration(seconds: 10);
                engine.seek(
                    target.isNegative ? Duration.zero : target);
              },
            ),
            const SizedBox(width: 16),
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
                  } else {
                    engine.resume();
                  }
                  controls.poke();
                },
              ),
            ),
            const SizedBox(width: 16),
            IconButton(
              icon: const Icon(Icons.forward_30,
                  color: Colors.white, size: 30),
              onPressed: () {
                controls.poke();
                final target =
                    engine.position + const Duration(seconds: 30);
                engine.seek(target > engine.duration
                    ? engine.duration
                    : target);
              },
            ),
            if (engine.queue.length > 1) const SizedBox(width: 8),
            if (engine.queue.length > 1)
              IconButton(
                icon: Icon(Icons.skip_next,
                    color: engine.hasNext ? Colors.white : Colors.white30,
                    size: 32),
                onPressed: engine.hasNext
                    ? () {
                        controls.poke();
                        engine.skipToNext();
                      }
                    : null,
              ),
          ],
        );
      },
    );
  }

  Widget _bottomBar(BuildContext context, AppLocalizations loc) {
    return Consumer<MediaEngine>(
      builder: (context, engine, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: Column(
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 14),
                ),
                child: Slider(
                  value: engine.progress,
                  onChanged: (v) {
                    engine.seekProgress(v);
                    controls.poke();
                  },
                ),
              ),
              Row(
                children: [
                  Text(
                    engine.positionFormatted,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '/ ${engine.durationFormatted}',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12),
                  ),
                  const Spacer(),
                  if (engine.videoQualities.isNotEmpty)
                    _QualityButton(
                      qualities: engine.videoQualities,
                      current: engine.videoQuality,
                      onSelect: (h) {
                        controls.poke();
                        engine.switchVideoQuality(h);
                      },
                    ),
                  _SpeedButton(
                      speed: engine.speed,
                      onTap: () {
                        controls.poke();
                        final i = _speedSteps.indexOf(engine.speed);
                        engine.setSpeed(_speedSteps[
                            (i + 1) % _speedSteps.length]);
                      }),
                  const PlayModeButton(
                    size: 22,
                    activeColor: Colors.white,
                    inactiveColor: Colors.white70,
                  ),
                  IconButton(
                    icon: Icon(
                        isFullscreen
                            ? Icons.fullscreen_exit
                            : Icons.fullscreen,
                        color: Colors.white,
                        size: 22),
                    onPressed: () {
                      controls.poke();
                      onToggleFullscreen();
                    },
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Real quality selector: only lists qualities the resolver actually
/// knows for this video (Auto + manifest heights). Switching preserves
/// the current position.
class _QualityButton extends StatelessWidget {
  final List<MediaQuality> qualities;
  final int current;
  final ValueChanged<int> onSelect;

  const _QualityButton({
    required this.qualities,
    required this.current,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final label = current == 0 ? 'Auto' : '${current}p';
    return TextButton(
      onPressed: () => _pick(context, loc),
      style: TextButton.styleFrom(
        minimumSize: const Size(56, 36),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label,
        style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700),
      ),
    );
  }

  void _pick(BuildContext context, AppLocalizations loc) {
    final options = <int>[0, ...qualities.map((q) => q.height)];
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(loc.videoQuality,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            for (final h in options)
              ListTile(
                title: Text(h == 0 ? 'Auto' : '${h}p'),
                trailing: h == current
                    ? const Icon(Icons.check, color: Colors.white)
                    : null,
                onTap: () {
                  Navigator.pop(ctx);
                  if (h != current) onSelect(h);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _SpeedButton extends StatelessWidget {  final double speed;
  final VoidCallback onTap;

  const _SpeedButton({required this.speed, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final label =
        speed == speed.roundToDouble() ? '${speed.round()}x' : '${speed}x';
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 36),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label,
        style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700),
      ),
    );
  }
}
