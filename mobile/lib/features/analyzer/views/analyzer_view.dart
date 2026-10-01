import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_animations.dart';
import '../../../core/localization/app_localizations.dart';
import '../controllers/analyze_controller.dart';
import '../widgets/media_card.dart';
import '../widgets/format_selector.dart';
import '../../../data/models/format_option.dart';
import '../../../data/models/download_task.dart';
import '../../../services/connectivity_service.dart';
import '../../../services/local_extraction_service.dart';
import '../../downloads/controllers/downloads_controller.dart';

class AnalyzerView extends StatefulWidget {
  const AnalyzerView({super.key});

  @override
  State<AnalyzerView> createState() => _AnalyzerViewState();
}

class _AnalyzerViewState extends State<AnalyzerView> with TickerProviderStateMixin {
  final _urlController = TextEditingController();
  final _focusNode = FocusNode();
  bool _isFocused = false;
  List<String> _recentUrls = [];
  static const _recentKey = 'vibegrab_recent_urls';
  static const _maxRecent = 8;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      setState(() => _isFocused = _focusNode.hasFocus);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncPendingUrl();
      _loadRecentUrls();
    });
  }

  void _syncPendingUrl() {
    final controller = context.read<AnalyzeController>();
    final pending = controller.pendingSharedUrl;
    if (pending != null && _urlController.text != pending) {
      _urlController.text = pending;
      controller.consumePendingUrl();
    }
  }

  Future<void> _loadRecentUrls() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _recentUrls = prefs.getStringList(_recentKey) ?? []);
  }

  Future<void> _saveRecentUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    _recentUrls.remove(url);
    _recentUrls.insert(0, url);
    if (_recentUrls.length > _maxRecent) _recentUrls = _recentUrls.sublist(0, _maxRecent);
    await prefs.setStringList(_recentKey, _recentUrls);
    if (mounted) setState(() {});
  }

  void _removeRecentUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    _recentUrls.remove(url);
    await prefs.setStringList(_recentKey, _recentUrls);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _urlController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _analyze() {
    final controller = context.read<AnalyzeController>();
    final loc = AppLocalizations.of(context);
    final url = LocalExtractionService.sanitizeUrl(_urlController.text);
    controller.analyze(url, emptyUrlMessage: loc.pleaseEnterUrl);
    _focusNode.unfocus();
    if (url.isNotEmpty) _saveRecentUrl(url);
  }

  void _download(FormatOption format, String title, String? thumbnail, String? source) async {
    final downloadsController = context.read<DownloadsController>();
    final url = LocalExtractionService.sanitizeUrl(_urlController.text);
    final loc = AppLocalizations.of(context);

    final mediaType = format.type == 'audio' ? DownloadMediaType.audio : DownloadMediaType.video;

    debugPrint('[DOWNLOAD] mediaType=${mediaType.name} direct=${format.directUrl != null}');

    final task = DownloadTask(
      id: 'dl_${DateTime.now().millisecondsSinceEpoch}',
      url: url,
      title: title,
      formatId: format.id,
      thumbnail: thumbnail,
      source: source,
      hasVideo: format.hasVideo,
      hasAudio: format.hasAudio,
      mediaType: mediaType,
      directUrl: format.directUrl,
      fileExt: format.extension,
      totalBytes: format.sizeBytes,
      createdAt: DateTime.now().toIso8601String(),
    );
    
    downloadsController.addTask(task);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(loc.downloadAdded(title)),
          backgroundColor: AppColors.success,
        ),
      );
    }
  }

  void _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _urlController.text = data!.text!;
      setState(() {});
      _analyze();
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: Consumer<AnalyzeController>(
        builder: (context, controller, _) {
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _buildHeader(loc, cs)),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: _buildSearchBar(loc, cs, controller),
                ),
              ),
              if (controller.isLoading && controller.result == null)
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverToBoxAdapter(child: _buildSkeletonLoading()),
                ),
              if (controller.error != null)
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverToBoxAdapter(child: _buildError(controller, cs)),
                ),
              if (controller.result != null)
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
                      FadeSlideIn(
                        child: MediaCard(media: controller.media!),
                      ),
                      const SizedBox(height: 20),
                      FadeSlideIn(
                        beginOffset: const Offset(0, 0.1),
                        duration: AppDurations.slow,
                        child: FormatSelector(
                          audioFormats: controller.audioFormats,
                          videoFormats: controller.videoFormats,
                          onSelected: (format) {
                            _download(
                              format,
                              controller.media!.title,
                              controller.media!.thumbnail,
                              controller.media!.source,
                            );
                          },
                        ),
                      ),
                    ]),
                  ),
                ),
              if (!controller.isLoading && controller.result == null && controller.error == null && _recentUrls.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  sliver: SliverToBoxAdapter(child: _buildRecentSection(loc, cs)),
                ),
              if (!controller.isLoading && controller.result == null && controller.error == null && _recentUrls.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _buildEmptyState(cs, loc),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeader(AppLocalizations loc, ColorScheme cs) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 0),
        child: Column(
          children: [
            FadeSlideIn(
              duration: AppDurations.slow,
              beginOffset: const Offset(0, -0.05),
              child: Text(
                'VibeGrab',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  color: cs.primary,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(height: 8),
            FadeSlideIn(
              duration: AppDurations.slow,
              beginOffset: const Offset(0, 0.05),
              child: Text(
                loc.pasteAndAnalyze,
                style: TextStyle(
                  fontSize: 15,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 8),
            _buildBackendStatus(cs, loc),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar(AppLocalizations loc, ColorScheme cs, AnalyzeController controller) {
    return AnimatedContainer(
      duration: AppDurations.fast,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _isFocused ? cs.primary : cs.outline,
          width: _isFocused ? 2 : 1,
        ),
        boxShadow: _isFocused
            ? [BoxShadow(color: cs.primary.withValues(alpha: 0.15), blurRadius: 12, spreadRadius: -2)]
            : [],
      ),
      child: TextField(
        controller: _urlController,
        focusNode: _focusNode,
        decoration: InputDecoration(
          hintText: loc.urlHint,
          prefixIcon: Icon(Icons.link, color: _isFocused ? cs.primary : cs.onSurfaceVariant),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_urlController.text.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () {
                    _urlController.clear();
                    controller.clear();
                    setState(() {});
                  },
                ),
              IconButton(
                icon: Icon(Icons.content_paste, size: 20, color: cs.primary),
                tooltip: loc.pasteAndAnalyze,
                onPressed: _pasteFromClipboard,
              ),
            ],
          ),
        ),
        onSubmitted: (_) => _analyze(),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  Widget _buildBackendStatus(ColorScheme cs, AppLocalizations loc) {
    final online = ConnectivityService.instance.hasInternet;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: online
            ? AppColors.success.withValues(alpha: 0.1)
            : AppColors.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            online ? Icons.check_circle_outline : Icons.wifi_off,
            size: 14,
            color: online ? AppColors.success : AppColors.error,
          ),
          const SizedBox(width: 6),
          Text(
            online ? loc.onlineReady : loc.noInternetConnection,
            style: TextStyle(
              color: online ? AppColors.success : AppColors.error,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSkeletonLoading() {
    return Column(
      children: [
        ShimmerLoading(width: double.infinity, height: 200, borderRadius: 16),
        const SizedBox(height: 16),
        ShimmerLoading(width: double.infinity, height: 48, borderRadius: 12),
        const SizedBox(height: 8),
        ShimmerLoading(width: double.infinity, height: 48, borderRadius: 12),
      ],
    );
  }

  Widget _buildRecentSection(AppLocalizations loc, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.history, size: 16, color: cs.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              'Recent',
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _recentUrls.map((url) {
            final display = url.length > 40 ? '${url.substring(0, 40)}...' : url;
            return GestureDetector(
              onTap: () {
                _urlController.text = url;
                setState(() {});
                _analyze();
              },
              onLongPress: () => _removeRecentUrl(url),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: cs.outline),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.link, size: 14, color: cs.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Text(
                      display,
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildError(AnalyzeController controller, ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: AppColors.error, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              controller.error!,
              style: TextStyle(color: AppColors.error, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme cs, AppLocalizations loc) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: FadeSlideIn(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.link, size: 40, color: cs.primary.withValues(alpha: 0.5)),
              ),
              const SizedBox(height: 24),
              Text(
                loc.pasteAndAnalyze,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Paste any YouTube, TikTok, Instagram or other link',
                style: TextStyle(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                  fontSize: 14,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
