import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../data/models/library_file.dart';
import '../../../services/media_metadata_service.dart';

class LibraryListTile extends StatelessWidget {
  final LibraryFile file;
  final bool isFavorite;
  final VoidCallback? onTap;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onDelete;
  final VoidCallback? onVault;
  final VoidCallback? onDeleteForever;

  const LibraryListTile({
    super.key,
    required this.file,
    this.isFavorite = false,
    this.onTap,
    this.onToggleFavorite,
    this.onDelete,
    this.onVault,
    this.onDeleteForever,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final metaService = context.read<MediaMetadataService>();
    final resumeMs = metaService.getResumePosition(file.filename);
    final hasResume = resumeMs > 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(
                          file.isVideo ? Icons.videocam : Icons.audiotrack,
                          size: 13,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _formatSize(file.fileSize),
                          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                        ),
                        if (hasResume) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: cs.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              _formatDuration(resumeMs),
                              style: TextStyle(color: cs.primary, fontSize: 10, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (onToggleFavorite != null)
                IconButton(
                  icon: Icon(
                    isFavorite ? Icons.favorite : Icons.favorite_border,
                    color: isFavorite ? AppColors.error : cs.onSurfaceVariant,
                    size: 18,
                  ),
                  onPressed: onToggleFavorite,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: cs.onSurfaceVariant, size: 18),
                onSelected: (value) {
                  if (value == 'delete') onDelete?.call();
                  if (value == 'vault') onVault?.call();
                  if (value == 'deleteForever') onDeleteForever?.call();
                },
                itemBuilder: (_) => [
                  if (onVault != null)
                    PopupMenuItem(
                      value: 'vault',
                      child: Text(AppLocalizations.of(context).vaultMoveAction,
                          style: const TextStyle(fontSize: 13)),
                    ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(AppLocalizations.of(context).delete,
                        style:
                            TextStyle(color: AppColors.error, fontSize: 13)),
                  ),
                  if (onDeleteForever != null)
                    PopupMenuItem(
                      value: 'deleteForever',
                      child: Text(
                        AppLocalizations.of(context).deleteForever,
                        style: TextStyle(color: AppColors.error, fontSize: 13),
                      ),
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
          width: 44,
          height: 44,
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
        width: 44,
        height: 44,
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
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: cs.primary.withValues(alpha: 0.1),
      ),
      child: Icon(
        file.isVideo ? Icons.videocam : Icons.audiotrack,
        color: cs.primary,
        size: 22,
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
