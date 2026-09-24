import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../data/models/library_file.dart';
import '../../../services/media_metadata_service.dart';
import '../../../services/media_engine.dart';
import '../../media_player/views/video_player_view.dart';
import '../controllers/library_controller.dart';

class LibraryCard extends StatelessWidget {
  final LibraryFile file;
  final VoidCallback onDelete;
  final VoidCallback? onToggleFavorite;
  final bool isFavorite;

  const LibraryCard({
    super.key,
    required this.file,
    required this.onDelete,
    this.onToggleFavorite,
    this.isFavorite = false,
  });

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final metaService = context.read<MediaMetadataService>();
    final resumeMs = metaService.getResumePosition(file.filename);
    final hasResume = resumeMs > 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          if (file.isVideo) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChangeNotifierProvider.value(
                  value: context.read<MediaEngine>(),
                  child: VideoPlayerView(file: file),
                ),
              ),
            );
          } else {
            context.read<MediaEngine>().playFile(file);
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              _buildThumbnail(cs),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.title,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          file.isVideo ? Icons.videocam : Icons.audiotrack,
                          size: 14,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          file.fileType.toUpperCase(),
                          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatSize(file.fileSize),
                          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                        ),
                      ],
                    ),
                    if (hasResume) ...[
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${loc.resumeLeft} ${_formatDuration(resumeMs)}',
                          style: TextStyle(
                            color: cs.primary,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onToggleFavorite != null)
                IconButton(
                  icon: Icon(
                    isFavorite ? Icons.favorite : Icons.favorite_border,
                    color: isFavorite ? AppColors.error : cs.onSurfaceVariant,
                    size: 20,
                  ),
                  onPressed: onToggleFavorite,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: cs.onSurfaceVariant, size: 20),
                onSelected: (value) => _handleMenuAction(context, value, loc),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'open', child: Text(loc.openFile)),
                  PopupMenuItem(value: 'info', child: Text(loc.fileInfo)),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(loc.delete, style: TextStyle(color: AppColors.error)),
                  ),
                ],
                padding: EdgeInsets.zero,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail(ColorScheme cs) {
    if (file.thumbnailPath != null && file.thumbnailPath!.isNotEmpty) {
      final imgFile = File(file.thumbnailPath!);
      if (imgFile.existsSync()) {
        return Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: cs.surfaceContainerHighest,
          ),
          clipBehavior: Clip.antiAlias,
          child: Image.file(
            imgFile,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _buildIconPlaceholder(cs),
          ),
        );
      }
    }
    if (file.thumbnail != null && file.thumbnail!.isNotEmpty) {
      return Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: cs.surfaceContainerHighest,
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.network(
          file.thumbnail!,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildIconPlaceholder(cs),
        ),
      );
    }
    return _buildIconPlaceholder(cs);
  }

  Widget _buildIconPlaceholder(ColorScheme cs) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: cs.primary.withValues(alpha: 0.1),
      ),
      child: Icon(
        file.isVideo ? Icons.videocam : Icons.audiotrack,
        color: cs.primary,
        size: 24,
      ),
    );
  }

  void _handleMenuAction(BuildContext context, String action, AppLocalizations loc) {
    switch (action) {
      case 'open':
        if (file.isVideo) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChangeNotifierProvider.value(
                value: context.read<MediaEngine>(),
                child: VideoPlayerView(file: file),
              ),
            ),
          );
        } else {
          context.read<MediaEngine>().playFile(file);
        }
        break;
      case 'info':
        _showFileInfo(context, loc);
        break;
      case 'delete':
        _confirmDelete(context, loc);
        break;
    }
  }

  void _showFileInfo(BuildContext context, AppLocalizations loc) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.fileInfo),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infoRow(loc.titleLabel, file.title, Theme.of(context).colorScheme),
            _infoRow(loc.fileName, file.filename, Theme.of(context).colorScheme),
            _infoRow(loc.typeLabel, file.fileType, Theme.of(context).colorScheme),
            _infoRow(loc.sizeLabel, _formatSize(file.fileSize), Theme.of(context).colorScheme),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(loc.close),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(color: cs.onSurface, fontSize: 14)),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, AppLocalizations loc) {
    final libraryController = context.read<LibraryController>();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.deleteConfirmTitle),
        content: Text(loc.deleteConfirmContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(loc.cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              libraryController.deleteFile(file.filename);
            },
            child: Text(loc.delete, style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatDuration(int ms) {
    final d = Duration(milliseconds: ms);
    final hours = d.inHours;
    final mins = d.inMinutes.remainder(60);
    final secs = d.inSeconds.remainder(60);
    if (hours > 0) return '${hours}h ${mins}m';
    if (mins > 0) return '${mins}m ${secs}s';
    return '${secs}s';
  }
}
