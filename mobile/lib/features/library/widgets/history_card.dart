import 'dart:io';
import 'package:flutter/material.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../services/media_metadata_service.dart';

class HistoryCard extends StatelessWidget {
  final HistoryEntry entry;
  final MediaMetadata? metadata;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  final String? thumbnailPath;

  const HistoryCard({
    super.key,
    required this.entry,
    this.metadata,
    this.onTap,
    this.onRemove,
    this.thumbnailPath,
  });

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final meta = metadata;
    final cs = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
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
                      entry.title,
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
                          _typeIcon,
                          size: 14,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _formatTimestamp(entry.playedAt, loc),
                          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                        ),
                      ],
                    ),
                    if (meta != null &&
                        meta.lastPositionMs > 0 &&
                        meta.durationMs > 0)
                      _buildResumeBadge(meta, loc, cs),
                  ],
                ),
              ),
              if (onRemove != null)
                IconButton(
                  tooltip: loc.removeFromHistory,
                  icon: Icon(Icons.close_rounded,
                      size: 18, color: cs.onSurfaceVariant),
                  onPressed: onRemove,
                ),
          ],
        ),
      ),
    ),
    );
  }

  Widget _buildThumbnail(ColorScheme cs) {
    if (thumbnailPath != null && thumbnailPath!.isNotEmpty) {
      final imgFile = File(thumbnailPath!);
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
    if (entry.thumbnail != null && entry.thumbnail!.isNotEmpty) {
      return Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: cs.surfaceContainerHighest,
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.network(
          entry.thumbnail!,
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
      child: Icon(_typeIcon, color: cs.primary, size: 24),
    );
  }

  Widget _buildResumeBadge(MediaMetadata meta, AppLocalizations loc, ColorScheme cs) {
    final remaining = meta.durationMs - meta.lastPositionMs;
    if (remaining <= 0) return const SizedBox.shrink();
    final text = '${loc.resumeLeft} ${_formatDuration(remaining)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(color: cs.primary, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }

  IconData get _typeIcon {
    switch (entry.fileType) {
      case 'audio':
        return Icons.audiotrack;
      case 'video':
        return Icons.videocam;
      default:
        return Icons.file_present;
    }
  }

  String _formatTimestamp(String isoDate, AppLocalizations loc) {
    final dt = DateTime.tryParse(isoDate);
    if (dt == null) return '';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return loc.justNow;
    if (diff.inHours < 1) return loc.minutesAgo(diff.inMinutes);
    if (diff.inDays < 1) return loc.hoursAgo(diff.inHours);
    if (diff.inDays < 7) return loc.daysAgo(diff.inDays);
    return '${dt.day}/${dt.month}/${dt.year}';
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
