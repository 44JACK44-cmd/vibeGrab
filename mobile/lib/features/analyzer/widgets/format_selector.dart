import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../data/models/format_option.dart';

class FormatSelector extends StatelessWidget {
  final List<FormatOption> audioFormats;
  final List<FormatOption> videoFormats;
  final ValueChanged<FormatOption> onSelected;
  final String? recommendedId;

  const FormatSelector({
    super.key,
    required this.audioFormats,
    required this.videoFormats,
    required this.onSelected,
    this.recommendedId,
  });

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (videoFormats.isNotEmpty) ...[
          _buildSectionHeader(loc.formatVideo, Icons.videocam_rounded, cs.primary),
          const SizedBox(height: 8),
          ...videoFormats.map((f) => _FormatTile(
            format: f,
            recommended: recommendedId != null && recommendedId == f.id,
            onTap: () => onSelected(f),
            accentColor: cs.primary,
            actionLabel: loc.downloadAsVideo,
          )),
          const SizedBox(height: 20),
        ],
        if (audioFormats.isNotEmpty) ...[
          _buildSectionHeader(loc.formatAudio, Icons.music_note_rounded, cs.secondary),
          const SizedBox(height: 8),
          Text(
            loc.downloadAsMusic,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
          const SizedBox(height: 8),
          ...audioFormats.map((f) => _FormatTile(
            format: f,
            recommended: recommendedId != null && recommendedId == f.id,
            onTap: () => onSelected(f),
            accentColor: cs.secondary,
            actionLabel: loc.downloadAsMusic,
          )),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(String label, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: color,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

class _FormatTile extends StatelessWidget {
  final FormatOption format;
  final VoidCallback onTap;
  final Color accentColor;
  final String actionLabel;
  final bool recommended;

  const _FormatTile({
    required this.format,
    required this.onTap,
    required this.accentColor,
    required this.actionLabel,
    this.recommended = false,
  });

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final isAudio = format.type == 'audio';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    isAudio ? Icons.music_note_rounded : Icons.play_circle_outline,
                    color: accentColor,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        format.label,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: cs.onSurface,
                        ),
                      ),
                      if (!isAudio && !format.hasAudio) ...[
                        const SizedBox(height: 2),
                        Text(
                          'No audio',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.warning,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                      if (recommended) ...[
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: accentColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.star_rounded, size: 12, color: accentColor),
                              const SizedBox(width: 4),
                              Text(
                                loc.recommendedFormat,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: accentColor,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: accentColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.download_rounded, color: Colors.white, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        actionLabel,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
