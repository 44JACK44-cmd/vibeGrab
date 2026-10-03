import 'package:flutter/material.dart';
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
import '../../../services/api_service.dart';
import '../../../features/analyzer/controllers/analyze_controller.dart';
import '../../../features/downloads/controllers/downloads_controller.dart';
import '../../analyzer/widgets/format_selector.dart';
import '../../media_player/widgets/mini_player.dart';

class VideoDetailView extends StatefulWidget {
  final ExploreVideo video;

  const VideoDetailView({super.key, required this.video});

  @override
  State<VideoDetailView> createState() => _VideoDetailViewState();
}

class _VideoDetailViewState extends State<VideoDetailView> {
  final ApiService _api = ApiService();

  bool _showFormats = false;

  List<RelatedVideo> _related = [];
  bool _relatedLoading = true;

  List<CommentItem> _comments = [];
  String? _commentsToken;
  bool _commentsLoading = true;
  bool _commentsFailed = false;
  bool _commentsLoadingMore = false;

  @override
  void initState() {
    super.initState();
    _loadRelated();
    _loadComments();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<MediaEngine>().playExploreVideo(widget.video);
    });
  }

  String get _videoId {
    final id = widget.video.id;
    if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)) return id;
    final match = RegExp(r'(?:v=|youtu\.be/|shorts/)([A-Za-z0-9_-]{11})')
        .firstMatch(widget.video.url);
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

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final video = widget.video;

    return Scaffold(
      body: Column(
        children: [
          _buildPlayerArea(),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          video.title,
                          style: TextStyle(
                            color: cs.onSurface,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _buildMetaRow(cs),
                        const SizedBox(height: 16),
                        _buildPlayButton(loc, cs),
                        const SizedBox(height: 8),
                        _buildDownloadButton(loc),
                        const SizedBox(height: 16),
                        if (_showFormats) _buildFormatSection(cs),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  _buildCommentsSection(loc, cs),
                  const Divider(height: 1),
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

  // --- Player ---

  Widget _buildPlayerArea() {
    final loc = AppLocalizations.of(context);
    return Consumer<MediaEngine>(
      builder: (context, engine, _) {
        final cs = Theme.of(context).colorScheme;
        final isThis = engine.currentMediaId == widget.video.url;
        final controller = engine.videoController;
        final showingVideo = isThis &&
            engine.isVideo &&
            controller != null &&
            controller.value.isInitialized;
        final buffering = isThis &&
            (engine.state.status == MediaStatus.loading ||
                engine.state.status == MediaStatus.buffering);

        return Container(
          color: Colors.black,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Stack(
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
                            tag: 'explore_thumb_${widget.video.url}',
                            child: widget.video.thumbnail != null &&
                                    widget.video.thumbnail!.isNotEmpty
                                ? Image.network(
                                    widget.video.thumbnail!,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        _buildPlaceholder(cs),
                                  )
                                : _buildPlaceholder(cs),
                          ),
                          if (buffering)
                            const CircularProgressIndicator(
                                color: Colors.white)
                          else
                            GestureDetector(
                              onTap: () =>
                                  engine.playExploreVideo(widget.video),
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

  Widget _buildMetaRow(ColorScheme cs) {
    final video = widget.video;
    final parts = <Widget>[];
    if (video.channel != null && video.channel!.isNotEmpty) {
      parts.add(Icon(Icons.person_outline, size: 16, color: cs.onSurfaceVariant));
      parts.add(const SizedBox(width: 4));
      parts.add(Flexible(
        child: Text(
          video.channel!,
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ));
      parts.add(const SizedBox(width: 12));
    }
    if (video.viewCountFormatted.isNotEmpty) {
      parts.add(Text(
        video.viewCountFormatted,
        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
      ));
      parts.add(const SizedBox(width: 12));
    }
    if (video.age != null && video.age!.isNotEmpty) {
      parts.add(Text(
        video.age!,
        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
      ));
      parts.add(const SizedBox(width: 12));
    }
    if (video.durationFormatted.isNotEmpty) {
      parts.add(Text(
        video.durationFormatted,
        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
      ));
    }

    return Row(children: parts);
  }

  Widget _buildPlayButton(AppLocalizations loc, ColorScheme cs) {
    return Consumer<MediaEngine>(
      builder: (context, engine, _) {
        final isThis = engine.currentMediaId == widget.video.url;
        final playingThis = isThis && engine.isPlaying;
        return SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () {
              if (isThis) {
                engine.togglePlayPause();
              } else {
                engine.playExploreVideo(widget.video);
              }
            },
            icon: Icon(
              playingThis ? Icons.pause_circle_outline : Icons.play_circle_outline,
              size: 20,
            ),
            label: Text(playingThis ? loc.pauseVideo : loc.playVideo),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 44),
              side: BorderSide(color: cs.primary),
              foregroundColor: cs.primary,
            ),
          ),
        );
      },
    );
  }

  Widget _buildDownloadButton(AppLocalizations loc) {
    return Consumer<AnalyzeController>(
      builder: (context, analyzeCtrl, _) {
        return SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: analyzeCtrl.isLoading ? null : () => _startAnalyze(),
            icon: analyzeCtrl.isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.download),
            label: Text(analyzeCtrl.isLoading ? loc.analyzing : loc.downloadVideo),
          ),
        );
      },
    );
  }

  Future<void> _startAnalyze() async {
    final analyzeCtrl = context.read<AnalyzeController>();
    await analyzeCtrl.analyze(widget.video.url);
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
              AppLocalizations.of(context).formatAudio,
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
          ],
        );
      },
    );
  }

  Future<void> _startDownload(FormatOption format) async {
    final downloadsCtrl = context.read<DownloadsController>();
    final video = widget.video;

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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context).downloadAdded(video.title)),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  // --- Comments ---

  Widget _buildCommentsSection(AppLocalizations loc, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.mode_comment_outlined, size: 20, color: cs.onSurface),
              const SizedBox(width: 8),
              Text(
                loc.commentsTitle,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
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

  void _openRelated(RelatedVideo item) {
    final relatedVideo = ExploreVideo(
      id: item.id,
      title: item.title,
      url: 'https://www.youtube.com/watch?v=${item.id}',
      thumbnail: item.thumbnail,
      channel: item.channel,
      durationString: item.duration,
      viewsLabel: item.viewsLabel ?? item.views,
      age: item.age,
    );
    Navigator.push(
      context,
      PageSlideTransition(
        page: VideoDetailView(video: relatedVideo),
      ),
    );
  }
}
