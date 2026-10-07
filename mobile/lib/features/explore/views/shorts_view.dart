import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../data/models/explore_video.dart';
import '../../../services/media_engine.dart';
import '../../../services/media_metadata_service.dart';
import '../controllers/explore_controller.dart';
import 'video_detail_view.dart';

/// Vertical Shorts feed: swipe up for the next short video, with minimal
/// controls (play/pause on tap, like, copy link, open details/download).
/// Plays through the shared MediaEngine, like everything else.
class ShortsView extends StatefulWidget {
  const ShortsView({super.key});

  @override
  State<ShortsView> createState() => _ShortsViewState();
}

class _ShortsViewState extends State<ShortsView> {
  final _pages = PageController();
  bool _started = false;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = context.read<ExploreController>();
      if (c.shorts.isEmpty && !c.shortsLoading) c.loadShorts();
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _maybeStart(List<ExploreVideo> shorts) {
    if (_started || shorts.isEmpty) return;
    _started = true;
    _playAt(0, shorts);
  }

  void _playAt(int i, List<ExploreVideo> shorts) {
    if (i < 0 || i >= shorts.length) return;
    _index = i;
    // The whole feed is the queue: auto-next, the notification controls and
    // previous/next all walk it through the shared MediaEngine.
    context.read<MediaEngine>().playExploreQueue(shorts, startIndex: i);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(loc.shortsTitle),
      ),
      body: Consumer<ExploreController>(
        builder: (context, controller, _) {
          final shorts = controller.shorts;
          if (controller.shortsLoading && shorts.isEmpty) {
            return const Center(
                child: CircularProgressIndicator(color: Colors.white));
          }
          if (shorts.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  loc.shortsEmpty,
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ),
            );
          }
          _maybeStart(shorts);
          return PageView.builder(
            controller: _pages,
            scrollDirection: Axis.vertical,
            itemCount: shorts.length,
            onPageChanged: (i) => _playAt(i, shorts),
            itemBuilder: (context, i) => _ShortPage(
              video: shorts[i],
              active: i == _index,
            ),
          );
        },
      ),
    );
  }
}

class _ShortPage extends StatelessWidget {
  final ExploreVideo video;
  final bool active;

  const _ShortPage({required this.video, required this.active});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Consumer<MediaEngine>(
      builder: (context, engine, _) {
        final vc = engine.videoController;
        final showing = active &&
            vc != null &&
            vc.value.isInitialized &&
            !vc.value.hasError;
        return Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => engine.togglePlayPause(),
              child: Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: showing
                    ? AspectRatio(
                        aspectRatio: 9 / 16,
                        child: VideoPlayer(vc),
                      )
                    : (video.thumbnail != null &&
                            video.thumbnail!.isNotEmpty
                        ? Image.network(video.thumbnail!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const SizedBox.shrink())
                        : const CircularProgressIndicator(
                            color: Colors.white)),
              ),
            ),
            if (!engine.isPlaying && active)
              const Center(
                child: Icon(Icons.play_circle_fill,
                    color: Colors.white70, size: 72),
              ),
            Positioned(
              right: 8,
              bottom: 90,
              child: Column(
                children: [
                  _RailButton(
                    icon: engine.isRemoteLiked(video.url)
                        ? Icons.favorite
                        : Icons.favorite_border,
                    color: engine.isRemoteLiked(video.url)
                        ? Colors.redAccent
                        : Colors.white,
                    onTap: () => engine.toggleRemoteLike(
                      url: video.url,
                      title: video.title,
                      artist: video.channel,
                      thumbnail: video.thumbnail,
                      isVideo: true,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _RailButton(
                    icon: Icons.link,
                    onTap: () {
                      Clipboard.setData(
                          ClipboardData(text: video.url));
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(loc.linkCopied),
                        behavior: SnackBarBehavior.floating,
                        duration: const Duration(seconds: 1),
                      ));
                    },
                  ),
                  const SizedBox(height: 16),
                  _RailButton(
                    icon: Icons.download_outlined,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              VideoDetailView(video: video)),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 12,
              right: 76,
              bottom: 24,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    video.channel ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: engine.progress,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                        Colors.white),
                    minHeight: 2,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RailButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _RailButton({
    required this.icon,
    this.color = Colors.white,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black45,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: color, size: 26),
        ),
      ),
    );
  }
}
