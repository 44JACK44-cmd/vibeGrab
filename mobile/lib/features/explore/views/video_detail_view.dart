import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_animations.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../data/models/explore_video.dart';
import '../../../data/models/related_video.dart';
import '../../../data/models/comment_item.dart';
import '../../../data/models/format_option.dart';
import '../../../data/models/download_task.dart';
import '../../../data/models/media_state.dart';
import '../../../services/media_engine.dart';
import '../../../services/media_metadata_service.dart';
import '../../../services/api_service.dart';
import '../../../features/analyzer/controllers/analyze_controller.dart';
import '../../../features/downloads/controllers/downloads_controller.dart';
import '../../analyzer/widgets/format_selector.dart';
import '../../media_player/views/video_fullscreen_view.dart';
import '../../media_player/widgets/video_controls_overlay.dart';

class VideoDetailView extends StatefulWidget {
  final ExploreVideo video;

  /// Queue this video belongs to (the list it was opened from). When set,
  /// next/previous and end-of-video auto-advance operate on that queue
  /// through the shared MediaEngine.
  final List<ExploreVideo>? queue;

  const VideoDetailView({super.key, required this.video, this.queue});

  @override
  State<VideoDetailView> createState() => _VideoDetailViewState();
}

class _VideoDetailViewState extends State<VideoDetailView> {
  final ApiService _api = ApiService();

  /// Video currently displayed. Starts as the opened one and follows the
  /// engine when the queue advances (auto-next / next button / related tap).
  late ExploreVideo _current;

  /// Queue driving this page: the list it was opened from, replaced by the
  /// related list when a related video is tapped in place.
  List<ExploreVideo>? _queue;
  final ScrollController _scroll = ScrollController();

  bool _showFormats = false;

  List<RelatedVideo> _related = [];
  bool _relatedLoading = true;

  /// Mini history of videos the user swiped away from on the player, so
  /// swiping down restores the previous video of this session.
  final List<ExploreVideo> _swipeBack = [];

  List<CommentItem> _comments = [];
  String? _commentsToken;
  bool _commentsLoading = true;
  bool _commentsFailed = false;
  bool _commentsLoadingMore = false;
  bool _commentsExpanded = false;

  String? _channelAvatar;
  int? _commentCount;
  String? _description;
  bool _descExpanded = false;
  bool _liked = false;
  bool _disliked = false;

@override
void initState() {
super.initState();
_current = widget.video;
_queue = widget.queue;
_engine = context.read<MediaEngine>();
_engine!.addListener(_onEngineChanged);
_liked = MediaMetadataService().isLiked(_current.url);
_loadRelated();
_loadComments();
_loadMeta();
// Warm the backend while the user reads: a sleeping server needs ~40s to
// wake, so pinging now means stream URLs resolve fast when play starts.
ApiService().checkHealth().then((ok) {
debugPrint('[VideoDetail] Backend warmup: $ok');
});
WidgetsBinding.instance.addPostFrameCallback((_) {
if (!mounted) return;
_play();
});
}

  MediaEngine? _engine;

  /// Starts playback for the displayed video: the whole queue when the view
  /// was opened from a list, a single item otherwise.
  void _play() {
    final engine = _engine;
    if (engine == null) return;
    // The engine may already be playing this exact video (the page was
    // reopened from the mini player or a notification): adopt that running
    // session instead of restarting it from 00:00.
    if (engine.currentMediaId == _current.url &&
        engine.playbackError == null &&
        (engine.state.status == MediaStatus.loading ||
            engine.state.status == MediaStatus.buffering ||
            engine.state.status == MediaStatus.playing ||
            engine.state.status == MediaStatus.paused)) {
      return;
    }
    final q = _queue;
    if (q != null && q.isNotEmpty) {
      final i = q.indexWhere((v) => v.url == _current.url);
      engine.playExploreQueue(q, startIndex: i < 0 ? 0 : i);
    } else {
      engine.playExploreVideo(_current);
    }
  }

  /// Resets every piece of per-video state before showing [video].
  void _showVideo(ExploreVideo video) {
    setState(() {
      _current = video;
      _related = [];
      _relatedLoading = true;
      _comments = [];
      _commentsLoading = true;
      _commentsToken = null;
      _commentsExpanded = false;
      _commentsFailed = false;
      _descExpanded = false;
      _showFormats = false;
      _description = null;
      _channelAvatar = null;
      _commentCount = null;
      _disliked = false;
      _liked = MediaMetadataService().isLiked(video.url);
    });
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: AppDurations.normal,
        curve: Curves.easeOut,
      );
    }
    _loadRelated();
    _loadComments();
    _loadMeta();
  }

  /// Follows the shared queue: when the engine moves to another item (auto
  /// next, notification controls, next button) the page shows that video and
  /// reloads its related/comments/meta without stacking a new route.
  void _onEngineChanged() {
    if (!mounted) return;
    final q = _queue;
    final id = _engine?.currentMediaId;
    if (q == null || id == null) return;
    final idx = q.indexWhere((v) => v.url == id);
    if (idx < 0 || q[idx].url == _current.url) return;
    _showVideo(q[idx]);
  }

  @override
  void dispose() {
    _engine?.removeListener(_onEngineChanged);
    _scroll.dispose();
    super.dispose();
  }

Future<void> _toggleLike() async {
  final engine = context.read<MediaEngine>();
  await engine.toggleRemoteLike(
    url: _current.url,
    title: _current.title,
    artist: _current.channel,
    thumbnail: _current.thumbnail,
    isVideo: true,
  );
  if (!mounted) return;
  setState(() {
    _liked = engine.isRemoteLiked(_current.url);
    if (_liked) _disliked = false;
  });
}

  String get _videoId {
    final id = _current.id;
    if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)) return id;
    final match = RegExp(r'(?:v=|youtu\.be/|shorts/)([A-Za-z0-9_-]{11})')
        .firstMatch(_current.url);
    return match?.group(1) ?? '';
  }

  Future<void> _loadRelated() async {
    await Future<void>.delayed(Duration.zero);
    final videoId = _videoId;
    if (videoId.isEmpty) {
      setState(() => _relatedLoading = false);
      return;
    }
    try {
      final items = await _api.fetchRelated(videoId);
      if (!mounted) return;
      setState(() {
        _related = items;
        _relatedLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _relatedLoading = false);
    }
  }

  Future<void> _loadComments({bool loadMore = false}) async {
    await Future<void>.delayed(Duration.zero);
    final videoId = _videoId;
    if (videoId.isEmpty) {
      setState(() {
        _commentsLoading = false;
        _commentsFailed = true;
      });
      return;
    }
    setState(() {
      if (loadMore) {
        _commentsLoadingMore = true;
      } else {
        _commentsLoading = true;
        _commentsFailed = false;
      }
    });
    try {
      final page = await _api.fetchComments(
        videoId,
        token: loadMore ? _commentsToken : null,
      );
      if (!mounted) return;
      setState(() {
        if (loadMore) {
          _comments.addAll(page.items);
        } else {
          _comments = page.items;
        }
        _commentsToken = page.nextToken;
        _commentsLoading = false;
        _commentsLoadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _commentsLoading = false;
        _commentsLoadingMore = false;
        if (!loadMore) _commentsFailed = true;
      });
    }
  }

  Future<void> _loadMeta() async {
    final videoId = _videoId;
    if (videoId.isEmpty) return;
    try {
      final s = await _api.fetchStreamUrls(videoId);
      if (!mounted) return;
      setState(() {
        _channelAvatar = s.channelAvatar;
        _commentCount = s.commentCount;
        final desc = s.description?.trim();
        _description = (desc == null || desc.isEmpty) ? null : desc;
      });
    } catch (_) {
      // Meta is optional; playback falls back on its own.
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final video = _current;

    return Scaffold(
      body: Column(
        children: [
          _buildPlayerArea(),
          _buildErrorBanner(),
          Expanded(
            child: SingleChildScrollView(
              controller: _scroll,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          video.title,
                          style: TextStyle(
                            color: cs.onSurface,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 6),
                        _buildMetaLine(cs),
                        const SizedBox(height: 12),
                        _buildChannelRow(cs),
                        if (_description != null) ...[
                          const SizedBox(height: 8),
                          _buildDescription(cs, loc),
                        ],
                        const SizedBox(height: 14),
                        _buildButtonsRow(loc, cs),
                        _buildQueueNav(loc, cs),
                        if (_showFormats) ...[
                          const SizedBox(height: 14),
                          _buildFormatSection(cs),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildCommentsSection(loc, cs),
                  const SizedBox(height: 8),
                  if (_related.isNotEmpty || _relatedLoading)
                    _buildRelatedSection(loc, cs),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- Playback error ---

  Widget _buildErrorBanner() {
    return Consumer<MediaEngine>(
      builder: (context, engine, _) {
        final isThis = engine.currentMediaId == _current.url;
        if (!isThis || engine.playbackError == null) {
          return const SizedBox.shrink();
        }
        final loc = AppLocalizations.of(context);
        final cs = Theme.of(context).colorScheme;
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          decoration: BoxDecoration(
            color: cs.errorContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: cs.onErrorContainer, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loc.playbackFailed,
                      style: TextStyle(
                        color: cs.onErrorContainer,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      engine.playbackError ?? '',
                      style: TextStyle(
                        color: cs.onErrorContainer,
                        fontSize: 11,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if ((engine.playbackError ?? '').contains('servidor')) ...[
                      const SizedBox(height: 4),
                      Text(
                        loc.playCheckConnection,
                        style: TextStyle(
                          color: cs.onErrorContainer,
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              TextButton(
                onPressed: _play,
                child: Text(loc.playVideo),
              ),
            ],
          ),
        );
      },
    );
  }

  // --- Player ---

  Widget _buildPlayerArea() {
    final loc = AppLocalizations.of(context);
    return Consumer<MediaEngine>(
      builder: (context, engine, _) {
        final cs = Theme.of(context).colorScheme;
        final isThis = engine.currentMediaId == _current.url;
        final controller = engine.videoController;
        final showingVideo = isThis &&
            engine.isVideo &&
            controller != null &&
            controller.value.isInitialized;
        final buffering = isThis &&
            (engine.state.status == MediaStatus.loading ||
                engine.state.status == MediaStatus.buffering);

        // PiP window: ONLY the video surface. The system renders its own
        // transport controls from the media session; drawing our full UI
        // here overlaps buttons and breaks the floating window.
        if (engine.isInPiP && showingVideo) {
          return Container(
            color: Colors.black,
            alignment: Alignment.center,
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),
          );
        }

        return Container(
          color: Colors.black,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Vertical swipe over the player: up = next recommendation,
              // down = previous video of this swipe session.
              GestureDetector(
                onVerticalDragEnd: (details) =>
                    _onPlayerSwipe(details.primaryVelocity ?? 0),
                child: Stack(
                alignment: Alignment.center,
                children: [
                  if (showingVideo)
                    AspectRatio(
                      aspectRatio: controller.value.aspectRatio,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          VideoPlayer(controller),
                          GestureDetector(
                            onTap: () => engine.togglePlayPause(),
                            child: AnimatedOpacity(
                              opacity: engine.isPlaying ? 0.0 : 1.0,
                              duration: const Duration(milliseconds: 200),
                              child: Container(
                                width: 64,
                                height: 64,
                                decoration: const BoxDecoration(
                                  color: Colors.black45,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  engine.isPlaying
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                  color: Colors.white,
                                  size: 40,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Hero(
                            tag: 'explore_thumb_${_current.url}',
                            child: _current.thumbnail != null &&
                                    _current.thumbnail!.isNotEmpty
                                ? Image.network(
                                    _current.thumbnail!,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        _buildPlaceholder(cs),
                                  )
                                : _buildPlaceholder(cs),
                          ),
                          if (buffering)
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const CircularProgressIndicator(
                                    color: Colors.white),
                                if (engine.loadingStageKey != null) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    loc.value(engine.loadingStageKey!),
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 12),
                                  ),
                                ],
                              ],
                            )
                          else
                            GestureDetector(
                              onTap: _play,
                              child: Container(
                                width: 64,
                                height: 64,
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.6),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.play_arrow,
                                    color: Colors.white, size: 40),
                              ),
                            ),
                        ],
                      ),
                    ),
                  Positioned(
                    top: 0,
                    left: 0,
                    child: SafeArea(
                      child: IconButton(
                        icon: const Icon(Icons.arrow_back,
                            color: Colors.white, size: 26),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ),
                  ),
                  if (showingVideo)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: SafeArea(
                        child: IconButton(
                          icon: const Icon(Icons.fullscreen,
                              color: Colors.white, size: 26),
                          onPressed: () => _openFullscreen(context, engine),
                        ),
                      ),
                    ),
                ],
                ),
              ),
              if (showingVideo)
                _buildInlineControls(engine, cs, loc),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInlineControls(
      MediaEngine engine, ColorScheme cs, AppLocalizations loc) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              engine.isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
              size: 28,
            ),
            onPressed: () => engine.togglePlayPause(),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            constraints: const BoxConstraints(),
          ),
          const SizedBox(width: 4),
          Text(
            engine.positionFormatted,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: engine.progress,
                onChanged: (v) => engine.seekProgress(v),
              ),
            ),
          ),
          Text(
            engine.durationFormatted,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          // Quality + speed in portrait, so fullscreen is never required
          // to change them (Fase 2C).
          if (engine.videoQualities.isNotEmpty)
            QualityButton(
              qualities: engine.videoQualities,
              current: engine.videoQuality,
              onSelect: (h) => engine.switchVideoQuality(h),
            ),
          SpeedButton(
            speed: engine.speed,
            onTap: () {
              final i = speedSteps.indexOf(engine.speed);
              engine.setSpeed(speedSteps[(i + 1) % speedSteps.length]);
            },
          ),
          IconButton(
            icon: const Icon(Icons.picture_in_picture_alt,
                color: Colors.white, size: 22),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            constraints: const BoxConstraints(),
            onPressed: () async {
              final available = await engine.isPiPAvailable();
              final entered = available && await engine.enterPiP();
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
    );
  }

  void _openFullscreen(BuildContext context, MediaEngine engine) {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => ChangeNotifierProvider.value(
          value: engine,
          child: const VideoPlayerFullScreen(),
        ),
        transitionDuration: const Duration(milliseconds: 300),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: child,
          );
        },
      ),
    );
  }

  Widget _buildPlaceholder(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: Icon(Icons.videocam, color: cs.onSurfaceVariant, size: 48),
      ),
    );
  }

  // --- Info ---

Widget _buildMetaLine(ColorScheme cs) {
final video = _current;
final loc = AppLocalizations.of(context);
final parts = <String>[
if (video.viewCountLocalized(loc).isNotEmpty) video.viewCountLocalized(loc),
      if (video.age != null && video.age!.isNotEmpty) video.age!,
      if (video.durationFormatted.isNotEmpty) video.durationFormatted,
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(
      parts.join(' · '),
      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
    );
  }

Widget _buildChannelRow(ColorScheme cs) {
final video = _current;
final loc = AppLocalizations.of(context);
return Row(
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: cs.surfaceContainerHighest,
          backgroundImage: _channelAvatar != null
              ? NetworkImage(_channelAvatar!)
              : null,
          onBackgroundImageError: (_, __) {},
          child: _channelAvatar == null
              ? Icon(Icons.person, size: 20, color: cs.onSurfaceVariant)
              : null,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            video.channel ?? '',
            style: TextStyle(
              color: cs.onSurface,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        _actionIcon(
          cs,
          _liked ? Icons.thumb_up : Icons.thumb_up_alt_outlined,
          _liked,
          _toggleLike,
          loc.like,
        ),
        _actionIcon(
          cs,
          _disliked ? Icons.thumb_down : Icons.thumb_down_alt_outlined,
          _disliked,
          () => setState(() {
            _disliked = !_disliked;
            if (_disliked) _liked = false;
          }),
          loc.dislike,
        ),
        _actionIcon(
          cs,
          Icons.share_outlined,
          false,
          _shareLink,
          loc.share,
        ),
      ],
    );
  }

  Widget _actionIcon(
      ColorScheme cs, IconData icon, bool active, VoidCallback onTap, String tip) {
    return IconButton(
      onPressed: onTap,
      tooltip: tip,
      icon: Icon(
        icon,
        size: 22,
        color: active ? cs.primary : cs.onSurfaceVariant,
      ),
      visualDensity: VisualDensity.compact,
    );
  }

  void _shareLink() {
    Clipboard.setData(ClipboardData(text: _current.url));
    final loc = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(loc.linkCopied),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 1),
    ));
  }

  Widget _buildDescription(ColorScheme cs, AppLocalizations loc) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _description!,
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13, height: 1.35),
          maxLines: _descExpanded ? null : 2,
          overflow: _descExpanded ? null : TextOverflow.ellipsis,
        ),
        if (_description!.length > 80)
          GestureDetector(
            onTap: () => setState(() => _descExpanded = !_descExpanded),
            child: Text(
              _descExpanded ? loc.showLess : loc.showMore,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }

  String _formatCompact(int n) {
    if (n >= 1000000) {
      final v = n / 1000000;
      return '${v.toStringAsFixed(v < 10 ? 1 : 0)} M'.replaceAll('.0 M', ' M');
    }
    if (n >= 1000) {
      final v = n / 1000;
      return '${v.toStringAsFixed(v < 10 ? 1 : 0)} K'.replaceAll('.0 K', ' K');
    }
    return '$n';
  }

  Widget _buildButtonsRow(AppLocalizations loc, ColorScheme cs) {
    return Consumer2<MediaEngine, AnalyzeController>(
      builder: (context, engine, analyzeCtrl, _) {
        final isThis = engine.currentMediaId == _current.url;
        final playingThis = isThis && engine.isPlaying;
        return Row(
          children: [
            Expanded(
              flex: 3,
              child: FilledButton.icon(
                onPressed: () {
                  if (isThis) {
                    engine.togglePlayPause();
                  } else {
                    _play();
                  }
                },
                icon: Icon(
                  playingThis
                      ? Icons.pause_circle_outline
                      : Icons.play_circle_outline,
                  size: 20,
                ),
                label: Text(playingThis ? loc.pauseVideo : loc.playVideo),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 46),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: OutlinedButton.icon(
                onPressed:
                    analyzeCtrl.isLoading ? null : () => _startAnalyze(),
                icon: analyzeCtrl.isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download, size: 20),
                label: Text(
                  analyzeCtrl.isLoading ? loc.analyzing : loc.downloadVideo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 46),
                  side: BorderSide(color: cs.outline),
                  foregroundColor: cs.onSurface,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Previous / next controls for the queue driving this page. The engine
  /// owns the state; the listener above keeps this page in sync.
  Widget _buildQueueNav(AppLocalizations loc, ColorScheme cs) {
    final q = _queue;
    if (q == null || q.length < 2) return const SizedBox.shrink();
    final raw = q.indexWhere((v) => v.url == _current.url);
    final idx = raw < 0 ? 0 : raw;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: idx > 0 ? () => _engine?.skipToPrevious() : null,
              icon: const Icon(Icons.skip_previous_rounded, size: 18),
              label: Text(
                loc.prevVideo,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 40),
                side: BorderSide(color: cs.outline),
                foregroundColor: cs.onSurface,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              '${idx + 1} / ${q.length}',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ),
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed:
                  idx < q.length - 1 ? () => _engine?.skipToNext() : null,
              icon: const Icon(Icons.skip_next_rounded, size: 18),
              label: Text(
                loc.nextVideo,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 40),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startAnalyze() async {    final analyzeCtrl = context.read<AnalyzeController>();
    await analyzeCtrl.analyze(_current.url);
    if (mounted && analyzeCtrl.result != null) {
      setState(() => _showFormats = true);
    }
  }

  Widget _buildFormatSection(ColorScheme cs) {
    return Consumer<AnalyzeController>(
      builder: (context, controller, _) {
        if (controller.result == null) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppLocalizations.of(context).downloadFormats,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            FormatSelector(
              audioFormats: controller.audioFormats,
              videoFormats: controller.videoFormats,
              onSelected: (format) {
                _startDownload(format);
              },
            ),
            if (_current.thumbnail != null &&
                _current.thumbnail!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Material(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: _startImageDownload,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: cs.tertiary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(Icons.image_rounded,
                              color: cs.tertiary, size: 18),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'JPG',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                  color: cs.onSurface,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                AppLocalizations.of(context).imageCover,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurfaceVariant
                                      .withValues(alpha: 0.7),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _startDownload(FormatOption format) async {
    final downloadsCtrl = context.read<DownloadsController>();
    final video = _current;

    final task = DownloadTask(
      id: 'dl_${DateTime.now().millisecondsSinceEpoch}',
      url: video.url,
      title: video.title,
      formatId: format.id,
      thumbnail: video.thumbnail,
      source: video.channel,
      hasVideo: format.hasVideo,
      hasAudio: format.hasAudio,
      createdAt: DateTime.now().toIso8601String(),
    );

    downloadsCtrl.addTask(task);
    if (mounted) {
      setState(() => _showFormats = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context).downloadAdded(video.title)),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  /// Saves the video cover as a JPG in the gallery and closes the panel.
  Future<void> _startImageDownload() async {
    final thumb = _current.thumbnail;
    if (thumb == null || thumb.isEmpty || !mounted) return;
    context
        .read<DownloadsController>()
        .addImageDownload(imageUrl: thumb, title: _current.title);
    if (!mounted) return;
    setState(() => _showFormats = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(AppLocalizations.of(context).downloadAdded(_current.title)),
      backgroundColor: AppColors.success,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  // --- Comments ---

  Widget _buildCommentsSection(AppLocalizations loc, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => _commentsExpanded = !_commentsExpanded),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    loc.commentsTitle,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (_commentCount != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      _formatCompact(_commentCount!),
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const Spacer(),
                  Icon(
                    _commentsExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    color: cs.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (_commentsLoading)
                _buildCommentsSkeleton(cs)
              else if (_commentsFailed)
                Text(
                  loc.commentsUnavailable,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
                )
              else if (_comments.isEmpty)
                Text(
                  loc.commentsEmpty,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
                )
              else if (!_commentsExpanded)
                _buildCommentPreview(_comments.first, cs)
              else ...[
                for (final comment in _comments) _buildCommentTile(comment, cs),
                if (_commentsToken != null)
                  Center(
                    child: _commentsLoadingMore
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : TextButton(
                            onPressed: () => _loadComments(loadMore: true),
                            child: Text(loc.loadMoreComments),
                          ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCommentPreview(CommentItem comment, ColorScheme cs) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: cs.surfaceContainer,
          backgroundImage: comment.avatar != null
              ? NetworkImage(comment.avatar!)
              : null,
          onBackgroundImageError: (_, __) {},
          child: comment.avatar == null
              ? Icon(Icons.person, size: 16, color: cs.onSurfaceVariant)
              : null,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                comment.text,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 13,
                  height: 1.3,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                comment.author,
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCommentsSkeleton(ColorScheme cs) {
    return Column(
      children: List.generate(
        3,
        (index) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: cs.surfaceContainerHighest,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 12,
                      width: 120,
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 12,
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCommentTile(CommentItem comment, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: cs.surfaceContainerHighest,
            backgroundImage: comment.avatar != null
                ? NetworkImage(comment.avatar!)
                : null,
            onBackgroundImageError: (_, __) {},
            child: comment.avatar == null
                ? Icon(Icons.person, size: 18, color: cs.onSurfaceVariant)
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        comment.author,
                        style: TextStyle(
                          color: cs.onSurface,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (comment.verified) ...[
                      const SizedBox(width: 4),
                      Icon(Icons.verified, size: 14, color: cs.primary),
                    ],
                    if (comment.published != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        comment.published!,
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
                if (comment.pinnedText != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    comment.pinnedText!,
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  comment.text,
                  style: TextStyle(color: cs.onSurface, fontSize: 14),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.favorite_border,
                        size: 14, color: cs.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(
                      comment.likes ?? '',
                      style:
                          TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                    ),
                    const SizedBox(width: 12),
                    Icon(Icons.mode_comment_outlined,
                        size: 14, color: cs.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(
                      comment.replies ?? '',
                      style:
                          TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- Related ---

  Widget _buildRelatedSection(AppLocalizations loc, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.queue_play_next, size: 20, color: cs.onSurface),
              const SizedBox(width: 8),
              Text(
                loc.relatedVideos,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_relatedLoading)
            _buildRelatedSkeleton(cs)
          else
            for (final item in _related) _buildRelatedTile(item, cs),
        ],
      ),
    );
  }

  Widget _buildRelatedSkeleton(ColorScheme cs) {
    return Column(
      children: List.generate(
        4,
        (index) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Container(
                width: 150,
                height: 84,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 12,
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 12,
                      width: 100,
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRelatedTile(RelatedVideo item, ColorScheme cs) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _openRelated(item),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 150,
                    height: 84,
                    child: item.thumbnail.isNotEmpty
                        ? Image.network(
                            item.thumbnail,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                _buildPlaceholder(cs),
                          )
                        : _buildPlaceholder(cs),
                  ),
                ),
                if (item.duration != null && item.duration!.isNotEmpty)
                  Positioned(
                    bottom: 4,
                    right: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        item.duration!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (item.channel != null && item.channel!.isNotEmpty)
                        item.channel!,
                      if (item.displayViews.isNotEmpty) item.displayViews,
                      if (item.age != null && item.age!.isNotEmpty) item.age!,
                    ].join(' • '),
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  ExploreVideo _relatedToExplore(RelatedVideo item) => ExploreVideo(
        id: item.id,
        title: item.title,
        url: 'https://www.youtube.com/watch?v=${item.id}',
        thumbnail: item.thumbnail,
        channel: item.channel,
        durationString: item.duration,
        viewsLabel: item.viewsLabel ?? item.views,
        age: item.age,
        provider: 'youtube',
      );

  void _openRelated(RelatedVideo item) => _playRelated(_relatedToExplore(item));

  /// Shows [video] in place: the related list becomes this page's queue, so
  /// the rest of the recommendations keep playing (next/previous included)
  /// instead of stacking another detail route on top.
  void _playRelated(ExploreVideo video) {
    final queue = <ExploreVideo>[_current];
    for (final r in _related) {
      final v = _relatedToExplore(r);
      if (v.url != _current.url) queue.add(v);
    }
    if (!queue.any((v) => v.url == video.url)) queue.add(video);
    final idx = queue.indexWhere((v) => v.url == video.url);
    _queue = queue;
    _engine?.playExploreQueue(queue, startIndex: idx < 0 ? 0 : idx);
    if (mounted) _showVideo(video);
  }

  /// Vertical swipe on the player: up plays the next recommendation,
  /// down returns to the previous video of this swipe session.
  void _onPlayerSwipe(double velocity) {
    if (velocity.abs() < 350) return;
    if (velocity < 0) {
      if (_related.isEmpty) return;
      final next = _relatedToExplore(_related.first);
      if (next.url == _current.url) return;
      _swipeBack.add(_current);
      if (_swipeBack.length > 20) _swipeBack.removeAt(0);
      _playRelated(next);
    } else {
      if (_swipeBack.isEmpty) return;
      final prev = _swipeBack.removeLast();
      _playRelated(prev);
    }
  }
}
