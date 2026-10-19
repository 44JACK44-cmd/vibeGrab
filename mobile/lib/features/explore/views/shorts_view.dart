import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../data/models/explore_video.dart';
import '../../../services/media_engine.dart';
import '../controllers/explore_controller.dart';
import 'video_detail_view.dart';

/// Vertical Shorts feed: swipe up for the next short video, with minimal
/// controls (play/pause on tap, like, copy link, open details/download).
/// Plays through the shared MediaEngine, like everything else, and follows
/// it: when the player moves on its own (a short ends, the notification
/// controls are used, MediaSession skips) the feed scrolls with it.
class ShortsView extends StatefulWidget {
  const ShortsView({super.key});

  @override
  State<ShortsView> createState() => _ShortsViewState();
}

/// Decides which page of the Shorts feed has to follow the shared player.
///
/// The feed and the player share ONE queue, so every way the player can move
/// on its own (auto-advance when a short ends, the notification/lockscreen
/// next-previous, MediaSession) must move the feed with it. The opposite
/// direction already works: swiping calls [ShortsView._playAt], which drives
/// the player. So the feed only ever reacts here.
///
/// Returns the page to jump to, or null when the feed must not move: it is
/// already there, the index is out of range, or the player is driving a
/// DIFFERENT queue (another screen replaced it while this feed was behind it,
/// in which case this feed is no longer the owner of what is playing).
int? shortsPageForEngineIndex({
  required int engineIndex,
  required List<ExploreVideo> shorts,
  required int shownIndex,
  required List<String> engineQueueIds,
}) {
  if (engineIndex == shownIndex) return null;
  if (engineIndex < 0 || engineIndex >= shorts.length) return null;
  if (engineIndex >= engineQueueIds.length) return null;
  // MediaItem.id is the video url for Explorer/Shorts items, so this tells
  // the two queues apart without guessing.
  if (engineQueueIds[engineIndex] != shorts[engineIndex].url) return null;
  return engineIndex;
}

class _ShortsViewState extends State<ShortsView> {
  final _pages = PageController();
  bool _started = false;
  int _index = 0;
  List<ExploreVideo> _shorts = const [];
  late final MediaEngine _engine;

  /// True while the feed is moving BECAUSE the player moved: the resulting
  /// [PageView.onPageChanged] must not drive the player again, or the video
  /// the player just started would restart from the beginning.
  bool _followingEngine = false;

  @override
  void initState() {
    super.initState();
    _engine = context.read<MediaEngine>();
    _engine.addListener(_syncToEngine);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = context.read<ExploreController>();
      if (c.shorts.isEmpty && !c.shortsLoading) c.loadShorts();
    });
  }

  @override
  void dispose() {
    _engine.removeListener(_syncToEngine);
    _pages.dispose();
    super.dispose();
  }

  /// Moves the feed to wherever the player is, no matter what moved it there
  /// (auto-advance at the end of a short, notification controls, MediaSession).
  void _syncToEngine() {
    if (!mounted) return;
    // Every position tick notifies: the feed only reacts when the player
    // actually moved somewhere else.
    if (_engine.currentIndex == _index) return;
    final target = shortsPageForEngineIndex(
      engineIndex: _engine.currentIndex,
      shorts: _shorts,
      shownIndex: _index,
      engineQueueIds: [
        for (final item in _engine.queue) item.id,
      ],
    );
    if (target == null || !_pages.hasClients) return;

    _followingEngine = true;
    setState(() => _index = target);
    _pages
        .animateToPage(
          target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
      _followingEngine = false;
    });
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
    _engine.playExploreQueue(shorts, startIndex: i);
  }

  /// A swipe (or the feed scrolling back from [_syncToEngine]) changed the
  /// page. While following the player the page is already the one playing:
  /// driving it again would restart that same short.
  void _onPageChanged(int i, List<ExploreVideo> shorts) {
    if (_followingEngine) return;
    _playAt(i, shorts);
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
          _shorts = shorts;
          _maybeStart(shorts);
          return PageView.builder(
            controller: _pages,
            scrollDirection: Axis.vertical,
            itemCount: shorts.length,
            onPageChanged: (i) => _onPageChanged(i, shorts),
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
