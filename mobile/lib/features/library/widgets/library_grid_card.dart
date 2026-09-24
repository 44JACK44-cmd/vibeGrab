import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_animations.dart';
import '../../../data/models/library_file.dart';
import '../../../services/media_metadata_service.dart';

class LibraryGridCard extends StatelessWidget {
  final LibraryFile file;
  final bool isFavorite;
  final VoidCallback? onTap;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onDelete;

  const LibraryGridCard({
    super.key,
    required this.file,
    this.isFavorite = false,
    this.onTap,
    this.onToggleFavorite,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final metaService = context.read<MediaMetadataService>();
    final resumeMs = metaService.getResumePosition(file.filename);
    final hasResume = resumeMs > 0;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildThumbnail(cs),
                  if (hasResume)
                    Positioned(
                      bottom: 6,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _formatDuration(resumeMs),
                          style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: AnimatedHeart(
                      isActive: isFavorite,
                      size: 22,
                      activeColor: AppColors.error,
                      inactiveColor: Colors.white.withValues(alpha: 0.7),
                      onTap: onToggleFavorite,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.title,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        Icon(
                          file.isVideo ? Icons.videocam : Icons.audiotrack,
                          size: 12,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _formatSize(file.fileSize),
                          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(ColorScheme cs) {
    if (file.thumbnailPath != null && file.thumbnailPath!.isNotEmpty) {
      final imgFile = File(file.thumbnailPath!);
      if (imgFile.existsSync()) {
        return Image.file(
          imgFile,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildIconPlaceholder(cs),
        );
      }
    }
    if (file.thumbnail != null && file.thumbnail!.isNotEmpty) {
      return Image.network(
        file.thumbnail!,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildIconPlaceholder(cs),
      );
    }
    return _buildIconPlaceholder(cs);
  }

  Widget _buildIconPlaceholder(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: Icon(
          file.isVideo ? Icons.videocam : Icons.audiotrack,
          color: cs.primary,
          size: 32,
        ),
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
