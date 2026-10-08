import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_animations.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../data/models/explore_video.dart';
import '../../../services/media_engine.dart';
import '../../../services/media_provider_resolver.dart';
import '../controllers/explore_controller.dart';
import '../widgets/search_result_card.dart';
import '../widgets/recent_searches.dart';
import 'video_detail_view.dart';
import 'shorts_view.dart';

class ExploreView extends StatefulWidget {
  const ExploreView({super.key});

  @override
  State<ExploreView> createState() => _ExploreViewState();
}

class _ExploreViewState extends State<ExploreView> {
final _searchController = TextEditingController();
final _focusNode = FocusNode();
bool _forYouAsked = false;
bool _railsAsked = false;

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
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.content_paste_go, size: 20),
                  tooltip: loc.pasteLink,
                  onPressed: () => _pasteLinkSheet(),
                ),
                if (_searchController.text.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear, size: 20),
                    onPressed: () {
                      _searchController.clear();
                      controller.clearResults();
                      _focusNode.requestFocus();
                    },
                  ),
              ],
            ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTrendingRich(ExploreController controller, AppLocalizations loc, ColorScheme cs) {
    // "Para ti" loads once, lazily, without blocking trending.
    if (!_forYouAsked && controller.forYou.isEmpty && !controller.forYouLoading) {
      _forYouAsked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<ExploreController>().loadForYou();
      });
    }
    // Category rails are requested lazily too: the first row lands fast and
    // the rest keep appending as the user scrolls.
    if (!_railsAsked && controller.railKeys.isEmpty && !controller.railsLoading) {
      _railsAsked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<ExploreController>().loadRails(count: 4);
      });
    }
    if (controller.trendingLoading && controller.trending.isEmpty) {
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

    // Videos of trending NOT already visible above (hero card shows
    // trending[0], the row shows [1..8]) and not repeated in the other
    // sections — this kills the "same video 3 times on one screen" bug.
    String keyOf(ExploreVideo v) => v.id.isNotEmpty ? v.id : v.url;
    final shownIds = <String>{};
    for (final v in controller.continueWatching) {
      shownIds.add(keyOf(v));
    }
    for (final v in controller.forYou) {
      shownIds.add(keyOf(v));
    }
    for (final rail in controller.railKeys) {
      for (final v in controller.rail(rail)) {
        shownIds.add(keyOf(v));
      }
    }
    final trendingRest = controller.trending
        .skip(9)
        .where((v) => !shownIds.contains(keyOf(v)))
        .toList();

    return RefreshIndicator(
      onRefresh: () async {
        controller.clearLink();
        await Future.wait([
          controller.loadTrending(),
          controller.loadContinueWatching(),
        ]);
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          // Progressive rails: the next category is fetched only when the
          // user actually scrolls towards the end of the feed.
          if (notification.depth == 0 &&
              notification.metrics.axis == Axis.vertical &&
              notification.metrics.extentAfter < 400 &&
              !controller.railsLoading &&
              controller.railKeys.length < controller.categories.length) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) context.read<ExploreController>().loadMoreRails();
            });
          }
          return false;
        },
        child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (controller.continueWatching.isNotEmpty) ...[
            _sectionHeader(loc.continueWatching, cs, icon: Icons.history),
            const SizedBox(height: 8),
            _buildHorizontalRow(controller.continueWatching, cs,
                showResume: true),
            const SizedBox(height: 16),
          ],
          _buildCategoryChips(controller, cs),
          const SizedBox(height: 12),
          if (controller.forYou.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(loc.forYou, style: TextStyle(
                color: cs.onSurface, fontSize: 18, fontWeight: FontWeight.bold,
              )),
            ),
            const SizedBox(height: 8),
            _buildHorizontalRow(controller.forYou, cs),
            const SizedBox(height: 16),
          ],
          if (controller.trending.isNotEmpty) ...[
            _buildHeroCard(controller.trending.first, cs,
                queue: controller.trending),
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
            _buildHorizontalRow(controller.trending.skip(1).take(8).toList(),
                cs),
            const SizedBox(height: 16),
          ],
          for (final key in controller.railKeys)
            if (controller.rail(key).isNotEmpty) ...[
              _sectionHeader(key, cs),
              const SizedBox(height: 8),
              _buildHorizontalRow(controller.rail(key), cs),
              const SizedBox(height: 16),
            ],
          if (controller.railsLoading) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          ],
          if (trendingRest.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(loc.allResults, style: TextStyle(
                color: cs.onSurface, fontSize: 18, fontWeight: FontWeight.bold,
              )),
            ),
            const SizedBox(height: 8),
            ...trendingRest.map((video) => FadeSlideIn(
              key: ValueKey(video.id.isNotEmpty ? video.id : video.url),
              duration: AppDurations.normal,
              child: SearchResultCard(
                video: video,
                onTap: () => _openDetail(video, queue: controller.trending),
                onPlay: () => _playList(controller.trending, video),
                onDownload: () => _openDetail(video, queue: controller.trending),
              ),
            )),
          ],
        ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title, ColorScheme cs, {IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: cs.primary),
            const SizedBox(width: 6),
          ],
          Text(
            title,
            style: TextStyle(
              color: cs.onSurface,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  static const Map<String, IconData> _catIcons = {
    'Music': Icons.music_note,
    'Gaming': Icons.sports_esports_outlined,
    'News': Icons.newspaper_outlined,
    'Sports': Icons.sports_outlined,
    'Entertainment': Icons.movie_outlined,
    'Education': Icons.school_outlined,
    'Science': Icons.science_outlined,
    'Comedy': Icons.theater_comedy_outlined,
    'Podcasts': Icons.podcasts_outlined,
  };

  /// Horizontal chips that jump straight into a real category search.
  Widget _buildCategoryChips(ExploreController controller, ColorScheme cs) {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: controller.categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final cat = controller.categories[index];
          return ActionChip(
            avatar: Icon(
              _catIcons[cat] ?? Icons.category_outlined,
              size: 16,
              color: cs.primary,
            ),
            label: Text(cat, style: const TextStyle(fontSize: 12.5)),
            onPressed: () {
              controller.setTab(ExploreTab.categories);
              controller.selectCategory(cat);
            },
          );
        },
      ),
    );
  }

  Widget _buildHeroCard(ExploreVideo video, ColorScheme cs,
      {List<ExploreVideo>? queue}) {
    return GestureDetector(
      onTap: () => _openDetail(video, queue: queue),
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
                gaplessPlayback: true,
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

  Widget _buildHorizontalRow(List<ExploreVideo> videos, ColorScheme cs,
      {bool showResume = false}) {
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
            key: ValueKey(video.id.isNotEmpty ? video.id : video.url),
            onTap: () => _openDetail(video, queue: videos),
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
                            gaplessPlayback: true,
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          video.title,
                          style: TextStyle(color: cs.onSurface, fontSize: 12, fontWeight: FontWeight.w500),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (showResume && video.hasResume) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Icon(Icons.play_circle_outline,
                                  size: 13, color: cs.primary),
                              const SizedBox(width: 3),
                              Text(
                                video.resumeLabel,
                                style: TextStyle(
                                    color: cs.primary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ],
                      ],
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

    final groups = controller.categoryGroups;
    const groupIcons = {
      'Música': Icons.music_note,
      'Video': Icons.videocam_outlined,
      'Audio': Icons.podcasts,
      'Series': Icons.movie_outlined,
    };
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        GestureDetector(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ShortsView()),
          ),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  cs.primary,
                  cs.primary.withValues(alpha: 0.6),
                ],
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const Icon(Icons.slow_motion_video,
                    color: Colors.white, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        loc.shortsSection,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        loc.watchShorts,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: Colors.white),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        for (final entry in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8, top: 8),
            child: Row(
              children: [
                Icon(groupIcons[entry.key] ?? Icons.category_outlined,
                    color: cs.primary, size: 20),
                const SizedBox(width: 8),
                Text(
                  entry.key,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: entry.value
                .map((category) => ActionChip(
                      label: Text(category,
                          style: const TextStyle(fontSize: 13)),
                      onPressed: () => controller.selectCategory(category),
                    ))
                .toList(),
          ),
        ],
      ],
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
                  itemCount: controller.categoryResults.length + 1,
                  itemBuilder: (context, index) {
                    if (index >= controller.categoryResults.length) {
                      if (controller.categoryExhausted) {
                        return const SizedBox.shrink();
                      }
                      if (!controller.loadingMore) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) controller.loadMoreCategory();
                        });
                      }
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final video = controller.categoryResults[index];
                    final queue = controller.categoryResults;
                    return SearchResultCard(
                      key: ValueKey(
                          video.id.isNotEmpty ? video.id : video.url),
                      video: video,
                      onTap: () => _openDetail(video, queue: queue),
                      onPlay: () => _playList(queue, video),
                      onDownload: () => _openDetail(video, queue: queue),
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
    return Column(
      children: [
        _buildSortChips(controller),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              if (controller.query.isNotEmpty) {
                controller.searchImmediate(controller.query);
              }
            },
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: controller.results.length + 1,
              itemBuilder: (context, index) {
                if (index >= controller.results.length) {
                  return _buildLoadMore(controller);
                }
                final video = controller.results[index];
                final queue = controller.results;
                return FadeSlideIn(
                  key: ValueKey(video.url),
                  duration: AppDurations.normal,
                  child: SearchResultCard(
                    video: video,
                    onTap: () => _openDetail(video, queue: queue),
                    onPlay: () => _playList(queue, video),
                    onDownload: () => _openDetail(video, queue: queue),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// Ordering chips: sort (relevance / views) + date window. Both run real
  /// server-side queries again, never a local re-sort of the same page.
  Widget _buildSortChips(ExploreController controller) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    Widget chip(String label, String value, String group, bool selected) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label, style: const TextStyle(fontSize: 12)),
          selected: selected,
          onSelected: (_) {
            if (group == 'sort') {
              controller.setSort(value);
            } else {
              controller.setWhen(value);
            }
          },
          selectedColor: cs.primary,
          labelStyle: TextStyle(
            color: selected ? Colors.white : cs.onSurfaceVariant,
            fontSize: 12,
          ),
          visualDensity: VisualDensity.compact,
        ),
      );
    }

    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
        children: [
          chip(loc.sortRelevance, 'relevance', 'sort',
              controller.sort == 'relevance'),
          chip(loc.sortViews, 'views', 'sort', controller.sort == 'views'),
          Container(
            width: 1,
            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
            color: cs.outlineVariant,
          ),
          chip(loc.whenAny, 'any', 'when', controller.when == 'any'),
          chip(loc.whenHour, 'hour', 'when', controller.when == 'hour'),
          chip(loc.whenToday, 'today', 'when', controller.when == 'today'),
          chip(loc.whenWeek, 'week', 'when', controller.when == 'week'),
        ],
      ),
    );
  }

  /// Trailing loader: fetches the next page once when scrolled into view.
  Widget _buildLoadMore(ExploreController controller) {
    if (controller.query.isEmpty || controller.searchExhausted) {
      return const SizedBox.shrink();
    }
    if (!controller.loadingMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) controller.loadMoreResults();
      });
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(child: CircularProgressIndicator()),
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

  /// Plays [video] inside its list so next/previous walk that list.
  void _playList(List<ExploreVideo> list, ExploreVideo video) {
    if (list.isEmpty) return;
    final engine = context.read<MediaEngine>();
    final i = list.indexWhere((v) => v.url == video.url);
    engine.playExploreQueue(list, startIndex: i < 0 ? 0 : i);
  }

  void _openDetail(ExploreVideo video, {List<ExploreVideo>? queue}) {
    Navigator.push(
      context,
      PageSlideTransition(
        page: ChangeNotifierProvider.value(
          value: context.read<ExploreController>(),
          child: VideoDetailView(video: video, queue: queue),
        ),
      ),
    );
  }

  /// Reads the clipboard and resolves the link through the provider
  /// resolver: playable links start playback, the rest are reported
  /// honestly with a download path.
  Future<void> _pasteLinkSheet() async {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty || !MediaProviderResolver.looksLikeLink(text)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(loc.shareInvalidUrl),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    final controller = context.read<ExploreController>();
    final future = controller.resolveLink(text);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => FutureBuilder(
        future: future,
        builder: (context, snapshot) {
          final loading = snapshot.connectionState != ConnectionState.done;
          final result = controller.linkResult;
          final err = controller.linkError;
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.link, color: cs.primary, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      loc.pasteLink,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (result == null || result.video == null) ...[
                  Text(
                    err != null ? loc.linkResolveFailed : loc.linkNotPlayable,
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: Text(loc.close),
                    ),
                  ),
                ] else ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (result.video!.thumbnail != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(
                            result.video!.thumbnail!,
                            width: 110,
                            height: 62,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              width: 110,
                              height: 62,
                              color: cs.surfaceContainerHighest,
                            ),
                          ),
                        ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              result.video!.title.isEmpty
                                  ? text
                                  : result.video!.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: cs.onSurface,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              [
                                if (result.video!.channel != null &&
                                    result.video!.channel!.isNotEmpty)
                                  result.video!.channel!,
                                result.provider,
                              ].join(' • '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: cs.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (!result.playable) ...[
                    const SizedBox(height: 12),
                    Text(
                      loc.linkNotPlayable,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      if (result.playable)
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () {
                              Navigator.pop(sheetContext);
                              final video = result.video!;
                              context
                                  .read<MediaEngine>()
                                  .playExploreVideo(video);
                              _openDetail(video);
                            },
                            icon: const Icon(Icons.play_arrow, size: 20),
                            label: Text(loc.playVideo),
                          ),
                        ),
                      if (result.playable) const SizedBox(width: 10),
                      if (!result.playable || !result.downloadable)
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(sheetContext),
                            child: Text(loc.close),
                          ),
                        )
                      else
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () {
                              Navigator.pop(sheetContext);
                              final video = result.video!;
                              _openDetail(video);
                            },
                            icon: const Icon(Icons.download_outlined,
                                size: 18),
                            label: Text(loc.downloadVideo,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
    controller.clearLink();
  }
}
