import 'package:flutter/material.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../core/theme/app_colors.dart';
import '../../../services/storage_service.dart';
import '../../../services/trash_service.dart';

class TrashView extends StatefulWidget {
  const TrashView({super.key});

  @override
  State<TrashView> createState() => _TrashViewState();
}

class _TrashViewState extends State<TrashView> {
  List<TrashEntry> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await TrashService.instance.list();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _confirmEmpty(AppLocalizations loc) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.emptyTrash),
        content: Text(loc.emptyTrashConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(loc.cancel),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await TrashService.instance.emptyTrash();
              _snack(loc.emptyTrash);
              _load();
            },
            child: Text(loc.emptyTrash, style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteForever(TrashEntry entry, AppLocalizations loc) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.deleteForever),
        content: Text(entry.filename),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(loc.cancel),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await TrashService.instance.deleteForever(entry);
              _load();
            },
            child: Text(loc.delete, style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  Future<void> _restore(TrashEntry entry, AppLocalizations loc) async {
    await TrashService.instance.restore(entry);
    _snack(loc.trashRestored);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.trash),
        actions: [
          if (_entries.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: loc.emptyTrash,
              onPressed: () => _confirmEmpty(loc),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.delete_outline,
                          size: 64, color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
                      const SizedBox(height: 12),
                      Text(
                        loc.trashEmpty,
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 15),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.schedule, size: 16, color: cs.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              loc.trashHint,
                              style: TextStyle(
                                color: cs.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        itemCount: _entries.length,
                        itemBuilder: (context, index) =>
                            _buildTile(_entries[index], loc, cs),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _buildTile(
      TrashEntry entry, AppLocalizations loc, ColorScheme cs) {
    final base = TrashService.baseNameOf(entry.filename);
    final ext = entry.filename.contains('.')
        ? entry.filename.substring(entry.filename.lastIndexOf('.') + 1)
        : '';
    final isVideo = StorageService.fileTypeFor(ext) == 'video';

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: cs.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            isVideo ? Icons.videocam_outlined : Icons.audiotrack_outlined,
            color: cs.primary,
            size: 22,
          ),
        ),
        title: Text(
          base,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          StorageService.formatSize(entry.size),
          style: TextStyle(
            fontSize: 12,
            color: cs.onSurfaceVariant,
          ),
        ),
        trailing: PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, color: cs.onSurfaceVariant, size: 20),
          onSelected: (value) {
            if (value == 'restore') _restore(entry, loc);
            if (value == 'forever') _confirmDeleteForever(entry, loc);
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'restore',
              child: Row(
                children: [
                  const Icon(Icons.restore, size: 18),
                  const SizedBox(width: 10),
                  Text(loc.restore),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'forever',
              child: Row(
                children: [
                  const Icon(Icons.delete_forever, size: 18, color: AppColors.error),
                  const SizedBox(width: 10),
                  Text(loc.deleteForever,
                      style: const TextStyle(color: AppColors.error)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
