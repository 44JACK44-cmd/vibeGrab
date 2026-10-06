import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_animations.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../data/models/explore_video.dart';
import '../controllers/explore_controller.dart';
import '../widgets/search_result_card.dart';
import '../widgets/recent_searches.dart';
import 'video_detail_view.dart';

class ExploreView extends StatefulWidget {
  const ExploreView({super.key});

  @override
  State<ExploreView> createState() => _ExploreViewState();
}

class _ExploreViewState extends State<ExploreView> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ExploreController>().init();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.navExplore),
      ),
      body: Column(
        children: [
          _buildSearchBar(loc, cs),
          Consumer<ExploreController>(
            builder: (context, controller, _) {
if (controller.query.isNotEmpty) return const SizedBox.shrink();
return _buildTabs(controller, cs, AppLocalizations.of(context));
            },
          ),
          Expanded(
            child: Consumer<ExploreController>(
              builder: (context, controller, _) {
                return AnimatedSwitcher(
                  duration: AppDurations.normal,
                  child: _buildState(controller, loc, cs),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildState(ExploreController controller, AppLocalizations loc, ColorScheme cs) {
    if (controller.isLoading) {
      return _buildSkeleton(cs);
    }

    if (controller.exploreError != ExploreError.none) {
      return _buildError(controller, loc, cs);
    }

    if (controller.query.isNotEmpty && controller.results.isNotEmpty) {
      return _buildResults(controller);
    }

    if (controller.activeTab == ExploreTab.trending) {
      return _buildTrendingRich(controller, loc, cs);
    }

    if (controller.activeTab == ExploreTab.categories) {
      return _buildCategories(controller, loc, cs);
    }

    return _buildIdle(controller, loc, cs);
  }

  Widget _buildTabs(ExploreController controller, ColorScheme cs, AppLocalizations loc) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          _tabChip(
            cs: cs,
            icon: Icons.trending_up,
            label: loc.trending,
            selected: controller.activeTab == ExploreTab.trending,
            onTap: () => controller.setTab(ExploreTab.trending),
          ),
          const SizedBox(width: 8),
          _tabChip(
            cs: cs,
            icon: Icons.category_outlined,
            label: loc.categories,
            selected: controller.activeTab == ExploreTab.categories,
            onTap: () => controller.setTab(ExploreTab.categories),
          ),
        ],
      ),
    );
  }

  Widget _tabChip({
    required ColorScheme cs,
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? cs.primary : cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: selected ? Colors.white : cs.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : cs.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar(AppLocalizations loc, ColorScheme cs) {
    return Consumer<ExploreController>(
      builder: (context, controller, _) {
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _searchController,
            focusNode: _focusNode,
            onChanged: (value) {
              controller.searchDebounced(value);
              if (value.isEmpty) controller.clearResults();
            },
            onSubmitted: (value) => controller.searchImmediate(value),
            decoration: InputDecoration(
              hintText: loc.exploreSearchHint,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 20),
                      onPressed: () {
                        _searchController.clear();
                        controller.clearResults();
                        _focusNode.requestFocus();
                      },
                    )
                  : null,
            ),
          ),
        );
      },
    );
  }

  Widget _buildTrendingRich(ExploreController controller, AppLocalizations loc, ColorScheme cs) {
    if (controller.trendingLoading) {
      return _buildSkeleton(cs);
    }

    if (controller.trending.isEmpty) {
      if (controller.recentSearches.isNotEmpty) {
        return ListView(
          children: [
            RecentSearches(
              searches: controller.recentSearches,
              onTap: (query) {
                _searchController.text = query;
                controller.searchImmediate(query);
              },
              onRemove: (query) => controller.removeRecentSearch(query),
              onClearAll: () => controller.clearRecentSearches(),
            ),
          ],
        );
      }

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
                  child: Icon(Icons.trending_up, size: 40, color: cs.primary.withValues(alpha: 0.5)),
                ),
                const SizedBox(height: 24),
                Text(
                  loc.noTrendingContent,
                  style: TextStyle(color: cs.onSurface, fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  loc.exploreIdleHintLong,
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

    return RefreshIndicator(
      onRefresh: () => controller.loadTrending(),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (controller.trending.isNotEmpty) ...[
            _buildHeroCard(controller.trending.first, cs),
            const SizedBox(height: 16),
          ],
          if (controller.trending.length > 1) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(loc.trending, style: TextStyle(
                color: cs.onSurface, fontSize: 18, fontWeight: FontWeight.bold,
              )),
            ),
            const SizedBox(height: 8),
            _buildHorizontalRow(controller.trending.skip(1).take(8).toList(), cs),
            const SizedBox(height: 16),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(loc.allResults, style: TextStyle(
              color: cs.onSurface, fontSize: 18, fontWeight: FontWeight.bold,
            )),
          ),
          const SizedBox(height: 8),
          ...controller.trending.map((video) => FadeSlideIn(
            key: ValueKey(video.id),
            duration: AppDurations.normal,
            child: SearchResultCard(
              video: video,
              onTap: () => _openVideoDetail(video),
              onPlay: () => _playVideo(context, video),
            ),
          )),
        ],
      ),
    );
  }

  Widget _buildHeroCard(ExploreVideo video, ColorScheme cs) {
    return GestureDetector(
      onTap: () => _openVideoDetail(video),
      child: Container(
        height: 220,
        margin: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: cs.surfaceContainerHighest,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (video.thumbnail != null && video.thumbnail!.isNotEmpty)
              Image.network(video.thumbnail!, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(color: cs.surfaceContainerHighest)),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.8),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 16, right: 16, bottom: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (video.channel != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      video.channel!,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 13),
                    ),
                  ],
                ],
              ),
            ),
            Center(
              child: Container(
                width: 56, height: 56,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow, color: Colors.white, size: 36),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHorizontalRow(List<ExploreVideo> videos, ColorScheme cs) {
    return SizedBox(
      height: 130,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: videos.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final video = videos[index];
          return GestureDetector(
            onTap: () => _openVideoDetail(video),
            child: Container(
              width: 160,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: cs.surfaceContainerHighest,
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: video.thumbnail != null && video.thumbnail!.isNotEmpty
                        ? Image.network(video.thumbnail!, width: 160, fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: cs.surfaceContainerHighest,
                              child: Icon(Icons.music_note, color: cs.onSurfaceVariant),
                            ))
                        : Container(
                            color: cs.surfaceContainerHighest,
                            child: Icon(Icons.music_note, color: cs.onSurfaceVariant),
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      video.title,
                      style: TextStyle(color: cs.onSurface, fontSize: 12, fontWeight: FontWeight.w500),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCategories(ExploreController controller, AppLocalizations loc, ColorScheme cs) {
    if (controller.selectedCategory != null) {
      return _buildCategoryResults(controller, loc, cs);
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 1.2,
      ),
      itemCount: controller.categories.length,
      itemBuilder: (context, index) {
        final category = controller.categories[index];
        final icons = [
          Icons.music_note, Icons.sports_esports, Icons.newspaper,
          Icons.sports_soccer, Icons.movie, Icons.school,
          Icons.science, Icons.psychology, Icons.podcasts,
        ];
        return GestureDetector(
          onTap: () => controller.selectCategory(category),
          child: Container(
            decoration: BoxDecoration(
              color: cs.primaryContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icons[index % icons.length], color: cs.primary, size: 28),
                const SizedBox(height: 6),
                Text(
                  category,
                  style: TextStyle(
                    color: cs.onPrimaryContainer,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCategoryResults(ExploreController controller, AppLocalizations loc, ColorScheme cs) {
    if (controller.categoryLoading) {
      return _buildSkeleton(cs);
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 20),
                onPressed: () => controller.clearCategory(),
              ),
              Text(
                controller.selectedCategory ?? '',
                style: TextStyle(color: cs.onSurface, fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        Expanded(
          child: controller.categoryResults.isEmpty
              ? Center(
                  child: Text(
                    loc.noCategoryResults,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: controller.categoryResults.length,
                  itemBuilder: (context, index) {
                    final video = controller.categoryResults[index];
                    return SearchResultCard(
                      video: video,
                      onTap: () => _openVideoDetail(video),
                      onPlay: () => _playVideo(context, video),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildIdle(ExploreController controller, AppLocalizations loc, ColorScheme cs) {
    if (controller.recentSearches.isEmpty) {
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
                  child: Icon(Icons.explore_outlined, size: 40, color: cs.primary.withValues(alpha: 0.5)),
                ),
                const SizedBox(height: 24),
                Text(
                  loc.exploreSearchHint,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  loc.exploreIdleHint,
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

    return ListView(
      children: [
        RecentSearches(
          searches: controller.recentSearches,
          onTap: (query) {
            _searchController.text = query;
            controller.searchImmediate(query);
          },
          onRemove: (query) => controller.removeRecentSearch(query),
          onClearAll: () => controller.clearRecentSearches(),
        ),
      ],
    );
  }

  Widget _buildResults(ExploreController controller) {
    return RefreshIndicator(
      onRefresh: () async {
        if (controller.query.isNotEmpty) {
          controller.searchImmediate(controller.query);
        }
      },
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: controller.results.length,
        itemBuilder: (context, index) {
          final video = controller.results[index];
          return FadeSlideIn(
            key: ValueKey(video.url),
            duration: AppDurations.normal,
            child: SearchResultCard(
              video: video,
              onTap: () => _openVideoDetail(video),
              onPlay: () => _playVideo(context, video),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSkeleton(ColorScheme cs) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: 4,
      itemBuilder: (_, __) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShimmerLoading(width: double.infinity, height: 200, borderRadius: 0),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ShimmerLoading(width: double.infinity, height: 16, borderRadius: 4),
                    const SizedBox(height: 8),
                    ShimmerLoading(width: 180, height: 12, borderRadius: 4),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildError(ExploreController controller, AppLocalizations loc, ColorScheme cs) {
    String title;
    String hint;
    IconData icon;
    Color iconColor;

    switch (controller.exploreError) {
      case ExploreError.noInternet:
        title = loc.errorNoConnection;
        hint = loc.errorNoConnectionHint;
        icon = Icons.wifi_off_outlined;
        iconColor = AppColors.error;
        break;
      case ExploreError.backendUnavailable:
        title = loc.noResults;
        hint = loc.noResultsHint;
        icon = Icons.search_off_outlined;
        iconColor = cs.onSurfaceVariant;
        break;
      case ExploreError.noResults:
        title = loc.noResults;
        hint = loc.noResultsHint;
        icon = Icons.search_off_outlined;
        iconColor = cs.onSurfaceVariant;
        break;
      case ExploreError.searchFailed:
        title = loc.errorSearchFailed;
        hint = controller.error ?? '';
        icon = Icons.error_outline;
        iconColor = AppColors.error;
        break;
      default:
        title = loc.errorSearchFailed;
        hint = '';
        icon = Icons.error_outline;
        iconColor = AppColors.error;
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 36, color: iconColor),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: TextStyle(color: cs.onSurface, fontSize: 15, fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),
            if (hint.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                hint,
                style: TextStyle(color: cs.onSurfaceVariant.withValues(alpha: 0.7), fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 20),
            if (controller.exploreError != ExploreError.noResults)
              ElevatedButton.icon(
                onPressed: () => controller.searchImmediate(controller.query),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(loc.retry),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(140, 44),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _playVideo(BuildContext context, ExploreVideo video) {
    _openVideoDetail(video);
  }

  void _openVideoDetail(ExploreVideo video) {
    Navigator.push(
      context,
      PageSlideTransition(
        page: ChangeNotifierProvider.value(
          value: context.read<ExploreController>(),
          child: VideoDetailView(video: video),
        ),
      ),
    );
  }
}
