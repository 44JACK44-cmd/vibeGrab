import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_animations.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../data/models/library_file.dart';
import '../../../services/media_engine.dart';
import '../../media_player/views/video_player_view.dart';
import '../controllers/library_controller.dart';
import '../widgets/library_grid_card.dart';
import '../widgets/history_card.dart';
import '../widgets/library_list_tile.dart';

import 'liked_videos_view.dart';

class LibraryView extends StatefulWidget {
  const LibraryView({super.key});

  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView> {
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<LibraryController>().loadLibrary();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.libraryTitle),
        actions: [
          Consumer<LibraryController>(
            builder: (context, ctrl, _) {
              return IconButton(
                icon: Icon(ctrl.viewMode == LibraryViewMode.grid
                    ? Icons.view_list_outlined
                    : Icons.grid_view_outlined),
                tooltip: ctrl.viewMode == LibraryViewMode.grid ? loc.listView : loc.gridView,
                onPressed: () => ctrl.toggleViewMode(),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: loc.refresh,
            onPressed: () => context.read<LibraryController>().loadLibrary(),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSearchBar(loc, cs),
          _buildFilterTabs(context, loc, cs),
          _buildSortBar(loc, cs),
          _buildLikesHeader(context, loc, cs),
          Expanded(
            child: Consumer<LibraryController>(
              builder: (context, controller, _) {
                switch (controller.status) {
                  case LibraryStatus.loading:
                    // Never replace a populated list with a spinner: this
                    // view reloads on every app resume and the blink was
                    // read as a glitch.
                    if (controller.files.isEmpty &&
                        controller.filter != LibraryFilter.history) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return controller.filter == LibraryFilter.history
                        ? _buildHistory(controller, loc)
                        : (controller.files.isEmpty
                            ? _buildEmpty(loc, cs)
                            : (controller.viewMode == LibraryViewMode.grid
                                ? _buildFileGrid(controller, loc, cs)
                                : _buildFileList(controller, loc, cs)));
                  case LibraryStatus.permissionRequired:
                    return _buildPermissionRequired(loc, cs, controller);
                  case LibraryStatus.empty:
                    return _buildEmpty(loc, cs);
                  case LibraryStatus.error:
                    return _buildError(controller, loc, cs);
                  case LibraryStatus.loaded:
                    if (controller.filter == LibraryFilter.history) {
                      return _buildHistory(controller, loc);
                    }
                    if (controller.files.isEmpty) {
                      return _buildEmpty(loc, cs);
                    }
                    return controller.viewMode == LibraryViewMode.grid
                        ? _buildFileGrid(controller, loc, cs)
                        : _buildFileList(controller, loc, cs);
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(AppLocalizations loc, ColorScheme cs) {
    return Consumer<LibraryController>(
      builder: (context, controller, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            onChanged: (value) => controller.setSearchQuery(value),
            decoration: InputDecoration(
              hintText: loc.searchLibrary,
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: controller.searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 20),
                      onPressed: () {
                        _searchController.clear();
                        controller.setSearchQuery('');
                      },
                    )
                  : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSortBar(AppLocalizations loc, ColorScheme cs) {
    return Consumer<LibraryController>(
      builder: (context, controller, _) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Icon(Icons.sort, size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 4),
              PopupMenuButton<LibrarySort>(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _sortLabel(controller.sort, loc),
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                      ),
                      const SizedBox(width: 2),
                      Icon(Icons.arrow_drop_down, size: 16, color: cs.onSurfaceVariant),
                    ],
                  ),
                ),
                onSelected: (sort) => controller.setSort(sort),
                itemBuilder: (_) => [
                  _sortMenuItem(LibrarySort.dateNewest, loc.sortNewestFirst),
                  _sortMenuItem(LibrarySort.dateOldest, loc.sortOldestFirst),
                  _sortMenuItem(LibrarySort.nameAsc, loc.sortNameAsc),
                  _sortMenuItem(LibrarySort.nameDesc, loc.sortNameDesc),
                  _sortMenuItem(LibrarySort.sizeLargest, loc.sortLargest),
                  _sortMenuItem(LibrarySort.sizeSmallest, loc.sortSmallest),
                ],
              ),
              const Spacer(),
              Text(
                loc.fileCount(controller.files.length),
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
              ),
              const SizedBox(width: 8),
              Text(
                _totalSize(controller.files),
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }

  PopupMenuItem<LibrarySort> _sortMenuItem(LibrarySort sort, String label) {
    return PopupMenuItem(value: sort, child: Text(label, style: const TextStyle(fontSize: 14)));
  }

  String _sortLabel(LibrarySort sort, AppLocalizations loc) {
    switch (sort) {
      case LibrarySort.dateNewest: return loc.sortLabelNewest;
      case LibrarySort.dateOldest: return loc.sortLabelOldest;
      case LibrarySort.nameAsc: return loc.sortLabelAsc;
      case LibrarySort.nameDesc: return loc.sortLabelDesc;
      case LibrarySort.sizeLargest: return loc.sortLabelLargest;
      case LibrarySort.sizeSmallest: return loc.sortLabelSmallest;
    }
  }

  Widget _buildFilterTabs(BuildContext context, AppLocalizations loc, ColorScheme cs) {
    return Consumer<LibraryController>(
      builder: (context, controller, _) {
        return Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _tab(context, controller, LibraryFilter.all, Icons.folder_outlined, loc.tabAll),
              _tab(context, controller, LibraryFilter.videos, Icons.videocam_outlined, loc.tabVideos),
              _tab(context, controller, LibraryFilter.audio, Icons.audiotrack_outlined, loc.tabAudio),
              _tab(context, controller, LibraryFilter.favorites, Icons.favorite_outline, loc.tabFavorites),
              _tab(context, controller, LibraryFilter.history, Icons.history, loc.tabHistory),
            ],
          ),
        );
      },
    );
  }

  Widget _tab(BuildContext ctx, LibraryController ctrl, LibraryFilter filter, IconData icon, String label) {
    final selected = ctrl.filter == filter;
    final cs = Theme.of(ctx).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: FilterChip(
        selected: selected,
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: selected ? Colors.white : cs.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(
              color: selected ? Colors.white : cs.onSurfaceVariant,
              fontSize: 13,
            )),
          ],
        ),
        selectedColor: cs.primary,
        checkmarkColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        onSelected: (_) => ctrl.setFilter(filter),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Widget _buildFileGrid(LibraryController controller, AppLocalizations loc, ColorScheme cs) {
    final files = controller.files;
    return RefreshIndicator(
      onRefresh: () => controller.loadLibrary(),
      child: GridView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 0.85,
        ),
        itemCount: files.length,
        itemBuilder: (context, index) {
          final file = files[index];
          return LibraryGridCard(
            key: ValueKey('grid_${file.filename}'),
            file: file,
            isFavorite: controller.meta.isFavorite(file.filename),
            onTap: () => _playFile(context, file),
            onToggleFavorite: () => controller.toggleFavorite(file.filename),
            onDelete: () async {
              await controller.deleteFile(file.filename);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(loc.movedToTrash)));
              }
            },
            onVault: () async {
              final ok = await controller.vaultFile(file.filename);
              if (ok && context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(loc.vaultMoved)));
              }
            },
          );
        },
      ),
    );
  }

  Widget _buildFileList(LibraryController controller, AppLocalizations loc, ColorScheme cs) {
    final files = controller.files;
    return RefreshIndicator(
      onRefresh: () => controller.loadLibrary(),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: files.length,
        itemBuilder: (context, index) {
          final file = files[index];
          return LibraryListTile(
            key: ValueKey('list_${file.filename}'),
            file: file,
            isFavorite: controller.meta.isFavorite(file.filename),
            onTap: () => _playFile(context, file),
            onToggleFavorite: () => controller.toggleFavorite(file.filename),
            onDeleteForever: () => _confirmDeleteForever(context, controller, file, loc),
            onDelete: () async {
              await controller.deleteFile(file.filename);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(loc.movedToTrash)));
              }
            },
            onVault: () async {
              final ok = await controller.vaultFile(file.filename);
              if (ok && context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(loc.vaultMoved)));
              }
            },
          );
        },
      ),
    );
  }

  Future<void> _confirmDeleteForever(
      BuildContext context,
      LibraryController controller,
      LibraryFile file,
      AppLocalizations loc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.deleteForeverTitle),
        content: Text(loc.deleteForeverConfirm),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(loc.cancel)),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            child: Text(loc.deleteForever),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      final done = await controller.deletePermanently(file.filename);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(done ? loc.fileDeleted : loc.errorFailedDeleteFile),
        ));
      }
    }
  }

  /// Shown only on the Favorites tab: entry to "Videos que me gustan"
  /// plus the remote audio likes (playable songs from Explorer).
  Widget _buildLikesHeader(
      BuildContext context, AppLocalizations loc, ColorScheme cs) {
    return Consumer<LibraryController>(
      builder: (context, controller, _) {
        if (controller.filter != LibraryFilter.favorites) {
          return const SizedBox.shrink();
        }
        final meta = controller.meta;
        final videos = meta.likedVideoItems;
        final audios = meta.likedAudios;
        if (videos.isEmpty && audios.isEmpty) {
          return const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (videos.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            color: cs.primary.withValues(alpha: 0.15),
                          ),
                          child: Icon(Icons.favorite,
                              color: cs.primary, size: 22),
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: cs.primary,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${videos.length}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ],
                    ),
                    title: Text(loc.likedVideosTitle,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const LikedVideosView()),
                    ),
                  ),
                ),
              ),
            if (audios.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  loc.onlineLikes,
                  style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
              SizedBox(
                height: 148,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: audios.length,
                  itemBuilder: (context, i) {
                    final a = audios[i];
                    return OnlineLikeCard(
                        key: ValueKey('online_${a.url}'), like: a);
                  },
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  void _playFile(BuildContext context, LibraryFile file) {
    final engine = context.read<MediaEngine>();
    final controller = context.read<LibraryController>();

    final allFiles = controller.files;
    final audioFiles = allFiles.where((f) => f.isAudio).toList();
    final videoFiles = allFiles.where((f) => f.isVideo).toList();
    final playlist = file.isAudio ? audioFiles : videoFiles;

    engine.setQueueFromFiles(playlist, startIndex: playlist.indexWhere((f) => f.filename == file.filename).clamp(0, playlist.length - 1));

    if (file.isVideo) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChangeNotifierProvider.value(
            value: engine,
            child: VideoPlayerView(file: file),
          ),
        ),
      );
    } else {
      engine.playFile(file);
    }
  }

  Widget _buildHistory(LibraryController controller, AppLocalizations loc) {
    final history = controller.history;
    if (history.isEmpty) {
      return _buildEmpty(loc, Theme.of(context).colorScheme);
    }
    return RefreshIndicator(
      onRefresh: () => controller.loadLibrary(),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: history.length,
        itemBuilder: (context, index) {
          final entry = history[index];
          final file = controller.findFile(entry.filename);
          return HistoryCard(
            key: ValueKey('hist_${entry.filename}_$index'),
            entry: entry,
            metadata: controller.meta.getMeta(entry.filename),
            thumbnailPath: file?.thumbnailPath,
            onTap: file != null
                ? () {
                    final engine = context.read<MediaEngine>();
                    engine.setQueueFromFiles(controller.files.where((f) => f.isAudio).toList(), startIndex: 0);
                    engine.playFile(file);
                  }
                : null,
            onRemove: () => controller.removeFromHistory(entry.filename),
          );
        },
      ),
    );
  }

  Widget _buildPermissionRequired(AppLocalizations loc, ColorScheme cs, LibraryController controller) {
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
                child: Icon(Icons.perm_media_outlined, size: 40, color: cs.primary.withValues(alpha: 0.5)),
              ),
              const SizedBox(height: 24),
              Text(
                loc.permissionRequiredTitle,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                loc.permissionRequiredHint,
                style: TextStyle(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                  fontSize: 14,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              ElevatedButton.icon(
                onPressed: () => controller.requestPermissions(),
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: Text(loc.grantPermission),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(180, 44),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () async => await openAppSettings(),
                child: Text(loc.openSettings),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildError(LibraryController controller, AppLocalizations loc, ColorScheme cs) {
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
                color: AppColors.error.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.error_outline, size: 36, color: AppColors.error),
            ),
            const SizedBox(height: 20),
            Text(
              _translateError(loc, controller.errorKey!),
              style: TextStyle(color: cs.onSurface, fontSize: 15, fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () => controller.loadLibrary(),
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

  Widget _buildEmpty(AppLocalizations loc, ColorScheme cs) {
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
                child: Icon(Icons.library_music_outlined, size: 40, color: cs.primary.withValues(alpha: 0.5)),
              ),
              const SizedBox(height: 24),
              Text(
                loc.noFiles,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                loc.noFilesHint,
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

  String _totalSize(List<LibraryFile> files) {
    int total = 0;
    for (final f in files) {
      total += f.fileSize;
    }
    if (total < 1024 * 1024) return '${(total / 1024).toStringAsFixed(0)} KB';
    if (total < 1024 * 1024 * 1024) return '${(total / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(total / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _translateError(AppLocalizations loc, String key) {
    switch (key) {
      case 'errorFailedLoadLibrary': return loc.errorFailedLoadLibrary;
      case 'errorFailedDeleteFile': return loc.errorFailedDeleteFile;
      default: return key;
    }
  }
}
