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
                tooltip: ctrl.viewMode == LibraryViewMode.grid ? 'List view' : 'Grid view',
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
          Expanded(
            child: Consumer<LibraryController>(
              builder: (context, controller, _) {
                switch (controller.status) {
                  case LibraryStatus.loading:
                    return const Center(child: CircularProgressIndicator());
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
              hintText: 'Search library...',
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
                        _sortLabel(controller.sort),
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                      ),
                      const SizedBox(width: 2),
                      Icon(Icons.arrow_drop_down, size: 16, color: cs.onSurfaceVariant),
                    ],
                  ),
                ),
                onSelected: (sort) => controller.setSort(sort),
                itemBuilder: (_) => [
                  _sortMenuItem(LibrarySort.dateNewest, 'Newest first'),
                  _sortMenuItem(LibrarySort.dateOldest, 'Oldest first'),
                  _sortMenuItem(LibrarySort.nameAsc, 'Name A-Z'),
                  _sortMenuItem(LibrarySort.nameDesc, 'Name Z-A'),
                  _sortMenuItem(LibrarySort.sizeLargest, 'Largest'),
                  _sortMenuItem(LibrarySort.sizeSmallest, 'Smallest'),
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

  String _sortLabel(LibrarySort sort) {
    switch (sort) {
      case LibrarySort.dateNewest: return 'Newest';
      case LibrarySort.dateOldest: return 'Oldest';
      case LibrarySort.nameAsc: return 'A-Z';
      case LibrarySort.nameDesc: return 'Z-A';
      case LibrarySort.sizeLargest: return 'Largest';
      case LibrarySort.sizeSmallest: return 'Smallest';
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
            file: file,
            isFavorite: controller.meta.isFavorite(file.filename),
            onTap: () => _playFile(context, file),
            onToggleFavorite: () => controller.toggleFavorite(file.filename),
            onDelete: () => controller.deleteFile(file.filename),
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
            file: file,
            isFavorite: controller.meta.isFavorite(file.filename),
            onTap: () => _playFile(context, file),
            onToggleFavorite: () => controller.toggleFavorite(file.filename),
            onDelete: () => controller.deleteFile(file.filename),
          );
        },
      ),
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
